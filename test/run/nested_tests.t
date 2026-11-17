SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Single-pattern tests with nested patterns (design 4.6, 4.7 rule 9,
13.5) and their hand-written twin, a switch on each tag nested in a
switch on the tag around it, give the same output on each backend at
-O0 and -O2 under -pedantic-errors, AddressSanitizer and
UndefinedBehaviorSanitizer. The programs cover an if test on a field
of variant type, a while test that follows a pointer, field lists left
out at depth, the jumps of 4.6 rule 5 in the statement of a while test,
and an operand with a side effect, which a test evaluates once each
time its condition is evaluated.

  $ . ./backends.sh
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror -g"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $ cat > main.h <<'EOF'
  > int main(void) {
  >   res ok = make_ok(4), zero = make_err(0), over = make_err(1);
  >   expr two = make_num(2), three = make_num(3);
  >   expr sum = make_add(&two, &three), nested = make_add(&sum, &three);
  >   list nil = make_nil(), one = make_cons(1, &nil);
  >   list two_items = make_cons(2, &one), three_items = make_cons(3, &two_items);
  >   printf("divides %d %d %d\n", divides(ok), divides(zero), divides(over));
  >   printf("calls %d\n", calls);
  >   printf("total %d %d\n", total(&nil), total(&three_items));
  >   printf("calls %d\n", calls);
  >   printf("numbers %d %d %d\n", numbers(&two), numbers(&sum),
  >          numbers(&nested));
  >   printf("until %d %d\n", until(&three_items, 2), until(&three_items, 0));
  >   printf("odd %d\n", odd(&three_items));
  >   return 0;
  > }
  > EOF

The Type-C program.

  $ cat > tests.tc <<'EOF'
  > #include <stdio.h>
  > type eval_error = | DivByZero | Overflow;
  > type res = | Ok(int value) | Err(eval_error error);
  > type expr = | Num(int value) | Add(const expr *l, const expr *r);
  > type list = | Nil | Cons(int head, const list *tail);
  > type cursor = | At(const list *at);
  > static int calls;
  > static res counted(res r) { calls++; return r; }
  > static cursor step(cursor c) { calls++; return c; }
  > static res make_ok(int v) { return Ok(v); }
  > static res make_err(int overflow) {
  >   if (overflow)
  >     return Err(Overflow);
  >   return Err(DivByZero);
  > }
  > static expr make_num(int v) { return Num(v); }
  > static expr make_add(const expr *l, const expr *r) { return Add(l, r); }
  > static list make_nil(void) { return Nil; }
  > static list make_cons(int h, const list *t) { return Cons(h, t); }
  > static int divides(res r) {
  >   if (case Err(DivByZero) = counted(r))
  >     return 1;
  >   else
  >     return 0;
  > }
  > static int total(const list *l) {
  >   int sum = 0;
  >   cursor c = At(l);
  >   while (case At(*Cons(h, t)) = step(c)) {
  >     sum += h;
  >     c = At(t);
  >   }
  >   return sum;
  > }
  > static int numbers(const expr *e) {
  >   if (case Add(*Num, *Num) = *e)
  >     return 2;
  >   if (case Add(*Add, _) = *e)
  >     return 1;
  >   return 0;
  > }
  > static int until(const list *l, int stop) {
  >   int sum = 0;
  >   cursor c = At(l);
  >   while (case At(*Cons(h, t)) = c) {
  >     c = At(t);
  >     if (h == stop)
  >       break;
  >     sum += h;
  >   }
  >   return sum;
  > }
  > static int odd(const list *l) {
  >   int sum = 0;
  >   cursor c = At(l);
  >   while (case At(*Cons(h, t)) = c) {
  >     c = At(t);
  >     if (h % 2 == 0)
  >       continue;
  >     sum += h;
  >   }
  >   return sum;
  > }
  > #include "main.h"
  > EOF

