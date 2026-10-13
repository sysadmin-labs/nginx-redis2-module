#!/bin/sh
#
# Regenerate src/ngx_http_redis2_reply.c from the ragel sources beside it.
#
# usage: ci/parser.sh [ragel]
#
# The generated file is checked in so that building this module needs no
# ragel.  That only stays true if the two never drift apart, which is what
# the "parser" workflow checks: it runs this script and then asks git
# whether anything changed.
#
# Changing the parser therefore means changing the .rl file, running this,
# and committing both.

set -eu

RAGEL=${1:-ragel}
SRC=$(cd "$(dirname "$0")/.." && pwd)

command -v "$RAGEL" > /dev/null 2>&1 || [ -x "$RAGEL" ] || {
	echo "ci/parser.sh: cannot run \"$RAGEL\"" >&2
	echo "ci/parser.sh: pass the path to a ragel binary as the first argument" >&2
	exit 2
}

cd "$SRC"

# -I src because the main file includes common.rl and multi_bulk_reply.rl,
# and -T1 for the table-driven backend, which is what the checked-in file
# was made with.  ragel derives the output path from the input, so this
# writes src/ngx_http_redis2_reply.c.
"$RAGEL" -I src -T1 src/ngx_http_redis2_reply.rl

# ragel declares two constants that the generated code never reads, and
# clang counts an unused constant as an error under -Werror.  nginx builds
# modules with -Werror, so they have to go.  Stripping them by name rather
# than by line number: a new ragel release moves the lines around.
tmp=$(mktemp)
grep -v -E 'reply_(en_main|first_final)' src/ngx_http_redis2_reply.c > "$tmp"
mv "$tmp" src/ngx_http_redis2_reply.c

echo "ci/parser.sh: src/ngx_http_redis2_reply.c regenerated with $("$RAGEL" --version | head -1)"
