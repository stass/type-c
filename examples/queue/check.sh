#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs the Type-C version, ./sched, and the C original, original/sched,
# on the same inputs, and compares their output, messages and exit
# status. Both programs are called sched, so that their messages name
# the same program. Prints a count of the inputs when every one agrees;
# exits 1 after printing each that does not.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
for program in "$here/sched" "$here/original/sched"; do
	if [ ! -x "$program" ]; then
		echo "check.sh: $program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

agreed=0
failed=0

# run PROGRAM SIDE: runs PROGRAM on $work/input into $work/SIDE.*.
run() {
	"$1" <"$work/input" >"$work/$2.out" 2>"$work/$2.err"
	echo $? >"$work/$2.status"
}

# same NAME: runs both programs on $work/input and compares them.
same() {
	run "$here/original/sched" original
	run "$here/sched" port
	for part in out err status; do
		if ! cmp -s "$work/original.$part" "$work/port.$part"; then
			echo "differs in $part: $1"
			diff "$work/original.$part" "$work/port.$part"
			failed=1
			return
		fi
	done
	agreed=$((agreed + 1))
}

# A round of the queue: a job is done and leaves it, mid-round.
printf 'add a 5\nadd b 2\nadd c 4\nrun 2\nps\nrun 2\nrun 2\nps\n' \
    >"$work/input"
same 'rounds'

# urgent puts a job at the head of the queue and at the tail of ps.
printf 'add a 3\nurgent b 3\nurgent c 1\nadd d 2\nrun 1\nrun 5\nps\n' \
    >"$work/input"
same 'urgent'

# kill takes a job off the queue, whether first, last or between.
printf 'add a 3\nadd b 3\nadd c 3\nadd d 3\nkill b\nrun 1\nkill a\n' \
    >"$work/input"
printf 'kill d\nrun 1\nps\nkill c\nrun 1\nps\n' >>"$work/input"
same 'kill'

# A job that has ended cannot be killed or added again.
printf 'add a 1\nrun 1\nkill a\nadd a 1\nadd b 2\nkill b\nkill b\n' \
    >"$work/input"
printf 'add b 1\nps\n' >>"$work/input"
same 'ended'

# Errors of a command, each skipped.
printf 'bogus\nadd\nadd a\nadd a 1 2\nadd a 0\nadd a -1\nadd a 1x\n' \
    >"$work/input"
printf 'add a 1000001\nadd a 1000000\nadd 0123456789abcdef 1\n' \
    >>"$work/input"
printf 'add 0123456789abcde 1\nrun\nrun 0\nrun 99999999999\n' \
    >>"$work/input"
printf 'kill\nkill nobody\nps 1\n\n  \t \nps\n' >>"$work/input"
same 'errors'

# Blanks and a last line without a newline.
printf '  add\ta  7 \n\trun 3\t\nps' >"$work/input"
same 'blanks'

# Nothing at all.
: >"$work/input"
same 'empty'

# Many jobs: every fifth added urgent, every seventh killed, and rounds
# between, until the queue is empty.
awk 'BEGIN {
	for (i = 1; i <= 2000; i++) {
		if (i % 5 == 0)
			print "urgent j" i, i % 97 + 1
		else
			print "add j" i, i % 89 + 1
		if (i % 7 == 0)
			print "kill j" (i - 3)
		if (i % 50 == 0)
			print "run 13"
	}
	for (i = 0; i < 10; i++)
		print "run 11"
	print "ps"
}' >"$work/input"
same 'many jobs'

if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "queue: $agreed inputs agree with original/sched"