The twin, a tagged structure read by nested switches.

  $ cat > tests.c <<'EOF'
  > #include <stdio.h>
  > enum eval_error_tag { DivByZero, Overflow };
  > typedef struct { enum eval_error_tag tag; } eval_error;
  > typedef struct {
  >   enum { Ok, Err } tag;
  >   union { struct { int value; } Ok; struct { eval_error error; } Err; } u;
  > } res;
  > typedef struct expr expr;
  > struct expr {
  >   enum { Num, Add } tag;
  >   union { int value; struct { const expr *l, *r; } add; } u;
  > };
  > typedef struct list list;
  > struct list {
  >   enum { Nil, Cons } tag;
  >   struct { int head; const list *tail; } cons;
  > };
  > typedef struct { const list *at; } cursor;
  > static int calls;
  > static res counted(res r) { calls++; return r; }
  > static cursor step(cursor c) { calls++; return c; }
  > static res make_ok(int v) { res r = { Ok, { { v } } }; return r; }
  > static res make_err(int overflow) {
  >   res r = { Err, { { 0 } } };
  >   r.u.Err.error.tag = overflow ? Overflow : DivByZero;
  >   return r;
  > }
  > static expr make_num(int v) { expr e = { Num, { v } }; return e; }
  > static expr make_add(const expr *l, const expr *r) {
  >   expr e = { Add, { 0 } };
  >   e.u.add.l = l;
  >   e.u.add.r = r;
  >   return e;
  > }
  > static list make_nil(void) { list l = { Nil, { 0, 0 } }; return l; }
  > static list make_cons(int h, const list *t) {
  >   list l = { Cons, { h, t } };
  >   return l;
  > }
  > static int divides(res r) {
  >   res held = counted(r);
  >   switch (held.tag) {
  >   case Err:
  >     switch (held.u.Err.error.tag) {
  >     case DivByZero: return 1;
  >     case Overflow: return 0;
  >     }
  >     break;
  >   case Ok: return 0;
  >   }
  >   return -100;
  > }
  > static int total(const list *l) {
  >   int sum = 0;
  >   cursor c = { l };
  >   for (;;) {
  >     cursor held = step(c);
  >     if (held.at->tag != Cons)
  >       break;
  >     sum += held.at->cons.head;
  >     c.at = held.at->cons.tail;
  >   }
  >   return sum;
  > }
  > static int numbers(const expr *e) {
  >   if (e->tag == Add && e->u.add.l->tag == Num && e->u.add.r->tag == Num)
  >     return 2;
  >   if (e->tag == Add && e->u.add.l->tag == Add)
  >     return 1;
  >   return 0;
  > }
  > static int until(const list *l, int stop) {
  >   int sum = 0;
  >   while (l->tag == Cons) {
  >     int h = l->cons.head;
  >     l = l->cons.tail;
  >     if (h == stop)
  >       break;
  >     sum += h;
  >   }
  >   return sum;
  > }
  > static int odd(const list *l) {
  >   int sum = 0;
  >   while (l->tag == Cons) {
  >     int h = l->cons.head;
  >     l = l->cons.tail;
  >     if (h % 2 == 0)
  >       continue;
  >     sum += h;
  >   }
  >   return sum;
  > }
  > #include "main.h"
  > EOF

Each program prints the same lines.

  $ for cc in "$clang" "$gcc"; do
  >   for opt in -O0 -O2; do
  >     typec --cc="$cc" $opt $flags $sanitize -o tests-tc tests.tc &&
  >     "$cc" $opt $flags $sanitize -o tests-c tests.c || exit 1
  >     ./tests-tc > tests-tc.out
  >     ./tests-c > tests-c.out
  >     cmp tests-tc.out tests-c.out || echo "$cc $opt differs"
  >   done
  > done
  $ cat tests-tc.out
  divides 0 1 0
  calls 3
  total 0 6
  calls 8
  numbers 0 2 1
  until 3 6
  odd 4

The partner of the count: the lowered text with the operand written
again where the tree of `divides` reads its second tag evaluates it
twice for an `Err`, and counts five calls where the test counts three.

  $ typec --cc="$clang" --emit-c tests.tc > tests-lowered.c
  $ sed 's/__tc_match->u\.Err\.error\.tag/(counted(r)).u.Err.error.tag/' \
  >   tests-lowered.c > twice.c
  $ cmp -s tests-lowered.c twice.c || echo rewritten
  rewritten
  $ "$clang" -std=c11 -w -o twice twice.c && ./twice | sed -n 2p
  calls 5

A test traps where a match would (4.6 rule 3, 4.5): a tag below the
pattern that is no constructor's traps in a test that names a
constructor there, where a flat test that binds the field runs its
statement; and selection stops at the first tag that holds another
constructor, so a null pointer under a constructor that the test gives
up is never followed, where one under the constructor that it asks for
is, and the address sanitizer stops the program.

  $ cat > corrupt.h <<'EOF'
  > static void corrupt(res *r) { r->u.Err.error.tag = (enum eval_error_tag)7; }
  > EOF
  $ cat > trap.tc <<'EOF'
  > #include <stdio.h>
  > type eval_error = | DivByZero | Overflow;
  > type res = | Ok(int value) | Err(eval_error error);
  > type tree = | Leaf(int value) | Node(const tree *l, const tree *r);
  > type side = | Left | Right;
  > type pair = | Pair(side s, const tree *t);
  > #include "corrupt.h"
  > int main(int argc, char **argv) {
  >   res r = Err(Overflow);
  >   pair right = Pair(Right, 0), left = Pair(Left, 0);
  >   if (case Pair(Left, *Leaf(n)) = right)
  >     printf("leaf %d\n", n);
  >   else
  >     printf("given up\n");
  >   fflush(stdout);
  >   if (argc > 1 && argv[1][0] == 'n') {
  >     if (case Pair(Left, *Leaf) = left)
  >       printf("followed\n");
  >     return 0;
  >   }
  >   corrupt(&r);
  >   if (case Err(eval_error e) = r) {
  >     (void)e;
  >     printf("bound\n");
  >   }
  >   fflush(stdout);
  >   if (case Err(DivByZero) = r)
  >     printf("selected\n");
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for opt in -O0 -O2; do
  >     typec --cc="$cc" $opt $flags $sanitize -o trap trap.tc || exit 1
  >     sh -c "./trap; exit \$?" 2> /dev/null
  >     test $? -gt 128 && echo trapped
  >     sh -c "./trap null; exit \$?" 2> trap.null
  >     grep -q 'runtime error: member access within null pointer' trap.null &&
  >       echo stopped
  >   done
  > done
  given up
  bound
  trapped
  given up
  stopped
  given up
  bound
  trapped
  given up
  stopped
  given up
  bound
  trapped
  given up
  stopped
  given up
  bound
  trapped
  given up
  stopped
