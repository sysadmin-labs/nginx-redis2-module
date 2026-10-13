# nginx-redis2-module

[![Build & Test][build-test-badge]][build-test-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![Hostile][hostile-badge]][hostile-link]
[![Parser][parser-badge]][parser-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/build-test.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/freebsd.yml
[hostile-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/hostile.yml/badge.svg
[hostile-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/hostile.yml
[parser-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/parser.yml/badge.svg
[parser-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/parser.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-redis2-module/actions/workflows/lint.yml

Talk to Redis from nginx.  A location sends one command or a pipeline of
them and answers with the **raw Redis reply**, exactly the bytes the server
sent.

That is the point of this module and the reason it is small: it does not
interpret the reply, it only needs to know where the reply ends so the
request can be finished.  What to do with `+OK\r\n` or `$5\r\nhello\r\n` is
the caller's business -- a client, a `proxy_pass` in front of it, or a
parser in whatever language is already in the stack.

## Directives

### redis2\_pass

**syntax:** `redis2_pass <host>:<port>` or `redis2_pass <upstream>`

**context:** location, if in location

The Redis server to talk to, directly or through an `upstream` block.  The
host may contain variables, in which case it is resolved per request and a
`resolver` is needed.

```nginx
location = /ping {
    redis2_query ping;
    redis2_pass 127.0.0.1:6379;
}
```

### redis2\_query

**syntax:** `redis2_query <word> ...`

**context:** location, if in location

One Redis command, given as separate words, which the module turns into a
proper Redis request.  Words may contain variables, and an empty word is
allowed.

**Several `redis2_query` in one location are pipelined**: all commands go
out in one write and the replies come back in order, concatenated in the
response body.

```nginx
location = /fill {
    redis2_query del colours;
    redis2_query rpush colours red;
    redis2_query rpush colours green;
    redis2_query lrange colours 0 -1;
    redis2_pass 127.0.0.1:6379;
}
```

### redis2\_raw\_query

**syntax:** `redis2_raw_query <request>`

**context:** location, if in location

A request in Redis wire format, variables included.  The module counts one
reply for it.

### redis2\_raw\_queries

**syntax:** `redis2_raw_queries <count> <requests>`

**context:** location, if in location

The same, for a string that holds `<count>` pipelined requests, so the
module knows how many replies to wait for.

### redis2\_literal\_raw\_query

**syntax:** `redis2_literal_raw_query <request>`

**context:** location, if in location

A raw request taken literally: `$` is an ordinary character here, which is
what a Redis request is full of.

```nginx
location = /ping {
    redis2_literal_raw_query '*1\r\n$4\r\nPING\r\n';
    redis2_pass 127.0.0.1:6379;
}
```

### redis2\_buffer\_size

**syntax:** `redis2_buffer_size <size>`

**default:** one page

**context:** http, server, location

The buffer the reply is read into.  A reply larger than this is passed on
in pieces, so this is not a limit on the reply size.

### redis2\_connect\_timeout, redis2\_send\_timeout, redis2\_read\_timeout

**default:** `60s`

**context:** http, server, location

### redis2\_next\_upstream

**syntax:** `redis2_next_upstream error | timeout | invalid_response | off ...`

**default:** `error timeout`

**context:** http, server, location

When to give the next server in the `upstream` block a turn.

### redis2\_bind

**syntax:** `redis2_bind <address> [transparent]` or `redis2_bind off`

**context:** http, server, location

The local address outgoing connections are bound to.

## Pub/sub

`subscribe` works, within the limit an HTTP request puts on it: the module
finishes the request once the number of replies it expects has arrived, and
`subscribe` answers once immediately to confirm the subscription and then
again for every message somebody publishes.  A single
`redis2_query subscribe <channel>` therefore returns at the confirmation
and nothing else.

The count is what makes it useful -- it includes the confirmation, so two
replies mean "confirm, then wait for one message":

```nginx
location = /listen {
    redis2_raw_queries 2 "subscribe one\r\n";
    redis2_pass 127.0.0.1:6379;
}
```

The request hangs until that message arrives or `redis2_read_timeout`
runs out.

## Building

```sh
./configure --add-module=/path/to/nginx-redis2-module
```

or as a loadable module:

```sh
./configure --with-compat --add-dynamic-module=/path/to/nginx-redis2-module
```

```nginx
load_module modules/ngx_http_redis2_module.so;
```

The reply parser in `src/ngx_http_redis2_reply.c` is generated by
[ragel](https://www.colm.net/open-source/ragel/) from the `.rl` files
beside it and is checked in, so a build needs no ragel.  Changing the
parser means changing the `.rl` file and regenerating:

```sh
ragel -I src -T1 src/ngx_http_redis2_reply.rl
```

The `parser` workflow does exactly that and fails if the checked-in C file
is not what the `.rl` sources produce.

## Testing

The suite needs a Redis server on `127.0.0.1:6379`.  It uses database 13
and deletes its own keys, so it will not touch anything else -- but point
it at a scratch Redis anyway.

```sh
ci/build.sh 1.30.5 /tmp/nginx-redis2
ci/redis.sh
TEST_NGINX_BINARY=/tmp/nginx-redis2/sbin/nginx prove -r t/
ci/hostile.sh /tmp/nginx-redis2/sbin/nginx
```

`ci/redis.sh` starts a Redis that keeps nothing -- no snapshot, no
append-only file -- and leaves an already running one alone.

`ci/hostile.sh` does not use Redis at all.  It puts a server in its place
that answers the way a real one does under load: one byte at a time, with
the reply split in the middle of a length header, with a reply that stops
halfway, and with a connection that closes without answering.

## License

BSD 2-Clause, see [LICENSE](LICENSE).
