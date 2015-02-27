#!/usr/bin/perl
use strict;
use warnings;
use HTTP::Daemon;
use HTTP::Status qw(status_message);
use Net::MQTT::Simple 1.17;
use JSON::XS qw(encode_json);
use URI::QueryParam;
use Linux::Epoll;

# Note: this will probably not work well with MQTT brokers that send duplicate
# messages when subscriptions overlap, e.g. mosquitto with the setting
# allow_duplicate_messages = false (defaults to true).

my $CRLF = "\cM\cJ";

# config
$HTTP::Daemon::DEBUG = 0;
my $port = 80;
my $mqtt_server = "::1";
my $maxaccept = 20;
my $maxtime = 10 * 60;
my $request_timeout = 10;
my $select_timeout = .02;
my $client_select_timeout = .05;
my $retry_min = 5;
my $retry_extra = 15;
my $use_chunked = 0;
my @allow_subscribe = ('typing-speed-test.aoeu.eu');
my %allow_publish   = (
    'typing-speed-test.aoeu.eu' => qr/^\d+ CPM$/,
    'tst-internal/details' => qr/^[\r\n\x20-\x7f]+$/,  # ascii only
);
my @keep_subscribed = ('typing-speed-test.aoeu.eu');
my @fake_retain     = ('typing-speed-test.aoeu.eu');

# state
our @clients;
my %topic_refcount;
my %retain;
my $delta = 0;

*filter_as_regex = \&Net::MQTT::Simple::filter_as_regex;

my %keep_subscribed = map { $_ => 1 } @keep_subscribed;
$topic_refcount{$_} = -1 for @keep_subscribed;

my $never_match = '(?!)';
my $keep_subscribed_re = join('|', map filter_as_regex($_), @keep_subscribed)
    || $never_match;
my $allow_subscribe_re = join('|', map filter_as_regex($_), @allow_subscribe)
    || $never_match;
my $fake_retain_re     = join('|', map filter_as_regex($_), @fake_retain)
    || $never_match;

{
    package HTTP::Daemon::Blah;
    use base 'HTTP::Daemon';

    sub accept {
        shift->SUPER::accept('HTTP::Daemon::ClientConn::Blah');
    }

    package HTTP::Daemon::ClientConn::Blah;
    use base 'HTTP::Daemon::ClientConn';

    sub chunk {
        my ($self, $chunk) = @_;
        no warnings qw(closed);
        if (not $use_chunked) {
            return print $self $chunk;
        }
        return printf $self "%x%s%s%s",
            length $chunk,
            $CRLF,
            $chunk,
            $CRLF;
    }

    my $epoll = Linux::Epoll->new;
    sub _need_more {
        # Hack: use epoll instead of select
        my $self = shift;
        my $timeout = $_[1];
        if ($timeout) {
            my $n = 0;
            $epoll->add($self, 'in', sub {
                shift->{in} or return;
                $n = 1;
            });
            $epoll->wait(1, $timeout);
            $epoll->delete($self);
            if (not $n) {
                main::poll();  # accept() asap.
                return;
            }
        }
        $self->SUPER::_need_more($_[0]);
    }
}

my $mqtt = Net::MQTT::Simple->new($mqtt_server);

sub shout {
    my ($clients, $incoming_topic, $value, $retain) = @_;
    eval { utf8::decode($value) };

    $retain ||= 2 if $incoming_topic =~ /$fake_retain_re/;
    $retain{$incoming_topic} = $value if $retain;

    my $interested = 0;

    for my $client (@$clients) {
        next if not $client->{streaming};

        for my $client_topic (@{ $client->{topics} }) {
            next if $incoming_topic !~ $client_topic->{regex};

            my $event = $client_topic->{event}
                ? "event: $client_topic->{event}$CRLF"
                : "";

            my $data = join $CRLF, map "data: $_", split /\r?\n/,
                encode_json([ $incoming_topic, $value, $retain ]);

            $client->{socket}->chunk("$event$data$CRLF$CRLF")
                and $interested++;
        }
    }
    return $interested;
}

sub incoming {
    my ($topic, $value, $retain) = @_;
    my $num = shout \@clients, $topic, $value, $retain;
    substr $value, 12, 3, "..." if length($value) > 15;
    warn "\n" if $delta;
    $delta = 0;
    warn "Pushed $topic to $num clients: $value\n";
}

$mqtt->subscribe(map { $_ => \&incoming } @keep_subscribed);

my $epoll = Linux::Epoll->new;
my @can_read;

$SIG{PIPE} = sub {
    my $now = time;
    for (@clients) {
        next if $_->{delete};

        next if $_->{streaming}
            and ($_->{time} + $maxtime) > $now
            and $_->{socket}->connected;

        next if (not $_->{streaming})
            and ($_->{time} + $request_timeout) > $now;

        $_->{socket}->chunk("") if $_->{streaming};

        $_->{delete} = 1;  # Delay because of foreach in main loop
        close $_->{socket};

        $topic_refcount{$_}-- for grep !/$keep_subscribed_re/,
            map $_->{topic}, @{ $_->{topics} };

        my @gone = grep $topic_refcount{$_} == 0, keys %topic_refcount;
        $mqtt->unsubscribe(@gone);
        delete @topic_refcount{@gone};

        print STDERR $_->{streaming} ? "-" : "!";
        $delta++;
    }
};

