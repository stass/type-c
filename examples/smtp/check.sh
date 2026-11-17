#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

# Runs the port, ./smtpd, and the original, original/smtpd, on the same
# sessions, and compares their replies, messages, exit status and
# mailbox. Each runs as "smtpd" from PATH, so that both print the same
# name, in a directory of its own that holds its mailbox. A session must
# end with status 0, so that the two cannot agree by both failing.
# Prints a count of the cases when every one agrees; exits 1 after
# printing each that does not. Three cases more check the command line
# and a mailbox that cannot be opened.

set -u

here=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
# A missing program would leave PATH to find another smtpd instead.
for program in "$here/smtpd" "$here/original/smtpd"; do
	if [ ! -x "$program" ]; then
		echo "check.sh: $program is not built" >&2
		exit 1
	fi
done
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/port" "$work/original" || exit 1
ln -s "$here/smtpd" "$work/port/smtpd" || exit 1
ln -s "$here/original/smtpd" "$work/original/smtpd" || exit 1

agreed=0
failed=0

# Runs one program, port or original, with the arguments that follow, on
# the client's side in $work/in, into $work/$1.out, .err and .status.
run() {
	side=$1
	shift
	rm -rf "$work/$side/mailbox"
	# A file may grow to 2 or 4 MiB, by the shell's unit of 512 or 1024
	# bytes: past MAX_SPOOL, so that a spool not bounded by it kills its
	# program with SIGXFSZ on the session message-too-big.
	(ulimit -f 4096 && cd "$work/$side" &&
	    PATH="$work/$side:$PATH" exec smtpd "$@") \
	    <"$work/in" >"$work/$side.out" 2>"$work/$side.err"
	echo $? >"$work/$side.status"
}

# Compares the two programs on $work/in, the case $2, run with the
# arguments that follow; both must exit with $1.
compare() {
	expected=$1
	name=$2
	shift 2
	run port "$@"
	run original "$@"
	for part in out err status; do
		if ! cmp -s "$work/port.$part" "$work/original.$part"; then
			echo "differs in $part: $name"
			failed=1
			return
		fi
	done
	if [ -e "$work/port/mailbox" ] || [ -e "$work/original/mailbox" ]; then
		if ! cmp -s "$work/port/mailbox" "$work/original/mailbox"; then
			echo "differs in mailbox: $name"
			failed=1
			return
		fi
	fi
	if [ "$(cat "$work/port.status")" != "$expected" ]; then
		echo "exits with $(cat "$work/port.status")," \
		    "not $expected: $name"
		failed=1
		return
	fi
	agreed=$((agreed + 1))
}

# Runs the session $1, whose client side is the printf format $2 with
# the arguments that follow it. Lines end in \r\n where the client keeps
# to SMTP.
session() {
	name=$1
	shift
	# The format is the argument that the case gives.
	# shellcheck disable=SC2059
	printf "$@" >"$work/in"
	compare 0 "$name" mailbox
}

# Prints a string of $1 bytes, each $2.
repeat() {
	printf "%$1s" '' | tr ' ' "$2"
}

hello='HELO client.example\r\n'
envelope="${hello}MAIL FROM:<alice@client.example>\r\n"
envelope="${envelope}RCPT TO:<bob@smtpd.example>\r\n"

# Valid sessions.
session one-message "${envelope}"'DATA\r\nSubject: hi\r\n\r\n'\
'Hello.\r\n.\r\nQUIT\r\n'
session two-messages 'EHLO client.example\r\n'\
'MAIL FROM:<alice@client.example>\r\nRCPT TO:<bob@smtpd.example>\r\n'\
'RCPT TO:<carol@smtpd.example>\r\nDATA\r\nfirst\r\n.\r\n'\
'MAIL FROM:<alice@client.example>\r\nRCPT TO:<dave@smtpd.example>\r\n'\
'DATA\r\nsecond\r\n.\r\nQUIT\r\n'
session lower-case 'helo client.example\r\nmail from:<a@b>\r\n'\
'rcpt to:<c@d>\r\ndata\r\nx\r\n.\r\nquit\r\n'
session null-sender "${hello}"'MAIL FROM:<>\r\nRCPT TO:<bob@smtpd.example>\r\n'\
'DATA\r\nbounce\r\n.\r\nQUIT\r\n'
session empty-message "${envelope}"'DATA\r\n.\r\nQUIT\r\n'
session noop-everywhere 'NOOP\r\nNOOP anything at all\r\n'"${hello}"'NOOP\r\n'\
'MAIL FROM:<a@b>\r\nNOOP\r\nRCPT TO:<c@d>\r\nNOOP\r\nQUIT\r\n'
session end-without-quit "${envelope}"'DATA\r\nx\r\n.\r\n'

# Commands out of order.
session mail-before-helo 'MAIL FROM:<a@b>\r\nQUIT\r\n'
session rcpt-before-mail "${hello}"'RCPT TO:<c@d>\r\nQUIT\r\n'
session data-before-mail "${hello}"'DATA\r\nQUIT\r\n'
session data-before-helo 'DATA\r\nRCPT TO:<c@d>\r\nQUIT\r\n'
session data-without-rcpt "${hello}"'MAIL FROM:<a@b>\r\nDATA\r\nQUIT\r\n'
session nested-mail "${envelope}"'MAIL FROM:<x@y>\r\nDATA\r\nx\r\n.\r\nQUIT\r\n'

