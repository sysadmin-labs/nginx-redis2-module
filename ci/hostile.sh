#!/bin/sh
#
# Put the module in front of something that answers the way a Redis server
# answers when the network is having a bad day.
#
# t/ asks a real Redis server, which is well behaved: it writes a whole reply
# in one go and the pieces nginx reads are whatever the kernel hands over.
# That never breaks a length header in half, never stops in the middle of a
# value, and never sends a sixth reply type.  The parser in
# src/ngx_http_redis2_reply.c exists for exactly those cases, so they have to
# come from somewhere -- here.
#
# usage: ci/hostile.sh <nginx binary>
#
# Set HOSTILE_LOAD_MODULE to the path of ngx_http_redis2_module.so to test a
# loadable build.  No Redis server is needed or used.

set -eu

NGINX=${1:?path to the nginx binary missing}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/hostile
PORT=${HOSTILE_PORT:-18520}
UPORT=${HOSTILE_UPSTREAM_PORT:-18521}

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }
command -v perl > /dev/null || { echo "perl(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/out" "$WORK/tmp"

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

# ------------------------------------------------------- the pretend Redis
#
# It reads the request only far enough to find the key, which is the name of
# the case, and then answers badly on purpose.  Written by hand rather than
# driven by a real server because the whole point is to choose where the
# pieces end.

cat > "$WORK/redis.pl" <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;
use IO::Handle;

# nginx hanging up mid-reply would otherwise kill this process with SIGPIPE
# and every case after it would fail for the wrong reason.
$SIG{PIPE} = 'IGNORE';

my $port = shift or die "port missing\n";
my $srv = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port,
                                Listen => 16, ReuseAddr => 1, Proto => 'tcp')
    or die "listen: $!\n";

my $value = 'a' x 1000;
my $bulk  = "\$" . length($value) . "\r\n" . $value . "\r\n";

# Write one piece and give nginx a chance to read it on its own.  Without the
# pause the kernel coalesces everything into one segment and the reply
# arrives whole, which is the case this script is here not to test.
sub piece {
    my ($c, $s) = @_;
    print $c $s;
    select undef, undef, undef, 0.002;
}

while (my $c = $srv->accept) {
    $c->autoflush(1);

    # Enough of the request to see the key.  A Redis request is a multi-bulk
    # of words; reading 4 kB covers every request this script provokes.
    my $req = '';
    my $n = sysread($c, $req, 4096);
    $n = 0 unless defined $n;

    my $mode = 'unknown';
    for my $word (qw(dribble split truncate garbage extra silent bigmulti)) {
        $mode = $word if $req =~ /\b\Q$word\E\b/;
    }

    if ($mode eq 'dribble') {
        # One byte at a time, so every boundary nginx reads at falls inside
        # the reply: in the header, in the value, between CR and LF.
        piece($c, $_) for split //, $bulk;

    } elsif ($mode eq 'split') {
        # The length header cut in three, then the value in uneven pieces,
        # then the trailing CRLF split as well.
        piece($c, "\$10");
        piece($c, "00\r");
        piece($c, "\n");
        piece($c, substr($value, 0, 1));
        piece($c, substr($value, 1, 998));
        piece($c, substr($value, 999, 1));
        piece($c, "\r");
        piece($c, "\n");

    } elsif ($mode eq 'truncate') {
        # Announces 100000 bytes, sends three, hangs up.
        piece($c, "\$100000\r\n");
        piece($c, "abc");

    } elsif ($mode eq 'garbage') {
        # 'X' is not one of the five bytes a Redis reply can start with.
        piece($c, "X not a redis reply\r\n");

    } elsif ($mode eq 'extra') {
        # The reply that was asked for, and then one that was not.
        piece($c, "+OK\r\n");
        piece($c, "+SURPRISE\r\n");

    } elsif ($mode eq 'silent') {
        # Connected, accepted the request, says nothing.

    } elsif ($mode eq 'bigmulti') {
        my $elem = "\$50\r\n" . ('b' x 50) . "\r\n";
        piece($c, "*100\r\n");
        my $all = $elem x 100;
        for (my $i = 0; $i < length($all); $i += 7) {
            piece($c, substr($all, $i, 7));
        }

    } else {
        piece($c, "-ERR unknown case\r\n");
    }

    close $c;
}
PERL

perl "$WORK/redis.pl" "$UPORT" &
redis_pid=$!
sleep 1

