#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs ./wordfreq and original/wordfreq on the same texts and command
# lines, and compares their output, messages and exit status.  Each runs
# as "wordfreq" from PATH, so that both print the same name.  Prints a
# count of the cases when every one agrees; exits 1 after printing each
# that does not.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
for program in "$here/wordfreq" "$here/original/wordfreq"; do
	if [ ! -x "$program" ]; then
		echo "check.sh: $program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/data" "$work/port" "$work/original" || exit 1
ln -s "$here/wordfreq" "$work/port/wordfreq" || exit 1
ln -s "$here/original/wordfreq" "$work/original/wordfreq" || exit 1

cd "$work/data" || exit 1
: >empty
printf 'The cat and the Hat.\nthe end, THE END' >short
printf 'tab\tseparated\r\nnon-ASCII caf\303\251 na\303\257ve\n' >mixed
printf 'nul\000inside\000nul\n\n\n123 456 x1y2z\n' >>mixed
# Words of one count that are prefixes of each other.
printf 'ab a b ab a b abc\n' >prefixes
awk -v words=200000 -v vocab=20000 -f "$here/corpus.awk" >corpus ||
    exit 1
cat "$here/original/wordfreq.c" "$here/original/khash.h" \
    "$here/wordfreq.tc" "$here/map.tci" >sources ||
    exit 1

agreed=0
failed=0

# Runs one command line with each program first on PATH.
run() {
	PATH="$work/$1:$PATH" sh -c "$2" >"$work/$1.out" 2>"$work/$1.err"
	echo $? >"$work/$1.status"
}

same() {
	for part in out err status; do
		cmp -s "$work/port.$part" "$work/original.$part" || return 1
	done
}

compare() {
	run port "$1"
	run original "$1"
	if same; then
		agreed=$((agreed + 1))
	else
		failed=$((failed + 1))
		echo "check.sh: differs from original/wordfreq: $1" >&2
	fi
}

for text in empty short mixed corpus sources; do
	compare "wordfreq <$text"
	compare "wordfreq -n 0 <$text"
	compare "wordfreq -n 3 <$text"
	compare "wordfreq -n 100000 <$text"
done
compare "wordfreq -n 25 <corpus"
compare "wordfreq <prefixes"
compare "wordfreq <short >&-"
compare "wordfreq -n -1 <short"
compare "wordfreq -n 3x <short"
compare "wordfreq -n '' <short"
compare "wordfreq -n 99999999999999999999 <short"
compare "wordfreq extra <short"
compare "wordfreq -x <short"
compare "wordfreq <&-"

if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "wordfreq: $agreed cases agree with original/wordfreq"
