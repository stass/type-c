#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs the port, ./xargs, and FreeBSD's original/xargs on the same
# command lines and inputs, and compares their output, messages and exit
# status.  Each runs as "xargs" from PATH, so that both print the same
# name, from directories whose names have the same length, so that both
# see an environment of the same size, which xargs subtracts from the
# room for arguments.  Where the port differs from the original
# (README.md, "Where the port differs"), the port is checked against the
# output that xargs(1) describes instead.  Prints a count of the cases
# when every one agrees; exits 1 after printing each that does not.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
# A missing program would leave PATH to find the system's xargs instead.
for program in "$here/xargs" "$here/original/xargs"; do
	if [ ! -x "$program" ]; then
		echo "check.sh: $program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/data" "$work/port" "$work/orig" || exit 1
ln -s "$here/xargs" "$work/port/xargs" || exit 1
ln -s "$here/original/xargs" "$work/orig/xargs" || exit 1

cd "$work/data" || exit 1
printf 'one two  three\n\tfour\n\nfive six\n' >words
printf "a 'b c' \"d e\" f\\\\ g 'h\"i' \"j'k\" ''\n" >quoted
printf 'one\000two words\000\000three\n' >nul
printf 'a\nb\nc\nd\ne\nf\ng\n' >lines
printf 'a b\nc\nd e f\ng\n' >ragged
printf 'one\ntwo\nEND\nthree\n' >eof
printf 'one two' >unterminated_tail
printf "one 'two\nthree\n" >open_quote
printf 'one two\\' >backslash_tail
printf 'aa bbbbbbbbbbbbbbbbbbbbbb c\n' >shift
printf 'abcdefghijklmnopqrstuvwxyz\n' >long
: >empty
printf '#!/bin/sh\n' >notexec
i=0
while [ $i -lt 6000 ]; do
	echo "argument$i"
	i=$((i + 1))
done >many

agreed=0
expected=0
failed=0

# run SIDE COMMAND: runs COMMAND with SIDE's xargs into SIDE.*.
run() {
	(
		PATH="$work/$1:$PATH"
		LC_ALL=C
		export PATH LC_ALL
		eval "$2"
	) >"$work/$1.out" 2>"$work/$1.err"
	echo $? >"$work/$1.status"
}

# same COMMAND: runs COMMAND with each xargs and compares them.
same() {
	run orig "$1"
	run port "$1"
	for part in out err status; do
		if ! cmp -s "$work/orig.$part" "$work/port.$part"; then
			echo "differs in $part: $1"
			diff "$work/orig.$part" "$work/port.$part"
			failed=1
			return
		fi
	done
	agreed=$((agreed + 1))
}

# expect COMMAND OUTPUT MESSAGE STATUS: runs COMMAND with the port and
# compares its output with the printf format OUTPUT, its standard error
# with the line MESSAGE, none when MESSAGE is empty, and its exit status
# with STATUS.
expect() {
	run port "$1"
	printf "$2" >"$work/expected.out"
	if [ -n "$3" ]; then
		printf '%s\n' "$3"
	fi >"$work/expected.err"
	echo "$4" >"$work/expected.status"
	for part in out err status; do
		if ! cmp -s "$work/expected.$part" "$work/port.$part"; then
			echo "unexpected $part: $1"
			diff "$work/expected.$part" "$work/port.$part"
			failed=1
			return
		fi
	done
	expected=$((expected + 1))
}

# Splitting the input into arguments, and the default utility.
same 'xargs <words'
same 'xargs echo <words'
same 'xargs printf "[%s]\n" <words'
same 'xargs printf "[%s]\n" <quoted'
same 'xargs <empty'
same 'xargs echo <empty'
same 'xargs -r echo <empty'
same 'xargs <unterminated_tail'
same 'xargs echo <open_quote'
same 'xargs echo <backslash_tail'
same 'xargs -0 printf "[%s]\n" <nul'
same 'xargs --null printf "[%s]\n" <nul'
same 'xargs -0 printf "[%s]\n" <quoted'
same 'xargs echo <many | wc -l'

# -E: an argument that ends the input.
same 'xargs -E END echo <eof'
same 'xargs -E "" echo <eof'
same 'xargs -E three echo <eof'
same 'xargs -E one echo <eof'

