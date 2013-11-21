package Comed::Web;

use strict;

use AnyEvent::HTTP;
use JSON::XS;
use Try::Tiny;
use Comed::Log;
use Comed::MessageQueue;
use Data::Dumper;


our $VERSION = 1.88;


sub new
{
    my ($class, @args) = @_;

    my $self = bless {
        timeout              => 60,
        sidcookie_name       => 'session',
        sidcookie_length     => 128,
        auth_uri_prefix      => undef,
        auth_timeout         => 3,
        auth_status_ok       => 200,
        json_deserialize     => 0,
        num_connections      => 0,
        num_channel_requests => 0,
        num_auth_failures    => 0,
        num_errs_internal    => 0,
        @args,
    }, ref $class || $class;

    my $sidcookie_name   = $self->{sidcookie_name};
    my $sidcookie_length = $self->{sidcookie_length};
    $self->{sidcookie_regexp} = qr/$sidcookie_name=([^;]{1,$sidcookie_length})/;

    $self->{mq}   ||= Comed::MessageQueue->instance;
    $self->{json} ||= JSON::XS->new->allow_blessed
        if ($self->{json_deserialize});

    return $self;
}

sub num_connections { shift->{num_connections} }

sub throw
{
    my ($code, $msg) = @_;
    die [ $code, $msg ];
}

sub _catch
{
    my ($self, $error) = @_;

    if ('ARRAY' eq (ref $error)) {
        return [
            int($error->[0] || 500),
            [ 'Content-Type' => 'text/plain' ],
            [ $error->[1] || 'Unknown error' ]
        ];
    } else {
        ERROR $error;
        $self->{num_errs_internal} ++;
        return [
            500,
            [ 'Content-Type' => 'text/plain' ],
            [ "Internal Server Error" ]
        ];
    }
}

sub async_cb
{
    my $tx = shift;
    my $cb = shift;
    return sub {
        my @args = @_;
        try { $cb->(@args) }
        catch { $tx->[0]->croak($_) };
    };
}

sub reply_messages
{
    my ($self, $tx, $messages, $channel_id, $extra_headers) = @_;
    my $msg;

    if ($self->{json_deserialize})
    {
        my @deserialized = map { $self->{json}->decode($_) } @$messages;
        $msg = $self->{json}->encode(\@deserialized) if @deserialized;
    }
    else {
        $msg = '[' . join(',', @$messages) . ']' if @$messages;
    }

    $msg ||= '[[0]]';
    my $ct_postfix = $channel_id ? '; x-channel-id:' . $channel_id : '';
    my $headers = [
        'Content-Type'   => 'application/json' . $ct_postfix,
        'Content-Length' => length($msg),
    ];
    push @$headers, @$extra_headers if $extra_headers;

    $tx->[0]->send( [ 200, $headers ] );
    if (my $w = $tx->[1])
    {
        $w->write($msg);
        $w->close;
    }
}

sub reply_stats
{
    my ($self, $tx) = @_;
    my $now = time();
    my @uptime = gmtime($now - $^T);
    my $uptime = sprintf("%dd %dh %dm %ds", @uptime[7,2,1,0]);
    my $mq = $self->{mq};
    my $msg = <<END;
Comed Stats

--Comed---------------------------------
version          = r$VERSION
uptime           = $uptime

--Web-----------------------------------
connections      = ${\$self->{num_connections}}
channel_requests = ${\$self->{num_channel_requests}}
auth_failures    = ${\$self->{num_auth_failures}}
errors_internal  = ${\$self->{num_errs_internal}}

--MessageQueue--------------------------
last_channel     = ${\$mq->last_channel}
msgs_accepted    = ${\$mq->accepted}
msgs_delivered   = ${\$mq->requested}
msgs_rejected    = ${\$mq->rejected}
END

    $tx->[0]->send( [
        200, [
            'Content-Type'   => 'text/plain',
            'Content-Length' => length($msg),
        ], [ $msg ]
    ] );
}

