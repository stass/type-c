<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Developing typec

The tools that check `typec` beyond `dune test`: the test hosts, the
fuzz harness, the corpus runner, the typing oracle and the measurements
against hand-written C. How to build `typec` and run its tests is in the
[README](../README.md#building-and-testing).

## Linux test hosts

`tools/hosts` describes each Linux host that the suite runs on as a
Dockerfile, with the base image pinned by digest and the compilers, the
C library and OCaml by version: Debian 13 (glibc) and Alpine 3.24
(musl), each with the distribution's GCC and Clang, and OCaml 5.4 and
dune from Alpine's packages and from opam on Debian. The Debian image
also has GCC 16, from Debian testing, as `/usr/bin/gcc-16`; the suite
runs with it when `TYPEC_TEST_GCC` names it. Clang and GCC 14 then use
GCC 16's runtime libraries. A host is a
Dockerfile and a platform, and its name says both: `debian-amd64`,
`debian-arm64`, `alpine-amd64` and `alpine-arm64`.
`tools/hosts/run.sh HOST [LOG]` builds the image of HOST and runs
`dune build` and `dune test` in a container of it, with the source
mounted read-only, the build inside the container and no network. The
image is tagged `typec-host-HOST:HASH`, HASH being the first twelve hex
digits of the SHA-256 of its Dockerfile, so that the images of different
Dockerfiles never replace each other; Docker's build cache makes the
build of an unchanged Dockerfile instant. An image stays until
`docker rmi` removes it (`docker image ls 'typec-host-*'` lists them).
It needs a running Docker with buildx (`docker-buildx` in Homebrew)
that can mount the source tree (colima, for instance, shares the home
directory but not `/Volumes`), prints whether the suite passed, and
writes the whole output to `LOG`, by default
`${TMPDIR:-/tmp}/typec-host-HOST.log`.

A platform other than the machine's runs under emulation, which needs
qemu-user binfmt handlers for it in the Docker VM (colima's has them for
arm64: `docker run --rm --platform linux/arm64 alpine:3.24 uname -m`
prints `aarch64`) and makes the build and the suite many times slower.
LeakSanitizer needs ptrace, which qemu-user does not implement, so a
host whose platform is not the Docker daemon's runs the sanitized tests
with `ASAN_OPTIONS=detect_leaks=0`, and the run says so.

```sh
tools/hosts/run.sh debian-amd64
tools/hosts/run.sh alpine-arm64 /Volumes/Optaine/alpine-arm64.log
```

The tooling (the Dockerfiles, `corpus-in-container.sh` and
`tools/corpus/revision.sh`) is the tree the script sits in, and the
source that the suite or the corpus runs on is by default the same
tree. `--source DIR`, before the host, names another typec checkout
instead, so that the current tooling runs an older revision, for
instance one that a corpus record is to be made at, in a worktree of
it. For the corpus the revision the records carry (`-dirty` included)
is the source's, and the runner of the source must take the command
line that `corpus-in-container.sh` gives it. The records name the
source's revision and not the image, so the script also prints, and
writes to `LOG`, the image tag and the tooling's revision. `DIR` must be
a path that Docker shares, like the default tree for the suite, and is
trusted like the tooling tree: git runs in it. The FreeBSD host takes no
`--source`.

```sh
git worktree add ~/typec-old 5670550
tools/hosts/run.sh --source ~/typec-old debian-amd64
```

The arm64 hosts have known failures, explained in `TODO.md` under Test
hosts: among them `test_small_stack` with `FAIL: the backtrace names
the stage` on both, and `target.t`, `pipeline.t` and
`tools/corpus/runner.t` with a missing C compiler on `debian-arm64`.

`tools/hosts/run.sh --corpus HOST LOG PROGRAM...` runs the corpus
runner (see "Running the corpus") on the named programs in a container
of a Linux host instead, with the host's Clang and GCC as the backends.
The corpus repository and its cache are `TYPEC_CORPUS` and
`TYPEC_CORPUS_CACHE`, by default the paths that section names, and
`fetch.sh` must have filled the cache. Nothing is mounted, so the
paths need not be shared with Docker: the script sends the container
the source tree and the corpus repository, each as the files git
tracks or does not ignore, and the sources of the cache as a tar
stream, together with `tools/hosts/corpus-in-container.sh`, which builds
`typec` and the runner there and runs it. No git directory goes in, as the corpus
programs are third-party code: the script names the revision of each
tree as it is outside the container, `-dirty` included, on the
runner's command line, and the records carry it. The results come back
as a tar stream too; the script takes only plain files where the runner
writes them, for one host, and copies the records into
`CORPUS/runs/linux-MACHINE/` and the logs into `CACHE/build/`. The
runner's output goes to `LOG`; the script prints whether the runner
passed, counting its status 3 (substitute tests only) as a pass.

```sh
tools/hosts/run.sh --corpus debian-amd64 /Volumes/Optaine/debian.log \
  c-testsuite zlib lua sqlite chibicc qbe
```

## FreeBSD test host

The FreeBSD x86-64 host is a machine reached over ssh, not a container:
`tools/hosts/freebsd.sh`, or `tools/hosts/run.sh freebsd`, which runs
it. The header of the script says which environment variables name the
account (`TYPEC_FREEBSD_TARGET`, `TYPEC_FREEBSD_KEY`,
`TYPEC_FREEBSD_DIR`), the corpus programs to run
(`TYPEC_FREEBSD_CORPUS`) and the corpus repository and its cache
(`TYPEC_CORPUS`, `TYPEC_CORPUS_CACHE`), which compilers and tools the
host must supply, and which OCaml and dune it builds. The host fetches
nothing for the corpus: as for the containers, `fetch.sh` must have
filled the cache here, and the script sends its sources. Everything goes to
`~/typec-host` of the account and nothing runs as root; the corpus
programs are third-party code run with the account's own rights, so use
an account that holds nothing else. ssh asks no question, so the key
must be loaded or named and the host key must be known. The suite runs
under `proccontrol -m aslr -s disable`, as the AddressSanitizer runtime
of GCC 14 exits at the start of a program under FreeBSD's default ASLR;
a `dune test` run by hand on FreeBSD needs the same.

```sh
export TYPEC_FREEBSD_TARGET=user@freebsd-host
TYPEC_FREEBSD_CORPUS="c-testsuite zlib lua sqlite chibicc qbe" \
  tools/hosts/run.sh freebsd /Volumes/Optaine/freebsd.log
```

The run prints whether the suite passed, and the log holds the whole
output, including the record of each corpus run (the runner's status 3,
substitute tests only, counts as a pass). The records the runner writes
come back into `CORPUS/runs/freebsd-amd64/`, after a check that the
host sent only plain files named for the programs and compilers of the
run, as the host runs third-party code; the runner's logs
stay on the host, under `typec-host/corpus-cache/build/`. The toolchain,
the build tree and the build trees of the corpus stay between runs. To
remove them all:
`ssh USER@HOST "sh -c 'chmod -R u+w typec-host; rm -rf typec-host'"`.

## Fuzzing

`tools/fuzz/` holds the fuzz harness: `fuzz.exe TARGET [FILE]` runs one
input, from FILE or standard input, through a target, and fails on any
exception, broken property or memory beyond a bound linear in the input.
The `reader` target checks that every text is read or refused with a
printable message, and that an accepted text is spelled by its tokens
and gaps, has only layout in the gaps and is emitted unchanged. The
`parser` target parses every text the reader accepts, with the keywords
of an LP64 target; each stage must accept or refuse with a printable
message, every node's span must hold its parts in token order, and
parsing again must give the same tree. It stops at the parser, so that
its linear bounds below check that parsing stays linear. The `lowering`
target runs every stage after the parser: it reads the file-scope
declarations of every unit that parses, lowers every unit whose
declarations are read, with the builtin trap, and emits it as `typec`
does. Each stage must refuse with a printable message or accept;
lowering must make edits charged at most the output limit (design 3.5
rule 7), which emission applies without raising. The declaration
reader runs only there, because the instance budget, not the input,
bounds its work. The parser runs on a fiber whose stack is
limited to 32K words (`test/support/small_stack.ml`), which holds its
deepest nesting (`Parser.max_nesting`), so that recursion growing with
the input overflows it and is reported. The normal build compiles
the harness, and `dune test` runs it on the seeds in
`tools/fuzz/seeds/`.

AFL++ drives it, with coverage from an OCaml compiler configured for AFL
instrumentation. That compiler lives in its own opam root, so the normal
build keeps the system OCaml. On every host the compiler needs a patch
to `runtime/afl.c`, `tools/fuzz/patches/ocaml-5.5.2-afl.patch`, under the
license of the OCaml file it modifies (its header says so). The fork
server of the stock runtime speaks only the old handshake, which reports
no map size, so afl-fuzz gives every instance an 8 MiB map where the
instrumentation writes 64 KiB; the patch speaks the handshake of AFL++
4.20c and later, which reports it (an older afl-fuzz needs
`AFL_OLD_FORKSERVER=1`). AFL++ on macOS also hands its coverage map
over only as a POSIX shared memory descriptor, which the stock runtime
does not read and the patch does. Setting up, once, from the root of
this repository:

```sh
brew install afl++
export OPAMROOT=/Volumes/Optaine/opam
opam init --bare --disable-sandboxing -n -y
opam switch create afl -y --packages=\
ocaml-variants.5.5.2+options,ocaml-option-afl,compiler-cloning.disabled
opam install --switch afl -y dune
src=/Volumes/Optaine/typec-fuzz/ocaml-afl-src/ocaml-5.5.2
opam source --switch afl ocaml-compiler.5.5.2 --dir "$src"
patch -d "$src" -p1 \
  < tools/fuzz/patches/ocaml-5.5.2-afl.patch
opam pin add --switch afl -y --kind=path ocaml-compiler.5.5.2 "$src"
```

Without `compiler-cloning.disabled`, opam copies the compiler of another
switch of the same version instead of building the patched source. To
take a new version of the patch, remove the switch and `$src` and run
the recipe again, then remove `$TYPEC_FUZZ_DIR/_build` so that the
harness links the new runtime. The `afl-fuzz` log of a run says `new
fork server model v1 is up` and `Target map size: 65536` when the
patch is in.

A campaign keeps its build, seeds and findings in `TYPEC_FUZZ_DIR`
(default `/Volumes/Optaine/typec-fuzz`), never in this repository:

```sh
tools/fuzz/fuzz.sh build             # the instrumented harness
tools/fuzz/fuzz.sh seeds             # more seeds: cc -E of C headers
CC=gcc-16 tools/fuzz/fuzz.sh seeds   # and those of another compiler
tools/fuzz/fuzz.sh run reader 30     # 30 minutes; resumes a run
tools/fuzz/fuzz.sh run parser 180 12 # 3 hours: a main and 12 secondaries
tools/fuzz/fuzz.sh triage reader     # minimise crashes and hangs
```

With SECONDARIES, `run` starts one main instance (`-M default`) and that
many secondary ones (`-S s1`, `-S s2`, ...) in the same output
directory, where they share what each finds; each logs to
`out/TARGET.NAME.log` and shows no status screen (`afl-whatsup` on the
output directory shows the totals), and `triage` minimises the crashes
and hangs of every instance, so a bug that several found is minimised
once for each.

A running campaign keeps the harness it started with. After a change to
what a target runs, stop its campaign, run `fuzz.sh build`, and restart
it; its old crashes and hangs may be ones the new target no longer
reaches, which `triage` reports as not crashing again. An instance that
has run before resumes from its own queue and does not read the seeds;
only an instance new to `out/TARGET`, such as a new secondary, starts
from the current seeds, and the others take its finds from it.

A committed seed goes to the target of its directory and to every target
after it in the table of `fuzz.ml`, since each runs the stages of those
before it: `reader` seeds go to all three targets, `parser` seeds to
`parser` and `lowering`, `lowering` seeds to `lowering` alone.
`fuzz.exe -s TARGET` prints the directories a target reads, which
`fuzz.sh` and `seeds.t` take, so a new seed needs only its file in the
right directory; `fuzz.sh` refuses a seed that is a link.

The generated seeds, in any directory of `seeds/` there (`seeds/headers`
for those of `fuzz.sh seeds`; preprocessed units of the corpus under
16 KiB, thinned with `afl-cmin`, can go in another), go to every target.
So does the AFL++ dictionary, `fuzz.dict`, which the build generates from
the keyword and punctuator tables of the parser and the reader and the
pieces of `cc -E` output listed in `dictionary.ml`.

The limits of one execution, whose values are in `fuzz.ml` and
`fuzz.sh`:

* Input: at most `max_input_bytes`, 16 KiB; a longer one is skipped.
  The slowest input of that size measured, an array size of 8K
  additions in the `parser` target, takes about 65 ms in the
  instrumented harness; all `;` takes about 20 ms in the `reader`.
* Time: the target's `time_limit_ms` (`-t`), which `fuzz.sh` reads
  from `fuzz.exe -t TARGET`. AFL++ runs an input that exceeds it again
  with twice that (`AFL_HANG_TMOUT`) and saves it as a hang only if it
  exceeds that too, so that a busy host does not make one. The reader
  and the parser have 300 ms, about five times the worst linear run,
  while a step quadratic in the 16K bytes or tokens of that input would
  cost thousands of times more. A step quadratic in something sparser,
  such as line markers, can stay inside it. The `lowering` target has
  5 s: its stages write instances and copies of deferred statements
  until the instance budget or the output limit stops them, which a
  source of a few hundred bytes can reach. The slowest input measured,
  49 aliases 8 deep over structures
  (`Budget_probes.aliases_over_structures`), which nearly fills the
  instance budget and writes 11 MB of C, takes 1.7 s in the
  instrumented harness. The declaration reader runs only under these
  bounds, so a step of it that is superlinear in the input but makes no
  instances is reported only once it passes them.
* Memory: the harness fails when the major heap peaks above
  `heap_words_fixed` plus `heap_words_per_input_byte` per input byte,
  about twice what the densest input needs. The `lowering` target may
  add `heap_words_per_budget_byte` for each byte of the instance budget
  and of the output limit, about twice the densest rate measured: some
  51 million words, 400 MB, which each instance of a campaign may reach
  at once. The harness checks the bound at the end of every major GC
  cycle, so a runaway stops near it. AFL++'s own limit (`-m`) is off:
  it sets `RLIMIT_AS`, which macOS refuses to set, and on Linux that
  limit counts the address space OCaml 5 reserves, not what a stage
  uses.

The harness reports a crash with the exit code in `AFL_CRASH_EXITCODE`,
which `fuzz.sh` sets, because the crash reporter of macOS can hold a
signalled process for seconds and AFL++ would record a hang.

A target is a module with `check : string -> unit` that returns for
every input its stage accepts or refuses and raises otherwise. Adding
one is that module, its libraries in `tools/fuzz/dune`, an entry in the
`targets` table of `fuzz.ml`, linear or budgeted, and seeds in
`tools/fuzz/seeds/TARGET/`, which `dune test` runs through it.

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
  --typec-revision "$(tools/corpus/revision.sh .)" \
  --corpus-revision "$(tools/corpus/revision.sh "$corpus")" \
  --cc /usr/bin/clang --cc /usr/local/bin/gcc-16 \
  c-testsuite zlib lua sqlite chibicc qbe
```

The runner asks git nothing: its caller names the revision of the
`typec` checkout and of the corpus, as `tools/corpus/revision.sh`
prints them (the commit, then `-dirty` when the tree differs from it,
a file git does not track included), and the runner refuses any other
form. On a test host the
caller is `tools/hosts/run.sh` or `tools/hosts/freebsd.sh`, on the
machine that holds the trees, so no git directory goes where the corpus
programs run.

For each program and backend the runner makes a fresh build tree in
`CACHE/build/HOST/PROGRAM/BACKEND/` from the archives of the program's
recipe (`programs/PROGRAM/recipe`, in the format of
`tools/corpus/recipe.mli`) and compiles each unit `U.c` of it, with
`-O2`, no debug option and the recipe's options:

1. `typec --cc=BACKEND -c U.tc -o U.o`, where `U.tc` is a copy of `U.c`
   next to it, so that its includes resolve as before;
2. the reference, made of the commands of typec's own pipeline
   (`src/driver/pipeline.mli`) for the same goal on `U.tc`, so that
   its options are routed as typec routes them: the backend preprocesses
   `U.tc` to `U.ref.i`, and the plan's compile step reads a copy of that
   text at the path where the plan puts the emitted C, where typec's own
   compile step reads the C that typec emits. The copy is in
   `CACHE/build/HOST/PROGRAM/BACKEND.reference/`, outside the build
   tree, so that a test script looking for the tree's C sources does not
   find it. The reference makes `U.ref.o` and differs from step 1 only in
   its front end;
3. `U.o` and `U.ref.o` must be equal byte for byte.

Each unit ends in one of five states: identical, different, refused by
`typec`, an internal error of `typec` or failed in the backend. The
runner tells them apart by `typec`'s exit status (README, "Choosing the
backend"), and records `typec`'s message, the last line of its stderr;
any other failure, such as the backend compiling `typec`'s output or
preprocessing it, is the backend's. An error of `typec`'s environment,
such as a backend it cannot start or an option it refuses, ends the run
with 2. The runner reads the statuses from the checkout it is built
from, so the `typec` binary must be built from the same revision.

The runner then links each program of the recipe from the `typec`
objects, and runs the recipe's test scripts in the build tree on the
programs that linked, even when others did not. A script's environment
has `CC` and `TYPEC_CC` naming the backend and `TYPEC` naming the
`typec` under test. Each test line says whether its script is the
program's own test suite (`test own SCRIPT`) or a substitute for it
(`test substitute SCRIPT DESCRIPTION`, a smoke test or tests that are
only compiled); it has no default. A test line may name the host it
applies to, as `test@SYSTEM` or `test@SYSTEM/MACHINE` (by `uname -s` and
`uname -m`, such as `test@Linux/x86_64` for a suite that needs Linux on
x86-64); it is skipped on any other host, while a line without a host
runs everywhere. A script may print one line per test,
`TEST pass NAME`, `TEST fail NAME` or `TEST fail-with-backend NAME` (a
test that fails with the backend's own objects too, so that it says
something about the host), which the record counts.

It writes a record of each program and backend to
`CORPUS/runs/HOST/PROGRAM.BACKEND.txt` and prints it: the digest of the
`typec` binary, which cannot report its own revision, and the revision
its caller names for the `typec` checkout at run time, the revision of
the corpus, the counts of identical, different, refused, typec-bug and
backend-failed units, which failed and why, whether the programs
linked, and the tests. Each test line of the recipe gets a tests line
in the record, which names its script and says `passed` for an own
suite that passed with everything built; `partial: ...` when the
script passed but a unit failed or a program did not link, which does
not meet gate 1;
`substitute passed, not the program's own suite: DESCRIPTION` for a
substitute, which does not meet gate 1 either; `skipped on this host:
only on HOST` for a line limited to other hosts, which is neither a pass
nor a failure; and `FAILED` or `not run` otherwise. Its results line
counts the `TEST` lines (passed, failed, failed with the backend too)
and lists the failures. The record ends with the CPU time of
preprocessing, of `typec --emit-c` and of the compile step that the
pipeline plans for `-fsyntax-only` on the preprocessed text, summed over
the units, whose first two differ by the time of `typec`'s front end.
The stderr of every command and the stdout of the test scripts go to
`CACHE/build/HOST/PROGRAM/BACKEND.log`, and the stdout of each script is
kept beside it in `BACKEND.tests/N.SCRIPT`, for the Nth test line.

Exit status: 0 when every unit gave identical objects, every program
linked, every test line that applies to the host passed and each
program's own suite ran whole (it has an own line and none is limited to
other hosts); 1 when a unit differs or failed, a program did not link,
a test line that applies to the host failed or could not run, or a build
could not be set up; 3 when nothing failed but a program's own suite did
not run whole on this host (its tests are a substitute, or an own line
is limited to other hosts), so that a status of 0 never comes from a run
that did not meet gate 1 (the runner also prints a line for each record
that does not meet the gates); 2 when the command line or a recipe is
wrong, an archive has not been fetched, or the runner cannot read or
write a file of its own. A `TEST` line the runner cannot count, or a script that
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
  /Volumes/Optaine/typec-oracle/lvm.records -std=gnu17
