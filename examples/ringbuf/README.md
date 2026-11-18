<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

<!--
test/run/example_readmes.t checks the console blocks of this file on
Clang and GCC, but those marked untested: test/run/readme.sh says how
the blocks are marked.
-->

# ringbuf: firmware with no C library

A small device answers commands on its serial port. The UART interrupt
puts each byte it receives into a ring buffer; the main loop takes the
bytes out, assembles lines, and queues a reply to each in a second ring
for the UART to send:

<!-- untested: it is a session on the serial port of the device -->
```console
set led 1
ok
get temp
temp 21
echo hello
hello
stats
dropped rx 0 tx 0
frobnicate
error: unknown command
```

[`original/firmware.c`](original/firmware.c) and its ring,
[`original/ring.h`](original/ring.h), are that firmware as a C
programmer would write it; they were written for this example.
[`firmware.tc`](firmware.tc) and [`ring.tci`](ring.tci) are the port to
Type-C. The port keeps the original's functions, names, order, comments
and control flow, so that `diff -u original/firmware.c firmware.tc`
shows only what Type-C changes. [`firmware.h`](firmware.h) is the
interface that both implement, and [`driver.c`](driver.c) is a board on
a hosted system that feeds them bytes and prints their replies.

```sh
make            # gmake on FreeBSD
make check
TYPEC_CC=gcc-14 make clean check
```

## Freestanding

Freestanding C is C without its library: no `printf`, no `malloc`, no
`strlen`, no start-up code that calls `main`. Only the headers that
define types and macros remain, such as `<stddef.h>` and `<stdbool.h>`.
Firmware lives there: whatever it needs, it writes itself or gets from
its board. This one formats its numbers with its own `put_decimal` and
compares its words with its own `equal`.

The [Makefile](Makefile) builds each core as such an object:

```sh
typec -O2 -Wall -Wextra -Werror -ffreestanding -nostdlib -fno-builtin \
    -fno-stack-protector --trap-function=panic -c firmware.tc
typec -O2 -Wall -Wextra -Werror -ffreestanding -nostdlib -fno-builtin \
    -fno-stack-protector -c original/firmware.c
```

`-ffreestanding` tells the compiler that there is no C library, so that
it does not, for example, turn a loop into a call to `strlen`;
`-fno-builtin` says the same of each function by name, as
`-ffreestanding` already does. `-nostdlib` matters only to the
firmware's own link, which leaves the C library out; here the objects
are compiled, then linked into hosted drivers, and it is kept so that
the line is the one firmware uses. `-fno-stack-protector` turns off the
stack protector that some hosts enable by default: it calls
`__stack_chk_fail`, which a real firmware would supply itself.
`--trap-function=panic` is the one flag that Type-C adds, and the next
section is about it.

### The `nm` proof

An object built this way needs from its environment exactly the names
it leaves undefined, which `nm -u` lists. On the macOS host, which
prefixes each C name with `_`:

<!-- untested: the names are those of the macOS host -->
```console
$ nm -u firmware.o original/firmware.o

firmware.o:
_board_led
_board_temp
_panic

original/firmware.o:
_board_led
_board_temp
```

The port needs what the original needs, the two functions of the board,
and `panic`, which its traps call. Nothing of a C library, and nothing
of a Type-C runtime: there is none. `make check` takes the same list of
each object, on whichever backend `typec` runs, and fails when a name
is there that the board does not supply.

The board supplies four more names that the list allows:
`memcpy`, `memmove`, `memset` and `memcmp`. GCC and Clang require them
of every freestanding environment and may call them for C that names
none of them, such as a structure copy. Here only Clang at `-O0` calls
one, in both objects: it clears with `memset` the padding of each
`option` and `result` that the port makes, and the `struct command`
that the original initialises. At `-Os` and `-O2`, and with GCC at
every level, neither object calls any of the four.

The list holds on this host, whose processor divides. `put_decimal`
divides by 10, and on a core without a divider, such as a Cortex-M0,
the compiler calls a helper of its run-time library for that, such as
`__aeabi_uidivmod`, in both versions; such a firmware links that
library too.

### The trap path

