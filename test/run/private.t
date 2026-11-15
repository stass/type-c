SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A private variant and a private distinct type, declared in an interface
`ir.tci` that `#include` reads, are built in their owner `ir.tc` (design
9.2), matched in a second Type-C file that reaches them through the
functions of the interface, and read from a C file that declares the
layout of design 10.1 by hand (10.6, plan 1.7 exit gate 3), on each
backend.

  $ . ./backends.sh

  $ mkdir include src
  $ cat > include/ir.tci <<'EOF'
  > type instruction = private
  >     | Move(int dst, int src)
  >     | Halt;
  > type symbol = private distinct unsigned;
  > #define MOVE(d, s) Move(d, s)
  > instruction make_move(int dst, int src);
  > instruction make_halt(void);
  > symbol intern(unsigned n);
  > EOF
  $ cat > src/ir.tc <<'EOF'
  > #include "ir.tci"
  > instruction make_move(int dst, int src) { return MOVE(dst, src); }
  > instruction make_halt(void) { return instruction.Halt; }
  > symbol intern(unsigned n) { return (symbol)(n * 2); }
  > EOF
  $ cat > src/client.tc <<'EOF'
  > #include <stdio.h>
  > #include "ir.tci"
  > int c_destination(instruction i);
  > static int destination(instruction i) {
  >   match (i) {
  >   case Move(d, _):
  >     return d;
  >   case Halt:
  >     return -1;
  >   }
  > }
  > int main(void) {
  >   instruction zero = {0};
  >   printf("%d %d %d %u %d\n", destination(make_move(3, 4)),
  >          destination(make_halt()), c_destination(make_move(5, 6)),
  >          (unsigned)intern(21), destination(zero));
  >   return 0;
  > }
  > EOF
  $ cat > src/reader.c <<'EOF'
  > enum instruction_tag { instruction_Move, instruction_Halt };
  > struct instruction {
  >   enum instruction_tag tag;
  >   union { struct { int dst; int src; } Move; } u;
  > };
  > int c_destination(struct instruction i) {
  >   return i.tag == instruction_Move ? i.u.Move.dst : -1;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -Wall -Wextra -Werror -Iinclude -o prog \
  >     src/ir.tc src/client.tc src/reader.c && ./prog
  > done
  3 -1 5 42 0
  3 -1 5 42 0

A client builds neither: not through a constructor, nor through a macro
of the interface, whose tokens belong to the client's text (9.2 rule 3),
nor through a cast. typec refuses it with status 80.

  $ cat > src/forger.tc <<'EOF'
  > #include "ir.tci"
  > instruction forged(void) { return MOVE(1, 2); }
  > EOF
  $ typec --cc=$clang -Iinclude -c src/forger.tc -o forger.o
  typec: src/forger.tc:2: the variant 'instruction' is private to 'include/ir.tci', so only the text of its owner creates its values (design 9.2 rule 1) [TC0013]
  [80]
  $ printf '#include "ir.tci"\nsymbol s(void) { return (symbol)1; }\n' \
  >   > src/caster.tc
  $ typec --cc=$gcc -Iinclude -c src/caster.tc -o caster.o
  typec: src/caster.tc:2: the distinct type 'symbol' is private to 'include/ir.tci', so only the text of its owner creates its values (design 9.2 rule 1) [TC0013]
  [80]
