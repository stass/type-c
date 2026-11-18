<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# smtp: an SMTP server's state machine in Type-C

[`original/smtpd.c`](original/smtpd.c) is the server side of a small
subset of SMTP (RFC 5321): HELO, EHLO, MAIL, RCPT, DATA with its
dot-stuffing and its final `.`, RSET, NOOP and QUIT. It reads what a
client sends from standard input, writes the replies to standard output,
and appends each message it accepts to a mailbox file. It is written the
way an experienced C programmer writes a protocol state machine: an
`enum` for the state, a `switch` or an `if` on it in each command, and
one structure that holds the data of every state, each field valid in
only some of them. [`smtpd.tc`](smtpd.tc) is the same program in Type-C.
Both were written for this example and carry the BSD-2-Clause license.

SMTP is here, and not an HTTP/1.0 request reader, because a session
keeps state from one line to the next and that state carries data: the
client's name after HELO, the sender and the recipients after MAIL, the
spool file after DATA. A reader of one HTTP/1.0 request has little state
besides where it is in the request, and its data is valid throughout.

The port keeps the original's functions, in the same order, with the
same names, variables, comments and control flow, so that

```sh
diff original/smtpd.c smtpd.tc
```

shows only what Type-C changes. Both print the same replies, write the
same mailbox and exit with the same status on every session of
[`check.sh`](check.sh), which `make check` shows:

```sh
make            # gmake on FreeBSD; builds smtpd and original/smtpd
make check
TYPEC_CC=gcc-14 make clean check
```

```console
$ printf 'HELO client.example\r\nMAIL FROM:<alice@client.example>\r\nRCPT TO:<bob@smtpd.example>\r\nDATA\r\nSubject: dots\r\n\r\n..a line that starts with a dot\r\n.\r\nQUIT\r\n' |
    ./smtpd mailbox
220 smtpd.example ESMTP
250 smtpd.example
250 Ok
250 Ok
354 End data with <CR><LF>.<CR><LF>
250 Ok: queued as 1
221 Bye
$ cat mailbox
Message 1, 117 bytes
From <alice@client.example> via client.example
To <bob@smtpd.example>

Subject: dots

.a line that starts with a dot
```

## The tests

`make check` runs both programs on 41 sessions that `check.sh` writes
with `printf`, and compares their replies, messages, exit status and
mailbox. A session must end with status 0, so that the two programs
cannot agree by both failing. Each program runs with its files limited
to a few MiB, so that one that does not bound its spool is killed on
the largest message. The sessions are:

| Group | What they hold |
|---|---|
| valid sessions | one message; two messages, one to two recipients; commands in lower case; the null sender `<>`; an empty message; NOOP in every state; the end of input after a message without QUIT |
| out of order | MAIL before HELO, RCPT before MAIL, DATA before MAIL and before HELO, DATA without RCPT, MAIL inside a transaction |
| RSET and HELO | RSET in the middle of a transaction, before HELO and after a message; EHLO in the middle of a transaction |
| the text | dot-stuffing, with `..`, `...`, `.x`, `. ` and an empty line; lines in the text that look like commands; a bare CR, a NUL and the byte 0xff in the text; the end of input in DATA and in a line |
| line ends | a bare LF after a command, after the `.` of the text, and as the `\n.\n` of SMTP smuggling; a line that is a bare LF |
| lengths | the longest command and text lines, 998 bytes before the CRLF, and a byte more; the longest domain, 255 bytes, and the longest address, 254, and a byte more |
| syntax | unknown commands; HELO without a domain, with a space, a bracket or a control character in it; paths without brackets, with a space before them, with parameters, the null path in RCPT; arguments to DATA, RSET and QUIT; a NUL in a command |
| limits | 101 recipients; a message of exactly 1 MiB with its envelope, one of a byte more, and one of 6 MiB, each followed by a small one |

Three cases more run both programs without a mailbox, with two, and
with a directory as the mailbox.

## The port, step by step

### The state becomes a variant

The original keeps where the session is in an `enum`, and the data of
every state in one structure, whose comments say in which states each
field is valid:

```c
enum state {
	STATE_INIT,		/* before HELO or EHLO */
	STATE_GREETED,		/* after HELO, between messages */
	STATE_MAIL,		/* after MAIL, taking RCPT */
	STATE_DATA		/* after DATA, reading the message text */
};

struct session {
	enum state	state;
	char		client[MAX_DOMAIN + 1];	/* all but INIT */
	char		from[MAX_ADDRESS + 1];	/* MAIL; "" for <> */
	char		rcpt[MAX_RCPT][MAX_ADDRESS + 1]; /* MAIL */
	size_t		nrcpt;			/* MAIL */
	FILE		*spool;			/* DATA */
	FILE		*mailbox;
	unsigned	queued;			/* messages accepted */
};
```

Nothing but those comments ties `s->from` to `STATE_MAIL`. The port
moves each field into the constructor of the states where it is valid,
and keeps in the session what every state shares, and the recipients:

```c
type state =
    | Init				/* before HELO or EHLO */
    | Greeted(struct domain client)	/* after HELO, between messages */
    | Mail(struct domain client, struct address from, struct recipients *to)
    | Data(struct domain client, FILE *spool);	/* reading the text */

struct session {
	state		state;
	struct recipients rcpts;		/* what Mail's to points to */
	FILE		*mailbox;
	unsigned	queued;			/* messages accepted */
};
```

A field of a variant cannot be an array (design 3.2, rule 4), so the
port adds three structures, `struct domain`, `struct address` and
`struct recipients`, each of which wraps an array of the original.

