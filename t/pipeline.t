# vi:ft=perl
#
# Several commands in one location go out together and the replies come back
# in order.  The order is the thing being tested: a parser that loses count
# would still produce plausible-looking output for a pipeline of one.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: ten commands, ten replies, in order
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set a 1;
        redis2_query set b 2;
        redis2_query set c 3;
        redis2_query get a;
        redis2_query get b;
        redis2_query get c;
        redis2_query dbsize;
        redis2_query flushdb;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n"
    . "\$1\r\n1\r\n\$1\r\n2\r\n\$1\r\n3\r\n"
    . ":3\r\n+OK\r\n"



=== TEST 2: reply types mixed in one pipeline
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one first;
        redis2_query get one;
        redis2_query get nothing;
        redis2_query incr counter;
        redis2_query rpush list x;
        redis2_query lrange list 0 -1;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n"
    . "\$5\r\nfirst\r\n"
    . "\$-1\r\n"
    . ":1\r\n"
    . ":1\r\n"
    . "*1\r\n\$1\r\nx\r\n"



=== TEST 3: one command in the middle fails and the rest still arrive
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one first;
        redis2_query incr one;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body_like eval
qr/\A\+OK\r\n\+OK\r\n\+OK\r\n-ERR .+\r\n\$5\r\nfirst\r\n\z/s



=== TEST 4: two inline commands in one raw query
--- config
    location = /t {
        redis2_raw_queries 2 'ping\r\nping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n+PONG\r\n"



=== TEST 5: the count comes from a variable
--- config
    location = /t {
        set $n 2;
        redis2_raw_queries $n 'ping\r\nping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n+PONG\r\n"



=== TEST 6: asking for fewer replies than the commands produce
# The module stops at the count it was given.  The connection then holds a
# reply nobody read, which is why the warning exists and why this block
# insists on seeing it rather than on a tidy error.
--- config
    location = /t {
        redis2_raw_queries 1 'ping\r\nping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n"
--- error_log
Redis server returned extra bytes



=== TEST 7: a query in an if block
--- config
    location = /t {
        if ($arg_which = second) {
            redis2_query ping;
        }
        redis2_query select 13;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t?which=second
--- response_body eval
"+PONG\r\n"



=== TEST 8: a pipeline of a hundred commands
# The config is generated rather than written out, and the query string is
# deliberately not used for it: nginx hands $arg_* over still escaped, so a
# %0d%0a in there would reach Redis as those six characters.
--- config eval
"    location = /t {\n"
    . "        redis2_raw_queries 100 '" . ('ping\r\n' x 100) . "';\n"
    . "        redis2_pass 127.0.0.1:6379;\n"
    . "    }\n"
--- request
GET /t
--- response_body eval
"+PONG\r\n" x 100
