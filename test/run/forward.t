SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec hands every argument to the backend C compiler unchanged and exits
with its status. The caller's environment must not choose the backend.

  $ unset TYPEC_CC

A C program builds through typec with the default backend and runs.

  $ cat > hello.c <<'EOF'
  > #include <stdio.h>
  > int main(void) { puts("hello"); return 0; }
  > EOF
  $ typec -o hello hello.c
  $ ./hello
  hello

The arguments reach the backend as a vector, so no shell expands or splits
them, and --cc= is removed wherever it stands.

  $ typec '[%s]\n' 'two words' --cc=printf '$HOME' '' '*' --cc
  [two words]
  [$HOME]
  []
  [*]
  [--cc]

TYPEC_CC names the backend when --cc= does not.

  $ TYPEC_CC=printf typec '<%s>\n' a
  <a>
  $ TYPEC_CC=false typec --cc=printf '<%s>\n' a
  <a>

The exit status of the backend is the exit status of typec, and a backend
ended by a signal ends typec the same way: the shell reports 128 + 9. The
redirection drops the shell's own notice of the signal, which some shells
print with a pid.

  $ typec --cc=true
  $ typec --cc=false
  [1]
  $ typec --cc=sh -c 'exit 42'
  [42]
  $ { typec --cc=sh -c 'kill -s KILL $$'; } 2>/dev/null
  [137]

A backend that cannot be started, a --cc= without a path and a
--trap-function= that names no C identifier, which would go into the C
text unquoted (design 10.5), each give one message and 81, the status
of typec's environment errors (src/driver/exit_status.ml).

  $ typec --cc=./no-such-cc -c hello.c
  typec: cannot run the C compiler "./no-such-cc": No such file or directory
  [81]
  $ typec --cc=missing-cc -c hello.c
  typec: cannot run the C compiler "missing-cc": No such file or directory
  [81]
  $ typec --cc=./no-such-cc -c hello.c 2>&-
  [81]
  $ typec --cc= -c hello.c
  typec: --cc= needs the path of a C compiler
  [81]
  $ typec --trap-function='stop(); exit' -c hello.c
  typec: --trap-function= needs an ASCII C identifier that does not begin with `__tc_`, not "stop(); exit"
  [81]

A trap function named in typec's reserved space, such as __tc_trap,
which every trap calls, would call itself.

  $ typec --trap-function=__tc_trap -c hello.c
  typec: --trap-function= needs an ASCII C identifier that does not begin with `__tc_`, not "__tc_trap"
  [81]

A C compiler that runs typec again, such as a cc first on PATH that is a
symlink to typec or a script that runs it, would make typec start itself
forever. typec marks the environment of every C compiler it runs, and a
typec that finds the mark refuses with one message and 81, naming the C
compiler and the path that typec was started as, which sed replaces. The
cc here is a script that gives up on its fourth run, so that a typec that
loops fails the test rather than hang it.

  $ mkdir own
  $ cat > own/cc <<'EOF'
  > #!/bin/sh
  > echo run >> runs
  > test "$(wc -l < runs)" -le 3 || exit 99
  > exec typec "$@"
  > EOF
  $ chmod +x own/cc
  $ PATH="$PWD/own:$PATH" typec -c hello.c 2> message
  [81]
  $ sed 's/(".*",/(TYPEC,/' message
  typec: the C compiler "cc" runs typec again (TYPEC, marked by TYPEC_OUTER_CC): name the real C compiler with --cc=PATH or TYPEC_CC

The same holds when typec runs the C compiler as a step of compiling a
.tc input: the step ends with 81, and so does typec.

  $ rm runs
  $ touch empty.tc
  $ PATH="$PWD/own:$PATH" typec -c empty.tc 2> message
  [81]
  $ sed 's/(".*",/(TYPEC,/' message
  typec: the C compiler "cc" runs typec again (TYPEC, marked by TYPEC_OUTER_CC): name the real C compiler with --cc=PATH or TYPEC_CC
