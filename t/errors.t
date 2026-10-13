# vi:ft=perl
#
# What the module does when it is asked for something it cannot do.  The
# oracle is both halves: the status code the client sees and the line in the
# error log, because a 500 without an explanation is not much better than a
# hang.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: redis2_pass without a query
--- config
    location = /t {
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- error_code: 500
--- error_log
no redis2 query specified or the query is empty



=== TEST 2: a raw query that is empty
--- config
    location = /t {
        set $cmd '';
        redis2_raw_query $cmd;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- error_code: 500
--- error_log
the redis query is empty



=== TEST 3: the count of redis2_raw_queries is not a number
--- config
    location = /t {
        redis2_raw_queries not_a_number 'ping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- error_code: 500
--- error_log
the N argument to redis2_raw_queries is invalid



=== TEST 4: the count is zero
--- config
    location = /t {
        redis2_raw_queries 0 'ping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- error_code: 500
--- error_log
the N argument to redis2_raw_queries is invalid



=== TEST 5: the count comes from a variable and is empty
--- config
    location = /t {
        set $n '';
        redis2_raw_queries $n 'ping\r\n';
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- error_code: 500
--- error_log
the N argument to redis2_raw_queries is empty



=== TEST 6: nobody is listening on the other side
--- config
    location = /t {
        redis2_query ping;
        redis2_pass 127.0.0.1:65501;
    }
--- request
GET /t
--- error_code: 502
--- error_log
connect() failed



=== TEST 7: a redis2_pass target that is an empty variable
--- config
    location = /t {
        set $target '';
        redis2_query ping;
        redis2_pass $target;
    }
--- request
GET /t
--- error_code: 500
--- error_log
empty "redis2_pass" target



=== TEST 8: a redis2_pass variable naming an upstream that does not exist
--- config
    location = /t {
        set $target 'no_such_upstream';
        redis2_query ping;
        redis2_pass $target;
    }
--- request
GET /t
--- error_code: 500
--- error_log
not found



=== TEST 9: something that is not Redis on the other side
# nginx itself is pointed at, so the reply is an HTTP error page.  Its first
# byte is not one of the five a Redis reply can start with, which is the
# whole check -- a wrong first byte must end the request, not be guessed at.
--- config
    location = /t {
        redis2_query ping;
        redis2_pass 127.0.0.1:$TEST_NGINX_SERVER_PORT;
    }
--- request
GET /t
--- error_code: 502
--- error_log
redis2 sent invalid response
--- no_error_log
[alert]
