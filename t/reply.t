# vi:ft=perl
#
# The parser's job is to find the end of a reply in a byte stream that
# arrives in pieces nobody chose.  These blocks make the pieces small and
# the replies large, so a boundary lands inside a length header, inside a
# value, and between the two bytes of a CRLF.
#
# The values are made with "setrange", not written out here: setrange pads
# with NUL, so one short directive produces a reply of any length, and the
# NUL bytes check that nothing in the path treats the value as a C string.

use Test::Nginx::Socket 'no_plan';

repeat_each(2);

run_tests();

__DATA__

=== TEST 1: a value one byte long
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n\$1\r\nx\r\n"



=== TEST 2: a value that fills the buffer exactly
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query setrange one 63 x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:64\r\n\$64\r\n" . ("\0" x 63) . "x\r\n"



=== TEST 3: one byte more than the buffer
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query setrange one 64 x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:65\r\n\$65\r\n" . ("\0" x 64) . "x\r\n"



=== TEST 4: one byte less than the buffer
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query setrange one 62 x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:63\r\n\$63\r\n" . ("\0" x 62) . "x\r\n"



=== TEST 5: a value far larger than the buffer
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query setrange one 65535 x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:65536\r\n\$65536\r\n" . ("\0" x 65535) . "x\r\n"



=== TEST 6: the same value through a one-page buffer
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query setrange one 65535 x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:65536\r\n\$65536\r\n" . ("\0" x 65535) . "x\r\n"



=== TEST 7: a length header long enough to be split itself
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query setrange one 999999 x;
        redis2_query get one;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:1000000\r\n\$1000000\r\n" . ("\0" x 999999) . "x\r\n"



=== TEST 8: a multi-bulk reply whose elements cross the buffer
--- config
    redis2_buffer_size 64;
    location = /t {
        set $v 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query rpush list $v;
        redis2_query rpush list $v;
        redis2_query rpush list $v;
        redis2_query lrange list 0 -1;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:1\r\n:2\r\n:3\r\n*3\r\n"
    . ("\$50\r\n" . ("a" x 50) . "\r\n") x 3



=== TEST 9: an empty element inside a multi-bulk reply
--- config
    redis2_buffer_size 64;
    location = /t {
        set $empty '';
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query rpush list one;
        redis2_query rpush list $empty;
        redis2_query lrange list 0 -1;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n:1\r\n:2\r\n*2\r\n\$3\r\none\r\n\$0\r\n\r\n"



=== TEST 10: a nil element inside a multi-bulk reply
--- config
    redis2_buffer_size 64;
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query set one first;
        redis2_query mget one nothing;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n+OK\r\n*2\r\n\$5\r\nfirst\r\n\$-1\r\n"



=== TEST 11: an empty multi-bulk reply
--- config
    location = /t {
        redis2_query select 13;
        redis2_query flushdb;
        redis2_query lrange nothing 0 -1;
        redis2_pass 127.0.0.1:6379;
    }
--- request
GET /t
--- response_body eval
"+OK\r\n+OK\r\n*0\r\n"
