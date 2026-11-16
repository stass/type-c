SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A token of moved text keeps its own file and line wherever lowering
writes it, and the flags 3 and 4 of its location (design 13.4), so the
backend reports an error in an instance at the line of its generic's
definition. moved_probe deletes the first external declaration of a
preprocessed unit and writes its tokens in a packing bracket in front
of the last, as lowering writes the definition of a generic in an
instance. The backends are those that backends.sh names, and they
compile the output as typec's compile step does; compile prints the
file and line of each error.

  $ . ./backends.sh
  $ compile() {
  >   cc=$1 file=$2
  >   "$cc" -std=c11 -Wall -Wextra -pedantic-errors -Werror -fsyntax-only \
  >     -x cpp-output "$file" 2>&1 |
  >     grep -o '^[^ :]*:[0-9]*:[0-9]*: error' | cut -d: -f1,2
  > }
  $ unit() {
  >   flags=$1 member=$2
  >   printf '# 1 "user.c"\n# 1 "box.h" 1%s\n' "$flags"
  >   printf 'struct box {\n  int caf\\u00e9;\n  %s;\n};\n' "$member"
  >   printf '# 2 "user.c" 2\nint use;\n'
  > }

The zero-size array on line 3 of box.h, an error under -pedantic-errors,
is reported at that line by both backends, though the text stands after
line 2 of user.c. The identifier that a universal character name spells
is written in UTF-8, which both read as the same identifier.

  $ unit "" "int bad[0]" > user.i
  $ ./moved_probe.exe user.i > user-moved.i
  $ for cc in $clang $gcc; do compile $cc user-moved.i; done
  box.h:3
  box.h:3

Where a marker with flag 3 opened box.h, the moved lines keep the flag,
so the backends exempt them from the warning as from a system header.

  $ unit " 3" "int bad[0]" > system.i
  $ ./moved_probe.exe system.i > system-moved.i
  $ for cc in $clang $gcc; do compile $cc system-moved.i; done

An error that no flag exempts, the array of negative size, is reported
at its own line there too.

  $ unit " 3" "int bad[-1]" > negative.i
  $ ./moved_probe.exe negative.i > negative-moved.i
  $ for cc in $clang $gcc; do compile $cc negative-moved.i; done
  box.h:3
  box.h:3
