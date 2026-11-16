SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Moved text without a bracket, the operand of a try or a copy of a
deferred statement, can hold a #pragma line (design 13.5), which stands
on a line of its own under a marker for its own line (design 13.4), so
the backend reads the pragma where the text is written and reports an
error at the line of its token. moved_pragma_probe deletes the tokens
in front of the last external declaration of a preprocessed unit and
writes them, pragma lines among them, in front of that declaration,
whose marker puts it at line 20. The backends are those that
backends.sh names, and its compile_emitted compiles the output as
typec's compile step does; compile prints the file and line of each
error.

  $ . ./backends.sh
  $ compile() {
  >   compile_emitted "$1" "$2" -std=c11 2>&1 |
  >     grep -o '^[^ :]*:[0-9]*:[0-9]*: error' | cut -d: -f1,2
  > }
  $ unit() {
  >   printf '# 1 "user.c"\n#pragma GCC diagnostic push\n%s\n' "$1"
  >   printf 'int quiet[0];\n#pragma GCC diagnostic pop\nint loud[0];\n'
  >   printf '# 20 "user.c"\nint last;\n'
  > }

The zero-size arrays on lines 3 and 5, errors under -pedantic-errors,
are reported at their lines by both backends, though the text stands
at line 20.

  $ unit "" > plain.i
  $ ./moved_pragma_probe.exe plain.i > plain-moved.i
  $ for cc in $clang $gcc; do compile $cc plain-moved.i; done
  user.c:3
  user.c:5
  user.c:3
  user.c:5

The pragma lines are written as the source wrote them, and the one on
line 2 that ignores -Wpedantic until the pop on line 4 silences the
error on line 3 alone, where the text is moved as where it is not.

  $ unit '#pragma GCC diagnostic ignored "-Wpedantic"' > ignoring.i
  $ ./moved_pragma_probe.exe ignoring.i > ignoring-moved.i
  $ grep '^#pragma' ignoring-moved.i
  #pragma GCC diagnostic push
  #pragma GCC diagnostic ignored "-Wpedantic"
  #pragma GCC diagnostic pop
  $ for cc in $clang $gcc; do compile $cc ignoring.i; done
  user.c:5
  user.c:5
  $ for cc in $clang $gcc; do compile $cc ignoring-moved.i; done
  user.c:5
  user.c:5
