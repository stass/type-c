<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Examples

Programs that a C programmer would write anyway, written in Type-C, each
beside the C that it ports or competes with. Each says what the Type-C
version changes, what it costs in lines, and where it behaves
differently, and each runs a check that compares the two.

| Example | What it shows |
|---|---|
| [`cut`](cut/) | FreeBSD's `cut(1)`, ported with the original's functions, names and layout kept, so its diff is what Type-C changes: the option flags and the function pointer become a variant that a `match` dispatches, the errors of a list a `result` that `try` hands up, the "no open range" 0 an `option`, the column table and the lines slices, which removes an upstream buffer overrun, and a `defer` frees the line buffer. Its check runs both programs over the same command lines. |
| [`dns`](dns/) | A parser of DNS responses, beside the careful C it ports function for function: every error a `result` that `try` hands up in place of 24 tests for `-1`, the record data a variant in place of a tagged union, and the message a slice, so that a length check left out traps instead of leaking the heap. Its check runs both programs over real and malformed messages. |
| [`queue`](queue/) | A round-robin job scheduler on BSD `sys/queue.h` tail queues, beside the same program on `list(T)`, a typed list written once as generic functions: what the types catch of the classic `TAILQ` mistakes, what they do not, and what a list that owns its nodes costs against an intrusive one. Its check runs both over the same inputs. |
| [`ringbuf`](ringbuf/) | Firmware with no C library: a UART's byte rings and a line-command parser, built with `-ffreestanding` and `--trap-function=panic`. The ring is generic over a slice, a command is a variant parsed into a `result`, and words are `str`. Its check proves with `nm` that each object needs only its board, and runs both over the same bytes. |
| [`smtp`](smtp/) | The server side of a small SMTP subset, beside the C state machine it ports function for function: the state a variant whose constructors carry only the data valid in that state, in place of an `enum` and a structure of fields each valid in some states, and a line that does not parse a `result` that `try` hands up. Adding a state makes `typec` name each `match` that must handle it, where the C compilers miss the `if` that routes its lines; a field read in the wrong state cannot be written. The recipients, kilobytes that RCPT appends to, sit behind a pointer in the payload, the idiom for a large payload that arms update, and the README measures its stack against the value form. Its check runs both programs over 44 cases. |
| [`wordfreq`](wordfreq/) | A word counter on klib's `khash.h`, beside the same program on a generic `map(K, V)` written in the example: what the generic code costs in size and time on Clang and GCC, and the key type mixup that `khash`'s macros let through and the type checker stops. Its check runs both programs over the same texts. |
| [`xargs`](xargs/) | FreeBSD's `xargs(1)` with its `strnsubst`, ported function for function: `-I` and `-J` a variant matched where they are used, eleven errors a `result` that `try` hands to `main` in place of `warnx` and `xexit` at each, the argument buffer and vector slices, the `-I` list freed by a `defer` and the `-L` count an `option`. The port fixes three upstream bugs, two of which macOS's `xargs` shares. Its check runs both programs over the same command lines, error cases and limits among them. |

## Building one

Each example is a directory with a Makefile for GNU make (`gmake` on
FreeBSD) that builds with `typec` as the C compiler and the rule of the
main [README](../README.md#integrating-with-a-build-system). The C original builds with the
same `typec`, which hands a `.c` file to the C compiler untouched.

```sh
export PATH=/path/to/typec/bin:$PATH
cd cut
make                    # CC = typec, CFLAGS = -O2 -Wall -Wextra -Werror
make check              # build both programs, then compare them
make CC=/path/to/typec  # a typec that is not on PATH
TYPEC_CC=gcc-14 make clean check
```

`TYPEC_CC` names the C compiler that `typec` runs, `cc` when it is unset
([Choosing the backend](../README.md#choosing-the-backend)).

The test [`test/run/examples.t`](../test/run/examples.t) builds every
example with Clang and with GCC, at `-O0` and at `-O2`, with
`-Wall -Wextra -Werror`, and runs its `make check`.

## Adding one

An example is a directory here with a `README.md`, its Type-C source,
the C that it compares with, a `.gitignore` of what its Makefile
builds, and a Makefile with the targets `all`, `check` and `clean`,
where `check` builds what it needs and exits 0 when
the two programs agree. `examples.t` finds every directory and prints
what each `check` prints, so a new example shows up there as a new line
of expected output. C code taken from elsewhere keeps its license and
notice, and its README names where it comes from and at which revision.
