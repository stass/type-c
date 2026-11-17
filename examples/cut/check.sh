#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs the port, ./cut, and FreeBSD's original/cut on the same command
# lines and inputs, and compares their output, messages and exit status.
# Each runs as "cut" from PATH, so that both print the same name. Where
# the port differs from the original (README.md, "Where the port
# differs"), the port is checked against the output that cut(1)
# describes instead. Prints a count of the cases when every one agrees;
# exits 1 after printing each that does not.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
# A missing program would leave PATH to find the system's cut instead.
for program in "$here/cut" "$here/original/cut"; do
	if [ ! -x "$program" ]; then
		echo "check.sh: $program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/data" "$work/port" "$work/original" || exit 1
ln -s "$here/cut" "$work/port/cut" || exit 1
ln -s "$here/original/cut" "$work/original/cut" || exit 1

# A multibyte locale: C.UTF-8 where the C library has it, as glibc does.
utf8=
for name in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
	if locale -a 2>/dev/null | grep -qx "$name"; then
		utf8=$name
		break
	fi
done
if [ -z "$utf8" ]; then
	echo "check.sh: the host has no UTF-8 locale" >&2
	exit 1
fi

cd "$work/data" || exit 1
printf 'one\ttwo\tthree\tfour\tfive\tsix\tseven\teight\n' >fields
printf 'a\tb\nno delimiter here\n\ntrailing\t\n\tleading\nx\t\ty\n' >>fields
printf 'root:*:0:0:Charlie &:/root:/bin/csh\n' >passwd
printf 'toor:*:0:0:Bourne-again Superuser:/root:\n' >>passwd
printf 'daemon:*:1:1:Owner of many system processes:/:/sbin/nologin\n' \
    >>passwd
printf '  leading  blanks\none two\t three\nsingle\na \t b \n' >words
printf 'abcdefghij\nabc\n\n0123456789abcdef\n' >bytes
printf 'ab' >short_tail
printf 'abcdef' >long_tail
printf 'a\tb' >field_tail
printf 'abc' >plain_tail
printf 'a\000b\tc\000d\n' >nul
: >empty
printf 'h\303\251llo w\303\266rld\n' >utf8
printf '\346\227\245\346\234\254\tde\tfin\n' >>utf8
printf 'na\303\257ve:caf\303\251:r\303\251sum\303\251\nascii only\n' >>utf8
printf 'good\tline\nbad\377\tline\nafter\n' >bad
printf 'caf\303' >truncated

agreed=0
expected=0
failed=0

# run SIDE LOCALE COMMAND: runs COMMAND with SIDE's cut into SIDE.*.
run() {
	(
		PATH="$work/$1:$PATH"
		LC_ALL=$2
		export PATH LC_ALL
		eval "$3"
	) >"$work/$1.out" 2>"$work/$1.err"
	echo $? >"$work/$1.status"
}

# same LOCALE COMMAND: runs COMMAND with each cut and compares them.
same() {
	run original "$1" "$2"
	run port "$1" "$2"
	for part in out err status; do
		if ! cmp -s "$work/original.$part" "$work/port.$part"; then
			echo "differs in $part: LC_ALL=$1 $2"
			diff "$work/original.$part" "$work/port.$part"
			failed=1
			return
		fi
	done
	agreed=$((agreed + 1))
}

# expect LOCALE COMMAND OUTPUT MESSAGE STATUS: runs COMMAND with the
# port and compares its output with the printf format OUTPUT, its
# standard error with the line MESSAGE, none when MESSAGE is empty, and
# its exit status with STATUS.
expect() {
	run port "$1" "$2"
	printf "$3" >"$work/expected.out"
	if [ -n "$4" ]; then
		printf '%s\n' "$4"
	fi >"$work/expected.err"
	echo "$5" >"$work/expected.status"
	for part in out err status; do
		if ! cmp -s "$work/expected.$part" "$work/port.$part"; then
			echo "unexpected $part: LC_ALL=$1 $2"
			diff "$work/expected.$part" "$work/port.$part"
			failed=1
			return
		fi
	done
	expected=$((expected + 1))
}

# Bytes, and characters where a character is a byte.
same C 'cut -b 1 bytes'
same C 'cut -b 1-3 bytes'
same C 'cut -b 3- bytes'
same C 'cut -b -4 bytes'
same C 'cut -b 1,3,5 bytes'
same C 'cut -b 9,2-4 bytes'
same C 'cut -b 5-3 bytes'
same C 'cut -b 2-,5 bytes'
same C 'cut -b "1 3" bytes'
same C 'cut -b "1	3" bytes'
same C 'cut -b 1 -b 4 bytes'
same C 'cut -b -2,8- bytes'
same C 'cut -b -5,2- bytes'
same C 'cut -b 5-3- bytes'
same C 'cut -b 3-5- bytes'
same C 'cut -b -3-5 bytes'
same C 'cut -b 1-3 short_tail'
same C 'cut -b 1-2 short_tail'
same C 'cut -b 1-3 long_tail'
same C 'cut -b 2- long_tail'
same C 'cut -b 1-3 -n bytes'
same C 'cut -c 2-4 bytes'
same C 'cut -c 2 -b 4 bytes'
same C 'cut -b 1-3 nul'
same C 'cut -b 1 empty'
same C 'cut -b 1-2 utf8'
same C 'cut -c 1-2 utf8'

