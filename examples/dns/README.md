<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/example_readmes.t checks the console blocks of this file on
Clang and GCC, but those marked untested: test/run/readme.sh says how
the blocks are marked.
-->

# dns: a DNS response parser in Type-C

[`original/dns.c`](original/dns.c) reads a DNS response message from a
file and prints its header, its questions and its answers, with the
data of A, AAAA, CNAME and MX records. It is written the way a careful
C programmer writes a parser of bytes from the network: a cursor over
the message, a length check before every read, a bound on the loop that
follows compression pointers, and a `-1` returned up through every
caller. [`dns.tc`](dns.tc) is the same program in Type-C. Both were
written for this example and carry the BSD-2-Clause license.

The port keeps the original's functions, in the same order, with the
same names, variables, comments and control flow, so that

```sh
diff original/dns.c dns.tc
```

shows only what Type-C changes. Both print the same output and messages
and exit with the same status on every message of [`tests/`](tests/),
which `make check` shows:

```sh
make            # gmake on FreeBSD; builds dns and original/dns
make check
TYPEC_CC=gcc-14 make clean check
```

```console
$ ./dns tests/valid/cname-www-github-com.bin
header id 12809 flags 0x8180 questions 1 answers 2 authority 0 additional 0
question www.github.com. IN A
answer www.github.com. 3334 IN CNAME github.com.
answer github.com. 37 IN A 172.182.252.133
$ ./dns tests/invalid/pointer-to-itself.bin
header id 4660 flags 0x8180 questions 1 answers 0 authority 0 additional 0
dns: tests/invalid/pointer-to-itself.bin: compression loop at offset 12
[1]
```

## The tests

`make check` runs both programs on each message of [`tests/`](tests/)
and compares what they print and how they exit. A message of
`tests/valid` must print with status 0 and one of `tests/invalid` must
end in an error with status 1, so that the two programs cannot agree by
both failing.

The responses of `tests/valid` whose names start with a record type,
and `no-answer.bin`, are real: answers of the resolver 1.1.1.1 to
queries without EDNS, captured as they came off the wire. The other
messages were built byte by byte for the case each names:

| Message | What it holds |
|---|---|
| `valid/empty-rdata.bin` | a record of an unknown type with no data |
| `valid/escaped-labels.bin` | labels with a dot, a backslash, a NUL, a space, DEL, 0xff, ESC and a newline |
| `valid/longest-name.bin` | a name of 255 bytes, the most RFC 1035 allows |
| `valid/root-name.bin` | the root name, `.` |
| `invalid/empty.bin` | nothing |
| `invalid/short-header.bin` | 7 of the 12 bytes of a header |
| `invalid/question-truncated.bin` | a question cut off in its type |
| `invalid/second-answer-truncated.bin` | a whole answer, then half of one |
| `invalid/rdlength-past-end.bin` | an A record whose RDLENGTH, 4, runs past the end of the message |
| `invalid/rdata-longer-than-a.bin` | an A record of 5 bytes |
| `invalid/cname-past-record.bin` | a CNAME whose name runs past its RDLENGTH |
| `invalid/pointer-to-itself.bin` | a compression pointer to itself |
| `invalid/pointer-label-loop.bin` | a label, then a pointer back to it, which the bound on a name's length ends |
| `invalid/pointer-past-end.bin` | a pointer to offset 16383, past the end |
| `invalid/pointer-past-record.bin` | a pointer from record data forward, past the record |
| `invalid/label-type-0x40.bin` | a label length of 64, whose top bits, 01, RFC 1035 reserves |
| `invalid/label-type-0x80.bin` | a label length whose top bits, 10, RFC 1035 reserves |
| `invalid/name-too-long.bin` | four labels of 63 bytes, a name of 257 |

Two more cases run both programs on a file that is missing and on a
directory.

## The port, step by step

### Every error is a value that `try` hands up

The original records its first error in a global and returns `-1`, and
each caller tests for the `-1` and returns it again. `read_answer` reads
six fields, so it tests six times:

```c
static int
read_answer(struct reader *r, struct answer *a)
{
	...
	if (read_name(r, &a->owner) == -1)
		return (-1);
	if (read_u16(r, &type) == -1)
		return (-1);
	if (read_u16(r, &a->class) == -1)
		return (-1);
	if (read_u32(r, &a->ttl) == -1)
		return (-1);
	if (read_u16(r, &rdlength) == -1)
		return (-1);
	start = r->off;
	if (rdlength > r->len - start)
		return (fail(start, "record data past the end"));
	...
	if (read_rdata(&record, type, &a->data) == -1)
		return (-1);
```