"$build/oracle/tools/oracle/compare.exe" /usr/bin/clang lvm.tc.ref.i \
  /Volumes/Optaine/typec-oracle/lvm.records tools/oracle/allow-list \
  -std=gnu17
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
| `<builtin fn type>`, the type of a builtin function | its function type, or the builtin's name when `typec` states none | unresolved |
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

## Measuring against hand-written C

`tools/measure/gate4/` holds Type-C programs, each with a hand-written C
twin of the same name: `tree` walks a tree of a variant by `match`
against a tag, a union and a `switch`; `shapes` runs a `match` with
bindings in a hot loop; `ids` passes ids of a distinct type through
calls against a `typedef`; `nodes` passes constructors by value to the
function that stores them, as a parser builds its tree (design 13.5).
`tools/measure/gate4.sh OUT` builds each pair at `-O2` with both
backends, checks that the two print the same, and writes the bytes of
machine code of each object, and the instructions and core cycles each
program takes, to `OUT/results.md`, with the objects, the lowered C and
the raw counts under `OUT/work`. It runs on FreeBSD, where `pmcstat`
counts the events of one process in user mode, and reads the code size
of the ELF objects (the `.text*` sections) with `size -A`. Name the
backends (`TYPEC_TEST_CLANG`, `TYPEC_TEST_GCC`), and on a copy of the
tree without its git directory the revision (`REVISION`, as
`tools/corpus/revision.sh` prints it where the copy was made). `results.md` states how the verdicts are drawn.

