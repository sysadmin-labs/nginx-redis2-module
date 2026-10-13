#!/bin/sh
#
# Regenerate src/ngx_http_redis2_reply.c from the ragel sources beside it.
#
# usage: ci/parser.sh [--check] [ragel]
#
# The generated file is checked in so that building this module needs no
# ragel.  That only stays true if the two never drift apart, which is what
# --check is for: it regenerates and compares, and the "parser" workflow
# runs it that way.
#
# Changing the parser therefore means changing the .rl file, running this,
# and committing both.
#
# WHAT --check IGNORES, AND WHY.  ragel writes "#line <n> file.c" markers
# that point into the file it is generating, so that a compiler warning
# about generated code lands on the right line.  Two builds of ragel 6.10
# number those differently: measured here, the same input through the same
# release gave 18/288/308/615 on one machine and 13/279/295/578 on another,
# with the rest of the file identical byte for byte and the gap growing with
# the amount of table emitted.  They are bookkeeping about the output, they
# say nothing about the state machine, and a gate that fails on them would
# fail on the machine rather than on the code.  Everything else is compared
# exactly, including the "#line" markers that point back into the .rl files,
# because those do say which source produced what.

set -eu

CHECK=no
if [ "${1:-}" = --check ]; then
	CHECK=yes
	shift
fi

RAGEL=${1:-ragel}
SRC=$(cd "$(dirname "$0")/.." && pwd)
OUT=src/ngx_http_redis2_reply.c

command -v "$RAGEL" > /dev/null 2>&1 || [ -x "$RAGEL" ] || {
	echo "ci/parser.sh: cannot run \"$RAGEL\"" >&2
	echo "ci/parser.sh: pass the path to a ragel binary as the first argument" >&2
	exit 2
}

cd "$SRC"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

if [ "$CHECK" = yes ]; then
	cp "$OUT" "$work/before.c"
fi

# -I src because the main file includes common.rl and multi_bulk_reply.rl,
# and -T1 for the table-driven backend, which is what the checked-in file
# was made with.  ragel derives the output path from the input, so this
# writes src/ngx_http_redis2_reply.c.
"$RAGEL" -I src -T1 src/ngx_http_redis2_reply.rl

# ragel declares two constants that the generated code never reads, and
# clang counts an unused constant as an error under -Werror, which is how
# nginx builds modules.  They are commented out rather than deleted so that
# every "#line" marker after them still points at the line it names.
# Keyed on the names, not on line numbers: a new ragel release moves them.
sed -e 's|^static const int reply_first_final = .*|/* reply_first_final: emitted by ragel, read by nobody, see ci/parser.sh */|' \
	-e 's|^static const int reply_en_main = .*|/* reply_en_main: emitted by ragel, read by nobody, see ci/parser.sh */|' \
	"$OUT" > "$work/stripped.c"
mv "$work/stripped.c" "$OUT"

version=$("$RAGEL" --version | head -1)

if [ "$CHECK" = no ]; then
	echo "ci/parser.sh: $OUT regenerated with $version"
	exit 0
fi

# See the note at the top: the markers pointing into the generated file are
# ragel's own line bookkeeping and are not portable between ragel builds.
norm() {
	sed -E 's|^#line [0-9]+ ("src/ngx_http_redis2_reply\.c")$|#line _ \1|' "$1"
}

norm "$work/before.c" > "$work/a"
norm "$OUT" > "$work/b"

if cmp -s "$work/a" "$work/b"; then
	echo "ci/parser.sh: the checked-in parser is what the .rl sources produce"
	echo "ci/parser.sh: checked with $version"
	exit 0
fi

echo "ci/parser.sh: the checked-in parser is NOT what the .rl sources produce" >&2
echo "ci/parser.sh: either the .c was edited directly, or it was generated" >&2
echo "ci/parser.sh: from a different .rl than the one in the tree" >&2
echo >&2
diff -u "$work/a" "$work/b" >&2 || true
exit 1
