<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Type-C

Type-C is a programming language in the design stage. The design is
[type-c-language-design.md](type-c-language-design.md) and the order of
work is [type-c-implementation-plan.md](type-c-implementation-plan.md).

`typec` is its compiler. It takes the command line of the C compiler, so
it can replace `cc` in a build. At this stage it hands every argument to
the backend C compiler unchanged and exits with the backend's status, or
prints the target model the backend reports (`--print-target`).

## Building and testing

Requirements: OCaml 5 and dune 3; the tests also need a C compiler as
`cc`, and `test/run/target.t` and `test/run/read.t` run `/usr/bin/clang`
and `/usr/local/bin/gcc-16`. There are no other dependencies.

```sh
dune build    # builds typec as _build/install/default/bin/typec
dune test     # unit tests and end-to-end cram tests
```

`dune exec typec -- ARGS` runs the compiler from the build tree.

## Choosing the backend

The backend is the program named by the last `--cc=PATH` option, else by
the `TYPEC_CC` environment variable when it is set and not empty, else
`cc`. A name without a slash is looked up in `PATH`. `typec` consumes
`--cc=` and `--print-target` and forwards every other argument, `--cc`
without `=` included, in its original order. The backend is run with an
argument vector, never through a shell, so `TYPEC_CC` names one program:
it cannot carry extra arguments such as `ccache gcc`.

Exit status: the backend's own; a backend ended by a signal ends `typec`
with the same signal. `typec` exits with 2 when `--cc=` has no path and
with 127 when the backend cannot be started, after one message on stderr.

## Printing the target model

`typec --print-target [OPTIONS]` runs the backend as
`BACKEND OPTIONS -dM -E -x c /dev/null` and prints the target model that
its predefined macros give: the sizes of the scalar types, the
signedness of `char`, the types behind `size_t` and the other standard
typedefs, the byte order and `__STDC_VERSION__`, one `field: value` per
line. The other arguments are the backend options that select the
target or the dialect, such as `-m32`, `-funsigned-char` or `-std=gnu11`;
inputs, `-o` and dependency options do not belong there.

Exit status: 0 with the model on stdout; 1 when the backend fails or
prints macros the model cannot be read from; 2 and 127 as above.
