#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs the port, ./dns, and the original, original/dns, on each message
# of tests/, and compares their output, messages and exit status. Each
# runs as "dns" from PATH, so that both print the same name. A message
# of tests/valid must print with status 0, and one of tests/invalid must
# end in an error with status 1, so that the two cannot agree by both
# failing. Prints a count of the cases when every one agrees; exits 1
# after printing each that does not. Two cases more check the errors of
# reading the file.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
# A missing program would leave PATH to find another dns instead.
for program in "$here/dns" "$here/original/dns"; do
	if [ ! -x "$program" ]; then
		echo "check.sh: $program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/port" "$work/original" || exit 1
ln -s "$here/dns" "$work/port/dns" || exit 1
ln -s "$here/original/dns" "$work/original/dns" || exit 1

agreed=0
failed=0

# Runs one program on a message, into $work/$1.out, .err and .status.
run() {
	PATH="$work/$1:$PATH" dns "$2" >"$work/$1.out" 2>"$work/$1.err"
	echo $? >"$work/$1.status"
}

# Compares the two programs on the message $2, which must exit with $1.
compare() {
	run port "$2"
	run original "$2"
	for part in out err status; do
		if ! cmp -s "$work/port.$part" "$work/original.$part"; then
			echo "differs in $part: $2"
			failed=1
			return
		fi
	done
	if [ "$(cat "$work/port.status")" != "$1" ]; then
		echo "exits with $(cat "$work/port.status"), not $1: $2"
		failed=1
		return
	fi
	agreed=$((agreed + 1))
}

cd "$here" || exit 1
for message in tests/valid/*.bin; do
	compare 0 "$message"
done
for message in tests/invalid/*.bin; do
	compare 1 "$message"
done
# A file that is missing, and one that is not a regular file.
compare 1 tests/missing.bin
compare 1 tests
if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "dns: $agreed cases agree with original/dns"
