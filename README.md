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
through its pipeline, which reads it as C with the type declarations of
design 3.1 (aliases and forward declarations) and lowers those to C,
hands every other input and option to the backend C compiler unchanged,
and can print the target model the backend reports (`--print-target`).

## Building and testing

Requirements: OCaml 5.4 and dune 3; the tests also need a C compiler as
`cc`, a Clang and a GCC of releases that `typec` supports (see
[Choosing the backend](#choosing-the-backend)), and `tools/corpus/runner.t` runs
`/usr/bin/clang`. The cram tests in `test/run` run the Clang that
`TYPEC_TEST_CLANG` names and the GCC that `TYPEC_TEST_GCC` names; unset,
they are `/usr/bin/clang` and `/usr/local/bin/gcc-16`, those of the
macOS development host (`test/run/backends.sh`). `headers.t` parses
and reads the declarations of every C11 and POSIX header that each
backend's system headers hold.
`target.t` expects the model of x86-64, and `types.t` and
`declarations.t` also compile with `-m32`, so dune runs these three on
x86-64 hosts only. There are no other dependencies.

```sh
dune build    # builds typec as _build/install/default/bin/typec
dune test     # unit tests and end-to-end cram tests
TYPEC_TEST_GCC=/usr/bin/gcc dune test   # with another GCC
```

`dune exec typec -- ARGS` runs the compiler from the build tree.

Library tests are in `test/unit`; the parser's are tables of C text and
the structural dump of its tree (`test/support/tree_dump.ml`) or its
error. `test/golden` holds cram tests that show the C or the diagnostic
that the front end gives for a source, with no backend
(`test/golden/golden.ml`); `dune test test/golden` runs them and
`dune promote` takes a changed output. `test/run` holds cram tests that
run `typec` and the backends;
`types.t` and `declarations.t` compile static assertions of what typec
computes, so a backend that disagrees fails to compile them.

### Linux test hosts

`tools/hosts` describes each Linux host that the suite runs on as a
Dockerfile, with the base image pinned by digest and the compilers, the
C library and OCaml by version: `debian` (Debian 13, glibc) and `alpine` (Alpine 3.24,
musl), both x86-64 with the distribution's GCC and Clang, and OCaml 5.4
and dune from Alpine's packages and from opam on Debian.
`tools/hosts/run.sh HOST [LOG]` builds the image `typec-host-HOST` and
runs `dune build` and `dune test` in a container of it, with the source
mounted read-only, the build inside the container and no network. It
needs a running Docker that can mount the source tree (colima, for
instance, shares the home directory but not `/Volumes`), prints
whether the suite passed, and writes the whole output to `LOG`, by
default `${TMPDIR:-/tmp}/typec-host-HOST.log`.

```sh
tools/hosts/run.sh debian
tools/hosts/run.sh alpine /Volumes/Optaine/alpine.log
```

### FreeBSD test host

The FreeBSD x86-64 host is a machine reached over ssh, not a container:
`tools/hosts/freebsd.sh`, or `tools/hosts/run.sh freebsd`, which runs
it. The header of the script says which environment variables name the
account (`TYPEC_FREEBSD_TARGET`, `TYPEC_FREEBSD_KEY`,
`TYPEC_FREEBSD_DIR`) and the corpus programs to run
(`TYPEC_FREEBSD_CORPUS`), which compilers and tools the host must
supply, and which OCaml and dune it builds. Everything goes to
`~/typec-host` of the account and nothing runs as root; the corpus
programs are third-party code run with the account's own rights, so use
an account that holds nothing else. ssh asks no question, so the key
must be loaded or named and the host key must be known.

```sh
export TYPEC_FREEBSD_TARGET=user@freebsd-host
TYPEC_FREEBSD_CORPUS="c-testsuite zlib lua sqlite chibicc qbe" \
  tools/hosts/run.sh freebsd /Volumes/Optaine/freebsd.log
```

The run prints whether the suite passed, and the log holds the whole
output, including the record of each corpus run (the runner's status 3,
substitute tests only, counts as a pass). The toolchain, the build tree
and the corpus cache stay between runs. To remove them all:
`ssh USER@HOST "sh -c 'chmod -R u+w typec-host; rm -rf typec-host'"`.

## Choosing the backend

The backend is the program named by the last `--cc=PATH` option, else by
the `TYPEC_CC` environment variable when it is set and not empty, else
`cc`. A name without a slash is looked up in `PATH`. `typec` consumes
`--cc=`, `--print-target` and `--emit-c` where an option can stand (the
value of `-o` is never one) and forwards every other argument, `--cc`
without `=` included, in its original order. The backend is run with an
argument vector, never through a shell, so `TYPEC_CC` names one program:
it cannot carry extra arguments such as `ccache gcc`.

The backend is GCC or Clang, Apple's included, no older than the
releases that `minimum_major_version` in
[src/sema/target.ml](src/sema/target.ml) names. `typec` refuses an
older one with a message naming the oldest supported releases.

Without a `.tc` input `typec` replaces itself with the backend. Exit
status: the backend's own; a backend ended by a signal ends `typec`
with the same signal. `typec` exits with 81 when `--cc=` has no path or
the backend cannot be started, after one message on stderr.

`typec`'s own failures have statuses of their own, which
[src/driver/exit_status.ml](src/driver/exit_status.ml) defines and
design 13.2 explains: 80 when it refuses the program (a diagnostic about
the source), 81 for an error of its environment (the command line, the
backend, a file it cannot read or write) and 82 for an internal error, a
bug in `typec`. Every other status is the backend's.

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
usage error. Step 2 reads `asm` and `typeof` as keywords in the GNU forms
and as identifiers in the ISO forms, as GCC and Clang do; `-fasm` and
`-fno-asm` select the GNU and the ISO keywords whatever `-std=` says.
The options of step 1 are those that matter to
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
backend step that fails, or the signal that ended it; 80 when the reader
or the front end refuses the preprocessed text; 81 for a usage error,
when the backend cannot be started or gives no target model, or when a
file cannot be read or written; 82 for an internal error.

## Printing the target model

`typec --print-target [OPTIONS]` runs the backend as
`BACKEND OPTIONS -dM -E -x c /dev/null` and prints the target model that
its predefined macros give: the backend and its major version, the
sizes of the scalar types, the
signedness of `char`, the types behind `size_t` and the other standard
typedefs, the byte order and `__STDC_VERSION__`, one `field: value` per
line. The other arguments are the backend options that select the
target or the dialect, such as `-m32`, `-funsigned-char` or `-std=gnu11`;
inputs, `-o` and dependency options do not belong there.

Exit status: 0 with the model on stdout; 81 when the backend fails,
cannot be started, is not supported or prints macros the model cannot
be read from, or for a usage error; 82 for an internal error.

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
not read, so the compiler needs a patch to `runtime/afl.c` there:
`tools/fuzz/patches/ocaml-5.5.2-afl-posix-shm.patch`, under the license
of the OCaml file it modifies (its header says so). Setting up, once,
from the root of this repository:

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
  < tools/fuzz/patches/ocaml-5.5.2-afl-posix-shm.patch
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

Each unit ends in one of five states: identical, different, refused by
`typec`, an internal error of `typec` or failed in the backend. The
runner tells them apart by `typec`'s exit status (see "Choosing the
backend"), and records `typec`'s message, the last line of its stderr;
any other failure, such as the backend compiling `typec`'s output or
preprocessing it, is the backend's. An error of `typec`'s environment,
such as a backend it cannot start or an option it refuses, ends the run
with 2. The runner reads the statuses from the checkout it is built
from, so the `typec` binary must be built from the same revision.

The runner then links each program of the recipe from the `typec`
objects, and runs the recipe's test script in the build tree on the
programs that linked, even when others did not. The script's environment
has `CC` and `TYPEC_CC` naming the backend and `TYPEC` naming the
`typec` under test. The recipe says whether the script is the program's
own test suite (`test own SCRIPT`) or a substitute for it (`test
substitute SCRIPT DESCRIPTION`, a smoke test or tests that are only
compiled); it has no default. A script may print one line per test,
`TEST pass NAME`, `TEST fail NAME` or `TEST fail-with-backend NAME` (a
test that fails with the backend's own objects too, so that it says
something about the host), which the record counts.

It writes a record of each program and backend to
`CORPUS/runs/HOST/PROGRAM.BACKEND.txt` and prints it: the digest of the
`typec` binary, which cannot report its own revision, and the revision of
the checkout beside it at run time, the revision of the corpus, the
counts of identical, different, refused, typec-bug and backend-failed
units, which failed and why, whether the programs linked, and the
tests. The tests line says `passed` for an own suite that passed with
everything built; `partial: ...` when the script passed but a unit
failed or a program did not link, which does not meet gate 1;
`substitute passed, not the program's own suite: DESCRIPTION` for a
substitute, which does not meet gate 1 either; and `FAILED` or `not
run` otherwise. The results line counts the `TEST` lines (passed,
failed, failed with the backend too) and lists the failures. The record ends with the CPU time of preprocessing,
of `typec --emit-c` and of the backend's `-fsyntax-only` on `U.ref.i`,
summed over the units, whose first two differ by the time of `typec`'s
front end. The stderr of every command and the stdout of the test script
go to `CACHE/build/HOST/PROGRAM/BACKEND.log`, and its stdout is kept in
`BACKEND.tests` beside it.

Exit status: 0 when every unit gave identical objects, every program
linked and every program's own tests passed; 1 when a unit differs or
failed, a program did not link, a test failed or did not run, or a build
could not be set up; 3 when nothing failed but a program's tests are a
substitute, so that a status of 0 never comes from a run that did not
meet gate 1 (the runner also prints a line for each record that does not
meet the gates); 2 when the command line or a recipe is wrong, an
archive has not been fetched, or the runner cannot read or write a file
of its own. A `TEST` line the runner cannot count, or a script that
exits with 0 after reporting a failed test, is a failed test. `dune test`
runs `tools/corpus/runner.t`, which checks the runner on a fixture program.

## Typing oracle

`tools/oracle/` holds the typing oracle of plan package 0.10, which
checks the type and the value category `typec` gives each expression of
a preprocessed file against Clang's: `oracle.exe` records Clang's,
`compare.exe` compares `typec`'s with them, and `typec_dump.exe` prints
`typec`'s.

```sh
oracle.exe CC INPUT.i OUTPUT [OPTION...]
compare.exe [--show N] CC INPUT.i RECORDS ALLOW-LIST [OPTION...]
typec_dump.exe CC INPUT.i [OPTION...]
```

runs `CC -Xclang -ast-dump=json -fsyntax-only -w OPTION... -x cpp-output
-- INPUT.i`, without a shell, on the preprocessed text that `typec`
reads, and writes to OUTPUT a record of every expression node of the
translation unit: those of function bodies and initialisers, in the
file and in the headers it includes, and those of declarations, such as
array lengths and enumerators. It prints how many it recorded and how
many it left out for having no source range (the implicit initialisers
of the members an initialiser list leaves out). OUTPUT is written in
full or not at all; the exit status is 1 when Clang fails or its output
is refused.

`oracle.exe` reads JSON with yojson, which `typec` does not depend on,
so it is built in an opam switch of its own, in the opam root of the
fuzz harness. Setting up, once:

```sh
export OPAMROOT=/Volumes/Optaine/opam
opam init --bare --disable-sandboxing -n -y   # unless the root exists
opam switch create tools --no-switch -y ocaml-base-compiler.5.5.2
opam install --switch tools -y dune.3.24.2 yojson.3.0.0
```

Building the oracle and running its tests, with the build outside this
repository, then comparing a unit of the corpus:

```sh
export OPAMROOT=/Volumes/Optaine/opam
build=/Volumes/Optaine/typec-oracle/_build
dune build --root . --workspace tools/oracle/oracle.workspace \
  --build-dir "$build" @tools/oracle/runtest
"$build/oracle/tools/oracle/oracle.exe" /usr/bin/clang lvm.tc.ref.i \
  /Volumes/Optaine/typec-oracle/lvm.records -std=gnu11
"$build/oracle/tools/oracle/compare.exe" /usr/bin/clang lvm.tc.ref.i \
  /Volumes/Optaine/typec-oracle/lvm.records tools/oracle/allow-list \
  -std=gnu11
```

`tools/oracle/oracle.workspace` makes a dune context named `oracle` of
the switch, and `tools/oracle/dune` enables `oracle.exe` and the tests
only in that context, so a plain `dune build` or `dune test`, in the
default context, skips them; `compare.exe` and `typec_dump.exe` need only
`typec`'s libraries and are built in both. A condition on the library
itself (`%{lib-available:yojson}`) needs dune language 3.15, and an
executable marked `(optional)` is still built by the default alias.
`oracle.t` and `compare.t` run the Clang that `TYPEC_TEST_CLANG` names,
`/usr/bin/clang` when it is unset.

Each record is a line of tab-separated fields:

```text
FIRST  LIMIT  KIND  CAST  CATEGORY  TYPE  DESUGARED
```

* `FIRST` and `LIMIT` are byte offsets in INPUT.i: the expression's
  source range is from `FIRST` up to, not including, `LIMIT`. Clang
  gives a location's `offset` in the buffer it read, which for a
  preprocessed file is INPUT.i itself; line markers change only the
  presumed file and line it also gives (`presumedFile`, `presumedLine`,
  `includedFrom`). A range ends at the start of its last token, so
  `LIMIT` is the end's `offset` plus its `tokLen`. Clang names a
  location's buffer (`file`) only when it differs from that of the
  location written before it, so the oracle follows every location in
  the order of the dump, and refuses one in another buffer or in a
  macro expansion.
* `KIND` is Clang's node kind and `CAST` the cast kind of an implicit
  or explicit cast, such as `LValueToRValue`.
* `CATEGORY` is `lvalue`, `prvalue` or `xvalue`.
* `TYPE` is the type as Clang prints it (`qualType`), and `DESUGARED` the
  type with its outermost sugar removed (`desugaredQualType`), when
  that is spelled differently.
* An absent field is `-`. A backslash or control byte in a field, such
  as a tab in a file name, is written `\xHH`, and so is a field that is
  `-` alone.

The records come in the order of the dump, each node before the nodes
inside it, since Clang writes a node's range before its children. An
implicit conversion has the source range of its operand, so for the
nodes that share a range the first record has the type after the
conversions and the last the type of the expression as written, which
the comparison checks.

The oracle is a test tool that reads the pinned corpus through our own
Clang, so neither Clang's output nor the records are a trust boundary
and their size is not bounded. Clang's output is read one top-level
declaration at a time, which reads all of SQLite in about 55 megabytes;
a dump that yojson cannot read, such as one nested deep enough to
overflow the stack, fails that unit with status 1.

### Comparison

`compare.exe` takes the target model and the dialect from CC and the
options as `typec` would for the compilation, reads INPUT.i as `typec`
does, and joins its expressions with the records by their byte ranges:
an expression's range runs from the first byte of its first token to
the last of its last. Of the records that share a range, the last is
checked, the type of the expression as written, which is `typec`'s
type before the conversions of its context. The value categories are
compared first: they agree when both are lvalues or neither is,
`prvalue` and `xvalue` being values.

Types are compared by meaning, not by spelling. Clang's spellings name
typedefs and tags, so `typec` reads each one as a type name: it appends
to INPUT.i a function with a typedef of `__typeof__ (SPELLING)` for each
spelling of a record it has an expression for, each on a line of its
own, reads the whole as one unit, and takes the type of each typedef. A
spelling that typec refuses there drops out, with its message as the
reason, and the rest are read again. The types of the expressions
themselves come from INPUT.i read alone. The typedef names and tags a
spelling sees are those of file scope at the end of the unit: a
spelling with a tag that no file-scope declaration declares, or with a
typedef name of a block, is unresolved, and one whose name a block
declares again reads as the file-scope one, so its record disagrees, or
agrees where `typec` wrongly gives the file-scope type. Reading a
spelling in the scope of its expression would settle those too, but
needs the parser's scope at a point of the unit, which it does not
keep. The types then agree when `Ctype.same_type` says they are the
same; when it depends on a type that `typec` does not compute, the
comparison counts it as unknown.

Clang spells types as `Type_name.of_ctype` does, apart from these cases;
`tools/oracle/normalisation.ml` holds the rules that the comparison
applies to them:

| Clang | `typec` | comparison |
| --- | --- | --- |
| typedef names, anywhere in the type: `A3 *`, `size`; `DESUGARED` removes only the outermost (`size` gives `unsigned long`, `A3 *` none) | no typedef names | read as a type name |
| `typeof (n) *`, like a typedef name | the type of `n` | read as a type name |
| `struct (unnamed struct at FILE:LINE:COL)`, desugared `struct (unnamed at FILE:LINE:COL)`, or `union O::(unnamed at FILE:LINE:COL)` for a member of `struct O`, at the presumed location of the tag's keyword; `struct O::(anonymous at FILE:LINE:COL)` for an anonymous member | `struct <anonymous>` | unresolved: no type name names it |
| an anonymous tag declared in a typedef, by the typedef's name even when desugared: `point` | `struct <anonymous>` | read as a type name |
| `_Atomic(int)` | `_Atomic int` | read as a type name |
| `int[n]`, the length as written | `int[*]` | the length becomes a parameter of the appended function |
| `__builtin_va_list`, desugared `struct __va_list_tag[1]` on x86-64; a `va_list` parameter `struct __va_list_tag *` | `__builtin_va_list` | the parameter's type becomes `__builtin_va_list` |
| a function type with `__attribute__((noreturn))` after it | no attribute | the attribute is dropped |
| `<builtin fn type>`, the type of a builtin function | the builtin | unresolved |
| a string literal that initialises an array: a `prvalue` of the array's type | an lvalue of the literal's type | unresolved, the category too |
| a spelling over several lines, such as `typeof (({...}))` of a statement expression, or with a backslash, a brace, a semicolon or unbalanced brackets | any type | unresolved: it is not one type name on one line |
| `bool` under `-std=c23`, `_Bool` before | `_Bool` | none: `typec` takes C11 and C17 |
| `__attribute__((__vector_size__(4 * sizeof(int)))) int` | an unknown type, `<...>` | unknown |

Apart from spelling, Clang gives a function designator the category
`prvalue`, as `typec` does.

Each expression ends up in one of seven counts: those that agree; those
that disagree, outside the allow-list; those that disagree and the
allow-list accepts; those with a type `typec` does not compute; those
whose record is unresolved, once the categories agree; those that only
Clang records, such as the initialisers at file scope, which `typec`
does not type (TODO.md), a braced initialiser list, which is not an
expression in `typec`'s tree, and the bodies that a system header
defines, which `typec` keeps as spans; and
those that only `typec` types, such as the length of a constant array,
which Clang folds into the type. The comparison prints the counts, the
reasons of the unresolved records, and the first N (20 unless `--show`
says) of each count but the agreements, each with its presumed location
and byte range; what comes from INPUT.i or RECORDS is printed escaped as
in a record. It exits with 1 when a disagreement is outside the
allow-list, which gate 4 of the plan requires of the corpus, or `typec`
refuses INPUT.i or fails on it, and with 2 when there is nothing to compare: a wrong
command line, options that CC gives no target model for, or a file that
cannot be read.

`tools/oracle/allow-list` holds the reviewed disagreements. Each line is
a pattern and a reason separated by a tab, a blank line, or a comment
that starts with `#`. A pattern matches a disagreement as the comparison
prints it, the whole line from its location on; `*` matches any run of
bytes and every other byte itself.

`typec_dump.exe` prints a line for each expression `typec` types, in
the order of their ranges: `FIRST`, `LIMIT`, `lvalue` or `rvalue`, and
the type as `Type_name.of_ctype` spells it, separated by tabs.