```sh
TYPEC_TEST_CLANG=/usr/local/bin/clang21 TYPEC_TEST_GCC=/usr/local/bin/gcc14 \
  tools/measure/gate4.sh ~/typec-gate4-out
```

The `hwpmc` module must be loaded, and libpmc must honor the `usr`
qualifier of a pmu event, which the script checks: FreeBSD's libpmc
drops the qualifiers of pmu-events names and counts kernel mode too
until a fix (`pmu_parse_qualifiers` in `lib/libpmc/libpmc.c`) reaches
it. p620 runs a libpmc and an `hwpmc` module built with that fix.

`tools/measure/containers/` holds a benchmark of the container library
of `test/run/containers.t` (package 3.6). `bench N ROUNDS` runs ROUNDS
rounds of the phases of a `vector(int)`, a region and a `map(int, int)`
of N elements and prints the nanoseconds and a checksum of each phase
over all rounds; `bench.tc` and `bench_map.tc` both instantiate
`vector(int)`. `bench.c` and `bench_map.c` do the same over
`containers.h` and `containers.c`, a hand-written C twin of the library
whose vector and map are declared and defined for each element type by
macros, built twice: with external functions defined once in
`containers.c`, and with `-DCONTAINERS_INLINE`, static inline functions
defined in each unit, as Type-C defines its instances.
`bench_common.c`, plain C linked into every program, holds the phases,
the random numbers and the clock. `sum_checked` and `sum_unchecked` sum
the vector through the checked indexes of a slice and through its data
pointer. `tools/measure/containers.sh OUT [CC...]` builds the three
programs with each backend (by default those of `test/run/backends.sh`)
at `-O0` and `-O2`, checks that they print the same checksums, and
writes a CSV to `OUT`, outside the repository, with the objects in
`OUT.build`: the bytes of machine code of each object and program, the
best of `RUNS` compile times of each unit and of `typec --emit-c`, the
best of `RUNS` times of each phase for each `N:ROUNDS` of `SIZES`, and
what `typec --stats` reports for each Type-C unit, the test's own units
included. It runs on macOS, reading Mach-O sizes with `size -m`, and on
ELF hosts with `size -A`.