Every index of a slice is checked, and so is every `slice_sub`. A check
that fails is a trap. By default a trap executes `__builtin_trap()`, an
instruction that stops the processor; with `--trap-function=panic`, it
first calls `_Noreturn void panic(void)`, which the board supplies and
which, on a device, would log the fault and reset. The emitted C of
`ring_get`'s `r->buf[r->head]`, from `typec --emit-c`, broken into
lines:

```c
value = (*((void)(__tc_s0 = ( r -> buf )),
    (void)(__tc_i0 = (__typeof__(__tc_i0))( r -> head )),
    (void)(__tc_i0 < __tc_s0.len ? (void)0 : __tc_trap()),
    &__tc_s0.data[__tc_i0])) ;
```

and `__tc_trap` is

```c
static inline _Noreturn void __tc_trap(void) { _Noreturn void panic(void); panic(); __builtin_trap(); }
```

The checks that the compiler cannot prove away stay in the object,
such as those of the rings' indices, which live in memory between
calls. Clang gathers their failures into one call of `panic`; GCC keeps
five or six.

None of them fails on any input: the indices stay in range by
construction. They fail when something else breaks the construction,
such as a stray write over a ring's `head` or `count`.
[`stray.tc`](stray.tc) makes one: it moves a ring's head past its
storage, as an overrun of a neighbouring buffer would, and takes a
byte. `make check` runs it:

```console
$ ./stray
stray: panic
[3]
```

The C ring, given the same head, reads past its storage and returns
whatever is there. A check compares an index with the slice's own
length, so a stray write over the slice itself, its pointer or its
length, goes unseen by both versions.

## The port, step by step

### A command is a variant

The original's parser fills a `struct command` whose fields each mean
something for one kind of command only:

```c
struct command {
	enum command_kind kind;
	int		on;		/* CMD_SET_LED */
	const char	*text;		/* CMD_ECHO */
};
```

GCC at `-O2` sees `execute` read `cmd->on` and `cmd->text` where the
parser may not have set them, and warns; to build with `-Werror`, the
original's `end_line` clears the whole structure first:

```c
	struct command cmd = { CMD_EMPTY, 0, NULL };
```

In the port, the fields belong to their cases, so there is nothing to
clear, and `match` reads `on` only from a `SetLed`:

```c
type command =
    | Empty				/* a blank line */
    | SetLed(int on)
    | GetLed
    | GetTemp
    | Echo(str text)
    | Stats;
```

### The parser returns a result

The original returns an error code, with `PARSE_OK` among the errors,
and writes the command through a pointer. The port returns
`result(command, parse_error)`: an `Ok` holds the command, an `Err`
the error, and `end_line` takes both apart in one `match`:

```c
		match (parse(slice_sub(slice_from_array(line), 0, line_len))) {
		case Ok(command cmd):
			execute(cmd);
			break;
		case Err(UnknownCommand):
			put_string("error: unknown command\n");
			break;
		case Err(BadArgument):
			put_string("error: bad argument\n");
			break;
		}
```

### Words are `str`, cut without writing

The original ends the line with a NUL and cuts it into words in place,
as `strsep` does, writing a NUL over the space after each word. The
port's `next_word` returns a `str` of the line, a pointer and a length,
and writes nothing; the line needs no room for a NUL, and `echo` gets
the rest of the line as a `str` too. `equal` compares lengths before
bytes. Each `slice_sub` that cuts a word is checked.

### The ring is generic, over a slice

The original's ring is a pointer and a size; the port's is a `slice(T)`,
whose `len` is the size, so the `size` field is gone and every index of
the storage is checked. `ring_get` returns an `option(T)`, `None` when
the ring is empty, where the original returns `-1`, which works only
because a byte is never `-1`. Without the sentinel nothing in the ring
depends on what it holds, so the port makes it generic, where C would
need a macro or a `void *`. Both rings of the firmware hold bytes, so
the instance for `unsigned char` is the only one that is built.

### Where the port adds code

- `fw_tx` turns the `option` back into `-1`, because `firmware.h` is a C
  interface that the C driver calls.
