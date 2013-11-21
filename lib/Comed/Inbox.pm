package Comed::Inbox;

use strict;
use AnyEvent;
use IO::Socket::INET;
use Comed::MessageQueue;


sub new
{
    my ($class, @args) = @_;

    my $self = bless {
        host       => '0.0.0.0',
        port       => 8686,
        reuse_port => 0,
        chunk_size => 1024,
        pattern    => undef,
        @args,
    }, ref $class || $class;

    $self->{socket} = new IO::Socket::INET(
        Proto     => 'udp',
        LocalHost => $self->{host},
        LocalPort => $self->{port},
        ReusePort => $self->{reuse_port},
        Broadcast => 1,
    ) or die $!;
    $self->{io}     = AE::io $self->{socket}, 0, sub { $self->read_message };
    $self->{mq}   ||= Comed::MessageQueue->instance;

    if (defined (my $pattern = $self->{pattern})) {
        $self->{pattern} = qr/^$pattern/ unless ref $pattern eq 'RegExp';
    }

    return $self;
}

sub read_message
{
    my $self = shift;
    recv $self->{socket}, my $raw, $self->{chunk_size}, 0;
    my ($user_name, $message) = split /,/, $raw, 2;
    my $pattern = $self->{pattern};

    $self->{mq}->accept_messages($user_name, $message)
        if (!$pattern || ($user_name =~ $pattern));
}

1;
__END__