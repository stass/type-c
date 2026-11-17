SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The C comparison catalogue (plan, Stage 1 exit gate 6): each entry
pairs a C program that holds an error with its Type-C counterpart. For
the C program it records, for GCC and for Clang, which warnings
-Wall -Wextra give and which flag outside them would; for the Type-C
program, the name of the rule that refuses it. Each pair also compiles
without the error, warning-free on each backend, so that the refusal
is of the error alone.

c_warnings compiles a C file on each backend with the flags given and
names the warnings it gives, or "silent"; a backend that refuses the
file says so. Where -Wall -Wextra are silent, the entry also tries the
flags outside them that bear on these errors, in $other_warnings. The
warning results are the same on Apple Clang 21, LLVM Clang 22 and 23
and GCC 16, and rest on long-standing defaults: GCC puts
-Wimplicit-fallthrough in -Wextra, Clang in neither -Wall nor -Wextra,
and both warn on a switch on an enumeration that misses an enumerator,
unless it has a default. A backend that changes one of them changes
this record.

  $ . ./backends.sh
  $ other_warnings="-Wswitch-enum -Wimplicit-fallthrough -Wconversion"
  $ c_warnings_on() {
  >   name=$1 cc=$2
  >   shift 2
  >   "$cc" -std=c11 "$@" -c -o c.o 2> c.err || echo "$name refuses"
  >   found=$(grep -o '\[-W[a-z=-]*\]' c.err | sort -u | paste -sd ' ' -)
  >   echo "$name: ${found:-silent}"
  > }
  $ c_warnings() {
  >   c_warnings_on clang "$clang" "$@"
  >   c_warnings_on gcc "$gcc" "$@"
  > }

1. A constructor added without updating every switch or match (design
4.2). A tree of expressions gains the kind Add, which eval does not
handle. A switch on an enumeration without a default is the one form
-Wswitch, in -Wall, catches. A default
in the switch, or a kind field of type int, hides the new kind from
-Wall -Wextra; -Wswitch-enum catches the default form, and nothing
catches the int form.

  $ cat > expr_enum.c <<'EOF'
  > #include <stdlib.h>
  > enum expr_kind {
  >   EXPR_NUMBER,
  >   EXPR_NEG,
  > #ifdef ADDED
  >   EXPR_ADD,
  > #endif
  > };
  > struct expr {
  >   enum expr_kind kind;
  >   long value;
  >   struct expr *left, *right;
  > };
  > long eval(const struct expr *e) {
  >   switch (e->kind) {
  >   case EXPR_NUMBER:
  >     return e->value;
  >   case EXPR_NEG:
  >     return -eval(e->left);
  > #ifdef WITH_DEFAULT
  >   default:
  >     break;
  > #endif
  >   }
  >   abort();
  > }
  > EOF
  $ sed -e 's/^  enum expr_kind kind;/  int kind;/' \
  >   -e 's/^enum expr_kind {/enum {/' expr_enum.c > expr_int.c
  $ c_warnings -Wall -Wextra -DADDED expr_enum.c
  clang: [-Wswitch]
  gcc: [-Wswitch]
  $ c_warnings -Wall -Wextra -DADDED -DWITH_DEFAULT expr_enum.c
  clang: silent
  gcc: silent
  $ c_warnings -Wswitch-enum -DADDED -DWITH_DEFAULT expr_enum.c
  clang: [-Wswitch-enum]
  gcc: [-Wswitch-enum]
  $ c_warnings -Wall -Wextra -Wswitch-enum -DADDED expr_int.c
  clang: silent
  gcc: silent

