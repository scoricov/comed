package Comed::MessageQueue;

use strict;
use AnyEvent;
use Math::BigInt;
use Try::Tiny;


my $MQ;


sub instance
{
    my $class = shift;
    $MQ = $class->new(@_) if @_;
    $MQ ||= $class->new;
}

sub new
{
    my ($class, @args) = @_;

    my $self = bless {
        rotation_interval   => 10, # seconds, fractional value
        buckets_number      => 2,  # >= 1
        max_store_msgs      => 64,
        max_user_chans      => 0,
        publish_async_delay => 0,
        channel_cnt         => Math::BigInt->new('0'),
        accepted_cnt        => Math::BigInt->new('0'),
        requested_cnt       => Math::BigInt->new('0'),
        rejected_cnt        => Math::BigInt->new('0'),
        b                   => [],
        @args,
    }, ref $class || $class;

    $self->rotate_buckets;
    $self->start_timer;

    return $self;
}

sub accepted           { shift->{accepted_cnt}->bstr  }
sub requested          { shift->{requested_cnt}->bstr }
sub rejected           { shift->{rejected_cnt}->bstr  }
sub last_channel       { shift->{channel_cnt}->bstr   }
sub reset_last_channel { shift->{channel_cnt}->bzero  }

sub rotate_buckets
{
    my $self = shift;
    my $buckets = $self->{b};

    unshift @$buckets, {};
    $#$buckets = $self->{buckets_number} - 1;

    return 1;
}

sub get_messages
{
    my ($self, $channel_id, $user_name, $cookie, $cv) = @_;
    my ($user, $bucket_id) = $self->_lookup_user($user_name);
    $user or return 0;
    my $channel = $user->{$channel_id} or return 0;

    # validation
    ( $cookie eq $channel->[1] ) or return 0;

    # retrieve and clear
    my $messages = delete $channel->[0];
    $channel->[0] = [];
    $channel->[2] = $cv if $cv;

    # refresh user
    $self->{b}[0]{$user_name} = $user if ($bucket_id != 0);

    my @messages_list = map { $$_ } @$messages;
    $self->{requested_cnt}->badd(scalar @messages_list);

    return \@messages_list;
}

sub accept_messages
{
    my ($self, $user_name, @messages) = @_;
    my $num_messages  = @messages or return 0;
    my ($user)        = $self->_lookup_user($user_name);

    if (!$user)
    {
        $self->{rejected_cnt}->badd($num_messages);
        return 0;
    }

    my $messages      = \@messages;
    my @channels      = values %$user;
    my $req_chans_cnt = 0;
    my $async_delay   = $self->{publish_async_delay};

    for my $id (0..$#channels)
    {
        if ($req_chans_cnt && $async_delay)
        {
            my $t; $t = AE::timer $async_delay, 0, sub
            {
                undef $t;
                my $cnt = 0;
    
                for my $id_t ($id..$#channels)
                {
                    $self->_publish_messages($channels[$id_t], $messages) &&
                        $cnt++;
                }
    
                $self->{requested_cnt}->badd($cnt * $num_messages) if $cnt;
            };
    
            last;
        }
    
        $self->_publish_messages($channels[$id], $messages) &&
            $req_chans_cnt++;
    }

    $self->{accepted_cnt}->badd($num_messages);
    $self->{requested_cnt}->badd($req_chans_cnt * $num_messages)
        if $req_chans_cnt;

    return 1;
}

sub register_channel
{
    my ($self, $user_name, $cookie, $cv) = @_;

    my $bucket = $self->{b}[0];
    my $user = $bucket->{$user_name} ||= {};
    my $num_channels = keys %$user;

    if (my $max_user_chans = $self->{max_user_chans})
    {
        ($num_channels >= $max_user_chans) && return 0;
    }

    my $channel_id = $self->{channel_cnt}->binc->bstr;
    $user->{$channel_id} = $cv ? [ [], $cookie, $cv ] : [ [], $cookie ];

    return $channel_id;
}

sub start_timer
{
    my $self = shift;

    $self->{timer} = AnyEvent->timer(
        after    => $self->{rotation_interval},
        interval => $self->{rotation_interval},
        cb       => sub { $self->rotate_buckets },
    );
}

sub stop_timer
{
    my $self = shift;
    undef $self->{timer};
}

sub _publish_messages
{
    my ($self, $channel, $messages) = @_;
    my $cv = $channel->[2];
    my $need_backup = 1;

    if ($cv && $cv->cb)
    {
        $need_backup = 0;
        try {
            $cv->send($messages);
        } catch {
            $channel->[2] = undef;
            $need_backup  = 1;
        }
    }

    if ($need_backup)
    {
        my $msgs_upper   = $self->{max_store_msgs} - 1;
        my $message_pool = $channel->[0];

        push @$message_pool, map { \$_ } @$messages;

        $#$message_pool = $msgs_upper
            if (($msgs_upper >= 0) && ($#$message_pool > $msgs_upper));

        return 0;
    }

    return 1;
}

sub _lookup_user
{
    my ($self, $user_name) = @_;
    my ($user, $bucket_id);
    my $buckets = $self->{b};

    for (0..$#$buckets)
    {
        $bucket_id = $_;
        $user = $buckets->[$bucket_id]{$user_name} and last;
    }

    return ($user, $bucket_id);
}

sub _buckets { shift->{b} }

1;
__END__