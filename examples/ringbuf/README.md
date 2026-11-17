<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# ringbuf: firmware with no C library

A small device answers commands on its serial port. The UART interrupt
puts each byte it receives into a ring buffer; the main loop takes the
bytes out, assembles lines, and queues a reply to each in a second ring
for the UART to send:

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
$ echo $?
3
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

The bytes of machine code, the `__text` section, of each core on the
x86-64 macOS host, with Apple Clang 21 and GCC 16, measured with
`size -m`:

| | `original/firmware.o` | `firmware.o` | growth |
|---|---:|---:|---:|
| Clang `-Os` | 1953 | 1950 | 0% |
| Clang `-O2` | 5057 | 5386 | 7% |
| GCC `-Os` | 1214 | 1618 | 33% |
| GCC `-O2` | 2790 | 3140 | 13% |

The constant strings are the same or smaller in the port, and its
zeroed data is 8 to 32 bytes smaller: the line has no byte for a NUL.
GCC also writes unwind tables, `__eh_frame`, at `-Os` of 368 bytes for
the original and 600 for the port; firmware turns them off with
`-fno-asynchronous-unwind-tables`.

The growth is the checks and their calls of `panic`, and the parser:
`next_word` keeps a length with each word, and `parse` returns a
`result` by value. Both compilers inline the parser into `fw_poll`,
which GCC at `-Os` makes 1075 bytes in the port and 766 in the
original. GCC at `-Os` also keeps the port's `ring_put` and `ring_get`
as functions of their own, `static inline` as they are in both
versions, where it inlines the original's.

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
