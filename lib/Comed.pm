package Comed;

use strict;
use 5.008_001;

use Carp;
use EV;
use AnyEvent;
use Twiggy::Server;
use Config::General qw( ParseConfig );
use Log::Dispatch;
use Comed::Log;
use Comed::MessageQueue;
use Comed::Inbox;
use Comed::Web;

our $VERSION = 1.88;

our %CONFIG_SETTINGS = (
    -LowerCaseNames => 1,
    -UseApacheInclude => 1,
    -IncludeRelative => 1,
    -IncludeDirectories => 1,
    -IncludeGlob => 1,
    -MergeDuplicateBlocks => 0,
    -MergeDuplicateOptions => 0,
    -AutoTrue => 0,
    -CComments => 0,
    -UTF8 => 0,
);

sub new
{
    my ($class, $config) = @_;
    my $ref = ref $config;

    (defined $config && (!$ref || ('HASH' eq $ref)))
        or croak 'Valid config HASHREF or filename SCALAR required';

    my $self = bless {
        config => $config,
        logger => undef,
    }, ref $class || $class;

    $self->read_config($config) unless $ref;
    return $self->init ? $self : 0;
}

sub config { shift->{config} }

sub init
{
    my $self = shift;
    my $config = $self->{config};

    my $log_level = $config->{logger}{level} || 'critical';
    my $logger = Comed::Log::set_logger( Log::Dispatch->new ) or return 0;

    if (my $log_file = $config->{logger}{file})
    {
        require Log::Dispatch::File;
        $logger->add( Log::Dispatch::File->new
            ( name      => 'logfile',
              min_level => $log_level,
              filename  => $log_file,
              mode      => '>>',
              newline   => 1,
            )
        );
    }

    if (my $syslog_ident = $config->{logger}{syslog})
    {
        require Log::Dispatch::Syslog;
        $logger->add( Log::Dispatch::Syslog->new
            ( name      => 'syslog',
              min_level => $log_level,
              ident     => $syslog_ident,
            )
        );
    }

    if ($config->{logger}{screen})
    {
        require Log::Dispatch::Screen;
        $logger->add( Log::Dispatch::Screen->new
            ( name      => 'screen',
              min_level => $log_level,
              newline   => 1,
            )
        );
    }

    $self->{logger} = $logger;
    $self->{cv}     = AE::cv;

    $self->{mq}     = Comed::MessageQueue->new(%{$config->{messagequeue}})
        or croak 'Failed to initialize message queue';

    $self->{inbox}  = Comed::Inbox->new(%{$config->{inbox}}, mq => $self->{mq})
        or croak 'Failed to initialize inbox';

    $self->{webserver}
                    = Twiggy::Server->new(%{$config->{web}{server}})
        or croak 'Failed to initialize web server';

    $self->{webapp} = Comed::Web->new(%{$config->{web}{app}}, mq => $self->{mq})
        or croak 'Failed to initialize web application';

    $self->{webserver}->register_service($self->{webapp}->psgi_app);

    1;
}

sub read_config
{
    my ($self, $filename) = @_;

    my %new_config = ParseConfig(
        -ConfigFile => $filename,
        %CONFIG_SETTINGS
    ) or croak 'Failed to read config file ' . $filename . '. ' . $!;

    $self->{config} = \%new_config;
}

sub start
{
    my $self = shift;
    $self->{cv}->recv;
}

1;
__END__


=head1 NAME

Comed - Comet server capable of high load


=head1 DESCRIPTION

This is a Perl implementation of Comet. The server was proven to withstand high
loads with more then 60000 simultanious user channels in production environment.
Comed is capable of performing authentication for clients against an external
HTTP resource based on session stored in cookies.


=head1 VERSION

This document describes Comed version 1.88


=head1 SYNOPSIS

    use Comed;

    my $comed = Comed->new( {
        messagequeue => {
            rotation_interval => 60,
        },
        inbox => {
            host    => '0.0.0.0',
            port    => 7777,
        },
        web => {
            server => {
                host    => '0.0.0.0',
                port    => 8888,
                timeout => 5,
            },
            app => {
                timeout          => 55,
                sidcookie_name   => 'ssid',
                sidcookie_length => 120,
                auth_uri_prefix  => 'http://my.app.com/authorize/?session=',
                auth_timeout     => 3,
                auth_status_ok   => 200,
            },
        },
    } );

    # Or

    my $comed = Comed->new('./comed.conf');

    # Then

    $comed->start;
