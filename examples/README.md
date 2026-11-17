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
| [`cut`](cut/) | FreeBSD's `cut(1)`, ported with the original's functions, names and layout kept, so its diff is what Type-C changes: the column table and the lines become slices, which removes an upstream buffer overrun, and a `defer` frees the line buffer. Its check runs both programs over the same command lines. |
| [`dns`](dns/) | A parser of DNS responses, beside the careful C it ports function for function: every error a `result` that `try` hands up in place of 24 tests for `-1`, the record data a variant in place of a tagged union, and the message a slice, so that a length check left out traps instead of leaking the heap. Its check runs both programs over real and malformed messages. |
| [`queue`](queue/) | A round-robin job scheduler on BSD `sys/queue.h` tail queues, beside the same program on `list(T)`, a typed list written once as generic functions: what the types catch of the classic `TAILQ` mistakes, what they do not, and what a list that owns its nodes costs against an intrusive one. Its check runs both over the same inputs. |

## Building one

Each example is a directory with a Makefile for GNU make (`gmake` on
FreeBSD) that builds with `typec` as the C compiler and the rule of the
main [README](../README.md#in-a-build). The C original builds with the
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
the C that it compares with, and a Makefile with the targets `all`,
`check` and `clean`, where `check` builds what it needs and exits 0 when
the two programs agree. `examples.t` finds every directory and prints
what each `check` prints, so a new example shows up there as a new line
of expected output. C code taken from elsewhere keeps its license and
notice, and its README names where it comes from and at which revision.
