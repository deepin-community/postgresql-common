use strict;

use lib 't';
use TestLib;
use PgCommon;

use Test::More;
use Time::HiRes qw/usleep/;

my ($pg_uid, $pg_gid) = (getpwnam 'postgres')[2,3];
my $systemd = (-d "/run/systemd/system" and not $ENV{_SYSTEMCTL_SKIP_REDIRECT});
note $systemd ? "We are running systemd" : "We are not running systemd";

foreach my $v (@MAJORS) {
    if ($v < 9.1) {
        ok 1, "pg_backupcluster not supported on $v";
        next;
    }
    note "PostgreSQL $v";

    note "create cluster";
    program_ok 0, "pg_createcluster --locale en_US.UTF-8 $v main --start";
    like_program_out 0, "pg_lsclusters -h", 0, qr/$v main 5432 online/;
    program_ok 0, "pg_conftool $v main set work_mem 11MB";
    if ($v <= 9.6) {
        open my $hba, ">>", "/etc/postgresql/$v/main/pg_hba.conf";
        print $hba "local replication all peer\n";
        close $hba;
        program_ok 0, "pg_conftool $v main set max_wal_senders 10";
        program_ok 0, "pg_conftool $v main set wal_level archive";
        program_ok 0, "pg_conftool $v main set max_replication_slots 10" if ($v >= 9.4);
        program_ok 0, "pg_conftool $v main set ssl off" if ($v <= 9.1); # cert symlinks not backed up in 9.1
        program_ok 0, "pg_ctlcluster $v main restart";
    }
    my $locale_provider = $v >= 15 ? "--locale-provider libc " : "";
    program_ok $pg_uid, "createdb -E SQL_ASCII $locale_provider-T template0 mydb";
    program_ok $pg_uid, "psql -c 'alter database mydb set search_path=public'";
    program_ok $pg_uid, "psql -c 'create table foo (t text)' mydb";
    program_ok $pg_uid, "psql -c \"insert into foo values ('data from backup')\" mydb";
    program_ok $pg_uid, "psql -c 'CREATE USER myuser'";
    program_ok $pg_uid, "psql -c 'alter role myuser set search_path=public, myschema'";
    program_ok $pg_uid, "createdb --locale-provider icu --icu-locale de -T template0 myicudb" if ($v >= 15);

    SKIP: { # in PG 10, ARID is part of globals.sql which we try to restore before databases.sql
        skip "alter role in database handling in PG <= 10 not supported", 1 if ($v <= 10);
        program_ok $pg_uid, "psql -c 'alter role myuser in database mydb set search_path=public, myotherschema'";
    }

    note "create directory";
    program_ok 0, "pg_backupcluster $v main createdirectory";
    my $dir = "/var/backups/postgresql/$v-main";
    my @stat = stat $dir;
    is $stat[4], $pg_uid, "$dir owned by uid postgres";
    is $stat[5], $pg_gid, "$dir owned by gid postgres";

    my @backups = ();
    my $dump = '';
    SKIP: {
        skip "dump not supported before 9.3", 1 if ($v < 9.3);
        note "dump";
        if ($systemd) {
            program_ok 0, "systemctl start pg_dump\@$v-main";
        } else {
            program_ok 0, "pg_backupcluster $v main dump";
        }
        ($dump) = glob "$dir/*.dump";
        ok -d $dump, "dump created in $dump";
        @stat = stat $dump;
        is $stat[4], $pg_uid, "$dump owned by uid postgres";
        is $stat[5], $pg_gid, "$dump owned by gid postgres";
        push @backups, $dump;
    }

    note "basebackup";
    my $receivewal_pid;
    if ($v >= 9.5) {
        if ($systemd) {
            program_ok 0, "systemctl start pg_receivewal\@$v-main";
        } else {
            $receivewal_pid = fork;
            if ($receivewal_pid == 0) {
                # suppress "not renaming "000000010000000000000003.gz.partial", segment is not complete"
                exec "pg_backupcluster $v main receivewal 2>/dev/null";
            }
        }
        program_ok $pg_uid, "psql -c 'create table poke_receivewal (t text)' mydb";
        usleep($delay);
        my $wal = "000000010000000000000001";
        $wal .= ".gz" if ($v >= 10);
        $wal .= ".partial";
        TODO: {
        local $TODO = "WAL test is unstable";
        ok_dir "$dir/wal", [$wal], "$dir/wal contains $wal";
        }
    }
    if ($systemd) {
        program_ok 0, "systemctl start pg_basebackup\@$v-main";
    } else {
        program_ok 0, "pg_backupcluster --checkpoint=fast $v main basebackup";
    }
    my ($basebackup) = glob "$dir/*.backup";
    ok -d $basebackup, "dump created in $basebackup";
    @stat = stat $basebackup;
    is $stat[4], $pg_uid, "$basebackup owned by uid postgres";
    is $stat[5], $pg_gid, "$basebackup owned by gid postgres";
    push @backups, $basebackup;

    note "list";
    like_program_out 0, "pg_backupcluster $v main list", 0, qr/$dump.*$basebackup/s;

    note "more database changes";
    program_ok $pg_uid, "psql -c \"insert into foo values ('data later deleted')\" mydb";
    program_ok $pg_uid, "psql -c \"insert into foo values ('data from archive')\" mydb";
    my $timestamp = `su -c "psql -XAtc 'select now()'" postgres`;
    ok $timestamp, "retrieve recovery timestamp";
    program_ok $pg_uid, "psql -c \"delete from foo where t = 'data later deleted'\" mydb";
    usleep($delay);
    if ($v >= 9.5) {
        # since we are stopping pg_receivewal before postgresql, this implicitly tests restoring from .partial WAL files as well
        if ($systemd) {
            program_ok 0, "systemctl stop pg_receivewal\@$v-main";
        } else {
            is kill('INT', $receivewal_pid), 1, "stop receivewal";
        }
    }

    for my $backup (@backups) {
        note "restore $backup";
        program_ok 0, "pg_dropcluster $v main --stop";
        program_ok 0, "pg_restorecluster $v main $backup --start --datadir /var/lib/postgresql/$v/snowflake";
        like_program_out 0, "pg_lsclusters -h", 0, qr/$v main 5432 online postgres .var.lib.postgresql.$v.snowflake/;
        my $outref;
        is exec_as($pg_uid, "psql -XAtl", $outref), 0, 'psql -XAtl';
        like $$outref, qr/^mydb\|postgres\|SQL_ASCII\|(libc\|)?en_US.UTF-8\|en_US.UTF-8\|(\|libc\||\|\|)?$/m, "mydb locales";
        like $$outref, qr/^myicudb\|postgres\|UTF8\|(icu\|)?en_US.UTF-8\|en_US.UTF-8\|(de\|icu\||de\|\|)?$/m, "myicudb locales" if ($v >= 15);
        is_program_out $pg_uid, "psql -XAtc 'show work_mem'", 0, "11MB\n";
        is_program_out $pg_uid, "psql -XAtc 'select * from foo' mydb", 0, "data from backup\n";
        is_program_out $pg_uid, "psql -XAtc \"select analyze_count between 1 and 3 from pg_stat_user_tables where relname = 'foo'\" mydb", 0,
            "t\n"; # --analyze-in-stages does 3 passes
        SKIP: {
            skip "alter role in database handling in PG <= 10 not supported", 1 if ($v <= 10);
            like_program_out $pg_uid, "psql -XAtc '\\drds'", 0, qr/myuser\|mydb\|search_path=public, myotherschema.*
myuser\|\|search_path=public, myschema.*
\|mydb\|search_path=public.*\n/;
        }
    }

    if ($v >= 9.5) {
        note "restore $basebackup with WAL archive";
        program_ok 0, "pg_dropcluster $v main --stop";
        program_ok 0, "pg_restorecluster $v main $basebackup --start --archive --port 5430";
        like_program_out 0, "pg_lsclusters -h", 0, qr/$v main 5430 online postgres .var.lib.postgresql.$v.main/;
        is_program_out $pg_uid, "psql -XAtc 'select * from foo order by t' mydb", 0, "data from archive\ndata from backup\n";

        note "restore $basebackup with PITR";
        program_ok 0, "pg_dropcluster $v main --stop";
        program_ok 0, "pg_restorecluster $v main $basebackup --start --pitr '$timestamp'";
        like_program_out 0, "pg_lsclusters -h", 0, qr/$v main 5432 online postgres .var.lib.postgresql.$v.main/;
        is_program_out $pg_uid, "psql -XAtc 'select * from foo order by t' mydb", 0, "data from archive\ndata from backup\ndata later deleted\n";
    }

    program_ok 0, "pg_dropcluster $v main --stop";
    check_clean;

} # foreach version

done_testing();

# vim: filetype=perl