The recipients are 25 KB that `rcpt` appends to, and a binding is a
copy that cannot change (design 4.1), so in `Mail` itself every RCPT
would copy them out, append to the copy and build the state again from
it. They stay in the session, and `Mail` holds a pointer to them, the
idiom of design 4.1 for a large payload that arms update; what that
saves and what it gives up is in [What it costs](#what-it-costs).

### A transition is a match, and the data comes with it

`mail` switches on the state, as in the original, and its `match`
binds the client's name only in the arm of `Greeted`, the one state
that has it. The new state is built whole, from that name, the sender
and the list of recipients, which `mail` empties as the original does:

```c
	switch (s->state) {
	...
	case STATE_GREETED:
		memcpy(s->from, cmd->address, sizeof(s->from));
		s->nrcpt = 0;
		s->state = STATE_MAIL;
		reply("250 Ok");
		break;
```

```c
	match (s->state) {
	...
	case Greeted(client):
		s->rcpts.nrcpt = 0;
		s->state = Mail(client, cmd->address, &s->rcpts);
		reply("250 Ok");
		break;
```

Where the original guards a command with `if (s->state != STATE_MAIL)`,
as `rcpt`, `data` and `rset` do, the port tests for the state and binds
its fields in one step, `if (case Mail(client, from, to) = s->state)`.
The bindings are in scope only in the statement that the test controls,
so the guard turns over: the work of the command goes in that
statement, and the refusal after `else`.
`deliver` and `text` read the spool from the session in the original;
in the port the arm of `serve` that matched `Data` passes them the
spool and the client's name, which no other state has:

```c
		if (s->state == STATE_DATA)
			text(s, line, len);
		else if (!command(s, line, len))
			return;
```

```c
		/* A match, not a test: each state says what its lines are. */
		match (s->state) {
		case Init:
		case Greeted(_):
		case Mail(_, _, _):
			if (!command(s, line, len))
				return;
			break;
		case Data(client, spool):
			text(s, &client, spool, line, len);
			break;
		}
```

### A line that does not parse is an error that `try` hands up

The original's parsers return `NULL`, or the reply to a line that does
not parse, and fill an out-parameter; each caller tests the result and
returns it again:

```c
	case VERB_MAIL:
		if ((error = parse_path(arg, " FROM:", true,
		    cmd->address)) != NULL)
			return (error);
		break;
```

In the port each parser returns a `result` whose error is that reply,
and `try` hands it up:

```c
	case VERB_MAIL:
		cmd.address = try parse_path(arg, " FROM:", true);
		break;
```

`command`, which sends the reply, matches the result of
`parse_command`. `read_line` returns a `result` too: the length of the
line, or why there is none, `EndOfInput`, `TooLong` or `BareLf`, where
the original returns a status and leaves the length in an
out-parameter that is valid only for one of the four.

## Adding a state

Add a state to both programs: `AUTH PLAIN` without its credentials,
after which the server waits for a line of credentials (RFC 4954).
Before writing any of its code, add the state alone, and ask the
compilers where it must be handled:

```diff
 	STATE_GREETED,		/* after HELO, between messages */
+	STATE_AUTH,		/* after AUTH, reading the credentials */
 	STATE_MAIL,		/* after MAIL, taking RCPT */
```

```diff
     | Greeted(struct domain client)	/* after HELO, between messages */
+    | Auth(struct domain client)	/* after AUTH, reading credentials */
     | Mail(struct domain client, struct address from, struct recipients *to)
```

Clang and GCC report the one `switch` on the state, in `mail`, and build
the program. `-Wall` reports it already, as `-Wswitch`, because the
`switch` has no `default`; `-Wswitch-enum` would add the `switch`es that
have one, and this program has none:

```console
$ clang -Wall -Wextra -Wswitch-enum -c smtpd.c
smtpd.c:253:10: warning: enumeration value 'STATE_AUTH' not handled in switch [-Wswitch]
  253 |         switch (s->state) {
      |                 ^~~~~~~~
smtpd.c:253:10: note: add missing switch cases
...
1 warning generated.
$ gcc-16 -Wall -Wextra -Wswitch-enum -c smtpd.c
smtpd.c: In function 'mail':
smtpd.c:253:9: warning: enumeration value 'STATE_AUTH' not handled in switch [-Wswitch]
  253 |         switch (s->state) {
      |         ^~~~~~
```

The place that matters most is not a `switch`: `serve` asks
`if (s->state == STATE_DATA)` and hands every other line to `command`.
Built as it stands, the server reads the client's credentials as a
command, replies `500 Command unrecognized` to them, and would run them
if they spelled one. No compiler says a word about it.

`typec` refuses the program at each `match` on the state that misses
`Auth`. It stops at the first error of a unit (main
[README](../../README.md#what-typec-reports)), so it names them one
build at a time: `mail`, and once `mail` handles `Auth`, `serve`:

```console
$ typec -Wall -Wextra -c smtpd.tc
smtpd.tc:265: error: the match does not cover the constructor 'Auth' of the variant 'state' [match-coverage]
$ typec -Wall -Wextra -c smtpd.tc       # with Auth in mail's match
smtpd.tc:457: error: the match does not cover the constructor 'Auth' of the variant 'state' [match-coverage]
```

With `Auth` in both matches the port builds again, and those are all
the places that must decide what `Auth` does. The tests `if (case
Mail(...) = s->state)` of `rcpt`, `data` and `rset` stay silent, as a
`default` would (design 4.2, rule 3), and rightly: a command that needs
a transaction is refused in `Auth` as in every state but `Mail`.

This is why `serve` is a `match` and not the test `if (case Data(...)
= s->state)`, which would read as the original's `if`: what a line is
depends on every state, so every state must answer. A test there would
miss `Auth` as the original does. The port writes a test where one
state matters and the others share one answer, and a `match` where each
state must decide.

## A field in the wrong state

The fields of the original's session are always there, whatever the
state. Delete from `mail` the line that starts the new transaction's
list of recipients:

```diff
 	case STATE_GREETED:
 		memcpy(s->from, cmd->address, sizeof(s->from));
-		s->nrcpt = 0;
 		s->state = STATE_MAIL;
```

Clang and GCC build it without a warning. `main` sets only the state
and the count of messages, so `nrcpt` starts as whatever the stack held:
built with `-O2` by either, the server crashes at the first RCPT. Built with
AddressSanitizer, where the stack held 0, it runs, and after an RSET it
sends Carol's message for Dave to Bob as well, the recipient of the
transaction that RSET ended:

```console
$ printf 'HELO client.example\r\nMAIL FROM:<alice@client.example>\r\nRCPT TO:<bob@smtpd.example>\r\nRSET\r\nMAIL FROM:<carol@client.example>\r\nRCPT TO:<dave@smtpd.example>\r\nDATA\r\nfor dave only\r\n.\r\nQUIT\r\n' |
    ./smtpd-asan mailbox >/dev/null
$ cat mailbox
Message 1, 109 bytes
From <carol@client.example> via client.example
To <bob@smtpd.example>
To <dave@smtpd.example>

for dave only
```

The port keeps the list in the session, for the sake of its stack
([What it costs](#what-it-costs)), so it has the same line,
`s->rcpts.nrcpt = 0`, and deleting it brings the same bug. `typec`
builds it without a warning; built with `-O2`, the server crashes at
the first RCPT, and built with AddressSanitizer it sends Carol's
message to Bob, as the original does. What the variant still checks is
that a `Mail` is given a pointer to a list: leave the pointer out of the
constructor, and `typec` refuses the program:

```diff
 	case Greeted(client):
 		s->rcpts.nrcpt = 0;
-		s->state = Mail(client, cmd->address, &s->rcpts);
+		s->state = Mail(client, cmd->address);
```

```console
$ typec -Wall -Wextra -c smtpd.tc
smtpd.tc:270: error: the constructor 'Mail' takes 3 arguments, its fields 'client', 'from' and 'to'; 2 are given [constructor-expression]
```

The sender is a field of `Mail` by value, and for it the port keeps
what the variant gives. `reply("250 Ok, <%s> forgotten",
s->from)` in the original's `rset` compiles without a warning and, in
any state but `Mail`, prints a sender that is stale or was never set.
The port has no `s->from` to write: the sender is a binding of the arm
or the test that matched `Mail`, and nowhere else is it in scope:

```console
$ typec -Wall -Wextra -c smtpd.tc       # from.text in rset, outside the test
smtpd.tc:327: error: 'from' is not declared (C11 6.5.1p2)
```

## What it costs

| | `original/smtpd.c` | `smtpd.tc` |
|---|---:|---:|
| lines | 463 | 489 |
| lines of code, without comments and blank lines | 372 | 381 |
| functions | 16 | 16 |
| places that test the state | 6 | 6 |

The lines of code are those that
`gcc -fpreprocessed -dD -E -P -x c FILE` prints that are not blank. The
port is 9 lines of code longer: the three structures that wrap the
arrays of the states, and the arms of the `match` in `mail` and `serve`
that name states with nothing to do there. The `match` in `mail` names
`Data`, though no command arrives in DATA; the original's `switch` names
it too, as `-Wswitch` asks.

The session is about 26 KB in both programs, most of it the list of
100 recipients of 255 bytes each. The port holds that list in the
session, and `Mail` a pointer to it, the idiom that design 4.1 gives
for a payload of kilobytes that arms update: `mail` empties `s->rcpts`
and stores `Mail(client, cmd->address, &s->rcpts)`, `rcpt` appends
through `to` as the original appends to `s->rcpt`, and `data` reads the
list through `to`.

The value form shows what the idiom saves. There `Mail(struct domain
client, struct address from, struct recipients to)` holds the list
itself, a binding is a copy that cannot change (design 4.1), and Type-C
has no binding by reference (design 12). So to add a recipient, `rcpt`
copies the list into its binding, appends to a second copy, and builds
the state again from that in a third, where the original appends in
place. The copies cost time in proportion to what the client sends, a
few times 26 KB a command at most, and they cost stack. The table gives
the deepest path from `main` through the calls among each program's own
functions, summing the frames that `-fstack-usage` reports; the C
library's frames are not counted. At `-Os` and `-O2` most functions are
inlined into `main`, whose frame is nearly all of the path. GCC is
GCC 16, and ARM is arm-none-eabi-gcc 14.2 with `-mcpu=cortex-m3 -mthumb
-fno-short-enums`; the value form is `smtpd.tc` at commit `d48cd49`:

| deepest stack path | `original/smtpd.c` | `smtpd.tc` | value form |
|---|---:|---:|---:|
| Clang `-O0` | 28,504 B | 31,440 B | 133,080 B |
| GCC `-O0` | 28,512 B | 32,176 B | 107,504 B |
| ARM `-O0` | 28,168 B | 31,920 B | 107,056 B |
| Clang `-Os` | 28,384 B | 30,272 B | 54,704 B |
| GCC `-Os` | 28,352 B | 30,040 B | 54,296 B |
| ARM `-Os` | 28,128 B | 29,680 B | 79,680 B |
| Clang `-O2` | 28,368 B | 30,272 B | 54,720 B |
| GCC `-O2` | 28,368 B | 30,048 B | 54,304 B |
| ARM `-O2` | 28,112 B | 29,680 B | 79,688 B |

The port is within 2 KB of the original under every optimizing
compiler, and within 3.8 KB at `-O0`. The rest is copies of payloads
of a few hundred bytes, the client's name, the sender and the parsed
command, that bindings, constructors and `try` make; at `-O0` the
deepest path goes through `parse_command`, which holds the command and
the results of the parsers it calls. The value form takes about twice
the original's stack under Clang and GCC at `-Os` and `-O2`, nearly
three times under ARM, and nearly four times under GCC and ARM and
nearly five under Clang at `-O0`.

The idiom gives up part of what the variant gives. `s->rcpts` can be
named in every state, though through the payload it is reached in
`Mail` only: a command can read or change a list that belongs to no
transaction, and forgetting to empty it is the original's bug again
([A field in the wrong state](#a-field-in-the-wrong-state)). And the
list lives as long as the session, not as long as `Mail`: that `to`
points to a live list is the program's to keep true, as for any C
pointer. Here it holds because every `to` is `&s->rcpts` of the session
that holds the state.

## What Type-C does not check here

- `text` and `deliver` take the spool, and `text` the client's name, as
  parameters. That they come from the `Data` state is true because
  `serve` passes them from its arm, not because the type says so.
- The recipients are the session's, and `Mail` points to them. That
  only `Mail` uses them, and that its `to` points to them, holds because
  the program is written so ([What it costs](#what-it-costs)).
- A test on one state, like a `default`, takes a state added later
  without a word (design 4.2, rule 3); the port relies on its tests
  being right for every other state, as the original relies on its
  `if`s.
- `read_line` writes through a `char *` and a size, as the original
  does; a slice would check its index.
- The format strings of `printf` and `fprintf` are C's; `typec` checks
  them no more than the C compiler does.

## Limits of both programs

- No extension is known: EHLO answers in one line, as HELO does, and a
  MAIL or RCPT with parameters, such as `SIZE=`, is refused.
- A line of a command or of text is at most 1000 bytes with its CRLF,
  the limit RFC 5321 sets for text; it sets 512 for a command.
- A line longer than that, or one that ends in a bare LF, ends the
  session with a `421` reply. A server that took `\n.\n` as the end of
  the text, as some did, is open to SMTP smuggling: a client hides a
  second message, with a sender of its choice, in the text of the first.
- A path is `<address>`, with nothing between the colon and `<` and no
  source route; an address is any printable ASCII but space, `<` and
  `>`, so that a quoted local part with a space is refused. Neither a
  domain nor an address can bring a control character to the mailbox.
- A message is at most 1 MiB, its envelope included. Past that, the
  text is read on to its `.` and dropped, and the reply is `552`.
- The mailbox's format is this example's own: a line `Message N, S
  bytes`, then the S bytes of the message, its envelope first. A
  record shorter than its S would frame every later one wrong, and
  could let the text of a message pass for an envelope, so both
  programs check what they copy and exit instead of replying `250`
  when a write fails. A write that fails in the middle of a record
  still leaves it torn, as does a second session that appends to the
  same mailbox at the same time: the mailbox has one writer, as a
  file that one test session writes has, and no lock.
- The mailbox is opened with `fopen`, which follows a symbolic link
  and creates the file with the mode of the umask. Its path comes from
  the command line, which the operator controls.
- Nothing bounds the number of messages in a session, the size of the
  mailbox, or how long a client may wait between lines.
