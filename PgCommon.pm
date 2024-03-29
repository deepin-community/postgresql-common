=head1 NAME

PgCommon - Common functions for the postgresql-common framework

=head1 COPYRIGHT AND LICENSE

 (C) 2008-2009 Martin Pitt <mpitt@debian.org>
 (C) 2012-2023 Christoph Berg <myon@debian.org>

This program is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation; either
L<version 2 of the License|https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>,
or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

=cut

package PgCommon;
use strict;
use IPC::Open3;
use Socket;
use POSIX;

use Exporter;
our $VERSION = 1.00;
our @ISA = ('Exporter');
our @EXPORT = qw/error user_cluster_map get_cluster_port set_cluster_port
    get_cluster_socketdir set_cluster_socketdir cluster_port_running
    get_cluster_start_conf set_cluster_start_conf set_cluster_pg_ctl_conf
    get_program_path cluster_info validate_cluster_owner get_versions get_newest_version version_exists
    get_version_clusters next_free_port cluster_exists install_file
    change_ugid system_or_error config_bool replace_v_c
    get_db_encoding get_db_locales get_cluster_locales get_cluster_controldata
    get_cluster_databases cluster_conf_filename read_cluster_conf_file
    read_pg_hba read_pidfile valid_hba_method/;
our @EXPORT_OK = qw/$confroot $binroot $rpm $have_python2
    quote_conf_value read_conf_file get_conf_value
    set_conf_value set_conffile_value disable_conffile_value disable_conf_value
    replace_conf_value cluster_data_directory get_file_device
    check_pidfile_running/;


=head1 CONTENTS

=head2 error

 Print an error message to stderr and die with exit status 1

=cut

sub error {
    $! = 1; # force exit code 1
    die "Error: $_[0]\n";
}

our $confroot = '/etc/postgresql';
if ($ENV{'PG_CLUSTER_CONF_ROOT'}) {
    ($confroot) = $ENV{'PG_CLUSTER_CONF_ROOT'} =~ /(.*)/; # untaint
}
our $common_confdir = "/etc/postgresql-common";
if ($ENV{'PGSYSCONFDIR'}) {
    ($common_confdir) = $ENV{'PGSYSCONFDIR'} =~ /(.*)/; # untaint
}
my $mapfile = "$common_confdir/user_clusters";
our $binroot = "/usr/lib/postgresql/";
#redhat# $binroot = "/usr/pgsql-";
our $rpm = 0;
#redhat# $rpm = 1;
our $defaultport = 5432;
our $have_python2 = 0; # python2 removed in bullseye+
#py2#$have_python2 = 1;

=head2 prepare_exec, restore_exec

 Untaint the environment for executing an external program

 Optional arguments: list of additional variables

=cut

{
    my %saved_env;

    # untaint the environment for executing an external program
    sub prepare_exec {
	my @cleanvars = qw/PATH IFS ENV BASH_ENV CDPATH/;
	push @cleanvars, @_;
	%saved_env = ();

	foreach (@cleanvars) {
	    $saved_env{$_} = $ENV{$_};
	    delete $ENV{$_};
	}

	$ENV{'PATH'} = '/sbin:/bin:/usr/sbin:/usr/bin';
    }

    # restore the environment after prepare_exec()
    sub restore_exec {
	foreach (keys %saved_env) {
	    if (defined $saved_env{$_}) {
		$ENV{$_} = $saved_env{$_};
	    } else {
		delete $ENV{$_};
	    }
	}
    }
}


=head2 config_bool

 returns '1' if the argument is a configuration file value that stands for
 true (ON, TRUE, YES, or 1, case insensitive), '0' if the argument represents
 a false value (OFF, FALSE, NO, or 0, case insensitive), or undef otherwise.

=cut

sub config_bool {
    return undef unless defined($_[0]);
    return 1 if ($_[0] =~ /^(on|true|yes|1)$/i);
    return 0 if ($_[0] =~ /^(off|false|no|0)$/i);
    return undef;
}


=head2 quote_conf_value

 Quotes a value with single quotes

 Arguments: <value>
 Returns: quoted string

=cut

sub quote_conf_value ($) {
    my $value = shift;
    return $value if ($value =~ /^-?[\d.]+$/); # integer or float
    return $value if ($value =~ /^\w+$/); # plain word
    $value =~ s/'/''/g; # else quote it
    return "'$value'";
}


=head2 replace_v_c

 Replaces %v and %c placeholders

 Arguments: <string> <version> <cluster>
 Returns: string

=cut

sub replace_v_c ($$$) {
    my ($str, $version, $cluster) = @_;
    $str =~ s/%([vc%])/$1 eq 'v' ? $version :
                       $1 eq 'c' ? $cluster : '%'/eg;
    return $str;
}


=head2 read_conf_file

 Read a 'var = value' style configuration file and return a hash with the
 values. Error out if the file cannot be read.

 If the file name ends with '.conf', the keys will be normalized to
 lower case (suitable for e.g. postgresql.conf), otherwise kept intact
 (suitable for environment).

 Arguments: <path>
 Returns: hash (empty if file does not exist)

=cut

