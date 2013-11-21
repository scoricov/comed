#!/usr/bin/env perl

use warnings;
use strict;

use Test::More tests => 5;
use AnyEvent;
use File::Temp qw(tempdir tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";


BEGIN {
    use_ok( 'Comed::MessageQueue' );
}

diag( 'Testing Comed::MessageQueue' );

my $mq = Comed::MessageQueue->new(
    rotation_interval => 1,
    buckets_number => 2
);

my $subscription_id = $mq->register_channel('user1', 'cookie1');
$mq->accept_messages('user1', 'test message1');
$mq->accept_messages('user1', 'test message2');
$mq->accept_messages('user1', 'test message3');

$mq->rotate_buckets;

my $subscription2_id = $mq->register_channel('user2', 'cookie2');
$mq->accept_messages('user2', 'test message for user2');

my $mesages = $mq->get_messages($subscription_id, 'user1', 'cookie1');
$mq->rotate_buckets;

diag( 'Complience' );

is_deeply($mesages,
    [
        'test message1',
        'test message2',
        'test message3'
    ]
);

$mq->accept_messages('user1', 'NEW test message for user1');
$mq->accept_messages('nonexisting-user', 'foo');

my $subscription3_id = $mq->register_channel('user3', 'cookie3');
$mq->accept_messages('user3', 'daily mail for user3');

is_deeply($mq->_buckets,
        [
          {
            'user3' =>  {
                           '3' => [
                                    [
                                      \'daily mail for user3'
                                    ],
                                    'cookie3'
                                  ]
                        }
          },
          {
            'user1' =>  {
                           '1' => [
                                    [
                                      \'NEW test message for user1'
                                    ],
                                    'cookie1'
                                  ]
                        }
                       ,
            'user2' => 
                        {
                           '2' => [
                                    [
                                      \'test message for user2'
                                    ],
                                    'cookie2'
                                  ]
                        }
          }
        ]
);

my $cv = AnyEvent->condvar;

my $w  = AnyEvent->timer(after => 1.5, cb => sub {
    is_deeply($mq->_buckets,
        [
          {},
          {
            'user3' =>  {
                           '3' => [
                                    [
                                      \'daily mail for user3'
                                    ],
                                    'cookie3'
                                  ]
                        }
          }
        ]
    );
} );

my $w2 = AnyEvent->timer(after => 2.2, cb => sub {
    is_deeply($mq->_buckets,
        [ {}, {} ]
    );
    $cv->send;
} );

$cv->recv;
