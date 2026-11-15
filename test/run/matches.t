SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type-C code matches variants that constructors build, reading the
bindings of each arm, on each backend (design 4); a binding is a copy,
which assigning to the scrutinee in its arm leaves unchanged (4.1 rule
7). A value whose tag is
none of its constructors, which only code that writes the bytes of the
object can make, here C code, traps in every match, also in one with a
default (design 4.5, 10.5): the program stops on a signal.

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
  trapped
  $ sh -c './clang-eval default; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  trapped
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-eval eval.tc
  $ ./gcc-eval
  3 3 1 0 104
  9 0
  $ sh -c './gcc-eval match; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  trapped
  $ sh -c './gcc-eval default; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  trapped
