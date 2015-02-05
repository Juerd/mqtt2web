#!/usr/bin/perl
use strict;
use warnings;
use HTTP::Daemon;
use Net::MQTT::Simple 1.17;
use JSON::XS qw(encode_json);
use URI::QueryParam;

# Note: this will probably not work well with MQTT brokers that send duplicate
# messages when subscriptions overlap, e.g. mosquitto with the setting
# allow_duplicate_messages = false (defaults to true).

my $CRLF = "\cM\cJ";

# config
$HTTP::Daemon::DEBUG = 0;
my $port = 8080;
my $mqtt_server = "test.mosquitto.org";
my $maxtime = 10 * 60;
my $request_timeout = 5;
my $select_timeout = .05;
my $retry_min = 2;
my $retry_extra = 8;
my $use_chunked = 0;
my @allowed_topics = ('#');
my @keep_subscribed = (); # ('typing-speed-test.aoeu.eu');
my @fake_retain = ('typing-speed-test.aoeu.eu');

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
my $allowed_topics_re  = join('|', map filter_as_regex($_), @allowed_topics)
    || $never_match;
my $fake_retain_re     = join('|', map filter_as_regex($_), @fake_retain)
    || $never_match;

sub HTTP::Daemon::ClientConn::chunk {
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

$SIG{PIPE} = sub {
    my $now = time;
    for (@clients) {
        next if $_->{socket}->connected
            and $_->{streaming}
            and ($_->{time} + $maxtime) > $now;
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

        print STDERR "-";
        $delta++;
    }
};

my $d = HTTP::Daemon->new(
    LocalPort => $port,
    Reuse => 1,
    Listen => 50
) or die $!;

$d->timeout($select_timeout);

while (1) {
    $mqtt->tick($select_timeout);

    while (my $socket = $d->accept) {
        push @clients, { socket => $socket, time => time(), streaming => 0 };
        print STDERR "+";
        $delta++;
    }
    CLIENT: for my $client (grep { not $_->{streaming} } @clients) {
        $_->{delete} and next;  # could be set by SIGPIPE

        my $socket = $client->{socket};
        my $req = $socket->get_request($select_timeout) or next;
        my $uri = $req->uri;

        if ($req->method !~ /^(?:GET|HEAD)$/) {
            $socket->send_error(405, "Hey, don't do that.");
            close $socket;
            next;
        }
        if ($uri->path !~ m[^/*mqtt/*$]) {
            $socket->send_error(418, "Because 404 is boring.");
            close $socket;
            next;
        }

        for my $key ($uri->query_param) {
            if ($key !~ /$allowed_topics_re/) {
                $socket->send_error(403, "Topic $key is not in my whitelist.");
                close $socket;
                next CLIENT;
            }

            push @{ $client->{topics} }, {
                topic => $key,
                regex => filter_as_regex($key),
                event => scalar $uri->query_param($key),
            };
        }


        if (not exists $client->{topics}) {
            $socket->send_error(400, "Great http, bad mqtt. Need topics!");
            close $socket;
            next;
        }

        $socket->send_basic_header(200);
        $socket->send_header("Content-Type" => "text/event-stream");
        $socket->send_header("Access-Control-Allow-Origin" => "*");
        $socket->send_header("Connection" => "close");
        $socket->send_header("Cache-Control" => "no-transform,no-cache");
        $socket->send_header("Transfer-Encoding" => "chunked") if $use_chunked;
        $socket->send_crlf;

        if ($socket->head_request) {
            close $socket;
            next;
        }

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

    @clients = grep !$_->{delete}, @clients;
}