sub read_conf_file {
    my ($config_path) = @_;
    my %conf;
    local (*F);

    sub get_absolute_path {
        my ($path, $parent_path) = @_;
        return $path if ($path =~ m!^/!); # path is absolute
        # else strip filename component from parent path
        $parent_path =~ s!/[^/]*$!!;
        return "$parent_path/$path";
    }

    if (open F, $config_path) {
        while (<F>) {
            if (/^\s*(?:#.*)?$/) {
                next;
            } elsif(/^\s*include_dir\s*=?\s*'([^']+)'\s*(?:#.*)?$/i) {
                # read included configuration directory and merge into %conf
                # files in the directory will be read in ascending order
                my $path = $1;
                my $absolute_path = get_absolute_path($path, $config_path);
                next unless -e $absolute_path && -d $absolute_path;
                my $dir;
                opendir($dir, $absolute_path) or next;
                foreach my $filename (sort readdir($dir) ) {
                    next if ($filename =~ m/^\./ or not $filename =~/\.conf$/ );
                    my %include_conf = read_conf_file("$absolute_path/$filename");
                    while ( my ($k, $v) = each(%include_conf) ) {
                        $conf{$k} = $v;
                    }
                }
                closedir($dir);
            } elsif (/^\s*include(?:_if_exists)?\s*=?\s*'([^']+)'\s*(?:#.*)?$/i) {
                # read included file and merge into %conf
                my $path = $1;
                my $absolute_path = get_absolute_path($path, $config_path);
                my %include_conf = read_conf_file($absolute_path);
                while ( my ($k, $v) = each(%include_conf) ) {
                    $conf{$k} = $v;
                }
            } elsif (/^\s*([a-zA-Z0-9_.-]+)\s*(?:=|\s)\s*'((?:[^']|''|(?:(?<=\\)'))*)'\s*(?:#.*)?$/i) {
                # string value
                my $v = $2;
                my $k = $1;
                $k = lc $k if $config_path =~ /\.conf$/;
                $v =~ s/\\(.)/$1/g;
                $v =~ s/''/'/g;
                $conf{$k} = $v;
            } elsif (m{^\s*([a-zA-Z0-9_.-]+)\s*(?:=|\s)\s*(-?[[:alnum:]][[:alnum:]._:/+-]*)\s*(?:\#.*)?$}i) {
                # simple value (string/float)
                my $v = $2;
                my $k = $1;
                $k = lc $k if $config_path =~ /\.conf$/;
                $conf{$k} = $v;
            } else {
                chomp;
                error "invalid line $. in $config_path: $_";
            }
        }
        close F;
    }

    return %conf;
}

=head2 cluster_conf_filename

 Returns path to cluster config file from a cluster configuration
 directory (with /etc/postgresql-common/<file name> as fallback)
 and return a hash with the values. Error out if the file cannot be read.
 If config file name is postgresql.auto.conf, read from PGDATA

 Arguments: <version> <cluster> <config file name>
 Returns: hash (empty if the file does not exist)

=cut

sub cluster_conf_filename {
    my ($version, $cluster, $configfile) = @_;
    if ($configfile eq 'postgresql.auto.conf') {
        my $data_directory = cluster_data_directory($version, $cluster);
        return "$data_directory/$configfile";
    }
    my $fname = "$confroot/$version/$cluster/$configfile";
    -e $fname or $fname = "$common_confdir/$configfile";
    return $fname;
}


=head2 read_cluster_conf_file

Read a 'var = value' style configuration file from a cluster configuration

Arguments: <version> <cluster> <config file name>
Returns: hash (empty if the file does not exist)

=cut

sub read_cluster_conf_file {
    my ($version, $cluster, $configfile) = @_;
    my %conf = read_conf_file(cluster_conf_filename($version, $cluster, $configfile));

    if ($version >= 9.4 and $configfile eq 'postgresql.conf') { # merge settings changed by ALTER SYSTEM
        # data_directory cannot be changed by ALTER SYSTEM
        my $data_directory = cluster_data_directory($version, $cluster, \%conf);
        my %auto_conf = read_conf_file "$data_directory/postgresql.auto.conf";
        foreach my $guc (keys %auto_conf) {
            next if ($guc eq 'data_directory'); # defend against pg_upgradecluster bug in 200..202
            $conf{$guc} = $auto_conf{$guc};
        }
    }

    return %conf;
}


=head2 get_conf_value

 Return parameter from a PostgreSQL configuration file,
 or undef if the parameter does not exist.

 Arguments: <version> <cluster> <config file name> <parameter name>

=cut

sub get_conf_value {
    my %conf = (read_cluster_conf_file $_[0], $_[1], $_[2]);
    return $conf{$_[3]};
}


=head2 set_conffile_value

 Set parameter of a PostgreSQL configuration file.

 Arguments: <config file name> <parameter name> <value>

=cut

