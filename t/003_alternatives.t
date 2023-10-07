# Check that alternatives symlinks point to the correct locations

use warnings;
use strict;

use lib 't';
use TestLib;

use Test::More tests => $PgCommon::rpm ? 1 : 9;

if ($PgCommon::rpm) {
    ok "No alternatives test on RedHat";
    exit;
}

# server/client link group
my $newest_version = $ALL_MAJORS[-1];
note "Newest PG version installed is $newest_version";
program_ok 0, 'update-alternatives --list psql.1.gz', 0, 'psql.1.gz link group';
program_ok 0, 'update-alternatives --list postmaster.1.gz', 2, 'postmaster.1.gz link group does not exist'; # removed in pg-common 248
for my $name (qw(psql pg_dump postgres pg_ctl)) {
    is readlink "/etc/alternatives/$name.1.gz", "/usr/share/postgresql/$newest_version/man/man1/$name.1.gz", "$name.1.gz alternative";
}

# doc link group
my $newest_doc_version = `dpkg -l 'postgresql-doc-[1-9]*' | sed -ne 's/^ii  postgresql-doc-\\([0-9.]*\\).*/\\1/p' | sort -g | tail -n 1`;
note "Newest PG doc version installed is $newest_doc_version";
SKIP: {
    skip "No SPI_connect.3.gz link group on 8.x", 3 if ($newest_doc_version < 9.0);
    chomp $newest_doc_version;
    program_ok 0, 'update-alternatives --list SPI_connect.3.gz', 0, 'SPI_connect.3.gz link group';
    for my $name (qw(SPI_connect SPI_exec)) {
        is readlink "/etc/alternatives/$name.3.gz", "/usr/share/postgresql/$newest_doc_version/man/man3/$name.3.gz", "$name.3.gz alternative";
    }
}

# vim: filetype=perl
