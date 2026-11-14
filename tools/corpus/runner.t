SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The corpus runner builds a program of a fixture corpus with the Clang
that test/run/backends.sh names, linked as clang: a library unit and a
program unit, compiled through typec and through the reference recipe,
then linked and tested. The lines that depend on the host, the backend,
the revisions and the timings are left out.

  $ . ../../test/run/backends.sh
  $ ln -s "$(command -v "$clang")" clang
  $ mkdir -p corpus/programs/hello cache/src/hello-1/include
  $ cat > cache/src/hello-1/include/greet.h <<'EOF'
  > const char *greeting(void);
  > EOF
  $ cat > cache/src/hello-1/greet.c <<'EOF'
  > #include "greet.h"
  > const char *greeting(void) { return __FILE__ " " GREETING; }
  > EOF
  $ cat > cache/src/hello-1/main.c <<'EOF'
  > #include <stdio.h>
  > #include "greet.h"
  > int main(void) { puts(greeting()); return 0; }
  > EOF
  $ cat > corpus/programs/hello/recipe <<'EOF'
  > # The unit sees its suffix forced to .tc in __FILE__.
  > tree hello-1
  > cflags -Iinclude -DGREETING="hello"
  > cflags@NoSuchSystem -DGREETING="never"
  > library greet.c
  > program bin/hello main.c
  > test own test.sh
  > EOF
  $ cat > corpus/programs/hello/test.sh <<'EOF'
  > [ "$(bin/hello)" = 'greet.tc hello' ]
  > EOF
  $ run() {
  >   out=$(./corpus.exe --corpus corpus --cache cache \
  >     --typec "$(command -v typec)" --cc ./clang "$@")
  >   status=$?
  >   echo "$out" | grep -v -E '^(host|backend|typec|corpus|log) |^  |^$'
  >   return $status
  > }
  $ fails() {
  >   out=$(./corpus.exe --corpus corpus --cache cache \
  >     --typec "$(command -v typec)" --cc ./clang "$@" 2>&1)
  >   status=$?
  >   echo "$out" | sed "s|$PWD/||"
  >   return $status
  > }
  $ run hello
  program      hello
  units        2
  identical    2
  different    0
  refused      0
  typec-bug    0
  backend-fail 0
  linked       1 of 1
  tests        passed
  results      none reported
  cpu seconds, summed over the units:

The run record goes into the corpus, under the host; the build tree and
its log go into the cache.

  $ ls corpus/runs/*/
  hello.clang.txt

The record names the typec binary by its digest. typec cannot report the
revision it was built from, so the revision of the checkout beside it is
labelled as that of the run.

  $ grep '^typec ' corpus/runs/*/hello.clang.txt |
  >   sed -E 's/[0-9a-f]{64}/DIGEST/; s/time: .*\)/time: REVISION)/'
  typec        blake2b-256 DIGEST (checkout at run time: REVISION)

  $ ls cache/build/*/hello/
  clang
  clang.log
  clang.tests
  $ ls cache/build/*/hello/clang/
  bin
  greet.c
  greet.tc
  greet.tc.emit.err
  greet.tc.emit.i
  greet.tc.o
  greet.tc.ref.i
  greet.tc.ref.o
  greet.tc.typec.err
  include
  main.c
  main.tc
  main.tc.emit.err
  main.tc.emit.i
  main.tc.o
  main.tc.ref.i
  main.tc.ref.o
  main.tc.typec.err

A test script that fails is recorded as failed, with the exit status 1.

  $ echo 'exit 5' > corpus/programs/hello/fail.sh
  $ sed 's/test own test.sh/test own fail.sh/' corpus/programs/hello/recipe \
  >   > corpus/programs/hello/recipe.own-fails
  $ cp corpus/programs/hello/recipe corpus/programs/hello/recipe.good
  $ cp corpus/programs/hello/recipe.own-fails corpus/programs/hello/recipe
  $ run hello
  program      hello
  units        2
  identical    2
  different    0
  refused      0
  typec-bug    0
  backend-fail 0
  linked       1 of 1
  tests        FAILED: the tests exited with 5
  results      none reported
  cpu seconds, summed over the units:
  hello.clang: gates not met
  [1]

