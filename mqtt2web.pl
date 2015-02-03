#!/usr/bin/perl
use strict;
use warnings;
use HTTP::Daemon;
use Net::MQTT::Simple ();
use JSON::XS qw(encode_json);

my $CRLF = "\cM\cJ";

# config
$HTTP::Daemon::DEBUG = 0;
my $port = 80;
my $maxtime = 10 * 60;
my $request_timeout = 5;
my $select_timeout = .05;
my $retry_min = 2;
my $retry_extra = 8;
my $use_chunked = 0;

# state
my @clients;
my $retain = "";

sub HTTP::Daemon::ClientConn::chunk {
    my ($self, $chunk) = @_;
    no warnings qw(closed);
    if (not $use_chunked) {
        print $self $chunk;
        return;
    }
    printf $self "%x%s%s%s",
        length $chunk,
        $CRLF,
        $chunk,
        $CRLF;
}

sub shout {
    @_ = map { split /\n/ } @_;

    my @streaming = grep $_->{streaming}, @clients;
    printf "Sending to %d clients: %s",
        scalar @streaming, join "", map "$_\n", @_;

    my $now = time;
    for my $client (@streaming) {
        my $meuk = ($now - $client->{time});
        $client->{socket}->chunk(
            ":$meuk$CRLF" . join("", map {
                "data: $_$CRLF"
            } @_) . $CRLF
        );
    }
}

my $mqtt = Net::MQTT::Simple->new("localhost");
$mqtt->subscribe(
    "#" => sub {
        my ($topic, $value) = @_;
        my ($cpm) = $value =~ /(\d+) CPM/ or return;
        my $wpm = sprintf "%d", $cpm / 5;
        shout $retain = encode_json {
            cpm => $cpm+0, wpm => $wpm+0, time => time()
        };
    },
);

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
    }
    for my $client (grep { not $_->{streaming} } @clients) {
        $_->{delete} and next;  # could be set by SIGPIPE

        my $socket = $client->{socket};
        my $req = $socket->get_request($select_timeout) or next;

        if ($req->method !~ /^(?:GET|HEAD)$/) {
            $socket->send_error(405, "Hey, don't do that.");
            close $socket;
            next;
        }
        if ($req->uri->path !~ /test/) {
            $socket->send_error(418, "Because 404 is boring.");
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

        $socket->chunk("data: $retain$CRLF$CRLF");
        $client->{streaming} = 1;
    }

    @clients = grep !$_->{delete}, @clients;
}