```sh
tools/measure/containers.sh /Volumes/Optaine/measure-3.6/run/results.csv
```

`tools/measure/unit_stats.sh OUT SIDE CC [-I DIR]... -- UNIT...` writes
the same rows for the `--stats` fields of any `.tc` units, for a program
that is not the library, with a row for each of the refusals of design
7.3 rule 4 (`refusal_instance_pragma`) and of section 8 rule 9
(`refusal_slice_check_place`): 1 where the unit's first error names it,
0 where the unit has none. `containers.sh` stops at a unit that `typec`
refuses, so each unit that it measures has none.

```sh
tools/measure/unit_stats.sh /Volumes/Optaine/measure-3.6/run/pilot.csv \
  pilot-b /usr/bin/clang -- /Volumes/Optaine/type-c-pilot-b/toml.tc
```

`tools/measure/resume.sh OUT [CC...]` builds the programs of
`tools/measure/resume/` with `typec` on each backend at `-O0` and `-O2`
and writes one row for each run to `OUT`: what a slice index, and the
address of an element that a call holds across another argument,
reach when the full expression that holds them is resumed after the
same function has begun to evaluate it again (design section 8 rule
10), for `setjmp` in a statement expression, `getcontext` and
`__builtin_setjmp`, with the partners that C defines. It is a record,
not a test.

