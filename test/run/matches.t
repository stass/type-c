SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type-C code matches variants that constructors build, reading the
bindings of each arm, on each backend (design 4); a binding is a copy,
which assigning to the scrutinee in its arm leaves unchanged (4.1 rule
7). A value whose tag is
none of its constructors, which only code that writes the bytes of the
object can make, here C code, traps in every match, also in one with a
default (design 4.5, 10.5): the program stops on a signal. It flushes
its output before the corruption, which would otherwise be lost or kept
with the buffering of each libc.

  $ . ./backends.sh

  $ cat > corrupt.h <<'EOF'
  > static void corrupt(expr *e) { e->tag = (enum expr_tag)7; }
  > EOF
  $ cat > eval.tc <<'EOF'
  > #include <stdio.h>
  > type expr =
  >     | Number(long value)
  >     | Nil
  >     | Add(expr *left, expr *right);
  > #include "corrupt.h"
  > static long eval(const expr *e) {
  >   match (*e) {
  >   case Number(n):
  >     return n;
  >   case Nil:
  >     return 0;
  >   case Add(left, right):
  >     return eval(left) + eval(right);
  >   }
  > }
  > static expr made(int n) { return n ? Number(n) : Nil; }
  > static long reassigned(expr *e) {
  >   match (*e) {
  >   case Number(n):
  >     *e = Nil;
  >     return n;
  >   default:
  >     return -1;
  >   }
  > }
  > static int cost(expr e) {
  >   int c = 0;
  >   match (e) {
  >   case Number(_):
  >   case Nil:
  >     c = 1;
  >     break;
  >   default:
  >     c = 3;
  >     break;
  >   }
  >   return c;
  > }
  > int main(int argc, char **argv) {
  >   expr one = Number(1), two = Number(2), nil = Nil;
  >   expr sum = Add(&one, &two);
  >   long total = 0;
  >   for (int i = 0; i < 4; i++) {
  >     match (made(i)) {
  >     case Number(n):
  >       if (n == 2)
  >         continue;
  >       total += n;
  >       break;
  >     default:
  >       total += 100;
  >       break;
  >     }
  >   }
  >   printf("%ld %d %d %ld %ld\n", eval(&sum), cost(sum), cost(nil),
  >          eval(&nil), total);
  >   expr r = Number(9);
  >   long kept = reassigned(&r);
  >   printf("%ld %ld\n", kept, eval(&r));
  >   if (argc > 1) {
  >     fflush(stdout);
  >     corrupt(&sum);
  >     printf("%d\n", argv[1][0] == 'd' ? cost(sum) : (int)eval(&sum));
  >   }
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -Werror -o clang-eval eval.tc
  $ ./clang-eval
  3 3 1 0 104
  9 0
  $ sh -c './clang-eval match; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 3 1 0 104
  9 0
  trapped
  $ sh -c './clang-eval default; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 3 1 0 104
  9 0
  trapped
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-eval eval.tc
  $ ./gcc-eval
  3 3 1 0 104
  9 0
  $ sh -c './gcc-eval match; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 3 1 0 104
  9 0
  trapped
  $ sh -c './gcc-eval default; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 3 1 0 104
  9 0
  trapped

An arm ends where the rules of design 4.4 say its end is unreachable: in
a goto within the arm or out of the match, in a loop that never ends
but by a return, in a call to a function that does not return (4.3).
The program compiles without a warning and runs on each backend.

  $ cat > exits.tc <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > type step = | Repeat(int times) | Stop | Fail;
  > static _Noreturn void fail(void) { abort(); }
  > static int run(step s) {
  >   int count = 0;
  >   match (s) {
  >   case Repeat(times):
  >   again:
  >     count++;
  >     if (count < times)
  >       goto again;
  >     goto done;
  >   case Stop:
  >     for (;;)
  >       return -1;
  >   case Fail:
  >     fail();
  >   }
  > done:
  >   return count;
  > }
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   printf("%d %d\n", run(Repeat(3)), run(Stop));
  >   return argc > 1 ? run(Fail) : 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -Werror -o clang-exits exits.tc
  $ ./clang-exits
  3 -1
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-exits exits.tc
  $ ./gcc-exits
  3 -1

A goto to a label in a block, or a case label in a block that the
switch around it jumps to, reaches the end of that block, so the arm
ends in the break that the rules then ask for (4.4). Each program takes
that path and leaves the match by the break, not by the trap.

  $ cat > contained.tc <<'EOF'
  > #include <stdio.h>
  > type e = | A | B;
  > static int jumps(e v, int n) {
  >   match (v) {
  >   case A:
  >     if (n)
  >       goto inside;
  >     return 0;
  >     {
  >     inside:
  >       n++;
  >     }
  >     break;
  >   case B:
  >     return -1;
  >   }
  >   return n;
  > }
  > static int sections(e v, int n) {
  >   match (v) {
  >   case A:
  >     switch (n) {
  >     default:
  >       return 1;
  >       {
  >       case 2:
  >         ;
  >       }
  >     }
  >     break;
  >   case B:
  >     return -1;
  >   }
  >   return n + 10;
  > }
  > int main(void) {
  >   printf("%d %d %d %d\n", jumps(A, 0), jumps(A, 4), sections(A, 0),
  >          sections(A, 2));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -Werror -o clang-contained contained.tc
  $ ./clang-contained
  0 5 1 12
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-contained contained.tc
  $ ./gcc-contained
  0 5 1 12

A binding is a copy of its field, taken where the arm is entered
(design 4.1 rules 4 and 7): an assignment to the scrutinee by its name
inside the arm leaves the bindings unchanged, and a match of the
scrutinee after it sees the new value. A declaration in a block inside
the arm hides a binding there. The bindings of an outer arm are visible
in an inner match, one of them as its scrutinee. A scrutinee declared
register, a parameter or an object in a block, is copied (13.5). The
program compiles with -std=c11 -pedantic-errors on each backend.

  $ cat > copies.tc <<'EOF'
  > #include <stdio.h>
  > type shape = | Circle(int r) | Rect(int w, int h);
  > type box = | Empty | Wrap(shape inner, int scale);
  > static int area(shape s) {
  >   match (s) {
  >   case Rect(w, h):
  >     s = Circle(1);
  >     int hidden;
  >     {
  >       int w = 100;
  >       hidden = w;
  >     }
  >     match (s) {
  >     case Circle(r):
  >       return w * h + r + hidden;
  >     default:
  >       return -1;
  >     }
  >   case Circle(r):
  >     return 3 * r * r;
  >   }
  > }
  > static int scaled(register box b) {
  >   match (b) {
  >   case Wrap(inner, scale):
  >     match (inner) {
  >     case Circle(r):
  >       return scale * r;
  >     case Rect(w, h):
  >       return scale * w * h;
  >     }
  >   case Empty:
  >     return 0;
  >   }
  > }
  > int main(void) {
  >   register shape r = Rect(2, 3);
  >   int seen = 0;
  >   match (r) {
  >   case Rect(w, h):
  >     r = Circle(w);
  >     seen = w + h;
  >     break;
  >   default:
  >     break;
  >   }
  >   printf("%d %d %d %d %d\n", area(Rect(2, 3)), area(Circle(2)), seen,
  >          scaled(Wrap(Circle(4), 5)), scaled(Wrap(Rect(2, 3), 2)));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -std=c11 -pedantic-errors -Wall -Wextra -Werror \
  >   -o clang-copies copies.tc
  $ ./clang-copies
  107 12 5 20 12
  $ typec --cc=$gcc -std=c11 -pedantic-errors -Wall -Wextra -Werror \
  >   -o gcc-copies copies.tc
  $ ./gcc-copies
  107 12 5 20 12
