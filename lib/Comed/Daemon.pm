package Comed::Daemon;

use strict;
use warnings;

use Carp;
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(setsid setuid setpgid);
use Exporter;
use base qw(Exporter);


our @EXPORT_OK = qw(start_daemon stop_daemon);
our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);


sub start_daemon
{
    my ($pid_file, $uid, $gid, $process_name) = @_;
    local $| = 1;

    $process_name ||= 'comed';

    print "Starting $process_name... ";

    if (my $old_pid = get_pid($pid_file)) {
        kill(0, $old_pid) and
            croak "The daemon is already running with PID $old_pid. " .
                  "Please, remove PID file $pid_file and try again.";
    }

    sysopen(PIDFILE, $pid_file, O_RDWR|O_CREAT) or
        croak "Can't open PID file $pid_file: $!";
    flock(PIDFILE, LOCK_EX | LOCK_NB) or
        croak "PID file $pid_file is already locked";
    sysseek PIDFILE, 0, 0 and truncate PIDFILE, 0 or
        croak "PID file $pid_file is not writable: $!";

    if ($uid || $gid)
    {
        chown(($uid || -1), ($gid || -1), $pid_file) or do
        {
            unlink $pid_file;
            croak "Can't change owner of PID file $pid_file: $!";
        };
    }

    my $attempt = 0;
    my $pid;

    while (not defined ($pid = fork())) {
        croak "Too many failed fork attempts: $!\n"
            if ++$attempt > 7;
        warn "Fork failed: $!\n";
        sleep 2;
    }

    if ($pid)
    {
        syswrite PIDFILE, "$pid\n", length("$pid\n") and close(PIDFILE)
            or croak "Can't write PID file $pid_file: $!";

        print "Done (PID=$pid)\n";
        exit 0;
    }

    umask 0;
    POSIX::setsid()                 or croak "Can't start a new session: $!";
    $gid and POSIX::setgid($gid)    || croak "Can't set GID: $!";
    $uid and POSIX::setuid($uid)    || croak "Can't set UID: $!";
    open STDIN,  q{<}, '/dev/null'  or croak "Can't read /dev/null: $!";
    open STDOUT, q{+>&STDIN}        or croak "Can't write to STDIN: $!";
    open STDERR, q{+>&STDIN}        or croak "Can't write to STDIN: $!";
    $0 = $process_name;

    $SIG{TERM} = $SIG{KILL} = sub
    {
        sysopen(PIDFILE, $pid_file, O_TRUNC);
        close(PIDFILE);
        unlink $pid_file;
        exit 0;
    };

    1;
}

sub stop_daemon
{
    my $pid_file = shift;
    local $| = 1;

    print "Stopping daemon... ";

    my $pid = get_pid($pid_file) or die
        "The daemon is probably not running. Failed to read PID file $pid_file";

    if ( kill(0, $pid) )
    {
        kill(15, $pid) or kill(9, $pid)
            or croak "Failed to kill the process $pid";
    }
    else
    {
        print "Failed to locate the process with PID $pid. " .
              "Probably it is not running. Cleaning PID file... ";
    }

    unlink $pid_file or croak "Failed to remove PID file $pid_file";
    print "Done\n";

    1;
}

sub get_pid
{
    my ($pid_file) = @_;

    (-r $pid_file) or return 0;
    open(PIDFILE, '<', $pid_file) or return 0;
    my $pid = <PIDFILE>;
    close(PIDFILE);
    return int($pid);
}

1;
__END__