```sh
tools/measure/resume.sh /Volumes/Optaine/measure-3.6/run/resume.csv
```

`tools/measure/zero_record.sh OUT [CC...]` builds the program of
`test/run/zero_initialisers.t` with `typec` on each backend at `-O0`,
`-O2` and `-O3`, runs it as `zeroes record`, and writes one row to `OUT`
for each place and type of the test: how many of the bytes of a
`long double` that hold none of its value the zero initialiser left
non-zero (design 13.5). It fails where a promised byte is not zero. It
is a record, not a test.

```sh
tools/measure/zero_record.sh /Volumes/Optaine/measure-3.6/run/zero.csv
```

`tools/measure/nested/` holds six matchers over nested patterns (package
3.10), each a Type-C unit and a hand-written C twin of the same name:
`fold` (a match of eight arms, three nodes deep through pointers),
`fold_test` (three single-pattern tests), `sum_list` (a match five nodes
deep), `outcome` (two nodes with no pointer between them), and
`member_small` and `member_large` (a scrutinee that is a member, which
`typec` copies). The twins are nested `switch` statements of the same
decisions, with the arms written at the leaves and a trap for a tag that
is no constructor; `member_small_aligned.c` and `member_large_aligned.c`
read the member through a pointer to a typedef declared `aligned(1)`
instead. `driver.c` builds the same values for every program and times
each matcher. `tools/measure/nested.sh OUT [CC...]` builds the three
programs (`typec`, `c`, `c_aligned`) with each backend at `-O0` and
`-O2`, checks that they print the same checksums, and writes a CSV to
`OUT`, as `containers.sh` does: the bytes of machine code of each object
and program, the best of `RUNS` times of each matcher for each `N:ROUNDS`
of `SIZES`, and what `typec --stats` reports for each unit. It also
builds a match whose tree is as deep as design 4.7 rule 10 allows and
records whether the backend compiles it.

