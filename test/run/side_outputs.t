SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A command that compiles a .tc input and links leaves the side outputs
that the backend leaves for a one-step build of the same C input, named
as the backend names them there: on macOS the .dSYM bundle of -g, the
.dwo files of -gsplit-dwarf where the target has them, the stack usage
of -fstack-usage and GCC's call graph of -fcallgraph-info. Each case
builds a.c with the backend and a.tc, the same text, with typec, each in
a directory of its own, and compares the files that the two leave. What
they print is not compared: GCC prints a note for each step of typec
that gets -gsplit-dwarf on a target without split debug information.

  $ unset TYPEC_CC
  $ . ./backends.sh
  $ mkdir tmp
  $ export TMPDIR=$PWD/tmp
  $ cat > a.c <<'EOF'
  > int f(int x) { return x + 1; }
  > int main(void) { return f(-1); }
  > EOF
  $ files() {
  >   (cd "$1" && find . ! -name a.c ! -name a.tc | sort)
  > }
  $ same_outputs() {
  >   backend=$1
  >   shift
  >   rm -rf one two
  >   mkdir one one/out two two/out
  >   cp a.c one/a.c
  >   cp a.c two/a.tc
  >   (cd one && "$backend" "$@" a.c 2>/dev/null) || echo backend failed
  >   (cd two && typec --cc="$backend" "$@" a.tc 2>/dev/null) ||
  >     echo typec failed
  >   files one > one.files
  >   files two > two.files
  >   diff one.files two.files
  > }

The backends name the side outputs after the output, and GCC also after
the input when the output has another name.

  $ same_outputs $clang -g -o a
  $ same_outputs $gcc -g -o a
  $ same_outputs $clang -g -fstack-usage -o out/prog
  $ same_outputs $gcc -g -fstack-usage -o out/prog
  $ same_outputs $gcc -fstack-usage -fcallgraph-info -o a
  $ same_outputs $clang -g -gsplit-dwarf -o out/prog
  $ same_outputs $gcc -g -gsplit-dwarf -o out/prog

typec leaves nothing in TMPDIR.

  $ ls -A tmp