- `put_string` and `equal` loop over a length instead of up to a NUL.
- `add_char` and `end_line` index `slice_from_array(line)` where the
  original indexes `line`: an array of C is not checked, its slice is.

## Size

The bytes of machine code of each core: on the x86-64 macOS host with
Apple Clang 21 and GCC 16, the `__text` section that `size -m` gives;
for a Cortex-M3 (`-mcpu=cortex-m3`), with Arm GNU GCC 14.2 and with
Apple Clang 21 `--target=thumbv7m-none-eabi`, the sum of the sizes of
the functions, which `nm -S` gives. The Arm GCC builds both cores with
`-fno-short-enums`, so that the enumerations of the original are
`int`-sized, as the tags of a variant always are, and not the short ones
that `arm-none-eabi` has by default. Under the default the original's
enumerations take one byte and the tags of the port stay four, which the
Arm GCC rows leave out.

| | `original/firmware.o` | `firmware.o` | growth |
|---|---:|---:|---:|
| Clang `-Os` | 1953 | 1950 | 0% |
| Clang `-O2` | 5057 | 5386 | 7% |
| GCC `-Os` | 1214 | 1618 | 33% |
| GCC `-O2` | 2790 | 3140 | 13% |
| Cortex-M3, GCC `-Os` | 792 | 1288 | 63% |
| Cortex-M3, Clang `-Os` | 1674 | 1440 | -14% |

The constant strings are the same or smaller in the port, and its
zeroed data is up to 32 bytes smaller: the line has no byte for a NUL.
GCC also writes unwind tables, `__eh_frame`, at `-Os` of 368 bytes for
the original and 600 for the port; firmware turns them off with
`-fno-asynchronous-unwind-tables`.

### Where the bytes go

Each share below is the bytes that one change to a scratch copy of
the port removes, the changes made one after the other, so the shares
add up to the growth:

1. **Checks**: in `firmware.tc` and `ring.tci`, every checked index
   `s[i]` read as `s.data[i]`, and every `slice_sub` written as a
   `slice_unchecked`.
2. **`result`**: in `firmware.tc`, the parser rewritten to return an
   `int` and to write the command through a pointer, as the
   original's does.
3. **Tag traps**: in the C that `typec` writes, the trap of a `match`
   on an invalid tag, `default: __tc_trap();`, taken out.
4. **The rest**: what remains against the original. It is not a
   measured cause: it holds the differences in inlining too, and is
   negative where those make the port smaller.

Built as the `Makefile` builds them, with the compiler's own inlining
(M3 is the Cortex-M3 at `-Os`):

| | Clang `-Os` | Clang `-O2` | GCC `-Os` | GCC `-O2` | M3 GCC | M3 Clang |
|---|---:|---:|---:|---:|---:|---:|
| growth | -3 | 329 | 404 | 350 | 496 | -234 |
| checks | 62 | 409 | 47 | 950 | 104 | 48 |
| `result` | 32 | 0 | 10 | 192 | 28 | 64 |
| tag traps | 18 | -23 | 13 | -32 | 0 | -36 |
| the rest | -115 | -57 | 334 | -760 | 364 | -310 |

Built with `-fno-inline`, so that each function is set against its
counterpart:

| | Clang `-Os` | Clang `-O2` | GCC `-Os` | GCC `-O2` | M3 GCC | M3 Clang |
|---|---:|---:|---:|---:|---:|---:|
| growth | 489 | 480 | 448 | 653 | 608 | 292 |
| checks | 48 | 48 | 68 | 0 | 44 | 16 |
| `result` | 58 | 80 | 76 | 144 | 108 | 58 |
| tag traps | 24 | 32 | 26 | 47 | 20 | 4 |
| the rest | 359 | 320 | 278 | 462 | 436 | 214 |

GCC at `-O2` starts each function at 16 bytes, so its column counts
padding, which can hide a small share whole: the 0 of its checks is
two builds of the same size, 2489 bytes.

