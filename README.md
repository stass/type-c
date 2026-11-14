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
`test/run/declarations.t`, `test/run/pipeline.t`, `test/run/parse.t`
and `test/run/headers.t` run `/usr/bin/clang` and
`/usr/local/bin/gcc-16`, `types.t` and `declarations.t` with `-m32` too,
and `tools/corpus/runner.t` runs `/usr/bin/clang`. `headers.t` parses
every C11 and POSIX header that each backend's system headers hold.
There are no other dependencies.

```sh
dune build    # builds typec as _build/install/default/bin/typec
dune test     # unit tests and end-to-end cram tests
```

`dune exec typec -- ARGS` runs the compiler from the build tree.

Library tests are in `test/unit`; the parser's are tables of C text and
the structural dump of its tree (`test/support/tree_dump.ml`) or its
error. `test/run` holds cram tests that run `typec` and the backends;
`types.t` and `declarations.t` compile static assertions of what typec
computes, so a backend that disagrees fails to compile them.

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
2. `typec` reads the preprocessed text, parses it and reads its
   declarations at file scope, then emits it. The declarations are read
   for the target model that the backend gives with the options of step
   3 (see "Printing the target model"). A text that the front end
   refuses stops `typec` with one message, `FILE:LINE: MESSAGE`. With no
   Type-C construct yet the emitted text is the preprocessed text, byte
   for byte;
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
step that fails, or the signal that ended it; 1 when the front end
refuses the preprocessed text, the backend gives no target model or a
file cannot be read or written; 2 for a
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

## Fuzzing

`tools/fuzz/` holds the fuzz harness: `fuzz.exe TARGET [FILE]` runs one
input, from FILE or standard input, through a target, and fails on any
exception, broken property or memory beyond a bound linear in the input.
The `reader` target checks that every text is read or refused with a
printable message, and that an accepted text is spelled by its tokens
and gaps, has only layout in the gaps and is emitted unchanged. The
`parser` target parses every text the reader accepts and reads the
file-scope declarations of every unit that parses, for an LP64 target;
each stage must accept or refuse with a printable message, every node's
span must hold its parts in token order, and parsing again must give
the same tree. The parser runs on a fiber whose stack is limited to 32K
words (`test/support/small_stack.ml`), which holds its deepest nesting
(`Parser.max_nesting`), so that recursion growing with the input
overflows it and is reported. The normal build compiles
the harness, and `dune test` runs it on the seeds in
`tools/fuzz/seeds/`.

AFL++ drives it, with coverage from an OCaml compiler configured for AFL
instrumentation. That compiler lives in its own opam root, so the normal
build keeps the system OCaml. AFL++ on macOS hands its coverage map over
only as a POSIX shared memory descriptor, which the OCaml runtime does
not read, so the compiler needs a patch to `runtime/afl.c` there. The
patch is kept outside this repository, at
`/Volumes/Optaine/typec-fuzz/patches/ocaml-5.5.2-afl-posix-shm.patch`.
Setting up, once:

```sh
brew install afl++
export OPAMROOT=/Volumes/Optaine/opam
opam init --bare --disable-sandboxing -n -y
opam switch create afl -y \
  --packages=ocaml-variants.5.5.2+options,ocaml-option-afl
opam install --switch afl -y dune
src=/Volumes/Optaine/typec-fuzz/ocaml-afl-src/ocaml-5.5.2
opam source --switch afl ocaml-compiler.5.5.2 --dir "$src"
patch -d "$src" -p1 \
  < /Volumes/Optaine/typec-fuzz/patches/ocaml-5.5.2-afl-posix-shm.patch
opam pin add --switch afl -y --kind=path ocaml-compiler.5.5.2 "$src"
```

A campaign keeps its build, seeds and findings in `TYPEC_FUZZ_DIR`
(default `/Volumes/Optaine/typec-fuzz`), never in this repository:

```sh
tools/fuzz/fuzz.sh build             # the instrumented harness
tools/fuzz/fuzz.sh seeds             # more seeds: cc -E of C headers
CC=gcc-16 tools/fuzz/fuzz.sh seeds   # and those of another compiler
tools/fuzz/fuzz.sh run reader 30     # 30 minutes; resumes a run
tools/fuzz/fuzz.sh triage reader     # minimise crashes and hangs
```

The generated seeds, in `seeds/headers` there, go to every target. So
does the AFL++ dictionary, `fuzz.dict`, which the build generates from
the keyword and punctuator tables of the parser and the reader and the
pieces of `cc -E` output listed in `dictionary.ml`.