A match without a default fails at every match that misses the new
constructor. A match with a default hides it, as C's does: the default
covers Add as it covers Neg. Type-C refuses a default that covers no
constructor (match-default), so the vacuous default that C writes "just in
case" cannot be written ahead of a later constructor.

  $ cat > expr.tc <<'EOF'
  > #include <stdlib.h>
  > type expr =
  >     | Number(long value)
  >     | Neg(expr *operand)
  > #ifdef ADDED
  >     | Add(expr *left, expr *right)
  > #endif
  >     ;
  > long eval(const expr *e) {
  >   match (*e) {
  >   case Number(v):
  >     return v;
  > #ifdef WITH_DEFAULT
  >   default:
  >     abort();
  > #else
  >   case Neg(operand):
  >     return -eval(operand);
  > #endif
  > #ifdef VACUOUS_DEFAULT
  >   default:
  >     abort();
  > #endif
  >   }
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for form in -DPLAIN -DWITH_DEFAULT; do
  >     "$cc" -std=c11 -Wall -Wextra -Werror $form -c expr_enum.c -o c.o &&
  >     "$cc" -std=c11 -Wall -Wextra -Werror $form -c expr_int.c -o c.o &&
  >     typec --cc="$cc" -Wall -Wextra -Werror $form -c expr.tc -o tc.o
  >   done
  > done
  $ typec --cc=$clang -DADDED -c expr.tc -o tc.o
  expr.tc:10: error: the match does not cover the constructor 'Add' of the variant 'expr' [match-coverage]
  [80]
  $ typec --cc=$clang -Wall -Wextra -Werror -DADDED -DWITH_DEFAULT \
  >   -c expr.tc -o tc.o
  $ typec --cc=$clang -DVACUOUS_DEFAULT -c expr.tc -o tc.o
  expr.tc:21: error: the `default` of a match covers no constructor [match-default]
  [80]

2. A payload read outside a match (design 3.2 rule 6): under the wrong
tag, or with no tag test at all. C has no warning for either; the read
gives the bytes of another member. Type-C text reaches neither the tag
nor the payload: the wrong-tag form is refused first for naming the
tag's enumerator, which Type-C text cannot use (claimed-name); the access
itself, here in the form without a tag test, is refused as an
operation on a variant (variant-operation).

  $ cat > token.c <<'EOF'
  > enum token_kind { TOKEN_NUMBER, TOKEN_NAME };
  > struct token {
  >   enum token_kind kind;
  >   union {
  >     struct { long value; } number;
  >     struct { const char *text; } name;
  >   } u;
  > };
  > long number_value(struct token t) {
  > #if defined(WRONG_TAG)
  >   if (t.kind == TOKEN_NAME)
  >     return t.u.number.value;
  > #elif defined(NO_TAG_TEST)
  >   return t.u.number.value;
  > #endif
  >   if (t.kind == TOKEN_NUMBER)
  >     return t.u.number.value;
  >   return 0;
  > }
  > EOF
  $ c_warnings -Wall -Wextra $other_warnings -DWRONG_TAG token.c
  clang: silent
  gcc: silent
  $ c_warnings -Wall -Wextra $other_warnings -DNO_TAG_TEST token.c
  clang: silent
  gcc: silent
  $ cat > token.tc <<'EOF'
  > type token = | Number(long value) | Name(const char *text);
  > long number_value(token t) {
  > #if defined(WRONG_TAG)
  >   if (t.tag == token_Name)
  >     return t.u.Number.value;
  > #elif defined(NO_TAG_TEST)
  >   return t.u.Number.value;
  > #endif
  >   match (t) {
  >   case Number(value):
  >     return value;
  >   case Name(_):
  >     return 0;
  >   }
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   "$cc" -std=c11 -Wall -Wextra -Werror -c token.c -o c.o &&
  >   typec --cc="$cc" -Wall -Wextra -Werror -c token.tc -o tc.o
  > done
  $ typec --cc=$clang -DWRONG_TAG -c token.tc -o tc.o
  token.tc:4: error: the enumerator `token_Name` is not available to Type-C text, as a type declaration claims it [claimed-name]
  [80]
  $ typec --cc=$clang -DNO_TAG_TEST -c token.tc -o tc.o
  token.tc:7: error: the variant 'token' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  [80]

3. A missing break at the end of an arm (design 4.3). GCC's -Wextra
gives -Wimplicit-fallthrough; Clang gives it only when asked.

  $ cat > cost.c <<'EOF'
  > enum op_kind { OP_LOAD, OP_ADD };
  > int cost(enum op_kind k, int operands) {
  >   int c = 0;
  >   switch (k) {
  >   case OP_LOAD:
  >     c = 2;
  > #ifndef MISSING_BREAK
  >     break;
  > #endif
  >   case OP_ADD:
  >     c += operands;
  >     break;
  >   }
  >   return c;
  > }
  > EOF
  $ c_warnings -Wall -Wextra -DMISSING_BREAK cost.c
  clang: silent
  gcc: [-Wimplicit-fallthrough=]
  $ c_warnings -Wimplicit-fallthrough -DMISSING_BREAK cost.c
  clang: [-Wimplicit-fallthrough]
  gcc: [-Wimplicit-fallthrough=]
  $ cat > cost.tc <<'EOF'
  > type op = | Load(int address) | Add(int operands);
  > int cost(op o) {
  >   int c = 0;
  >   match (o) {
  >   case Load(_):
  >     c = 2;
  > #ifndef MISSING_BREAK
  >     break;
  > #endif
  >   case Add(operands):
  >     c += operands;
  >     break;
  >   }
  >   return c;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   "$cc" -std=c11 -Wall -Wextra -Werror -c cost.c -o c.o &&
  >   typec --cc="$cc" -Wall -Wextra -Werror -c cost.tc -o tc.o
  > done
  $ typec --cc=$clang -DMISSING_BREAK -c cost.tc -o tc.o
  cost.tc:5: error: the end of the match arm can be reached [match-arm-end]
  [80]

4. A value of one distinct type used as another or as its
representation, and an operator that design 3.4 does not allow on it.
In C the ids are typedefs of one type, so no warning applies, not even
-Wconversion. A structure of one member for each id would catch all
three, but it also refuses the operators that design 3.4 allows on a
distinct type, such as == and a truth test. Type-C refuses the implicit
conversions (distinct-conversion) and the operator (distinct-operation).

  $ cat > ids.c <<'EOF'
  > typedef unsigned user_id;
  > typedef unsigned group_id;
  > int member(user_id u, group_id g);
  > int may_read(user_id u, group_id g) {
  > #if defined(SWAPPED)
  >   return member(g, u);
  > #elif defined(RAW)
  >   unsigned slot = u;
  >   return slot < 16 && member(u, g);
  > #elif defined(PRODUCT)
  >   return member(u * 2, g);
  > #else
  >   return member(u, g);
  > #endif
  > }
  > EOF
  $ for error in SWAPPED RAW PRODUCT; do
  >   echo "$error"
  >   c_warnings -Wall -Wextra $other_warnings -D$error ids.c
  > done
  SWAPPED
  clang: silent
  gcc: silent
  RAW
  clang: silent
  gcc: silent
  PRODUCT
  clang: silent
  gcc: silent
  $ sed 's/^typedef unsigned \(.*\);/type \1 = distinct unsigned;/' \
  >   ids.c > ids.tc
  $ for cc in "$clang" "$gcc"; do
  >   "$cc" -std=c11 -Wall -Wextra -Werror -c ids.c -o c.o &&
  >   typec --cc="$cc" -Wall -Wextra -Werror -c ids.tc -o tc.o
  > done
  $ typec --cc=$clang -DSWAPPED -c ids.tc -o tc.o
  ids.tc:6: error: a value of type 'group_id' does not convert to 'user_id' without a cast [distinct-conversion]
  [80]
  $ typec --cc=$clang -DRAW -c ids.tc -o tc.o
  ids.tc:8: error: a value of type 'user_id' does not convert to 'unsigned int' without a cast [distinct-conversion]
  [80]
  $ typec --cc=$clang -DPRODUCT -c ids.tc -o tc.o
  ids.tc:11: error: a value of the distinct type 'user_id' takes no such operation; a cast to its underlying type crosses to it [distinct-operation]
  [80]

5. A private value made outside its owner (design 9.2). A C module that
passes its values by value must show their layout in its header, and
then any file can build one, as a compound literal does here. An
opaque structure would stop it, at the cost of passing by value. In
Type-C a private variant shows its constructors to every file but lets
only its owner build them: a second Type-C file is refused (private-creation),
apart from the zero value {0}. The rule is between Type-C files; a C
file reads and writes the layout of design 10.1 as C does, and the
owner builds the values, which private.t shows.

  $ mkdir include
  $ cat > include/insn.h <<'EOF'
  > enum insn_kind { INSN_MOVE, INSN_HALT };
  > struct insn {
  >   enum insn_kind kind;
  >   union { struct { int dst, src; } move; } u;
  > };
  > struct insn insn_move(int dst, int src);
  > EOF
  $ cat > forge.c <<'EOF'
  > #include "insn.h"
  > struct insn first(void) {
  > #ifdef FORGED
  >   return (struct insn){ INSN_MOVE, { .move = { 1, 2 } } };
  > #else
  >   return insn_move(1, 2);
  > #endif
  > }
  > struct insn none(void) { return (struct insn){0}; }
  > EOF
  $ c_warnings -Wall -Wextra $other_warnings -Iinclude -DFORGED forge.c
  clang: silent
  gcc: silent
  $ cat > include/insn.tci <<'EOF'
  > type insn = private
  >     | Move(int dst, int src)
  >     | Halt;
  > insn insn_move(int dst, int src);
  > EOF
  $ cat > forge.tc <<'EOF'
  > #include "insn.tci"
  > insn first(void) {
  > #ifdef FORGED
  >   return Move(1, 2);
  > #else
  >   return insn_move(1, 2);
  > #endif
  > }
  > insn none(void) { return (insn){0}; }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   "$cc" -std=c11 -Wall -Wextra -Werror -Iinclude -c forge.c -o c.o &&
  >   typec --cc="$cc" -Wall -Wextra -Werror -Iinclude -c forge.tc -o tc.o
  > done
  $ typec --cc=$clang -Iinclude -DFORGED -c forge.tc -o tc.o
  forge.tc:4: error: the variant 'insn' is private to 'include/insn.tci', so only the text of its owner creates its values [private-creation]
  [80]

6. An invalid tag, made by a cast or through a union (design 4.5). C
compiles both without a warning and reads the value as the member its
default assumes: the circle's radius as a square's side. Only
-Wswitch-enum warns, on the default that stands in for SHAPE_SQUARE; no
warning names the cast or the union. Through the
union, C leaves the bytes past the member written unspecified; GCC and
Clang keep them, so the radius survives. The Type-C program traps at
run time on each backend, as it would in a match with a default
(matches.t); this entry checks the trap in place of a diagnostic. The
runs print Clang's lines first, then GCC's. Each program flushes its
output before the corruption, which would otherwise be lost or kept
with the buffering of each libc.

  $ cat > area.c <<'EOF'
  > #include <stdio.h>
  > enum shape_kind { SHAPE_CIRCLE, SHAPE_SQUARE };
  > struct shape {
  >   enum shape_kind kind;
  >   union {
  >     struct { double radius; } circle;
  >     struct { double side; } square;
  >   } u;
  > };
  > union pun { struct shape s; int raw; };
  > static double area(struct shape s) {
  >   switch (s.kind) {
  >   case SHAPE_CIRCLE:
  >     return 3 * s.u.circle.radius * s.u.circle.radius;
  >   default:
  >     return s.u.square.side * s.u.square.side;
  >   }
  > }
  > int main(int argc, char **argv) {
  >   struct shape s = { SHAPE_CIRCLE, { .circle = { 2 } } };
  >   printf("%g\n", area(s));
  >   fflush(stdout);
  >   if (argc > 1 && argv[1][0] == 'c')
  >     s.kind = (enum shape_kind)7;
  >   if (argc > 1 && argv[1][0] == 'u') {
  >     union pun p;
  >     p.s = s;
  >     p.raw = 7;
  >     s = p.s;
  >   }
  >   printf("%g\n", area(s));
  >   return 0;
  > }
  > EOF
  $ c_warnings -Wall -Wextra $other_warnings area.c
  clang: [-Wswitch-enum]
  gcc: [-Wswitch-enum]
  $ for cc in "$clang" "$gcc"; do
  >   "$cc" -std=c11 -Wall -Wextra -Werror -o area area.c &&
  >   ./area cast && ./area union
  > done
  12
  4
  12
  4
  12
  4
  12
  4

The Type-C program makes the invalid tag in Type-C text, which casts and
unions reach as they do in C (4.5). Both write an int over the tag,
which the layout of design 10.1 puts first and gives the size of an
int. The trap leaves no core file behind.

  $ cat > area.tc <<'EOF'
  > #include <stdio.h>
  > type shape = | Circle(double radius) | Square(double side);
  > union pun { shape s; int raw; };
  > static double area(shape s) {
  >   match (s) {
  >   case Circle(radius):
  >     return 3 * radius * radius;
  >   case Square(side):
  >     return side * side;
  >   }
  > }
  > int main(int argc, char **argv) {
  >   shape s = Circle(2);
  >   printf("%g\n", area(s));
  >   fflush(stdout);
  >   if (argc > 1 && argv[1][0] == 'c')
  >     *(int *)&s = 7;
  >   if (argc > 1 && argv[1][0] == 'u') {
  >     union pun p;
  >     p.s = s;
  >     p.raw = 7;
  >     s = p.s;
  >   }
  >   printf("%g\n", area(s));
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -Wall -Wextra -Werror -o area area.tc && ./area &&
  >   for how in cast union; do
  >     sh -c "ulimit -c 0; ./area $how; exit \$?" 2>/dev/null
  >     test $? -gt 128 && echo "$how trapped"
  >   done
  > done
  12
  12
  12
  cast trapped
  12
  union trapped
  12
  12
  12
  cast trapped
  12
  union trapped
