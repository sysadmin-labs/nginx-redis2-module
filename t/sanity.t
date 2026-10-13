# vi:ft=perl
#
# The reply is the Redis reply, byte for byte.  Every block here starts with
# "select 13" and "flushdb", so what comes back is fully determined and the
# suite cannot be disturbed by, or disturb, anything else in that server.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: a status reply
--- config
    location = /t {
        redis2_query ping;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n"



=== TEST 2: set and get, pipelined in one location
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one first;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n\$5\r\nfirst\r\n"



=== TEST 3: a key that is not there is a nil bulk reply
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query get nothing;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n\$-1\r\n"



=== TEST 4: an integer reply
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query incr counter;
        redis2_query incr counter;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:1\r\n:2\r\n"



=== TEST 5: a multi-bulk reply keeps its order
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query rpush colours red;
        redis2_query rpush colours green;
        redis2_query lrange colours 0 -1;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:1\r\n:2\r\n*2\r\n\$3\r\nred\r\n\$5\r\ngreen\r\n"



=== TEST 6: an error reply is passed on, not swallowed
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one first;
        redis2_query incr one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body_like
\A\+OK\r\n\+OK\r\n\+OK\r\n-ERR .+\r\n\z



=== TEST 7: a variable in a query word
--- config
    location = /t {
        set $key 'one';
        set $value 'from a variable';
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set $key $value;
        redis2_query get $key;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n\$15\r\nfrom a variable\r\n"



=== TEST 8: an empty word is a word
--- config
    location = /t {
        set $empty '';
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one $empty;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n\$0\r\n\r\n"



=== TEST 9: a value is binary, CRLF inside it included
--- config
    location = /t {
        set $value "a\r\nb";
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one $value;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n\$4\r\na\r\nb\r\n"



=== TEST 10: a literal raw query, where $ is an ordinary character
--- config
    location = /t {
        redis2_literal_raw_query '*1\r\n$4\r\nPING\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n"



=== TEST 11: a raw query, where a variable is a variable
--- config
    location = /t {
        set $cmd "ping\r\n";
        redis2_raw_query $cmd;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n"



=== TEST 12: an inline raw query in the old protocol
--- config
    location = /t {
        redis2_raw_query 'ping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n"



=== TEST 13: redis2_pass through an upstream block
--- http_config
    upstream redisbackend {
        server 127.0.0.1:6379;
    }
--- config
    location = /t {
        redis2_query ping;
        redis2_pass redisbackend;
    }
--- request
GET /t
--- response_body eval
"+PONG\r\n"



=== TEST 14: a keepalive pool survives being used twice
--- http_config
    upstream redisbackend {
        server 127.0.0.1:6379;
        keepalive 1;
    }
--- config
    location = /t {
        redis2_query ping;
        redis2_pass redisbackend;
    }
--- pipelined_requests eval
["GET /t", "GET /t", "GET /t"]
--- response_body eval
["+PONG\r\n", "+PONG\r\n", "+PONG\r\n"]



=== TEST 15: POST reaches the same place a GET does
--- config
    location = /t {
        redis2_query ping;
        redis2_pass 127.0.0.1:6379;
    }
--- request
POST /t
body is ignored
--- response_body eval
"+PONG\r\n"