# Fields.
same C 'cut -f 1 fields'
same C 'cut -f 2-4,7- fields'
same C 'cut -f 3- fields'
same C 'cut -f -2 fields'
same C 'cut -f 1,3 fields'
same C 'cut -f 2 -s fields'
same C 'cut -f 9 fields'
same C 'cut -f 5-3 fields'
same C 'cut -f 2-,4 fields'
same C 'cut -f 2 nul'
same C 'cut -f 1 -d : passwd'
same C 'cut -d : -f 1,7 passwd'
same C 'cut -d : -f 6- passwd'
same C 'cut -s -d : -f 5 fields'
same C 'cut -d " " -f 2 words'
same C 'cut -w -f 2 words'
same C 'cut -w -f 1,3- words'
same C 'cut -w -f 2- words'
same C 'cut -w -s -f 1 fields'
same C 'cut -d "
" -f 1 fields'
same C 'cut -d "
" -f 2 -s fields'
same C 'cut -f 1 field_tail'
same C 'cut -f 2 field_tail'
same C 'cut -f 1 plain_tail'
same C 'cut -f 1 empty'

# Operands.
same C 'cut -f 1 <fields'
same C 'cut -f 1 - <fields'
same C 'cut -f 1 fields passwd'
same C 'cat fields | cut -f 2 - passwd -'
same C 'cut -f 1 missing'
same C 'cut -f 1 missing fields'
same C 'cut -f 1 fields missing'

# Errors of the command line.
same C 'cut -f 0 fields'
same C 'cut -f "" fields'
same C 'cut -f x fields'
same C 'cut -f 1-2x fields'
same C 'cut -f 1,,2 fields'
same C 'cut -f 1, fields'
same C 'cut -f - fields'
same C 'cut -f 3-0 fields'
same C 'cut -f 0 -z fields'
same C 'cut -f 99999999999999999999 fields'
same C 'cut -b'
same C 'cut -z -f 1 fields'
same C 'cut'
same C 'cut fields'
same C 'cut -f 1 -b 1 fields'
same C 'cut -b 1 -d : fields'
same C 'cut -b 1 -s fields'
same C 'cut -b 1 -w fields'
same C 'cut -c 1 -n fields'
same C 'cut -f 1 -n fields'
same C 'cut -f 1 -w -d : fields'
same C 'cut -d : -w -f 1 fields'
same C 'cut -d ab -f 1 fields'
same C 'cut -d "" -f 1 fields'

# A multibyte locale.
same "$utf8" 'cut -c 1-2 utf8'
same "$utf8" 'cut -c 3- utf8'
same "$utf8" 'cut -c -1,4 utf8'
same "$utf8" 'cut -b 2 utf8'
same "$utf8" 'cut -c 1-2 long_tail'
same "$utf8" 'cut -c 1-9 long_tail'
same "$utf8" 'cut -f 2 utf8'
same "$utf8" "cut -d \"$(printf '\303\251')\" -f 2 utf8"
same "$utf8" "cut -d \"$(printf '\303\266')\" -f 1 utf8"
same "$utf8" "cut -d \"$(printf '\303\251\303\251')\" -f 1 utf8"
same "$utf8" "cut -d \"$(printf '\303')\" -f 1 utf8"
same "$utf8" 'cut -w -f 2 utf8'
same "$utf8" 'cut -c 1 bad'
same "$utf8" 'cut -c 1 <bad'
same "$utf8" 'cut -f 1 bad'
same "$utf8" 'cut -f 1 <bad'
same "$utf8" 'cut -f 1 <bad; cut -f 1 <fields'
same "$utf8" 'cut -f 1 <truncated'

# The message of an invalid sequence in the standard input, in the words
# of the C library.
run original "$utf8" 'cut -f 1 <bad'
illegal=$(cat "$work/original.err")

# A sequence cut short by the end of the input, which the original's
# getwc reports or drops as the C library does.
expect "$utf8" 'cut -c 1-3 <truncated' 'caf\n' "$illegal" 1

# -n in a multibyte locale: a is 1 byte, the e-acute 2, the euro sign 3.
aeb='a\303\251\342\202\254b\n'
expect "$utf8" "printf '$aeb' | cut -n -b 1-2" 'a\n' '' 0
expect "$utf8" "printf '$aeb' | cut -n -b 1-3" 'a\303\251\n' '' 0
expect "$utf8" "printf '$aeb' | cut -n -b 3" '\303\251\n' '' 0
expect "$utf8" "printf '$aeb' | cut -n -b 4,6" '\n' '' 0
expect "$utf8" "printf '$aeb' | cut -n -b 5-" '\342\202\254b\n' '' 0
expect "$utf8" "printf 'a\303\251\nb\303\247\n' | cut -n -b 1-3" \
    'a\303\251\nb\303\247\n' '' 0
expect "$utf8" "printf 'a\303\251' | cut -n -b 1-3" 'a\303\251' '' 0
expect "$utf8" "printf 'a\377b\n' | cut -n -b 1-3" 'a' "$illegal" 1

if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "cut: $agreed cases agree with original/cut, $expected with cut(1)"