# -n, -L and -s: how many arguments a command takes.
same 'xargs -n 1 echo <words'
same 'xargs -n 2 echo <words'
same 'xargs --max-args=3 echo <lines'
same 'xargs -n 2 echo <many | wc -l'
same 'xargs -L 1 echo <ragged'
same 'xargs -L 2 echo <ragged'
same 'xargs -L 3 echo <lines'
same 'xargs -0 -L 1 printf "[%s]\n" <nul'
same 'xargs -s 20 echo <lines'
same 'xargs --max-chars=12 echo <lines'
same 'xargs -s 30 echo <shift'
same 'xargs -s 10 echo <long'
same 'xargs -s 5 echo <lines'
same 'xargs -s 0 echo <lines'
same 'xargs -L 2 -s 12 echo <ragged'
same 'xargs -n 0 echo <words'
same 'xargs -n 99999999999 echo <words'
same 'xargs -n two echo <words'
same 'xargs -L 0 echo <words'
same 'xargs -L x echo <words'
same 'xargs -s -1 echo <words'
same 'xargs -s 99999999999 echo <words'
same 'xargs -x echo <words'

# -I and -J: where the arguments go.
same 'xargs -I {} echo [{}] <ragged'
same 'xargs -I {} echo {} and {} <lines'
same 'xargs -I {} echo <ragged'
same 'xargs -I {} printf "<%s>\n" {} <quoted'
same 'xargs -I {} -R 1 echo {} {} <lines'
same 'xargs -I {} -R -1 echo {} {} {} <lines'
same 'xargs -I {} -R 0 echo {} <lines'
same 'xargs -I {} -S 20 echo {}{}{} <ragged'
same 'xargs -I {} -S 10 echo xx{}xx <long'
same 'xargs -I {} -S 6 echo ab{}c <lines'
same 'xargs -0 -I % printf "[%s]\n" %% <nul'
same 'xargs -I "" echo <lines'
same 'xargs -R 2 echo <lines'
same 'xargs -S 99 echo <lines'
same 'xargs -J % echo [ % ] <words'
same 'xargs -J % -n 2 echo [ % ] <words'
same 'xargs -J % echo [ ] <words'
same 'xargs -J % % <words'
same 'xargs -J "" echo % <words'
same 'xargs -J % -R 2 echo % <words'
same 'xargs -J % -I {} echo % {} <lines'
same 'xargs -I {} -J % echo % {} <lines'

# -t, -o and -P: tracing, the standard input and parallel commands.
same 'xargs -t echo <words'
same 'xargs --verbose -n 2 echo <words'
same 'xargs -t -I {} echo {} <lines'
same 'xargs -o echo <words'
same 'xargs -P 3 -n 1 true <lines'
same 'xargs -P 0 -n 2 true <lines'
same 'xargs --max-procs=2 -n 1 sh -c "exit 0" <lines'
same 'xargs -P x echo <words'
same 'xargs -P -1 echo <words'

# Children that fail.
same 'xargs -n 1 sh -c "exit 1" <lines'
same 'xargs -n 1 sh -c "exit 255" <lines'
same 'xargs -n 1 sh -c "kill -9 \$\$" <lines'
same 'xargs -n 1 sh -c "exit \$1" sh <lines'
same 'xargs no-such-utility <words'
same 'xargs ./notexec <words'

# Options it does not take.
same 'xargs -q echo <words'
same 'xargs --nope echo <words'
same 'xargs -E <words'

# -S: an argument too long once substituted.
same 'xargs -I {} -S 4 echo ab{}c <lines'

# -x with -n alone: xargs(1) gives each command n arguments, and stops
# where they do not fit; the original runs a command after each argument
# and at each empty line.
expect 'xargs -n 3 -x echo <words' 'one two three\nfour five six\n' '' 0
expect 'xargs -n 2 -x echo <words' 'one two\nthree four\nfive six\n' '' 0
expect 'xargs -n 2 -x echo <lines' 'a b\nc d\ne f\ng\n' '' 0
expect 'xargs -n 9 -x -s 12 echo <lines' '' \
    'xargs: insufficient space for arguments' 1
expect 'xargs -n 9 -x -s 20 echo <many' '' \
    'xargs: insufficient space for arguments' 1

# -S: an argument of exactly replsize bytes is substituted, where the
# original cuts its last byte and keeps the replstr.
expect 'xargs -I {} -S 5 echo ab{}c <lines' \
    'abac\nabbc\nabcc\nabdc\nabec\nabfc\nabgc\n' '' 0
# Where the substitution does not fit, the port stops, as for any other
# argument; the original runs the cut argument and exits 0.
expect 'echo xy | xargs -I X -S 3 echo aXc' '' \
    'xargs: command line cannot be assembled, too long' 1

if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "xargs: $agreed cases agree with original/xargs, $expected with xargs(1)"