cleanup() {
	kill "$redis_pid" 2>/dev/null || true
	[ -f "$WORK/logs/nginx.pid" ] &&
		kill -QUIT "$(cat "$WORK/logs/nginx.pid")" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------- the nginx

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

ngx_load=
if [ -n "${HOSTILE_LOAD_MODULE:-}" ]; then
	ngx_load="load_module $HOSTILE_LOAD_MODULE;"
fi

# A small read buffer on purpose: the pieces the pretend server writes are
# small, and a page-sized buffer would hide half of them behind one read.
cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_load
$ngx_user
daemon on;
master_process on;
worker_processes 1;
pid $WORK/logs/nginx.pid;
error_log $WORK/logs/error.log info;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $WORK/tmp/cb;
    fastcgi_temp_path $WORK/tmp/fc;
    uwsgi_temp_path $WORK/tmp/uw;
    scgi_temp_path $WORK/tmp/sc;
    default_type text/plain;

    redis2_buffer_size 64;
    redis2_read_timeout 5s;

    server {
        listen 127.0.0.1:$PORT;

        location = /dribble {
            redis2_query get dribble;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /split {
            redis2_query get split;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /truncate {
            redis2_query get truncate;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /garbage {
            redis2_query get garbage;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /extra {
            redis2_query get extra;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /silent {
            redis2_query get silent;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /bigmulti {
            redis2_query get bigmulti;
            redis2_pass 127.0.0.1:$UPORT;
        }

        location = /alive {
            return 200 'alive';
        }
    }
}
EOF

"$NGINX" -t -c "$WORK/conf/nginx.conf" -p "$WORK" > "$WORK/out/t.log" 2>&1 ||
	{ cat "$WORK/out/t.log"; exit 1; }
"$NGINX" -c "$WORK/conf/nginx.conf" -p "$WORK"
sleep 1

# What a correct answer looks like for the two streaming cases.
perl -e 'print "\$1000\r\n", "a" x 1000, "\r\n"' > "$WORK/out/want.bin"
perl -e 'print "*100\r\n", ("\$50\r\n" . ("b" x 50) . "\r\n") x 100' \
	> "$WORK/out/want-multi.bin"

# ---------------------------------------------------------------- the cases

echo "--- a bulk reply that arrives one byte at a time ---"
curl -s --max-time 30 "http://127.0.0.1:$PORT/dribble" -o "$WORK/out/dribble.bin" || true
if cmp -s "$WORK/out/dribble.bin" "$WORK/out/want.bin"; then
	echo "  $(wc -c < "$WORK/out/dribble.bin" | tr -d ' ') bytes, byte for byte what it should be"
else
	note "the dribbled reply came out wrong"
	note "got $(wc -c < "$WORK/out/dribble.bin" | tr -d ' ') bytes, wanted $(wc -c < "$WORK/out/want.bin" | tr -d ' ')"
fi

echo "--- the length header itself cut in three ---"
curl -s --max-time 30 "http://127.0.0.1:$PORT/split" -o "$WORK/out/split.bin" || true
if cmp -s "$WORK/out/split.bin" "$WORK/out/want.bin"; then
	echo "  the parser stitched \"\$10\" + \"00\\r\" + \"\\n\" back together"
else
	note "the reply with the split header came out wrong"
	note "got $(wc -c < "$WORK/out/split.bin" | tr -d ' ') bytes"
fi

echo "--- a multi-bulk reply of a hundred elements, seven bytes at a time ---"
curl -s --max-time 30 "http://127.0.0.1:$PORT/bigmulti" -o "$WORK/out/multi.bin" || true
if cmp -s "$WORK/out/multi.bin" "$WORK/out/want-multi.bin"; then
	echo "  all hundred elements, byte for byte"
else
	note "the multi-bulk reply came out wrong"
	note "got $(wc -c < "$WORK/out/multi.bin" | tr -d ' ') bytes, wanted $(wc -c < "$WORK/out/want-multi.bin" | tr -d ' ')"
fi

echo "--- a reply that promises 100000 bytes and sends three ---"
curl -s --max-time 10 "http://127.0.0.1:$PORT/truncate" -o "$WORK/out/cut.bin" || true
got=$(wc -c < "$WORK/out/cut.bin" | tr -d ' ')
if [ "$got" -lt 100000 ]; then
	echo "  the client got $got bytes and not a made-up remainder"
else
	note "the short reply was somehow answered in full ($got bytes)"
fi

echo "--- a first byte that no Redis reply starts with ---"
code=$(curl -s -o "$WORK/out/garbage.bin" -w '%{http_code}' --max-time 10 \
	"http://127.0.0.1:$PORT/garbage" || true)
if [ "$code" = 502 ] &&
	grep -q 'redis2 sent invalid response' "$WORK/logs/error.log"; then
	echo "  502, and the log says the reply was not a Redis reply"
else
	note "garbage reply: code $code, and the log does not name it"
fi

echo "--- a reply nobody asked for, after the one that was asked for ---"
code=$(curl -s -o "$WORK/out/extra.bin" -w '%{http_code}' --max-time 10 \
	"http://127.0.0.1:$PORT/extra" || true)
body=$(tr -d '\r\n' < "$WORK/out/extra.bin")
if [ "$code" = 200 ] && [ "$body" = '+OK' ] &&
	grep -q 'extra bytes' "$WORK/logs/error.log"; then
	echo "  the asked-for reply went out, the surplus is in the log"
else
	note "extra reply: code $code, body \"$body\""
fi

echo "--- a server that accepts the request and says nothing ---"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
	"http://127.0.0.1:$PORT/silent" || true)
if [ "$code" = 502 ]; then
	echo "  502 rather than a request that waits forever"
else
	note "silent server: code $code"
fi

echo "--- a client that hangs up in the middle ---"
curl -s --max-time 0.05 "http://127.0.0.1:$PORT/dribble" -o /dev/null 2>/dev/null || true
sleep 1
echo "  the worker is supposed to survive this, see the log check below"

echo "--- the worker is still there ---"
alive=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/alive" || true)
if [ "$alive" = alive ]; then
	echo "  it answers"
else
	note "the worker did not answer after all that"
fi

echo "--- nothing in the error log that should not be there ---"
if grep -E '\[alert\]|\[emerg\]|exited on signal' "$WORK/logs/error.log"; then
	note "the log carries an alert, an emerg or a worker that died"
else
	echo "  no alert, no emerg, no signal"
fi

exit $fail