The limits of one execution, whose values are in `fuzz.ml` and
`fuzz.sh`:

* Input: at most `max_input_bytes`, 16 KiB; a longer one is skipped.
  The slowest input of that size measured, an array size of 8K
  additions in the `parser` target, takes about 65 ms in the
  instrumented harness; all `;` takes about 20 ms in the `reader`.
* Time: `timeout_ms`, 300 ms (`-t`). AFL++ runs an input that exceeds
  it again with twice that (`AFL_HANG_TMOUT`) and saves it as a hang
  only if it exceeds that too, so that a busy host does not make one.
  The limit is about five times the worst linear run, while a step
  quadratic in the 16K bytes or tokens of that input would cost
  thousands of times more. A step quadratic in something sparser, such
  as line markers, can stay inside it.
* Memory: the harness fails when the major heap peaks above
  `heap_words_fixed` plus `heap_words_per_input_byte` per input byte,
  about twice what the densest input needs. AFL++'s own limit (`-m`) is
  off: it sets `RLIMIT_AS`, which macOS refuses to set, and on Linux
  that limit counts the address space OCaml 5 reserves, not what a
  stage uses.

The harness reports a crash with the exit code in `AFL_CRASH_EXITCODE`,
which `fuzz.sh` sets, because the crash reporter of macOS can hold a
signalled process for seconds and AFL++ would record a hang.

A target is a module with `check : string -> unit` that returns for
every input its stage accepts or refuses and raises otherwise. Adding
one is that module, its libraries in `tools/fuzz/dune`, an entry in the
`targets` table of `fuzz.ml` and seeds in `tools/fuzz/seeds/TARGET/`,
which `dune test` runs through it.

## Running the corpus

`tools/corpus/` holds the corpus runner, which checks the exit gate of
plan package 0.11 on real programs. The corpus itself, its recipes and
the records of its runs live in a separate repository, at
`/Volumes/Optaine/type-c-corpus`, and its sources in a cache outside
both, by default `/Volumes/Optaine/type-c-corpus-cache`; that
repository's README says how they are pinned and fetched.

```sh
corpus=/Volumes/Optaine/type-c-corpus
cache=/Volumes/Optaine/type-c-corpus-cache
"$corpus/fetch.sh"
dune build
_build/default/tools/corpus/corpus.exe --corpus "$corpus" --cache "$cache" \
  --typec _build/install/default/bin/typec \
  --cc /usr/bin/clang --cc /usr/local/bin/gcc-16 \
  c-testsuite zlib lua sqlite chibicc qbe
```

For each program and backend the runner makes a fresh build tree in
`CACHE/build/HOST/PROGRAM/BACKEND/` from the archives of the program's
recipe (`programs/PROGRAM/recipe`, in the format of
`tools/corpus/recipe.mli`) and compiles each unit `U.c` of it, with
`-O2`, no debug option and the recipe's options:

1. `typec --cc=BACKEND -c U.tc -o U.o`, where `U.tc` is a copy of `U.c`
   next to it, so that its includes resolve as before;
2. the reference, as `test/run/pipeline.t` builds it:
   `BACKEND -E -x c -D__TYPEC__=1 -std=gnu11 ... U.tc > U.ref.i`, then
   `BACKEND -x cpp-output -std=gnu11 ... -c U.ref.i -o U.ref.o`;
3. `U.o` and `U.ref.o` must be equal byte for byte.

It then links each program of the recipe from the `typec` objects and
runs the recipe's test script in the build tree, with `CC` naming the
backend. It writes a record of each program and backend to
`CORPUS/runs/HOST/PROGRAM.BACKEND.txt` and prints it: the revisions
of the corpus and of the checkout `typec` was built in and the digest
of the `typec` binary, the counts of
identical, different and failed units, which failed and at which step,
whether the programs linked and the tests passed, and the CPU time of
preprocessing, of `typec --emit-c` and of the backend's `-fsyntax-only`
on `U.ref.i`, summed over the units, whose first two differ by the time
of `typec`'s front end. The stderr of every command goes to
`CACHE/build/HOST/PROGRAM/BACKEND.log`.

Exit status: 0 when every unit gave identical objects and every
program's tests passed; 1 otherwise; 2 when the command line or a
recipe is wrong, an archive has not been fetched, or the runner cannot
write a file of its own. `dune test` runs
`tools/corpus/runner.t`, which checks the runner on a fixture program.