A script that is not the program's own suite is recorded as a substitute
that passed, and the exit status is 3, neither a pass nor a failure.

  $ sed 's/test own test.sh/test substitute test.sh a greeting smoke test/' \
  >   corpus/programs/hello/recipe.good > corpus/programs/hello/recipe
  $ run hello
  program      hello
  units        2
  identical    2
  different    0
  refused      0
  typec-bug    0
  backend-fail 0
  linked       1 of 1
  tests        substitute passed, not the program's own suite: a greeting smoke test
  results      none reported
  cpu seconds, summed over the units:
  hello.clang: gate 1 not met: only a substitute test passed
  [3]
  $ grep '^tests' corpus/runs/*/hello.clang.txt
  tests        substitute passed, not the program's own suite: a greeting smoke test

A substitute that fails is failed like any other test.

  $ sed 's/test own test.sh/test substitute fail.sh smoke/' \
  >   corpus/programs/hello/recipe.good > corpus/programs/hello/recipe
  $ run hello > out; echo "exit $?"; grep -E '^(tests|hello)' out
  exit 1
  tests        FAILED: the tests exited with 5
  hello.clang: gates not met

The exit status 1 outranks 3 when the run holds both.

  $ cp corpus/programs/hello/recipe.own-fails corpus/programs/hello/recipe
  $ mkdir corpus/programs/smoke
  $ sed 's/test own test.sh/test substitute test.sh smoke/' \
  >   corpus/programs/hello/recipe.good > corpus/programs/smoke/recipe
  $ cp corpus/programs/hello/test.sh corpus/programs/smoke/test.sh
  $ run hello smoke > out; echo "exit $?"; grep -E '^hello|^smoke|^tests' out
  exit 1
  tests        FAILED: the tests exited with 5
  hello.clang: gates not met
  tests        substitute passed, not the program's own suite: smoke
  smoke.clang: gate 1 not met: only a substitute test passed
  $ cp corpus/programs/hello/recipe.good corpus/programs/hello/recipe
  $ rm -r corpus/programs/smoke corpus/programs/hello/recipe.*

A unit typec refuses keeps the programs that use it from linking. With
no program linked the tests do not run, and the runner exits with 1.

  $ printf 'int @;\n' >> cache/src/hello-1/greet.c
  $ run hello
  program      hello
  units        2
  identical    1
  different    0
  refused      1
  typec-bug    0
  backend-fail 0
  linked       0 of 1
  tests        not run: no program linked
  results      none reported
  cpu seconds, summed over the units:
  refused      greet.c: greet.tc:3: unexpected character '@'
  not linked   bin/hello
  hello.clang: gates not met
  [1]

A unit that the backend refuses inside typec, here its preprocessing,
is told apart from one typec refuses. The tests run on the programs that
linked, with TYPEC and the backend in their environment, and the lines
they print as results are counted. A script that passes while anything
failed to build is recorded as a partial pass, which does not meet gate
1.

  $ printf 'int @;\n' > cache/src/hello-1/bad.c
  $ printf '#error the backend refuses this\n' > cache/src/hello-1/ugly.c
  $ printf 'int main(void) { return 0; }\n' > cache/src/hello-1/ok.c
  $ mkdir corpus/programs/multi
  $ cat > corpus/programs/multi/recipe <<'EOF'
  > tree hello-1
  > program bin/ok ok.c
  > program bin/bad bad.c
  > program bin/ugly ugly.c
  > test own test.sh
  > EOF
  $ cat > corpus/programs/multi/test.sh <<'EOF'
  > [ -x "$TYPEC" ] && [ "${CC##*/}" = clang ] && [ "$TYPEC_CC" = "$CC" ] ||
  >   exit 7
  > for name in ok bad ugly; do
  >   [ -x "bin/$name" ] && echo "TEST pass $name"
  > done
  > echo "TEST fail-with-backend a host test with spaces"
  > echo "an ordinary line"
  > exit 0
  > EOF
  $ run multi
  program      multi
  units        3
  identical    1
  different    0
  refused      1
  typec-bug    0
  backend-fail 1
  linked       1 of 3
  tests        partial: passed on what linked only, gate 1 not met
  results      1 passed, 0 failed, 1 failed with the backend too
  test-host    a host test with spaces
  cpu seconds, summed over the units:
  refused      bad.c: bad.tc:1: unexpected character '@'
  backend-fail ugly.c: typec -c exited with 1
  not linked   bin/bad
  not linked   bin/ugly
  multi.clang: gates not met
  [1]
  $ grep -c 'error: the backend refuses this' cache/build/*/multi/clang.log
  1
  $ grep -c 'TEST pass ok' cache/build/*/multi/clang.log
  1

