#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Prints the size of the code of wordfreq.o and original/wordfreq.o, and
# times ./wordfreq and original/wordfreq with hyperfine on a generated
# text of WORDS words (default 20000000) drawn from VOCAB (default
# 500000), written to a temporary directory.  Build first with the
# compiler and flags to measure.

set -u

if ! command -v hyperfine >/dev/null 2>&1; then
	echo "bench.sh: hyperfine is not installed" >&2
	exit 1
fi
here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
words=${WORDS:-20000000}
vocab=${VOCAB:-500000}
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# The machine code of an object file: its sections whose names begin
# with __text in Mach-O or .text in ELF, as GCC moves cold code and main
# to sections of their own.
text_size() {
	case $(uname) in
	Darwin)
		size -m "$1" |
		    awk '/__TEXT, __text/ { n += $NF } END { print n }'
		;;
	*)
		size -A "$1" |
		    awk '$1 ~ /^\.text/ { n += $2 } END { print n }'
		;;
	esac
}

for object in wordfreq.o original/wordfreq.o; do
	echo "$object: $(text_size "$here/$object") bytes of code"
done

awk -v words="$words" -v vocab="$vocab" -f "$here/corpus.awk" \
    >"$work/text" || exit 1
echo "text: $(wc -c <"$work/text") bytes, $words words," \
    "$("$here/wordfreq" -n 1000000000 <"$work/text" | wc -l) distinct"

# hyperfine -N splits a command at blanks, so the programs run by
# relative names from here.
cd "$here" || exit 1
hyperfine -N -w 2 -r 10 --input "$work/text" \
    -n wordfreq ./wordfreq -n original/wordfreq ./original/wordfreq