sub reply_dump
{
    my ($self, $tx, $user_name) = @_;
    my $dump = Dumper($self->{mq}{b}[0]{$user_name});
    my $msg = <<END;
Comed MseeageQueue Dump, user '$user_name'

$dump
END

    $tx->[0]->send( [
        200, [
            'Content-Type'   => 'text/plain',
            'Content-Length' => length($msg),
        ], [ $msg ]
    ] );
}

sub process_request
{
    my ($self, $tx, $env) = @_;
    my $method = $env->{REQUEST_METHOD};
    my $path   = $env->{PATH_INFO};

    ('GET' eq $method) or throw(405, "Method not allowed\n");

    if ($self->{expose_stats})
    {
        return $self->reply_dump($tx, $1)
            if ($path =~ m|^/stats/dump/([^/]+)/?|);
        return $self->reply_stats($tx)
            if ($path =~ m|^/stats/?|);
    }

    my ($channel_id, $flags) = ($path =~ m|/poll/(\d{1,32})/(\d)|)
        or throw(404, "Not found\n");

    my ($session_cookie) = ($env->{HTTP_COOKIE} =~ $self->{sidcookie_regexp})
        or throw(403, "Session cookie needed\n");

    my @session_id_parts = split /:/, $session_cookie, 4;
    my $user_name = $session_id_parts[2];
    my $session_id = join '', @session_id_parts[0,1,3];

    my $mq = $self->{mq};
    my $cb = async_cb($tx, sub {
        $self->reply_messages($tx, $_[0], $channel_id)
    } );
    my $cv = AE::cv;
    $cv->cb(sub { $cb->($_[0]->recv) });

    if ($channel_id)
    {
        if ( my $messages =
                $mq->get_messages($channel_id, $user_name, $session_id, $cv) )
        {
            $cv->send($messages) if (@$messages);
        }
        else { $channel_id = 0 }
    }

    unless ($channel_id)
    {
        $self->{num_channel_requests} ++;

        if ($self->{auth_uri_prefix})
        {
            my $url = $self->{auth_uri_prefix} . $session_cookie;
            http_request(
                GET       => $url,
                timeout   => $self->{auth_timeout},
                on_header => async_cb($tx,
                sub {
                    my ($status) = ($_[1]{Status} =~ m/^(\d{3})/);
                    if ($self->{auth_status_ok} == $status)
                    {
                        $channel_id =
                            $mq->register_channel($user_name, $session_id, $cv)
                                or throw(500, "Channels' limit exceeded\n");
                    }
                    elsif (500 <= $status) {
                        ERROR sprintf
                            'Authorization request has failed: %s. (%s)',
                            $_[1]{Reason} || '', $url;
                        throw(403, "Forbidden\n");
                    }
                    else {
                        $self->{num_auth_failures} ++;
                        throw(403, "Invalid session\n");
                    }
                } ),
            );
        }
        else
        {
            $channel_id = $mq->register_channel($user_name, $session_id, $cv)
                or throw(500, "Channels' limit exceeded\n");
        }
    }

    my $t; $t = AE::timer $self->{timeout}, 0, sub {
        undef $t;
        $cv->send();
    };
}

sub run
{
    my ($self, $env) = @_;
    my $cv = AE::cv;
    my $tx = [ $cv ];

    return sub {
        my $start_response = shift;
        $tx->[0]->cb(sub {
            my $cv = shift;
            try {
                my $res = $cv->recv;
                my $w = $start_response->($res);
                if (!$res->[2] && $w) {
                    $tx->[1] = $w;
                }
            } catch {
                $start_response->($self->_catch($_));
            };
            $self->{num_connections} --;
        });

        $self->{num_connections} ++;

        try {
            $self->process_request($tx, $env);
        } catch {
            $cv->croak($_);
        };
    };
}

sub compile_psgi_app
{
    my $self = shift;
    return sub { $self->run(shift); }
}

sub psgi_app
{
    my $self = shift;
    return $self->{psgi_app} ||= $self->compile_psgi_app;
}

1;
__END__