typec's own failures have exit statuses of their own
(src/driver/exit_status.mli), which the runner reads. An internal error
of typec is recorded against the unit; an environment typec cannot work
in ends the run with 2. buggy-typec fails as an internal error does, and
lost-cc-typec runs typec with a backend that cannot be started.

  $ cat > buggy-typec <<'EOF'
  > #!/bin/sh
  > echo 'typec: internal error, a bug in typec: Not_found' >&2
  > exit 82
  > EOF
  $ printf '#!/bin/sh\nexec "%s" "$@" --cc=no-such-cc\n' "$(command -v typec)" \
  >   > lost-cc-typec
  $ chmod +x buggy-typec lost-cc-typec
  $ run --typec ./buggy-typec multi | grep -E '^(refused|typec-bug|backend-fail)'
  refused      0
  typec-bug    3
  backend-fail 0
  typec-bug    ok.c: internal error, a bug in typec: Not_found
  typec-bug    bad.c: internal error, a bug in typec: Not_found
  typec-bug    ugly.c: internal error, a bug in typec: Not_found
  $ fails --typec ./lost-cc-typec multi
  corpus: typec -c cannot work in this environment: cannot run the C compiler "no-such-cc": No such file or directory
  [2]

A script that prints a TEST line it cannot count, or that exits with 0
after reporting a failed test, is recorded as failed.

  $ echo 'echo "TEST maybe ok"' > corpus/programs/multi/test.sh
  $ run multi | grep '^tests'
  tests        FAILED: test.sh: not a test result: "TEST maybe ok"
  $ echo 'echo "TEST pass "' > corpus/programs/multi/test.sh
  $ run multi | grep '^tests'
  tests        FAILED: test.sh: not a test result: "TEST pass "
  $ echo 'echo "TEST fail one"' > corpus/programs/multi/test.sh
  $ run multi | grep '^tests'
  tests        FAILED: the script exited with 0 but reported a failed test
  $ rm -r corpus/programs/multi

A recipe that cannot be read ends the run with 2 before anything is
built.

  $ printf 'tree hello-1\nlibrary ../outside.c\n' > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe:2: "../outside.c" is not a relative path inside the tree
  [2]
  $ printf 'tree hello-1\ncflags -O3\n' > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe:2: "-O3": the runner chooses optimisation and debug options
  [2]
  $ printf 'tree hello-1\nprogram a a.c\nprogram a b.c\n' \
  >   > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe:3: a second program "a"; list its units on one line
  [2]
  $ printf 'tree hello-1\n' > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe: no program line
  [2]
  $ printf 'tree hello-1\nprogram a a.c\n' > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe: no test line
  [2]

A test line must say whether its script is the program's own suite, so
the form without it, and a substitute without a description, are
refused.

  $ printf 'tree hello-1\nprogram a a.c\ntest test.sh\n' \
  >   > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe:3: a test line is "test own SCRIPT" or "test substitute SCRIPT DESCRIPTION..."
  [2]
  $ printf 'tree hello-1\nprogram a a.c\ntest substitute test.sh\n' \
  >   > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe:3: wrong number of words after test substitute
  [2]
  $ printf 'tree hello-1\nprogram a a.c\ntest own test.sh extra\n' \
  >   > corpus/programs/hello/recipe
  $ fails hello
  corpus: corpus/programs/hello/recipe:3: wrong number of words after test own
  [2]
  $ printf 'tree missing-1\nprogram a a.c\ntest own t.sh\n' \
  >   > corpus/programs/hello/recipe
  $ fails hello
  corpus: cache/src/missing-1 is missing: fetch the corpus first (fetch.sh)
  [2]
  $ fails ../hello
  corpus: program "../hello" is not a plain name
  [2]
  $ fails --cc /opt/other/clang hello
  corpus: two backends have the same name: clang clang
  [2]
  $ ./corpus.exe --corpus corpus hello
  corpus: usage: corpus.exe --corpus DIR --cache DIR --typec PATH --cc PATH [--cc PATH]... PROGRAM...
  [2]