# RSET and HELO end the transaction, and nothing of it reaches the next.
session rset-mid-transaction "${envelope}"'RSET\r\nRCPT TO:<c@d>\r\n'\
'MAIL FROM:<x@y>\r\nRCPT TO:<z@w>\r\nDATA\r\nx\r\n.\r\nQUIT\r\n'
session rset-before-helo 'RSET\r\nMAIL FROM:<a@b>\r\nQUIT\r\n'
session rset-after-message "${envelope}"'DATA\r\nx\r\n.\r\nRSET\r\n'\
'DATA\r\nQUIT\r\n'
session helo-mid-transaction "${envelope}"'EHLO other.example\r\n'\
'DATA\r\nMAIL FROM:<x@y>\r\nRCPT TO:<z@w>\r\nDATA\r\nx\r\n.\r\nQUIT\r\n'

# The text, its dots, and lines in it that look like commands.
session dot-stuffing "${envelope}"'DATA\r\n..\r\n...\r\n..x\r\n.x\r\n'\
' .\r\n. \r\n\r\n.\r\nQUIT\r\n'
session commands-in-text "${envelope}"'DATA\r\nQUIT\r\nRSET\r\n'\
'MAIL FROM:<evil@example>\r\n.\r\nQUIT\r\n'
session bytes-in-text "${envelope}"'DATA\r\na\rb\r\nnul\000byte\r\n\r\r\n'\
'\377\r\n.\r\nQUIT\r\n'
session eof-in-data "${envelope}"'DATA\r\nnever ended\r\n'
session eof-in-line "${envelope}"'NOOP'

# Lines that end otherwise than in CRLF.
session bare-lf-command "${hello}"'NOOP\nQUIT\r\n'
session bare-lf-text "${envelope}"'DATA\r\nx\r\n.\nMAIL FROM:<a@b>\r\n'
session smuggling "${envelope}"'DATA\r\nx\r\n\n.\n\r\n'\
'MAIL FROM:<forged@example>\r\n.\r\nQUIT\r\n'
session lone-lf "${hello}"'\n'

# The longest lines, and one byte more.
session longest-command "${hello}"'NOOP %s\r\nQUIT\r\n' "$(repeat 993 x)"
session overlong-command "${hello}"'NOOP %s\r\nQUIT\r\n' "$(repeat 994 x)"
session longest-text "${envelope}"'DATA\r\n%s\r\n.\r\nQUIT\r\n' \
    "$(repeat 998 y)"
session overlong-text "${envelope}"'DATA\r\n%s\r\n.\r\nQUIT\r\n' \
    "$(repeat 999 y)"

# Arguments that do not parse.
session unknown-command 'HELP\r\nHELOX a\r\nHEL\r\n\r\nQUIT\r\n'
session helo-syntax 'HELO\r\nHELO \r\nHELO a b\r\nHELO <a>\r\n'\
'HELO a\001b\r\nQUIT\r\n'
session longest-domain 'HELO %s\r\nHELO %s\r\nQUIT\r\n' \
    "$(repeat 255 d)" "$(repeat 256 d)"
session path-syntax "${hello}"'MAIL FROM:a@b\r\nMAIL FROM: <a@b>\r\n'\
'MAIL TO:<a@b>\r\nMAIL FROM:<a b>\r\nMAIL FROM:<a@b> SIZE=10\r\n'\
'MAIL FROM:<a@b>\r\nRCPT TO:<>\r\nRCPT TO:<<c@d>>\r\nRCPT FROM:<c@d>\r\n'\
'QUIT\r\n'
session longest-address "${hello}"'MAIL FROM:<%s>\r\nMAIL FROM:<%s>\r\n'\
'QUIT\r\n' "$(repeat 254 a)" "$(repeat 255 a)"
session arguments-not-taken "${envelope}"'DATA now\r\nRSET now\r\n'\
'QUIT now\r\nQUIT\r\n'
session nul-in-command "${hello}"'NOOP\000\r\nQUIT\000\r\nQUIT\r\n'

# The limits of a message.
rcpts=
i=0
while [ $i -lt 101 ]; do
	rcpts="${rcpts}RCPT TO:<r$i@smtpd.example>\\r\\n"
	i=$((i + 1))
done
session too-many-recipients "${hello}"'MAIL FROM:<a@b>\r\n'"${rcpts}"\
'DATA\r\nx\r\n.\r\nQUIT\r\n'

# Prints text whose lines take $1 bytes in the spool, each line of it
# with LF in place of CRLF.
text() {
	line=$(repeat 998 z)
	i=0
	while [ $i -lt $(($1 / 999)) ]; do
		printf '%s\r\n' "$line"
		i=$((i + 1))
	done
	if [ $(($1 % 999)) -gt 0 ]; then
		printf '%s\r\n' "$(repeat $(($1 % 999 - 1)) z)"
	fi
}

# Runs the session $1: a message of the text $2 bytes long in the spool,
# then a small one.
large() {
	{
		printf "${envelope}DATA\\r\\n"
		text "$2"
		printf ".\\r\\n${envelope}"
		printf 'DATA\r\nsmall\r\n.\r\nQUIT\r\n'
	} >"$work/in"
	compare 0 "$1" mailbox
}

# The envelope of $envelope in the spool, before the text.
from='From <alice@client.example> via client.example'
to='To <bob@smtpd.example>'
max_text=$((1024 * 1024 - ${#from} - 1 - ${#to} - 1 - 1))
large longest-message "$max_text"
large message-one-byte-too-big $((max_text + 1))
large message-too-big $((6 * 1024 * 1024))

# The command line, and a mailbox that cannot be opened.
printf 'QUIT\r\n' >"$work/in"
compare 2 no-mailbox
compare 2 two-mailboxes mailbox other
compare 1 mailbox-is-directory .

if [ "$failed" -ne 0 ]; then
	exit 1
fi
echo "smtp: $agreed cases agree with original/smtpd"