sub set_conffile_value {
    my ($fname, $key, $value) = ($_[0], $_[1], quote_conf_value($_[2]));
    my @lines;

    # read configuration file lines
    open (F, $fname) or die "Error: could not open $fname for reading";
    push @lines, $_ while (<F>);
    close F;

    my $found = 0;
    # first, search for an uncommented setting
    for (my $i=0; $i <= $#lines; ++$i) {
	if ($lines[$i] =~ /^\s*($key)(\s*(?:=|\s)\s*)\w+\b((?:\s*#.*)?)/i or
	    $lines[$i] =~ /^\s*($key)(\s*(?:=|\s)\s*)'[^']*'((?:\s*#.*)?)/i) {
	    $lines[$i] = "$1$2$value$3\n";
	    $found = 1;
	    last;
	}
    }

    # now check if the setting exists as a comment; if so, change that instead
    # of appending
    if (!$found) {
	for (my $i=0; $i <= $#lines; ++$i) {
	    if ($lines[$i] =~ /^\s*#\s*($key)(\s*(?:=|\s)\s*)\w+\b((?:\s*#.*)?)$/i or
		$lines[$i] =~ /^\s*#\s*($key)(\s*(?:=|\s)\s*)'[^']*'((?:\s*#.*)?)$/i) {
		$lines[$i] = "$1$2$value$3\n";
		$found = 1;
		last;
	    }
	}
    }

    # not found anywhere, append it
    push (@lines, "$key = $value\n") unless $found;

    # write configuration file lines
    open (F, ">$fname.new") or die "Error: could not open $fname.new for writing";
    foreach (@lines) {
	print F $_ or die "writing $fname.new: $!";
    }
    close F;

    # copy permissions
    my @st = stat $fname or die "stat: $!";
    chown $st[4], $st[5], "$fname.new"; # might fail as non-root
    chmod $st[2], "$fname.new" or die "chmod: $!";

    rename "$fname.new", "$fname" or die "rename $fname.new $fname: $!";
}


=head2 set_conf_value

 Set parameter of a PostgreSQL cluster configuration file.

 Arguments: <version> <cluster> <config file name> <parameter name> <value>

=cut

sub set_conf_value {
    return set_conffile_value(cluster_conf_filename($_[0], $_[1], $_[2]), $_[3], $_[4]);
}


=head2 disable_conffile_value

 Disable a parameter in a PostgreSQL configuration file by prepending it
 with a '#'. Appends an optional explanatory comment <reason> if given.

 Arguments: <config file name> <parameter name> <reason>

=cut

sub disable_conffile_value {
    my ($fname, $key, $reason) = @_;
    my @lines;

    # read configuration file lines
    open (F, $fname) or die "Error: could not open $fname for reading";
    push @lines, $_ while (<F>);
    close F;

    my $changed = 0;
    for (my $i=0; $i <= $#lines; ++$i) {
	if ($lines[$i] =~ /^\s*$key\s*(?:=|\s)/i) {
            $lines[$i] =~ s/^/#/;
            $lines[$i] =~ s/$/ #$reason/ if $reason;
            $changed = 1;
	    last;
	}
    }

    # write configuration file lines
    if ($changed) {
        open (F, ">$fname.new") or die "Error: could not open $fname.new for writing";
        foreach (@lines) {
	    print F $_ or die "writing $fname.new: $!";
        }
        close F;

	# copy permissions
	my @st = stat $fname or die "stat: $!";
	chown $st[4], $st[5], "$fname.new"; # might fail as non-root
	chmod $st[2], "$fname.new" or die "chmod: $1";

	rename "$fname.new", "$fname";
    }
}


=head2 disable_conf_value

 Disable a parameter in a PostgreSQL cluster configuration file by prepending
 it with a '#'. Appends an optional explanatory comment <reason> if given.

 Arguments: <version> <cluster> <config file name> <parameter name> <reason>

=cut

sub disable_conf_value {
    return disable_conffile_value(cluster_conf_filename($_[0], $_[1], $_[2]), $_[3], $_[4]);
}


=head2 replace_conf_value

 Replace a parameter in a PostgreSQL configuration file. The old parameter
 is prepended with a '#' and gets an optional explanatory comment <reason>
 appended, if given. The new parameter is inserted directly after the old one.

 Arguments: <version> <cluster> <config file name> <old parameter name>
            <reason> <new parameter name> <new value>

=cut

sub replace_conf_value {
    my ($version, $cluster, $configfile, $oldparam, $reason, $newparam, $val) = @_;
    my $fname = cluster_conf_filename($version, $cluster, $configfile);
    my @lines;

    # quote $val if necessary
    unless ($val =~ /^\w+$/) {
	$val = "'$val'";
    }

    # read configuration file lines
    open (F, $fname) or die "Error: could not open $fname for reading";
    push @lines, $_ while (<F>);
    close F;

    my $found = 0;
    for (my $i = 0; $i <= $#lines; ++$i) {
	if ($lines[$i] =~ /^\s*$oldparam\s*(?:=|\s)/i) {
	    $lines[$i] = '#'.$lines[$i];
	    chomp $lines[$i];
            $lines[$i] .= ' #'.$reason."\n" if $reason;

            # insert the new param
            splice @lines, $i+1, 0, "$newparam = $val\n";
            ++$i;

            $found = 1;
	    last;
	}
    }

    return if !$found;

    # write configuration file lines
    open (F, ">$fname.new") or die "Error: could not open $fname.new for writing";
    foreach (@lines) {
	print F $_ or die "writing $fname.new: $!";
    }
    close F;

    # copy permissions
    my @st = stat $fname or die "stat: $!";
    chown $st[4], $st[5], "$fname.new"; # might fail as non-root
    chmod $st[2], "$fname.new" or die "chmod: $1";

    rename "$fname.new", "$fname";
}


=head2 get_cluster_port

 Return the port of a particular cluster

 Arguments: <version> <cluster>

=cut

sub get_cluster_port {
    return get_conf_value($_[0], $_[1], 'postgresql.conf', 'port') || $defaultport;
}


=head2 set_cluster_port

 Set the port of a particular cluster.

 Arguments: <version> <cluster> <port>

=cut

sub set_cluster_port {
    set_conf_value $_[0], $_[1], 'postgresql.conf', 'port', $_[2];
}


=head2 cluster_data_directory

 Return cluster data directory.

 Arguments: <version> <cluster name> [<config_hash>]

=cut

sub cluster_data_directory {
    my $d;
    if ($_[2]) {
        $d = ${$_[2]}{'data_directory'};
    } else {
        $d = get_conf_value($_[0], $_[1], 'postgresql.conf', 'data_directory');
    }
    my $confdir = "$confroot/$_[0]/$_[1]";
    if (!$d) {
        # fall back to /pgdata symlink (supported by earlier p-common releases)
        $d = readlink "$confdir/pgdata";
    }
    if (!$d and -l $confdir and -f "$confdir/PG_VERSION") { # symlink from /etc/postgresql
        $d = readlink $confdir;
    }
    if (!$d and -f "$confdir/PG_VERSION") { # PGDATA in /etc/postgresql
        $d = $confdir;
    }
    ($d) = $d =~ /(.*)/ if defined $d; #untaint
    return $d;
}


=head2 get_cluster_socketdir

 Return the socket directory of a particular cluster
 or undef if the cluster does not exist.

 Arguments: <version> <cluster>

=cut

sub get_cluster_socketdir {
    # if it is explicitly configured, just return it
    my $socketdir = get_conf_value($_[0], $_[1], 'postgresql.conf',
        $_[0] >= 9.3 ? 'unix_socket_directories' : 'unix_socket_directory');
    $socketdir =~ s/\s*,.*// if ($socketdir); # ignore additional directories for now
    return $socketdir if $socketdir;

    #redhat# return '/tmp'; # RedHat PGDG packages default to /tmp
    # try to determine whether this is a postgres owned cluster and we default
    # to /var/run/postgresql
    $socketdir = '/var/run/postgresql';
    my @socketdirstat = stat $socketdir;

    error "Cannot stat $socketdir" unless @socketdirstat;

    if ($_[0] && $_[1]) {
        my $datadir = cluster_data_directory $_[0], $_[1];
        error "Invalid data directory for cluster $_[0] $_[1]" unless $datadir;
        my @datadirstat = stat $datadir;
        unless (@datadirstat) {
            my @p = split '/', $datadir;
            my $parent = join '/', @p[0..($#p-1)];
            error "$datadir is not accessible; please fix the directory permissions ($parent/ should be world readable)" unless @datadirstat;
        }

        $socketdir = '/tmp' if $socketdirstat[4] != $datadirstat[4];
    }

    return $socketdir;
}


=head2 set_cluster_socketdir

 Set the socket directory of a particular cluster.

 Arguments: <version> <cluster> <directory>

=cut

sub set_cluster_socketdir {
    set_conf_value $_[0], $_[1], 'postgresql.conf',
        $_[0] >= 9.3 ? 'unix_socket_directories' : 'unix_socket_directory',
        $_[2];
}


=head2 get_program_path

 Return the path of a program of a particular version.

 Arguments: <program name> [<version>]

=cut

sub get_program_path {
    my ($program, $version) = @_;
    return '' unless defined $program;
    $version //= get_newest_version($program);
    my $path = "$binroot$version/bin/$program";
    ($path) = $path =~ /(.*)/; #untaint
    return $path if -x $path;
    return '';
}


=head2 cluster_port_running

 Check whether a postgres server is running at the specified port.

 Arguments: <version> <cluster> <port>

=cut

sub cluster_port_running {
    die "port_running: invalid port $_[2]" if $_[2] !~ /\d+/;
    my $socketdir = get_cluster_socketdir $_[0], $_[1];
    my $socketpath = "$socketdir/.s.PGSQL.$_[2]";
    return 0 unless -S $socketpath;

    socket(SRV, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    my $running = connect(SRV, sockaddr_un($socketpath));
    close SRV;
    return $running ? 1 : 0;
}


=head2 get_cluster_start_conf

 Read, verify, and return the current start.conf setting.

 Arguments: <version> <cluster>
 Returns: auto | manual | disabled

=cut

sub get_cluster_start_conf {
    my $start_conf = "$confroot/$_[0]/$_[1]/start.conf";
    if (-e $start_conf) {
	open F, $start_conf or error "Could not open $start_conf: $!";
	while (<F>) {
	    s/#.*$//;
	    s/^\s*//;
	    s/\s*$//;
	    next unless $_;
            close F;
            return $1 if (/^(auto|manual|disabled)/);
            error "Invalid mode in $start_conf, must be one of auto, manual, disabled";
	}
	close F;
    }
    return 'auto'; # default
}


=head2 set_cluster_start_conf

 Change start.conf setting.

 Arguments: <version> <cluster> <value>
 <value> = auto | manual | disabled

=cut

sub set_cluster_start_conf {
    my ($v, $c, $val) = @_;

    error "Invalid mode: '$val'" unless $val eq 'auto' ||
	    $val eq 'manual' || $val eq 'disabled';

    my $perms = 0644;

    # start.conf setting
    my $start_conf = "$confroot/$_[0]/$_[1]/start.conf";
    my $text;
    if (-e $start_conf) {
	open F, $start_conf or error "Could not open $start_conf: $!";
	while (<F>) {
            if (/^\s*(?:auto|manual|disabled)\b(.*$)/) {
                $text .= $val . $1 . "\n";
            } else {
                $text .= $_;
            }
	}

        # preserve permissions if it already exists
        $perms = (stat F)[2];
        error "Could not get permissions of $start_conf: $!" unless $perms;
	close F;
    } else {
        $text = "# Automatic startup configuration
#   auto: automatically start the cluster
#   manual: manual startup with pg_ctlcluster/postgresql@.service only
#   disabled: refuse to start cluster
# See pg_createcluster(1) for details. When running from systemd,
# invoke 'systemctl daemon-reload' after editing this file.

$val
";
    }

    open F, '>' . $start_conf or error "Could not open $start_conf for writing: $!";
    chmod $perms, $start_conf;
    print F $text;
    close F;
}


=head2 set_cluster_pg_ctl_conf

 Change pg_ctl.conf setting.

 Arguments: <version> <cluster> <options>
 <options> = options passed to pg_ctl(1)

=cut

sub set_cluster_pg_ctl_conf {
    my ($v, $c, $opts) = @_;
    my $perms = 0644;

    # pg_ctl.conf setting
    my $pg_ctl_conf = "$confroot/$v/$c/pg_ctl.conf";
    my $text = "# Automatic pg_ctl configuration
# This configuration file contains cluster specific options to be passed to
# pg_ctl(1).

pg_ctl_options = '$opts'
";

    open F, '>' . $pg_ctl_conf or error "Could not open $pg_ctl_conf for writing: $!";
    chmod $perms, $pg_ctl_conf;
    print F $text;
    close F;
}


=head2 read_pidfile

 Return the PID from an existing PID file or undef if it does not exist.

 Arguments: <pid file path>

=cut

sub read_pidfile {
    return undef unless -e $_[0];

    if (open PIDFILE, $_[0]) {
	my $pid = <PIDFILE>;
	close PIDFILE;
        return undef unless ($pid);
        chomp $pid;
        ($pid) = $pid =~ /^(\d+)\s*$/; # untaint
	return $pid;
    } else {
	return undef;
    }
}


=head2 check_pidfile_running

 Check whether a pid file is present and belongs to a running postgres.
 Returns undef if it cannot be determined

 Arguments: <pid file path>

 postgres does not clean up the PID file when it stops, and it is
 not world readable, so only its absence is a definitive result;
 if it is present, we need to read it and check the PID, which will
 only work as root

=cut

sub check_pidfile_running {
    return 0 if ! -e $_[0];

    my $pid = read_pidfile $_[0];
    if (defined $pid and open CL, "/proc/$pid/cmdline") {
        my $cmdline = <CL>;
        close CL;
        if ($cmdline and $cmdline =~ /\bpostgres\b/) {
            return 1;
        } else {
            return 0;
        }
    }
    return undef;
}


=head2 cluster_supervisor

 Determine if a cluster is managed by a supervisor (pacemaker, patroni).
 Returns undef if it cannot be determined

 Arguments: <pid file path>

 postgres does not clean up the PID file when it stops, and it is
 not world readable, so only its absence is a definitive result; if it
 is present, we need to read it and check the PID, which will only
 work as root

=cut

sub cluster_supervisor {
    return undef if ! -e $_[0];

    my $pid = read_pidfile $_[0];
    if (defined $pid and open(CG, "/proc/$pid/cgroup")) {
        local $/; # enable localized slurp mode
        my $cgroup = <CG>;
        close CG;
        if ($cgroup and $cgroup =~ /\b(pacemaker|patroni)\b/) {
            return $1;
        }
    }
    return undef;
}


=head2 cluster_info

 Return a hash with information about a specific cluster (which needs to exist).

 Arguments: <version> <cluster name>
 Returns: information hash (keys: pgdata, port, running, logfile [unless it
          has a custom one], configdir, owneruid, ownergid, waldir, socketdir,
          config->postgresql.conf)

=cut

sub cluster_info {
    my ($v, $c) = @_;
    error 'cluster_info must be called with <version> <cluster> arguments' unless ($v and $c);

    my %result;
    $result{'configdir'} = "$confroot/$v/$c";
    $result{'configuid'} = (stat "$result{configdir}/postgresql.conf")[4];

    my %postgresql_conf = read_cluster_conf_file $v, $c, 'postgresql.conf';
    $result{'config'} = \%postgresql_conf;
    $result{'pgdata'} = cluster_data_directory $v, $c, \%postgresql_conf;
    return %result unless (keys %postgresql_conf);
    $result{'port'} = $postgresql_conf{'port'} || $defaultport;
    $result{'socketdir'} = get_cluster_socketdir  $v, $c;

    # if we can determine the running status with the pid file, prefer that
    if ($postgresql_conf{'external_pid_file'} &&
	$postgresql_conf{'external_pid_file'} ne '(none)') {
	$result{'running'} = check_pidfile_running $postgresql_conf{'external_pid_file'};
        my $supervisor = cluster_supervisor($postgresql_conf{'external_pid_file'});
        $result{supervisor} = $supervisor if ($supervisor);
    }

    # otherwise fall back to probing the port; this is unreliable if the port
    # was changed in the configuration file in the meantime
    if (!defined ($result{'running'})) {
	$result{'running'} = cluster_port_running ($v, $c, $result{'port'});
    }

    if ($result{'pgdata'}) {
        ($result{'owneruid'}, $result{'ownergid'}) =
            (stat $result{'pgdata'})[4,5];
        if ($v >= 12) {
            $result{'recovery'} = 1 if (-e "$result{'pgdata'}/recovery.signal"
                                     or -e "$result{'pgdata'}/standby.signal");
        } else {
            $result{'recovery'} = 1 if (-e "$result{'pgdata'}/recovery.conf");
        }
        my $waldirname = $v >= 10 ? 'pg_wal' : 'pg_xlog';
        if (-l "$result{pgdata}/$waldirname") { # custom wal directory
            ($result{waldir}) = readlink("$result{pgdata}/$waldirname") =~ /(.*)/; # untaint
        }
    }
    $result{'start'} = get_cluster_start_conf $v, $c;

    # default log file (possibly used only for early startup messages)
    my $log_symlink = $result{'configdir'} . "/log";
    if (-l $log_symlink) {
        ($result{'logfile'}) = readlink ($log_symlink) =~ /(.*)/; # untaint
    } else {
        $result{'logfile'} = "/var/log/postgresql/postgresql-$v-$c.log";
    }

    return %result;
}


=head2 validate_cluster_owner

 Checks if the owner of a cluster is valid, and the owner of the config matches
 the owner of the data directory.

 Arguments: cluster_info hash reference

=cut

sub validate_cluster_owner($) {
    my $info = shift;

    unless ($info->{pgdata}) {
        error "Cluster data directory is unknown";
    }
    unless (-d $info->{pgdata}) {
        error "$info->{pgdata} is not accessible or does not exist";
    }
    unless (defined $info->{owneruid}) {
        error "Could not determine owner of $info->{pgdata}";
    }
    if ($info->{owneruid} == 0) {
        error "Data directory $info->{pgdata} must not be owned by root";
    }
    unless (getpwuid $info->{owneruid}) {
        error "The cluster is owned by user id $info->{owneruid} which does not exist";
    }
    unless (getgrgid $info->{ownergid}) {
        error "The cluster is owned by group id $info->{ownergid} which does not exist";
    }
    # owneruid and configuid need to match, unless configuid is root
    if (($< == 0 or $> == 0) and $info->{configuid} != 0 and
            $info->{configuid} != $info->{owneruid}) {
        my $configowner = (getpwuid $info->{configuid})[0] || "(unknown)";
        my $dataowner = (getpwuid $info->{owneruid})[0];
        error "Config owner ($configowner:$info->{configuid}) and data owner ($dataowner:$info->{owneruid}) do not match, and config owner is not root";
    }
}


=head2 get_versions

 Return an array of all available versions (by binaries and postgresql.conf files)

 Arguments: binary to scan for (optional, defaults to postgres), maximum acceptable version (optional)

=cut

sub get_versions {
    my $program = shift // 'postgres';
    my $max_version = shift;
    my %versions = ();

    # enumerate psql versions from /usr/lib/postgresql/* (or /usr/pgsql-*)
    my $dir = $binroot;
    #redhat# $dir = '/usr';
    if (opendir (D, $dir)) {
	my $entry;
        while (defined ($entry = readdir D)) {
            next if $entry eq '.' || $entry eq '..';
            my $pfx = '';
            #redhat# $pfx = "pgsql-";
            my $version;
            ($version) = $entry =~ /^$pfx(\d+\.?\d+)$/; # untaint
            next if ($max_version and $version > $max_version);
            $versions{$version} = 1 if $version and get_program_path ($program, $version);
        }
        closedir D;
    }

    # enumerate server versions from /etc/postgresql/*
    if ($program eq 'postgres' and opendir (D, $confroot)) {
        my $v;
        while (defined ($v = readdir D)) {
            next if $v eq '.' || $v eq '..';
            ($v) = $v =~ /^(\d+\.?\d+)$/; # untaint
            next unless ($v);
            next if ($max_version and $v > $max_version);

            if (opendir (C, "$confroot/$v")) {
                my $c;
                while (defined ($c = readdir C)) {
                    if (-e "$confroot/$v/$c/postgresql.conf") {
                        $versions{$v} = 1;
                        last;
                    }
                }
                closedir C;
            }
        }
        closedir D;
    }

    return sort { $a <=> $b } keys %versions;
}


=head2 get_newest_version

 Return the newest available version

 Arguments: binary to scan for (optional), maximum acceptable version (optional)

=cut

sub get_newest_version {
    my $program = shift;
    my $max_version = shift;
    my @versions = get_versions($program, $max_version);
    return undef unless (@versions);
    return $versions[-1];
}

=head2 version_exists

 Check whether a version exists

=cut

sub version_exists {
    my ($version) = @_;
    return get_program_path ('psql', $version);
}


=head2 get_version_clusters

 Return an array of all available clusters of given version

 Arguments: <version>

=cut

sub get_version_clusters {
    my $vdir = $confroot.'/'.$_[0].'/';
    my @clusters = ();
    if (opendir (D, $vdir)) {
	my $entry;
        while (defined ($entry = readdir D)) {
            next if $entry eq '.' || $entry eq '..';
	    ($entry) = $entry =~ /^(.*)$/; # untaint
            my $conf = "$vdir$entry/postgresql.conf";
            if (-e $conf or -l $conf) { # existing file, or dead symlink
                push @clusters, $entry;
            }
        }
        closedir D;
    }
    return sort @clusters;
}


=head2 cluster_exists

 Check if a cluster exists.

 Arguments: <version> <cluster>

=cut

sub cluster_exists {
    for my $c (get_version_clusters $_[0]) {
	return 1 if $c eq $_[1];
    }
    return 0;
}


=head2 next_free_port

 Return the next free PostgreSQL port.

=cut

sub next_free_port {
    # create list of already used ports
    my %ports;
    for my $v (get_versions) {
	for my $c (get_version_clusters $v) {
            $ports{ get_cluster_port ($v, $c) } = 1;
	}
    }

    my $port;
    for ($port = $defaultport; $port < 65536; ++$port) {
        # port in use by existing cluster
        next if (exists $ports{$port});

        # IPv4 port in use
        my ($have_ip4, $have_ip6);
        if (socket (SOCK, PF_INET, SOCK_STREAM, getprotobyname('tcp'))) {
	    $have_ip4 = 1;
            setsockopt(SOCK, Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1) or error "setsockopt: $!";
            my $res4 = bind (SOCK, sockaddr_in($port, INADDR_ANY)) and listen (SOCK, 0);
            my $err = $!;
            close SOCK;
            next unless ($res4);
	}

        # IPv6 port in use
        if (exists $Socket::{"IN6ADDR_ANY"}) {
	    if (socket (SOCK, PF_INET6, SOCK_STREAM, getprotobyname('tcp'))) {
		$have_ip6 = 1;
                setsockopt(SOCK, Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1) or error "setsockopt: $!";
                my $res6 = bind (SOCK, sockaddr_in6($port, Socket::IN6ADDR_ANY)) and listen (SOCK, 0);
                my $err = $!;
                close SOCK;
                next unless ($res6);
	    }
	}

	unless ($have_ip4 or $have_ip6) {
	    # require at least one protocol to work (PostgreSQL needs it anyway
	    # for the stats collector)
            die "could not create socket: $!";
	}

        close SOCK;
	# return port if it is available on all supported protocols
        return $port;
    }

    die "no free port found";
}


=head2 user_cluster_map

 Return the PostgreSQL version, cluster, and database to connect to.

 Version is always set (defaulting to the version of the default port
 if no matching entry is found, or finally to the latest installed version
 if there are no clusters at all), cluster and database may be 'undef'.
 If only one cluster exists, and no matching entry is found in the map files,
 that cluster is returned.

=cut

sub user_cluster_map {
    my ($user, $pwd, $uid, $gid) = getpwuid $>;
    my $group = (getgrgid  $gid)[0];

    # check per-user configuration file
    my $home = $ENV{"HOME"} || (getpwuid $>)[7];
    my $homemapfile = $home . '/.postgresqlrc';
    if (open MAP, $homemapfile) {
	while (<MAP>) {
	    s/#.*//;
	    next if /^\s*$/;
	    my ($v,$c,$db) = split;
	    if (!version_exists $v) {
                print "Warning: $homemapfile line $.: version $v does not exist\n";
                next;
	    }
	    if (!cluster_exists $v, $c and $c !~ /^(\S+):(\d*)$/) {
                print "Warning: $homemapfile line $.: cluster $v/$c does not exist\n";
                next;
	    }
	    if ($db) {
		close MAP;
		return ($v, $c, ($db eq "*") ? undef : $db);
	    } else {
		print  "Warning: ignoring invalid line $. in $homemapfile\n";
		next;
	    }
	}
	close MAP;
    }

    # check global map file
    if (open MAP, $mapfile) {
        while (<MAP>) {
            s/#.*//;
            next if /^\s*$/;
            my ($u,$g,$v,$c,$db) = split;
            if (!$db) {
                print  "Warning: ignoring invalid line $. in $mapfile\n";
                next;
            }
	    if (!version_exists $v) {
                print "Warning: $mapfile line $.: version $v does not exist\n";
                next;
	    }
	    if (!cluster_exists $v, $c and $c !~ /^(\S+):(\d*)$/) {
                print "Warning: $mapfile line $.: cluster $v/$c does not exist\n";
                next;
	    }
            if (($u eq "*" || $u eq $user) && ($g eq "*" || $g eq $group)) {
                close MAP;
                return ($v,$c, ($db eq "*") ? undef : $db);
            }
        }
        close MAP;
    }

    # if only one cluster exists, use that
    my $count = 0;
    my ($last_version, $last_cluster, $defaultport_version, $defaultport_cluster);
    for my $v (get_versions) {
	for my $c (get_version_clusters $v) {
	    my $port = get_cluster_port ($v, $c);
            $last_version = $v;
            $last_cluster = $c;
	    if ($port == $defaultport) {
		$defaultport_version = $v;
		$defaultport_cluster = $c;
	    }
            ++$count;
	}
    }
    return ($last_version, $last_cluster, undef) if $count == 1;

    if ($count == 0) {
	# if there are no local clusters, use latest clients for accessing
	# network clusters
	return (get_newest_version('psql'), undef, undef);
    }

    # more than one cluster exists, return cluster at default port
    return ($defaultport_version, $defaultport_cluster, undef);
}


=head2 install_file

 Copy a file to a destination and setup permissions

 Arguments: <source file> <destination file or dir> <uid> <gid> <permissions>

=cut

sub install_file {
    my ($source, $dest, $uid, $gid, $perm) = @_;

    if (system 'install', '-o', $uid, '-g', $gid, '-m', $perm, $source, $dest) {
	error "install_file: could not install $source to $dest";
    }
}


=head2 change_ugid

 Change effective and real user and group id. Also activates all auxiliary
 groups the user is in. Exits with an error message if user/group ID cannot
 be changed.

 Arguments: <user id> <group id>

=cut

sub change_ugid {
    my ($uid, $gid) = @_;

    # auxiliary groups
    my $uname = (getpwuid $uid)[0];
    prepare_exec;
    my $groups = "$gid " . `/usr/bin/id -G $uname`;
    restore_exec;

    $) = $groups;
    $( = $gid;
    $> = $< = $uid;
    error 'Could not change user id' if $< != $uid;
    error 'Could not change group id' if $( != $gid;
}


=head2 system_or_error

 Run a command and error out if it exits with a non-zero status.

 Arguments: <command ...>

=cut

sub system_or_error {
    my $ret = system @_;
    if ($ret) {
        my $message = "@_ failed with exit code $ret";
        $message .= ": $!" if ($!);
        error $message;
    }
}


=head2 get_db_encoding

 Return the encoding of a particular database in a cluster.

 This requires access privileges to that database, so this
 function should be called as the cluster owner.

 Arguments: <version> <cluster> <database>
 Returns: Encoding or undef if it cannot be determined.

=cut

sub get_db_encoding {
    my ($version, $cluster, $db) = @_;
    my $port = get_cluster_port $version, $cluster;
    my $socketdir = get_cluster_socketdir $version, $cluster;
    my $psql = get_program_path 'psql', $version;
    return undef unless ($port && $socketdir && $psql);

    # try to swich to cluster owner
    prepare_exec 'LC_ALL';
    $ENV{'LC_ALL'} = 'C';
    my $orig_euid = $>;
    $> = (stat (cluster_data_directory $version, $cluster))[4];
    open PSQL, '-|', $psql, '-h', $socketdir, '-p', $port, '-AXtc',
        'select getdatabaseencoding()', $db or
        die "Internal error: could not call $psql to determine db encoding: $!";
    my $out = <PSQL>;
    close PSQL;
    $> = $orig_euid;
    restore_exec;
    return undef if $?;
    chomp $out;
    ($out) = $out =~ /^([\w.-]+)$/; # untaint
    return $out;
}


=head2 get_db_locales

 Return locale of a particular database in a cluster. This requires access
 privileges to that database, so this function should be called as the cluster
 owner. (For versions >= 8.4; for older versions use get_cluster_locales()).

 Arguments: <version> <cluster> <database>
 Returns: (LC_CTYPE, LC_COLLATE) or (undef,undef) if it cannot be determined.
 PG15 adds locale provider and icu locale to the returned values
 PG16 adds icu rules

=cut

sub get_db_locales {
    my ($version, $cluster, $db) = @_;
    my $port = get_cluster_port $version, $cluster;
    my $socketdir = get_cluster_socketdir $version, $cluster;
    my $psql = get_program_path 'psql', $version;
    return undef unless ($port && $socketdir && $psql);
    my ($ctype, $collate, $locale_provider, $icu_locale, $icu_rules);

    # try to switch to cluster owner
    prepare_exec 'LC_ALL';
    $ENV{'LC_ALL'} = 'C';
    my $orig_euid = $>;
    $> = (stat (cluster_data_directory $version, $cluster))[4];

    open PSQL, '-|', $psql, '-h', $socketdir, '-p', $port, '-AXtc',
        "SELECT datctype, datcollate FROM pg_database where datname = current_database()", $db or
        die "Internal error: could not call $psql to determine datctype and datcollate: $!";
    my $out = <PSQL> // error 'could not determine datctype and datcollate';
    close PSQL;
    ($out) = $out =~ /^(.*)$/; # untaint
    ($ctype, $collate) = split /\|/, $out;

    if ($version >= 15) {
        open PSQL, '-|', $psql, '-h', $socketdir, '-p', $port, '-AXtc',
            "SELECT CASE datlocprovider::text WHEN 'c' THEN 'libc' WHEN 'i' THEN 'icu' END, daticulocale" .
            ($version >= 16 ? ", daticurules" : "") .
            " FROM pg_database where datname = current_database()", $db or
            die "Internal error: could not call $psql to determine datlocprovider: $!";
        $out = <PSQL> // error 'could not determine datlocprovider';
        close PSQL;
        ($out) = $out =~ /^(.*)$/; # untaint
        ($locale_provider, $icu_locale, $icu_rules) = split /\|/, $out;
    }

    $> = $orig_euid;
    restore_exec;
    chomp $ctype;
    chomp $collate;
    return ($ctype, $collate, $locale_provider, $icu_locale, $icu_rules) unless $?;
    return (undef, undef);
}


=head2 get_cluster_locales

 Return the CTYPE and COLLATE locales of a cluster.

 This needs to be called as root or as the cluster owner.
 (For versions <= 8.3; for >= 8.4, use get_db_locales()).

 Arguments: <version> <cluster>
 Returns: (LC_CTYPE, LC_COLLATE) or (undef,undef) if it cannot be determined.

=cut

sub get_cluster_locales {
    my ($version, $cluster) = @_;
    my ($lc_ctype, $lc_collate) = (undef, undef);

    if ($version >= '8.4') {
	print STDERR "Error: get_cluster_locales() does not work for 8.4+\n";
	exit 1;
    }

    my $pg_controldata = get_program_path 'pg_controldata', $version;
    if (! -e $pg_controldata) {
        print STDERR "Error: pg_controldata not found, please install postgresql-$version\n";
        exit 1;
    }
    prepare_exec ('LC_ALL', 'LANG', 'LANGUAGE');
    $ENV{'LC_ALL'} = 'C';
    my $result = open (CTRL, '-|', $pg_controldata, (cluster_data_directory $version, $cluster));
    restore_exec;
    return (undef, undef) unless defined $result;
    while (<CTRL>) {
	if (/^LC_CTYPE\W*(\S+)\s*$/) {
	    $lc_ctype = $1;
	} elsif (/^LC_COLLATE\W*(\S+)\s*$/) {
	    $lc_collate = $1;
	}
    }
    close CTRL;
    return ($lc_ctype, $lc_collate);
}


=head2 get_cluster_controldata

 Return the pg_control data for a cluster

 Arguments: <version> <cluster>
 Returns: hashref

=cut

sub get_cluster_controldata {
    my ($version, $cluster) = @_;

    my $pg_controldata = get_program_path 'pg_controldata', $version;
    if (! -e $pg_controldata) {
        print STDERR "Error: pg_controldata not found, please install postgresql-$version\n";
        exit 1;
    }
    prepare_exec ('LC_ALL', 'LANG', 'LANGUAGE');
    $ENV{'LC_ALL'} = 'C';
    my $result = open (CTRL, '-|', $pg_controldata, (cluster_data_directory $version, $cluster));
    restore_exec;
    return undef unless defined $result;
    my $data = {};
    while (<CTRL>) {
	if (/^(.+?):\s*(.*)/) {
            $data->{$1} = $2;
	} else {
            error "Invalid pg_controldata output: $_";
	}
    }
    close CTRL;
    return $data;
}


=head2 get_cluster_databases

 Return an array with all databases of a cluster.

 This requires connection privileges to template1, so
 this function should be called as the cluster owner.

 Arguments: <version> <cluster>
 Returns: array of database names or undef on error.

=cut

sub get_cluster_databases {
    my ($version, $cluster) = @_;
    my $port = get_cluster_port $version, $cluster;
    my $socketdir = get_cluster_socketdir $version, $cluster;
    my $psql = get_program_path 'psql', $version;
    return undef unless ($port && $socketdir && $psql);

    # try to swich to cluster owner
    prepare_exec 'LC_ALL';
    $ENV{'LC_ALL'} = 'C';
    my $orig_euid = $>;
    $> = (stat (cluster_data_directory $version, $cluster))[4];

    my @dbs;
    my @fields;
    if (open PSQL, '-|', $psql, '-h', $socketdir, '-p', $port, '-AXtl') {
        while (<PSQL>) {
            chomp;
            @fields = split '\|';
            next if $#fields < 2; # remove access privs which get line broken
            push (@dbs, $fields[0]);
        }
        close PSQL;
    }

    $> = $orig_euid;
    restore_exec;

    return $? ? undef : @dbs;
}


=head2 get_file_device

 Return the device name a file is stored at.

 Arguments: <file path>
 Returns:  device name, or '' if it cannot be determined.

=cut

sub get_file_device {
    my $dev = '';
    prepare_exec;
    my $pid = open3(\*CHLD_IN, \*CHLD_OUT, \*CHLD_ERR, '/bin/df', $_[0]);
    waitpid $pid, 0; # we simply ignore exit code and stderr
    while (<CHLD_OUT>) {
	if (/^\/dev/) {
	    $dev = (split)[0];
	}
    }
    restore_exec;
    close CHLD_IN;
    close CHLD_OUT;
    close CHLD_ERR;
    return $dev;
}


=head2 parse_hba_line

 Parse a single pg_hba.conf line.

 Arguments: <line>
 Returns: Hash reference (or only line and type==undef for invalid lines)

=over 4

=item *

line -> the verbatim pg_hba line

=item *

type -> comment, local, host, hostssl, hostnossl, undef

=item *

db -> database name

=item *

user -> user name

=item *

method -> trust, reject, md5, crypt, password, krb5, ident, pam

=item *

ip -> ip address

=item *

mask -> network mask (either a single number as number of bits, or bit mask)

=back

=cut

sub parse_hba_line {
    my $l = $_[0];
    chomp $l;

    # comment line?
    return { 'type' => 'comment', 'line' => $l } if ($l =~ /^\s*($|#)/);

    my $res = { 'line' => $l };
    my @tok = split /\s+/, $l;
    goto error if $#tok < 3;

    $$res{'type'} = shift @tok;
    $$res{'db'} = shift @tok;
    $$res{'user'} = shift @tok;

    # local connection?
    if ($$res{'type'} eq 'local') {
	goto error if $#tok > 1;
	goto error unless valid_hba_method($tok[0]);
	$$res{'method'} = join (' ', @tok);
	return $res;
    }

    # host connection?
    if ($$res{'type'} =~ /^host((no)?ssl)?$/) {
	my ($i, $c) = split '/', (shift @tok);
	goto error unless $i;
	$$res{'ip'} = $i;

	# CIDR mask given?
	if (defined $c) {
	    goto error if $c !~ /^(\d+)$/;
	    $$res{'mask'} = $c;
	} else {
	    $$res{'mask'} = shift @tok;
	}

	goto error if $#tok > 1;
	goto error unless valid_hba_method($tok[0]);
	$$res{'method'} = join (' ', @tok);
	return $res;
    }

error:
    $$res{'type'} = undef;
    return $res;
}


=head2 read_pg_hba

 Parse given pg_hba.conf file.

 Arguments: <pg_hba.conf path>
 Returns: Array with hash refs; for hash contents, see parse_hba_line().

=cut

sub read_pg_hba {
    open HBA, $_[0] or return undef;
    my @hba;
    while (<HBA>) {
	my $r = parse_hba_line $_;
	push @hba, $r;
    }
    close HBA;
    return @hba;
}


=head2 valid_hba_method

 Check if hba method is known

 Argument: hba method
 Returns: True if method is valid

=cut

sub valid_hba_method {
    my $method = $_[0];

    my %valid_methods = qw/trust 1 reject 1 md5 1 crypt 1 password 1 krb5 1 ident 1 pam 1/;

    return exists($valid_methods{$method});
}

1;