```sh
tools/measure/nested.sh /Volumes/Optaine/measure-3.10/run/nested.csv
```

`tools/measure/selection_stats.sh OUT CC [TEST.t...]` writes the rows of
`--stats` for the `.tc` files that the cram tests write (by default those
of `test/run` and `test/golden`) and that `test/run/readme.sh` writes
from the README, where a unit that `typec` refuses has the one row
`refused`. The `selection_steps`, `selection_nodes` and
`selection_depth` of a unit are the most that building the selection
tree of one of its matches or tests took; `unit_stats.sh` reports the
same for the container library and the pilot.

`tools/measure/try_expr/` and the two scripts beside it measure `try`
inside expressions (package 3.12, P33 to P35, P8).
`tools/measure/try_expr.sh OUT [CC...]` builds, with each backend at
`-O0` and `-O2`, four programs twice: with each `try` where its author
put it (side `prelude`, which `typec` lowers to preludes) and with each
`try` in a declaration of its own (side `decl`). They are `forms.tc`,
nine functions each of a form of design 5.1 rule 3 and `forms_decl.tc`,
its twin written by hand; the README's first example, `eval`, timed on a
tree, with its twin made by `readme_decl.sed`; the README's `copy.tc` and
`pair.tc`; and `toml.tc` of Pilot B, with its twin made by
`toml_decl.sed` and timed on the pilot's own `tools/bench/bench.c`. It
writes the bytes of machine code of each object and program, the best
time of each, and the counts that `--stats` reports, and fails where the
two sides print different checksums (for the pilot, parse a different
number of files) or a twin keeps a `try` in a place other than a
declaration or a statement of its own.
`tools/measure/try_stats.sh OUT CC` counts without building: for the
container library, the pilot and the README's units, which refusal of
design 5.1 rule 3 stops each unit, the preludes that `--stats` reports
(`try_holders`, `try_tries`, `try_first_operands`, `try_conditioned` and
`try_multiple`), where each `try` stands on its line, the loops that
call a function that returns a result and those whose body holds a
`try`, the initialiser lists that hold one, and the `#pragma` lines. It
writes `OUT.detail`, which lists the lines that those counts read.

```sh
tools/measure/try_expr.sh /Volumes/Optaine/measure-3.12/run/try_expr.csv
tools/measure/try_stats.sh /Volumes/Optaine/measure-3.12/run/try_stats.csv \
    /usr/bin/clang
```
