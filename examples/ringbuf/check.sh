#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Checks that each firmware object, firmware.o and original/firmware.o,
# leaves undefined only the names that the board supplies; runs the
# port's ./driver and original/driver over the same inputs and compares
# their output, messages and exit status; checks the port alone where
# the two differ (README.md, "Where the port differs"); and runs ./stray,
# whose trap must call panic. Prints a count of the cases when every one
# agrees; exits 1 after printing each that does not.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
for program in driver original/driver stray; do
	if [ ! -x "$here/$program" ]; then
		echo "check.sh: $here/$program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/original" || exit 1

failed=0

# The names that the board supplies: those that firmware.h declares,
# and the four that GCC and Clang may call in freestanding code and
# require of every environment. Clang at -O0 calls memset in both, to
# clear an option or a result of the port and the original's command.
printf '%s\n' board_led board_temp memcmp memcpy memmove memset panic |
    sort >"$work/board"

# undefined OBJECT: prints the undefined names of OBJECT, sorted, without
# the prefix that the C compiler of typec gives a C name on its target.
undefined() {
	prefix=$("${TYPEC_CC:-cc}" -dM -E -x c /dev/null |
	    sed -n 's/^#define __USER_LABEL_PREFIX__ *//p')
	nm -P "$1" | awk -v prefix="$prefix" '
	    $2 == "U" || $2 == "w" || $2 == "v" {
		name = $1
		if (prefix != "" && index(name, prefix) == 1)
			name = substr(name, length(prefix) + 1)
		print name
	    }' | sort
}

# Each object needs nothing but the board, and the port calls panic from
# its traps. board_led must show in both, so that an nm output that this
# cannot read fails the check.
for object in firmware.o original/firmware.o; do
	undefined "$here/$object" >"$work/found"
	extra=$(comm -23 "$work/found" "$work/board")
	if [ -n "$extra" ] || ! grep -qx board_led "$work/found"; then
		echo "$object needs more than the board:" $extra
		failed=1
	fi
done
if ! undefined "$here/firmware.o" | grep -qx panic; then
	echo "firmware.o does not call panic"
	failed=1
fi

agreed=0
expected=0

# run SIDE EVERY INPUT: feeds the printf format INPUT to SIDE's driver,
# which polls after every EVERY bytes, into SIDE.*.
run() {
	printf "$3" | "$here/$1" "$2" >"$work/$1.out" 2>"$work/$1.err"
	echo $? >"$work/$1.status"
}

# same EVERY INPUT: runs both drivers on INPUT and compares them.
same() {
	run original/driver "$1" "$2"
	run driver "$1" "$2"
	for part in out err status; do
		if ! cmp -s "$work/original/driver.$part" "$work/driver.$part"
		then
			echo "differs in $part: every $1: $2"
			diff "$work/original/driver.$part" "$work/driver.$part"
			failed=1
			return
		fi
	done
	agreed=$((agreed + 1))
}

# expect EVERY INPUT OUTPUT: runs the port's driver on INPUT and
# compares its output with the printf format OUTPUT.
expect() {
	run driver "$1" "$2"
	printf "$3" >"$work/expected.out"
	if ! cmp -s "$work/expected.out" "$work/driver.out" ||
	    [ -s "$work/driver.err" ] || [ "$(cat "$work/driver.status")" != 0 ]
	then
		echo "unexpected: every $1: $2"
		diff "$work/expected.out" "$work/driver.out"
		cat "$work/driver.err"
		failed=1
		return
	fi
	expected=$((expected + 1))
}

# A session of every command and every error, polled after every 1 to
# 1000 bytes: the rings wrap around at different points, and from 17 on
# the receive ring overflows and loses bytes, which can join two lines.
session='get led\nset led 1\nget led\nget temp\nget temp\nget temp\n'
session="${session}get temp\necho hello,  world\necho\nstats\n"
session="${session}  set   led   0  \r\nfoo\nGET led\nget\nget leds\n"
session="${session}set led\nset led 2\nset led 1 1\nset lamp 1\nstats x\n"
session="${session}\n   \necho  two spaces\nset led 1\r\nstats\n"
for every in 1 2 3 5 7 8 15 16 17 31 32 33 40 64 1000; do
	same "$every" "$session"
done

# Lines at and past the longest, at 32 bytes; a line too long is
# refused whole, and the next line is read as usual.
line32='echo 012345678901234567890123456'
same 1 "$line32\n"
same 1 "${line32}7\nget led\n"
same 1 "${line32}${line32}${line32}\necho after\n"
same 1 "${line32}\r\n"
same 1 "$line32"
same 1 'echo no newline at the end'

# Replies that overflow the 32 bytes of the transmit ring, when the
# main loop answers several lines before the UART sends any.
same 6 'x\ny\nz\nstats\n'
same 1000 'x\ny\nz\n'

# The behaviours that a comparison alone would not show.
expect 1 'get temp\nget temp\nget temp\nget temp\nget temp\n' \
    'temp 21\ntemp 0\ntemp -40\ntemp 125\ntemp 21\n'
expect 1 "${line32}\n${line32}7\n" \
    '012345678901234567890123456\nerror: line too long\n'
expect 40 'get led\nget led\nget led\nget led\nget led\nstats\n' \
    'led 0\nled 0\ndropped rx 24 tx 0\n'
expect 6 'x\ny\nz\nstats\n' \
    'error: unknown command\nerror: undropped rx 0 tx 37\n'

# A NUL byte is a character of the port's line, where it ends the
# original's line as a C string; the port refuses the line.
expect 1 'set led 1\000x\necho a\000b\n' 'error: bad argument\na\000b\n'

# A trap of the port calls panic.
"$here/stray" >"$work/stray.out" 2>"$work/stray.err"
status=$?
if [ $status -ne 3 ] || [ -s "$work/stray.out" ] ||
    [ "$(cat "$work/stray.err")" != 'stray: panic' ]; then
	echo "stray: status $status, expected 3 from panic"
	cat "$work/stray.out" "$work/stray.err"
	failed=1
fi

if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "ringbuf: the objects need only the board;" \
    "$agreed cases agree with original/driver, $expected as expected"
