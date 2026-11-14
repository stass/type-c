<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Type-C

Type-C is a programming language in the design stage. The design is
[type-c-language-design.md](type-c-language-design.md) and the order of
work is [type-c-implementation-plan.md](type-c-implementation-plan.md).

`typec` is its compiler. It takes the command line of the C compiler, so
it can replace `cc` in a build. At this stage it compiles a `.tc` input
as C through its pipeline, hands every other input and option to the
backend C compiler unchanged, and can print the target model the backend
reports (`--print-target`).

## Building and testing

Requirements: OCaml 5 and dune 3; the tests also need a C compiler as
`cc`, and `test/run/target.t`, `test/run/read.t`, `test/run/types.t`,
`test/run/pipeline.t` and `test/run/parse.t` run `/usr/bin/clang` and
`/usr/local/bin/gcc-16`, `types.t` with `-m32` too. There are no other
dependencies.

```sh
dune build    # builds typec as _build/install/default/bin/typec
dune test     # unit tests and end-to-end cram tests
```

`dune exec typec -- ARGS` runs the compiler from the build tree.

Library tests are in `test/unit`; the parser's are tables of C text and
the structural dump of its tree (`test/support/tree_dump.ml`) or its
error. `test/run` holds cram tests that run `typec` and the backends.

## Choosing the backend

The backend is the program named by the last `--cc=PATH` option, else by
the `TYPEC_CC` environment variable when it is set and not empty, else
`cc`. A name without a slash is looked up in `PATH`. `typec` consumes
`--cc=`, `--print-target` and `--emit-c` where an option can stand (the
value of `-o` is never one) and forwards every other argument, `--cc`
without `=` included, in its original order. The backend is run with an
argument vector, never through a shell, so `TYPEC_CC` names one program:
it cannot carry extra arguments such as `ccache gcc`.

Without a `.tc` input `typec` replaces itself with the backend. Exit
status: the backend's own; a backend ended by a signal ends `typec`
with the same signal. `typec` exits with 2 when `--cc=` has no path and
with 127 when the backend cannot be started, after one message on stderr.

## Compiling a `.tc` input

An input whose name ends in `.tc`, with no `-x` other than `-x none`
before it, goes through three steps:

1. `BACKEND -E -D__TYPEC__=1 -std=gnu11 OPTIONS -x c FILE.tc`, with its
   stdout in a private temporary directory;
2. `typec` reads the preprocessed text and emits it; with no Type-C
   construct yet the emitted text is the preprocessed text, byte for
   byte;
3. `BACKEND -std=gnu11 OPTIONS -c -o OUTPUT -x cpp-output EMITTED`, or
   `-S`, or `-fsyntax-only`, as the command line asks.

`-std=gnu11` is left out when the command line gives `-std=` for C11 or
C17 (`c11`, `c17`, `c18`, `gnu11`, `gnu17`, `gnu18`, `c1x`, `gnu1x`,
`iso9899:2011`, `iso9899:2017`, `iso9899:2018`); any other `-std=` is a
usage error. The options of step 1 are those that matter to
preprocessing and to code generation, those of step 3 the latter only;
`src/driver/cc_option.ml` is the one table that tells them apart and
says which options take a separate value. The output is named as cc
names it: after `-o`, else after the input in the current directory.
When the command line links, each `.tc` input becomes an object in the
temporary directory and the backend links the command line with those
objects in place of the `.tc` inputs; without linking, the other inputs
are compiled by one more backend command without the `.tc` inputs. A
`.c` input is thus compiled exactly as without `typec`.

With `-MD` or `-MMD` the dependency file comes from step 1, named as cc
names it: after `-MF`, else after `-o` with the suffix `.d`, else after
the input; its target is the `-MT` or `-MQ` value, else the real output.

`--emit-c` stops after step 2 and writes the C to the `-o` file, or to
stdout; the command line then has exactly one input, a `.tc` file.

A `.tc` input refuses the options that stop the backend at
preprocessing (`-E`, `-M`, `-MM`), that change the preprocessed text
(`-P`, `-C`, `-CC`, `-fuse-line-directives`, `-dD`, `-dM` and the like,
`-traditional-cpp`, `-fdirectives-only`), `-save-temps`, `-###`, `-ansi`,
`--` and response files (`@FILE`), with a usage error naming the option.

The temporary directory is made with mode 0700 in `TMPDIR`, or `/tmp`,
and removed on every way out. SIGHUP, SIGINT, SIGPIPE, SIGQUIT and
SIGTERM are passed on to the running backend; `typec` then removes the
directory and ends by the same signal.

Exit status: 0 when every step succeeds; else the status of the first
step that fails, or the signal that ended it; 1 when the reader refuses
the preprocessed text or a file cannot be read or written; 2 for a
usage error; 127 when the backend cannot be started.

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