my $d = HTTP::Daemon::Blah->new(
    LocalPort => $port,
    Reuse => 1,
    Listen => 50,
) or die $!;

$d->timeout($select_timeout);

$epoll->add($d, 'in', sub {
    shift->{in} or return;

    while (my $socket = $d->accept) { #  and $accepted++ < $maxaccept) {
        my $client = { socket => $socket, time => time(), streaming => 0 };
        push @clients, $client;
        $epoll->add($socket, 'in', sub {
            shift->{in} or return;
            push @can_read, $client;
        });
        $socket->timeout($client_select_timeout);
        print STDERR "+";
        $delta++;
    }
});

sub poll {
    $epoll->wait(1e4, $select_timeout);
}

while (1) {
    $mqtt->tick($select_timeout);

    poll();

    CLIENT: for my $client (@can_read) {
        my $socket = $client->{socket};

        $client->{delete} and next;
        $client->{streaming} and next;

        my $end = sub {
            eval { $epoll->delete($socket) } if $socket->fileno();
            close $socket;
            print STDERR shift;
            $delta++;
            $client->{delete} = 1;
            no warnings qw(exiting);
            next CLIENT;
        };
        my $error = sub {
            my ($code, $message) = @_;
            # Built-in send_error only does text/html
            my $body = "$code - " . status_message($code) ."$CRLF$message$CRLF";
            $socket->send_basic_header($code);
            $socket->send_header("Connection" => "close");
            $socket->send_header("Content-Type" => "text/plain");
            $socket->send_header("Content-Length" => length $body);
            $socket->send_crlf();
            print {$socket} $body;
            $end->('E');
        };

        my $req = $socket->get_request(0)
            or $end->('G');

        $epoll->delete($socket);

        my $uri = $req->uri;
        my $method = $req->method;

        $method =~ /^(?:GET|HEAD|POST)$/
            or $error->(405, "Oi, don't do that.");

        $uri->path =~ m[^/*mqtt$]
            or $error->(418, "Because 404 is boring.");

        # Cheat: turn body into query string
        $uri->query( $req->content ) if $method eq 'POST';

        my $good_topics = 0;

        for my $key ($uri->query_param) {
            my $value = $uri->query_param($key);

            # MSIE EventSource polyfill.
            next if $key eq 'lastEventId';
            next if $key eq 'r';

            $good_topics++;

            if ($method eq 'POST') {
                my $valid_key;
                my $valid_value;
                for my $filter (keys %allow_publish) {
                    my $topic_regex = filter_as_regex($filter);
                    my $value_regex = $allow_publish{$filter};
                    if ($key =~ /$topic_regex/) {
                        $valid_key = 1;
                        $valid_value ||= ($value =~ /$value_regex/);
                    }
                }
                $valid_key
                    or $error->(403, "Topic $key is not in my POST whitelist.");
                $valid_value
                    or $error->(403, "I don't like the value for $key.");

                $mqtt->publish($key, $value);
            } else {
                $key =~ /$allow_subscribe_re/
                    or $error->(403, "Topic $key is not in my GET whitelist.");

                push @{ $client->{topics} }, {
                    topic => $key,
                    regex => filter_as_regex($key),
                    event => $value,
                };
            }
        }

        $good_topics or $error->(400, "Great http, bad mqtt. Need topics!");

        $socket->send_basic_header(200);
        $socket->send_header("Access-Control-Allow-Origin" => "*");
        $socket->send_header("Cache-Control" => "no-transform,no-cache");

        if ($method eq 'POST') {
            my $body = "Done.$CRLF";
            $socket->send_header("Content-Type" => "text/event-stream");
            $socket->send_header("Content-Length" => length $body);
            $socket->send_crlf;
            print {$socket} $body;
            print STDERR "P";
            $delta++;
            next CLIENT;
        }

        $socket->send_header("Transfer-Encoding" => "chunked") if $use_chunked;
        $socket->send_header("Content-Type" => "text/event-stream");
        $socket->send_header("Connection" => "close");
        $socket->send_crlf;

        $end->('H') if $socket->head_request;

        if ($req->header("User-Agent") =~ /MSIE/) {
            $socket->chunk(":padding" x 256, $CRLF);
        }

        # Randomize retry time to avoid surge on reconnects
        my $retry = int(($retry_min + rand $retry_extra) * 1000);
        $socket->chunk("retry: $retry$CRLF");

        $client->{streaming} = 1;

        my $topics = join '|', map $_->{regex}, @{ $client->{topics} };

        # If we're still subscribed (refcount == 0), the broker will handle
        # sending retained messages for us, on subscription.
        shout(
            [ $client ],
            $_,
            $retain{$_},
            /$fake_retain_re/ ? (exists($topic_refcount{$_}) ? 2 : 3) : 1
            # 1 = real, 2 = fake, 3 = fake + stale
        ) for grep {
            /$topics/
            && (/$fake_retain_re/ || exists($topic_refcount{$_}))
        } keys %retain;

        for my $key (map $_->{topic}, @{ $client->{topics} }) {
            $mqtt->subscribe($key => \&incoming)
                unless $keep_subscribed{$key}
                or     $topic_refcount{$key}++;
        }
    }

    @can_read = ();

    @clients = grep !$_->{delete}, @clients;
}
