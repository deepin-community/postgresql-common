# Check that the necessary packages are installed

use warnings;
use strict;

use lib 't';
use TestLib;
use POSIX qw/setlocale LC_ALL LC_MESSAGES/;

use Test::More tests => $PgCommon::rpm ? (3 + 9*@MAJORS) : (15 + 7*@MAJORS);

ok (-f "/etc/os-release", "/etc/os-release exists");
my ($os, $osversion) = os_release();
ok (defined $os, "OS is $os");
ok (defined $osversion, "OS version is $osversion");

note "PostgreSQL versions installed: @MAJORS\n";
my $f = $ENV{'PG_FLAVOR'} // '';

if ($PgCommon::rpm) {
    foreach my $v (@MAJORS) {
        my $vv = $v;
        $vv =~ s/\.//;

        ok ((rpm_installed "postgresql$vv$f"),          "postgresql$vv$f installed");
        ok ((rpm_installed "postgresql$vv$f-libs"),     "postgresql$vv$f-libs installed");
        ok ((rpm_installed "postgresql$vv$f-server"),   "postgresql$vv$f-server installed");
        ok ((rpm_installed "postgresql$vv$f-contrib"),  "postgresql$vv$f-contrib installed");
        ok ((rpm_installed "postgresql$vv$f-plperl"),   "postgresql$vv$f-plperl installed");
        SKIP: {
            skip "No python2 support", 1 unless ($v <= 12);
            ok ((rpm_installed "postgresql$vv$f-plpython"), "postgresql$vv$f-plpython installed");
        }
        ok ((rpm_installed "postgresql$vv$f-plpython3"), "postgresql$vv$f-plpython3 installed");
        ok ((rpm_installed "postgresql$vv$f-pltcl"),    "postgresql$vv$f-pltcl installed");
        ok ((rpm_installed "postgresql$vv$f-devel"),    "postgresql$vv$f-devel installed");
    }
    exit;
}

my $docpkgs = 0;
foreach my $v (@MAJORS) {
    ok ((deb_installed "postgresql-$v$f"), "postgresql-$v$f installed");
    SKIP: {
        skip "No python2 support", 1 unless ($v <= 11 and $PgCommon::have_python2);
        ok ((deb_installed "postgresql-plpython-$v$f"), "postgresql-plpython-$v$f installed");
    }
    if ($v >= '9.1') {
	ok ((deb_installed "postgresql-plpython3-$v$f"), "postgresql-plpython3-$v$f installed");
    } else {
	pass "no Python 3 package for version $v";
    }
    ok ((deb_installed "postgresql-plperl-$v$f"), "postgresql-plperl-$v$f installed");
    ok ((deb_installed "postgresql-pltcl-$v$f"), "postgresql-pltcl-$v$f installed");
    ok ((deb_installed "postgresql-server-dev-$v$f"), "postgresql-server-dev-$v$f installed");
  SKIP: {
    skip "No postgresql-contrib-$v$f package for version $v", 1 if ($v >= 10);
    ok ((deb_installed "postgresql-contrib-$v$f"), "postgresql-contrib-$v$f installed");
  }
    my $docpkg = "postgresql-doc-$v$f";
    if (deb_installed $docpkg) {
        note "$docpkg installed";
        $docpkgs++;
    }
}
ok $docpkgs, "At least one doc package installed";

ok ((deb_installed 'libecpg-dev'), 'libecpg-dev installed');
ok ((deb_installed 'procps'), 'procps installed');
ok ((deb_installed 'netcat-openbsd'), 'netcat-openbsd installed');

ok ((deb_installed 'hunspell-en-us'), 'hunspell-en-us installed');

# check installed locales to fail tests early if they are missing
ok ((setlocale(LC_MESSAGES, '') =~ /utf8|UTF-8/), 'system has a default UTF-8 locale');
ok (setlocale (LC_ALL, "ru_RU"), 'locale ru_RU exists');
ok (setlocale (LC_ALL, "ru_RU.UTF-8"), 'locale ru_RU.UTF-8 exists');

my $key_file = '/etc/ssl/private/ssl-cert-snakeoil.key';
my $pem_file = '/etc/ssl/certs/ssl-cert-snakeoil.pem';
ok ((getgrnam('ssl-cert'))[3] =~ /postgres/, 
    'user postgres in the UNIX group ssl-cert');
ok (-e $key_file, "$key_file exists");
is (exec_as ('postgres', "cat $key_file > /dev/null"), 0, "$key_file is readable for postgres");
ok (-e $pem_file, "$pem_file exists");

# vim: filetype=perl
