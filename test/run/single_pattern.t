SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type-C code asks with single-pattern tests whether a variant holds one
constructor and reads its bindings, on each backend (design 4.6): an if
test with and without an else, a while test whose bindings are made anew
for each iteration, break and continue in the controlled statement as in
C, a nested block that hides a binding, and a jump from a statement
expression in the operand, which in an if goes to the loop around it and
in a while leaves that while (4.4). A value whose tag is none of its
constructors, here written by C code, traps and does not fail the test
(4.5, 10.5): the program stops on a signal. It flushes its output first.

  $ . ./backends.sh

  $ cat > corrupt.h <<'EOF'
  > static void corrupt(list *l) { l->tag = (enum list_tag)7; }
  > EOF
  $ cat > lists.tc <<'EOF'
  > #include <stdio.h>
  > type list = | Nil | Cons(long head, list *tail);
  > #include "corrupt.h"
  > static long sum(const list *l) {
  >   long total = 0;
  >   while (case Cons(head, tail) = *l) {
  >     total += head;
  >     l = tail;
  >   }
  >   return total;
  > }
  > static long first(const list *l) {
  >   if (case Cons(head, _) = *l) {
  >     {
  >       long head = 100;
  >       (void)head;
  >     }
  >     return head;
  >   } else
  >     return -1;
  > }
  > static long even_until_negative(const list *l) {
  >   long total = 0;
  >   while (case Cons(head, tail) = *l) {
  >     l = tail;
  >     if (head < 0)
  >       break;
  >     if (head % 2)
  >       continue;
  >     total += head;
  >   }
  >   return total;
  > }
  > static int until_nil(const list *items, int n) {
  >   int i;
  >   for (i = 0; i < n; i++)
  >     if (case Nil = items[i])
  >       break;
  >   return i;
  > }
  > static long heads_after_first(const list *items, int n) {
  >   long total = 0;
  >   for (int i = 0; i < n; i++) {
  >     if (case Cons(head, _) = ({ if (i == 0) continue; items[i]; }))
  >       total += head;
  >     else
  >       total += 100;
  >   }
  >   return total;
  > }
  > static long sum_below(const list *l, long limit) {
  >   long total = 0;
  >   while (case Cons(head, tail) = ({ if (total >= limit) break; *l; })) {
  >     total += head;
  >     l = tail;
  >   }
  >   return total;
  > }
  > int main(int argc, char **argv) {
  >   list nil = Nil, two = Cons(2, &nil), one = Cons(1, &two);
  >   list minus = Cons(-5, &one), three = Cons(3, &minus);
  >   list four = Cons(4, &three);
  >   list items[3] = { Cons(1, &nil), Nil, Cons(2, &nil) };
  >   printf("%ld %ld %ld\n", sum(&one), first(&one), first(&nil));
  >   printf("%ld %d %ld %ld\n", even_until_negative(&four),
  >          until_nil(items, 3), heads_after_first(items, 3),
  >          sum_below(&four, 5));
  >   if (argc > 1) {
  >     fflush(stdout);
  >     corrupt(&two);
  >     printf("%ld\n", argv[1][0] == 'w' ? sum(&one) : first(&two));
  >   }
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -Werror -o clang-lists lists.tc
  $ ./clang-lists
  3 1 -1
  4 1 102 7
  $ sh -c './clang-lists while; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 1 -1
  4 1 102 7
  trapped
  $ sh -c './clang-lists if; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 1 -1
  4 1 102 7
  trapped
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-lists lists.tc
  $ ./gcc-lists
  3 1 -1
  4 1 102 7
  $ sh -c './gcc-lists while; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 1 -1
  4 1 102 7
  trapped
  $ sh -c './gcc-lists if; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  3 1 -1
  4 1 102 7
  trapped
