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

A backend that cannot be started and a --cc= without a path each give one
message.

  $ typec --cc=./no-such-cc -c hello.c
  typec: cannot run the C compiler "./no-such-cc": No such file or directory
  [127]
  $ typec --cc=missing-cc -c hello.c
  typec: cannot run the C compiler "missing-cc": No such file or directory
  [127]
  $ typec --cc=./no-such-cc -c hello.c 2>&-
  [127]
  $ typec --cc= -c hello.c
  typec: --cc= needs the path of a C compiler
  [2]