In the port each reader returns a `result`: `Ok` with the field, or
`Err` with what went wrong and where. `try` takes the field out of an
`Ok`, or returns the `Err` from `read_answer` at once, so the fields are
assigned where they are read and no out-parameter is left half filled:

```c
static result(struct answer, parse_error)
read_answer(struct reader *r)
{
	...
	a.owner = try read_name(r);
	type = try read_u16(r);
	a.class = try read_u16(r);
	a.ttl = try read_u32(r);
	rdlength = try read_u16(r);
	start = r->off;
	if (rdlength > r->data.len - start)
		return (Err(RecordPastEnd(start)));
	...
	a.data = try read_rdata(&record, type);
```

The original has 24 of these `if (... == -1) return (-1);` pairs; the
port has none. The global `parse_error` and the function `fail` that
sets it are gone too: the error is a variant whose every case carries
the offset where it was found,

```c
type parse_error =
    | Truncated(size_t off)
    | CompressionLoop(size_t off)
    | PointerPastEnd(size_t off)
    ...
```

and `main` hands it to `report`, the one function the port adds, which
matches it to its message. A caller that wants to act on the kind of
error, as retrying over TCP when a UDP answer is `Truncated`, matches
the same value; the original's caller has a string to compare.

### A tagged union becomes a variant

The original keeps the data of a record in a union with a tag beside
it, as C does:

```c
struct rdata {
	uint16_t	type;
	union {
		const uint8_t	*addr;		/* A: 4 bytes, AAAA: 16 */
		struct name	target;		/* CNAME */
		struct {
			uint16_t	preference;
			struct name	exchange;
		}		mx;
		...
	} u;
};
```

Nothing ties `rd->u.mx` to `rd->type == TYPE_MX`: a `case TYPE_CNAME:`
that reads `rd->u.mx.exchange` compiles and prints whatever the union
holds. The port's variant gives each case its own fields, and `match`
binds only the fields of the case it is in, and stops the build if a
case is added and not handled:

```c
type rdata =
    | A(bytes addr)				/* 4 bytes */
    | AAAA(bytes addr)				/* 16 bytes */
    | CNAME(struct name target)
    | MX(uint16_t preference, struct name exchange)
    | Other(uint16_t type, bytes data);
```

```c
	match (*rd) {
	...
	case MX(preference, exchange):
		printf("MX %u ", preference);
		print_name(&exchange);
		break;
```

### The message is a slice, and every index is checked

The original's reader is a pointer, a length and an offset; the port's
is a slice, `bytes`, which is `slice(const uint8_t)`, and an offset.
The checks that turn a short message into an error stay: `read_u16`
still asks whether two bytes are left, because a short message is an
input error to report, not a crash. What changes is what happens when
a check is missing or wrong. `r->data[r->off]` checks its index, and
`slice_sub` checks its range, so a read past the message traps where
the original reads on, into whatever lies after the message. The same
goes for the text of a name: the original guards its fixed buffer with
an `assert`, which `-DNDEBUG` removes, and the port indexes a slice of
the array instead:

```c
	assert(n->len < sizeof(n->text));
	n->text[n->len++] = c;
```

```c
	slice(char) text = slice_from_array(n->text);

	/* NAME_TEXT_SIZE holds the text of the longest name. */
	text[n->len++] = c;
```

`read_name` keeps every one of its checks in both programs, the pointer
count and the bound on a name's length included, since each is a rule
of the format that a message can break.

## One missing check

RDLENGTH is the length of a record's data as the message states it, and
`read_answer` checks it against what the message actually holds. Delete
that check from the original:

```diff
 	start = r->off;
-	if (rdlength > r->len - start)
-		return (fail(start, "record data past the end"));
 	end = start + rdlength;
```

and the program reads past the end of the message. Built with
AddressSanitizer:

<!-- untested: the report of AddressSanitizer differs from run to run -->
```console
$ clang -g -fsanitize=address -o dns-asan dns.c
$ ./dns-asan tests/invalid/rdlength-past-end.bin
==71510==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x60400000033b ...
READ of size 4 at 0x60400000033b thread T0
    #0 0x000104622266 in inet_ntop.cold.2+0xa6 (libclang_rt.asan_osx_dynamic.dylib:x86_64h+0x121266)
    #1 0x00010454a55c in inet_ntop+0x20c (libclang_rt.asan_osx_dynamic.dylib:x86_64h+0x4955c)
    #2 0x00010404662d in print_address dns.c:373
    #3 0x000104046303 in print_rdata dns.c:397
    #4 0x000104044c4e in print_answer dns.c:447
    #5 0x000104044251 in print_message dns.c:471
    #6 0x0001040439f0 in main dns.c:520

0x60400000033b is located 0 bytes after 43-byte region [0x604000000310,0x60400000033b)
```

Built without it, the program says nothing and prints an address made
of two bytes of the message and two of the heap:

<!-- untested: the original without the check prints bytes of the heap -->
```console
$ ./dns tests/invalid/rdlength-past-end.bin
header id 4660 flags 0x8180 questions 1 answers 1 authority 0 additional 0
question example.com. IN A
answer example.com. 300 IN A 93.184.0.0
$ echo $?
0
```

For a record of an unknown type, which is printed whole, the same
message prints up to 64 KiB of the heap: the shape of Heartbleed.
ASan sees the read here only because `read_file` holds the message in
memory of exactly its size. A parser that reads into a 64 KiB receive
buffer, as a resolver does, reads stale bytes of its own buffer, and
ASan says nothing.

Delete the same two lines from the port, and it traps at the
`slice_sub` that makes the record's reader, because the record would
end past the end of the message:

<!-- untested: the shell names the trap and the process in words of its own -->
```console
$ sh -c './dns tests/invalid/rdlength-past-end.bin; echo $?'
header id 4660 flags 0x8180 questions 1 answers 1 authority 0 additional 0
question example.com. IN A
sh: line 1: 32394 Illegal instruction: 4  ./dns tests/invalid/rdlength-past-end.bin
132
```

The trap is not an error message: the process ends on a signal,
`SIGILL` on x86-64 and `SIGTRAP` on arm64, and when standard output is
a pipe or a file, the lines it had buffered are lost. It is the
difference between a crash and a leak. The slice carries the length of
the message, not of the buffer it lies in, so the port traps whatever
buffer the message is read into.

## What it costs

| | `original/dns.c` | `dns.tc` |
|---|---:|---:|
| lines | 530 | 528 |
| lines of code, without comments and blank lines | 440 | 428 |
| functions | 24 | 24 |
| `if (... == -1) return (-1);` after a call | 24 | 0 |

The lines of code are those that
`gcc -fpreprocessed -dD -E -P -x c FILE` prints that are not blank. The
port is about as long as the original. It drops the 24 pairs of lines
that hand an error up, the global and `fail`, and adds `report`, whose
seven cases print the seven errors, and a declaration and a `return
(Ok(...))` in each reader that builds a structure, where the original
fills an out-parameter.

## What Type-C does not check here

- `slice_unchecked(data, len)` in `main` takes the buffer of
  `read_file` and its length on trust. It is the one place where the
  length of the message is stated, and every slice after it is cut
  from it.
- `print_address` hands `addr.data` to `inet_ntop`, which reads 4 or
  16 bytes from it. `read_rdata` took exactly that many, but the type,
  a slice of any length, does not say so.

## Limits of both programs

- Only the header, the questions and the answers are read; the
  authority and additional sections are left unread.
- A name in record data may point only to bytes before the end of its
  record. RFC 1035 has a pointer refer to a prior occurrence of a name,
  so a real message does not need more.
- A name follows at most 128 pointers, one before each label a name of
  255 bytes can have, the root included. A message that chains pointers
  to pointers past that is refused, as a loop is.
- The output can be far larger than the message: compression lets
  thousands of two-byte pointers each print the same 255-byte name, so
  a message of 60 KB can print about 10 MB. The work stays bounded by
  the size of the message.
- A label byte that is not a printable ASCII character, a dot inside a
  label and a backslash print as `\DDD`, in decimal, as in a zone file,
  so that a name from the network cannot send control characters to the
  terminal. The data of a record of any type but A, AAAA, CNAME and MX
  prints in the generic form of RFC 3597, `\# length hex`.