- **Inlining decides the totals.** Function for function the port is
  26% to 64% larger at `-Os`. At `-Os` Clang inlines nearly all of it
  into `fw_poll` and the port comes out the same size or smaller; so the 0%
  of Clang `-Os` and the -14% of the Cortex-M3 are the inliner's, not a
  program as small as the original. GCC keeps the port's `ring_put` and
  `ring_get` out of line at `-Os`, where it inlines the original's, but
  that saves bytes: forced inline, the port grows to 1694 bytes; forced
  out of line, the original shrinks to 1154.
- **The checks** are a compare, a branch and a call of `panic` each,
  8 bytes in `ring_get` on the Cortex-M3: 3% to 8% of the port at
  `-Os`. At `-O2` they change what is inlined. Without them GCC
  keeps `put_string` out of line and `fw_poll` falls from 2352 bytes
  to 1264, so the port ends 600 bytes smaller than the original.
- **The `result`** is a structure of a tag and a union holding the
  command, which holds a `str`: 32 bytes on x86-64 and 16 on the
  Cortex-M3, returned through a hidden pointer and copied for the
  `match` in `end_line`. The original returns an `enum` in a register.
- **Tag traps** cost bytes only where the variant comes from a call
  that is not inlined; inlined, the compiler sees the tag and drops
  the trap, and the code can come out larger without it.
- **The rest** is mostly the parser. With `-fno-inline`, `parse`,
  `parse_get`, `parse_set`, `next_word` and `equal` are 136 to 261
  bytes of it at `-Os`. A word is a `str` of two machine words, so
  `equal` takes four arguments where the original takes two, and
  `next_word` returns a `str`, which the Cortex-M3 calling convention
  returns through memory, as it does any structure over 4 bytes. A
  command holds a `str`, and `execute` takes the command by value.
  An `option(unsigned char)` is 8 bytes, as its tag is an `int`. On
  x86-64 it comes back in a register; on the Cortex-M3 `ring_get`
  returns it through memory, and `fw_tx` turns it
  back into `-1`: with `-fno-inline`, 44 bytes on the Cortex-M3 where
  the original's `fw_tx` is a jump to `ring_get`, 8 bytes.

What `typec` writes around these adds nothing measurable. A checked
index copies the slice into a temporary, which every compiler removes;
the check left is the compare and the branch. A constructor is a
compound literal, which zeroes the bytes of the union that the variant
does not use; setting only the tag and the variant's member instead
makes GCC `-Os` 73 bytes larger when done in the 11 `return`
statements, and 213 when done in every constructor. The size of the
tags does matter:
with every tag of the lowered C an `unsigned char`, the port shrinks
by 39 bytes under GCC `-Os`, 64 under GCC `-O2` and 112 on the
Cortex-M3 with GCC, and by 0 to 4 under Clang (`TODO.md`).

The scratch copies, the scripts and the sizes of every function are in
`/Volumes/Optaine/ringbuf-growth` (its `README`), a repository of its
own, at commit `bfa192d`.

## Where the port differs

- **A NUL byte in a line.** The original reads its line as a C string,
  so a NUL ends it: `set led 1`, a NUL and `x` sets the LED. The port's
  line is a `str`, so the NUL is a character of the word `1\0x`, which
  is a bad argument; `echo` replies the NUL and what follows it. `make
  check` checks the port alone there.

Everything else is the same, and `make check` compares it: the commands
and their errors, lines at and past the 32 bytes of the longest,
replies that overflow the 32 bytes of the transmit ring, and a session
polled after every 1 to 1000 bytes, so that the rings wrap around at
different points and, past 16 bytes, the receive ring overflows and
loses bytes.

## What the example leaves out

A real UART interrupt runs while the main loop is inside `ring_get`.
Both sides then write `count`, and `ring_get` moves `head` before it
lowers `count`, so an interrupt between the two loses or garbles a
byte; `volatile` or an atomic `count` does not cure that. The main loop
has to mask the interrupt around each call of `ring_get`, or the ring
has to keep a head and a tail that each have one writer, with the
barriers that the processor needs. The same holds for the transmit ring
when `fw_tx` runs from the UART's transmit interrupt. Neither version
does either: `driver.c` calls everything from one thread. The race
cannot take an index out of range, in either version; and Type-C
changes nothing about it, as it keeps C's memory model.
