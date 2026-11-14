SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The corpus runner builds a program of a fixture corpus with Clang: a
library unit and a program unit, compiled through typec and through the
reference recipe, then linked and tested. The lines that depend on the
host, the backend, the revisions and the timings are left out.

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
  >     --typec "$(command -v typec)" --cc /usr/bin/clang "$@")
  >   status=$?
  >   echo "$out" | grep -v -E '^(host|backend|typec|corpus|log) |^  |^$'
  >   return $status
  > }
  $ run hello
  program      hello
  units        2
  identical    2
  different    0
  failed       0
  linked       1 of 1
  tests        passed
  cpu seconds, summed over the units:

The run record goes into the corpus, under the host; the build tree and
its log go into the cache.

  $ ls corpus/runs/*/
  hello.clang.txt
  $ ls cache/build/*/hello/
  clang
  clang.log
  $ ls cache/build/*/hello/clang/
  bin
  greet.c
  greet.tc
  greet.tc.emit.i
  greet.tc.o
  greet.tc.ref.i
  greet.tc.ref.o
  include
  main.c
  main.tc
  main.tc.emit.i
  main.tc.o
  main.tc.ref.i
  main.tc.ref.o

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
  failed       0
  linked       1 of 1
  tests        FAILED: the tests exited with 5
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
  failed       0
  linked       1 of 1
  tests        substitute passed, not the program's own suite: a greeting smoke test
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

A unit typec refuses keeps the programs that use it from linking, so the
tests do not run, and the runner exits with 1.

  $ printf 'int @;\n' >> cache/src/hello-1/greet.c
  $ run hello
  program      hello
  units        2
  identical    1
  different    0
  failed       1
  linked       0 of 1
  tests        not run: a program did not link
  cpu seconds, summed over the units:
  failed       greet.c: typec -c exited with 1
  not linked   bin/hello
  hello.clang: gates not met
  [1]

A recipe that cannot be read ends the run with 2 before anything is
built.

  $ fails() {
  >   out=$(./corpus.exe --corpus corpus --cache cache \
  >     --typec "$(command -v typec)" --cc /usr/bin/clang "$@" 2>&1)
  >   status=$?
  >   echo "$out" | sed "s|$PWD/||"
  >   return $status
  > }
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
