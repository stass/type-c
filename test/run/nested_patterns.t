SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Matches with nested patterns (design 4.7, 13.5) and their hand-written
twins, a switch on each tag nested in a switch on the tag around it,
give the same output on each backend at -O0 and -O2 under
-pedantic-errors, AddressSanitizer and UndefinedBehaviorSanitizer. The
programs cover the examples of 4.7, overlapping labels that select the
first in source order, a default written first, and a scrutinee with a
side effect, which selection evaluates once. Each program flushes its
output before the case that stops it.

  $ . ./backends.sh
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror -g"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $ cat > types.h <<'EOF'
  > type eval_error = | DivByZero | Overflow;
  > type res = | Ok(int value) | Err(eval_error error);
  > type expr = | Num(int value) | Add(const expr *l, const expr *r);
  > type list = | Nil | Cons(int head, const list *tail);
  > type tree = | Leaf(int value) | Node(const tree *l, const tree *r);
  > type side = | Left | Right;
  > type pair = | Pair(side s, const tree *t);
  > EOF
  $ cat > corrupt.h <<'EOF'
  > static void corrupt(res *r) { r->u.Err.error.tag = (enum eval_error_tag)7; }
  > EOF
  $ cat > common.h <<'EOF'
  > static int calls;
  > static int report(res r);
  > static int whole(res r);
  > static int evaluate(const expr *e);
  > static int last(const list *l);
  > static int ordered(pair p);
  > static int swapped(pair p);
  > static int defaulted(res r);
  > static res counted(res r) { calls++; return r; }
  > static int once(res r);
  > EOF
  $ cat > main.h <<'EOF'
  > int main(int argc, char **argv) {
  >   res ok = make_ok(4), zero = make_err(0), over = make_err(1);
  >   expr two = make_num(2), three = make_num(3);
  >   expr sum = make_add(&two, &three), nested = make_add(&sum, &three);
  >   list nil = make_nil(), one = make_cons(1, &nil);
  >   list two_items = make_cons(2, &one);
  >   tree leaf = make_leaf(7), node = make_node(&leaf, &leaf);
  >   pair left_leaf = make_pair(0, &leaf), right_leaf = make_pair(1, &leaf);
  >   pair right_node = make_pair(1, &node), left_null = make_pair(0, 0);
  >   if (argc > 1 && argv[1][0] == 'n') {
  >     printf("ordered %d\n", ordered(left_null));
  >     fflush(stdout);
  >     printf("swapped %d\n", swapped(left_null));
  >     return 0;
  >   }
  >   if (argc > 1 && argv[1][0] == 'c') {
  >     corrupt(&over);
  >     printf("whole %d\n", whole(over));
  >     fflush(stdout);
  >     printf("report %d\n", report(over));
  >     return 0;
  >   }
  >   printf("report %d %d %d\n", report(ok), report(zero), report(over));
  >   printf("evaluate %d %d\n", evaluate(&sum), evaluate(&nested));
  >   printf("last %d %d %d\n", last(&nil), last(&one), last(&two_items));
  >   printf("ordered %d %d %d\n", ordered(left_leaf), ordered(right_leaf),
  >          ordered(right_node));
  >   printf("swapped %d %d %d\n", swapped(left_leaf), swapped(right_leaf),
  >          swapped(right_node));
  >   printf("defaulted %d %d %d\n", defaulted(ok), defaulted(zero),
  >          defaulted(over));
  >   printf("once %d %d %d\n", once(ok), once(zero), once(over));
  >   printf("calls %d\n", calls);
  >   return 0;
  > }
  > EOF

The Type-C program. `swapped` is `ordered` with its two overlapping
labels in the other order, which selects another arm for a value that
both match, and follows the pointer of a value that `ordered` selects
by its side alone.

  $ cat > nested.tc <<'EOF'
  > #include <stdio.h>
  > #include "types.h"
  > #include "corrupt.h"
  > #include "common.h"
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
  > static tree make_leaf(int v) { return Leaf(v); }
  > static tree make_node(const tree *l, const tree *r) { return Node(l, r); }
  > static pair make_pair(int right, const tree *t) {
  >   if (right)
  >     return Pair(Right, t);
  >   return Pair(Left, t);
  > }
  > static int report(res r) {
  >   match (r) {
  >   case Ok(value):
  >     return value;
  >   case Err(DivByZero):
  >     return -1;
  >   case Err(Overflow):
  >     return -2;
  >   }
  > }
  > static int whole(res r) {
  >   match (r) {
  >   case Ok(_):
  >     return 0;
  >   case Err(eval_error e):
  >     (void)e;
  >     return -3;
  >   }
  > }
  > static int evaluate(const expr *e) {
  >   match (*e) {
  >   case Add(*Num(a), *Num(b)):
  >     return a + b;
  >   case Add(l, r):
  >     return evaluate(l) + evaluate(r) + 100;
  >   case Num(value):
  >     return value;
  >   }
  > }
  > static int last(const list *l) {
  >   match (*l) {
  >   case Cons(head, *Nil):
  >     return head;
  >   case Cons(_, tail):
  >     return last(tail);
  >   case Nil:
  >     return -1;
  >   }
  > }
  > static int ordered(pair p) {
  >   match (p) {
  >   case Pair(Left, _):
  >     return 1;
  >   case Pair(_, *Leaf(n)):
  >     return 10 + n;
  >   default:
  >     return 0;
  >   }
  > }
  > static int swapped(pair p) {
  >   match (p) {
  >   case Pair(_, *Leaf(n)):
  >     return 10 + n;
  >   case Pair(Left, _):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > static int defaulted(res r) {
  >   match (r) {
  >   default:
  >     return 0;
  >   case Err(Overflow):
  >     return 2;
  >   }
  > }
  > static int once(res r) {
  >   match (counted(r)) {
  >   case Err(DivByZero):
  >     return 1;
  >   case Err(_):
  >     return 2;
  >   case Ok(v):
  >     return v;
  >   }
  > }
  > #include "main.h"
  > EOF

The twin, a tagged structure read by nested switches.

  $ cat > nested.c <<'EOF'
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
  > typedef struct tree tree;
  > struct tree {
  >   enum { Leaf, Node } tag;
  >   union { int value; struct { const tree *l, *r; } node; } u;
  > };
  > enum side { Left, Right };
  > typedef struct { enum side s; const tree *t; } pair;
  > #include "corrupt.h"
  > #include "common.h"
  > static res make_ok(int v) { return (res){ Ok, { .Ok = { v } } }; }
  > static res make_err(int overflow) {
  >   return (res){ Err, { .Err = { { overflow ? Overflow : DivByZero } } } };
  > }
  > static expr make_num(int v) { return (expr){ Num, { .value = v } }; }
  > static expr make_add(const expr *l, const expr *r) {
  >   return (expr){ Add, { .add = { l, r } } };
  > }
  > static list make_nil(void) { return (list){ Nil, { 0, 0 } }; }
  > static list make_cons(int h, const list *t) {
  >   return (list){ Cons, { h, t } };
  > }
  > static tree make_leaf(int v) { return (tree){ Leaf, { .value = v } }; }
  > static tree make_node(const tree *l, const tree *r) {
  >   return (tree){ Node, { .node = { l, r } } };
  > }
  > static pair make_pair(int right, const tree *t) {
  >   return (pair){ right ? Right : Left, t };
  > }
  > static int report(res r) {
  >   switch (r.tag) {
  >   case Ok:
  >     return r.u.Ok.value;
  >   case Err:
  >     switch (r.u.Err.error.tag) {
  >     case DivByZero:
  >       return -1;
  >     case Overflow:
  >       return -2;
  >     }
  >   }
  >   __builtin_trap();
  > }
  > static int whole(res r) {
  >   return r.tag == Ok ? 0 : -3;
  > }
  > static int evaluate(const expr *e) {
  >   if (e->tag == Num)
  >     return e->u.value;
  >   if (e->u.add.l->tag == Num && e->u.add.r->tag == Num)
  >     return e->u.add.l->u.value + e->u.add.r->u.value;
  >   return evaluate(e->u.add.l) + evaluate(e->u.add.r) + 100;
  > }
  > static int last(const list *l) {
  >   if (l->tag == Nil)
  >     return -1;
  >   if (l->cons.tail->tag == Nil)
  >     return l->cons.head;
  >   return last(l->cons.tail);
  > }
  > static int ordered(pair p) {
  >   if (p.s == Left)
  >     return 1;
  >   if (p.t->tag == Leaf)
  >     return 10 + p.t->u.value;
  >   return 0;
  > }
  > static int swapped(pair p) {
  >   if (p.t->tag == Leaf)
  >     return 10 + p.t->u.value;
  >   if (p.s == Left)
  >     return 1;
  >   return 0;
  > }
  > static int defaulted(res r) {
  >   if (r.tag == Err && r.u.Err.error.tag == Overflow)
  >     return 2;
  >   return 0;
  > }
  > static int once(res r) {
  >   res s = counted(r);
  >   if (s.tag == Ok)
  >     return s.u.Ok.value;
  >   if (s.u.Err.error.tag == DivByZero)
  >     return 1;
  >   return 2;
  > }
  > #include "main.h"
  > EOF

Each program prints the same lines; `swapped` follows the null pointer
that `ordered` does not, where UndefinedBehaviorSanitizer stops the
program; a
tag that is no constructor of its variant, below a label that reads
it, traps (4.5), where a label that binds the field whole reads no tag
below it.

  $ for cc in "$clang" "$gcc"; do
  >   for opt in -O0 -O2; do
  >     typec --cc="$cc" $opt $flags $sanitize -o nested-tc nested.tc &&
  >     "$cc" $opt $flags $sanitize -o nested-c nested.c || exit 1
  >     for program in nested-tc nested-c; do
  >       ./$program > $program.out
  >       sh -c "./$program null; exit \$?" >> $program.out 2> $program.null
  >       grep -q 'runtime error: member access within null pointer' \
  >         $program.null &&
  >         echo stopped >> $program.out
  >       sh -c "./$program corrupt; exit \$?" >> $program.out 2> /dev/null
  >       test $? -gt 128 && echo trapped >> $program.out
  >     done
  >     cmp nested-tc.out nested-c.out || echo "$cc $opt differs"
  >   done
  > done
  $ cat nested-tc.out
  report 4 -1 -2
  evaluate 5 108
  last -1 1 1
  ordered 1 17 0
  swapped 17 17 0
  defaulted 0 0 2
  once 4 1 2
  calls 3
  ordered 1
  stopped
  whole -3
  trapped

A field of variant type in a packed variant may be misaligned, so
selection reads its tag and binds its fields by member access, which
the backend knows to be packed, and takes no pointer to it (13.5):
the alignment check of UndefinedBehaviorSanitizer passes.

  $ cat > packed.tc <<'EOF'
  > #include <stdio.h>
  > type inner = | A | B(int x);
  > #pragma pack(1)
  > type outer = | O(char c, inner i) | P;
  > #pragma pack()
  > static int f(outer v) {
  >   match (v) {
  >   case O(_, A): return 1;
  >   case O(_, B(x)): return x;
  >   case P: return 0;
  >   }
  > }
  > int main(void) {
  >   outer o = O('a', B(42));
  >   printf("%d %d\n", f(o), f(O('b', A)));
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for opt in -O0 -O2; do
  >     typec --cc="$cc" $opt $flags $sanitize -o packed packed.tc &&
  >       ./packed || echo "$cc $opt failed"
  >   done
  > done
  42 1
  42 1
  42 1
  42 1

A variant that is a member of a packed structure may be misaligned, so
a match or a test whose scrutinee is a member, an element of a member
array, or the object of a pointer that the scrutinee forms from one,
copies it rather than take its address (13.5), and the alignment check
of UndefinedBehaviorSanitizer passes.

  $ cat > member.tc <<'EOF'
  > #include <stdio.h>
  > type inner = | A | B(int x);
  > #pragma pack(1)
  > struct holder { char c; inner i; inner a[2]; };
  > #pragma pack()
  > static int selected(const struct holder *h) {
  >   match (h->i) {
  >   case A: return 1;
  >   case B(x): return x;
  >   }
  > }
  > static int tested(const struct holder *h) {
  >   if (case B(x) = h->i)
  >     return x;
  >   return 0;
  > }
  > static int element(struct holder h, int k) {
  >   if (case B(x) = h.a[k])
  >     return x;
  >   return 0;
  > }
  > static int formed(const struct holder *h, int k) {
  >   int sum = 0;
  >   if (case B(x) = *h->a)
  >     sum += x;
  >   match ((h->a)[k]) {
  >   case A: return sum;
  >   case B(x): return sum + x;
  >   }
  > }
  > int main(void) {
  >   struct holder h = { 'a', B(42), { B(1), B(2) } };
  >   printf("%d %d\n", selected(&h), tested(&h));
  >   printf("%d %d\n", element(h, 1), formed(&h, 1));
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for opt in -O0 -O2; do
  >     typec --cc="$cc" $opt $flags $sanitize -o member member.tc &&
  >       ./member || echo "$cc $opt failed"
  >   done
  > done
  42 42
  2 3
  42 42
  2 3
  42 42
  2 3
  42 42
  2 3

The partner, the address of the member taken as a pointer to the
scrutinee, is stopped by the alignment check.

  $ cat > member.c <<'EOF'
  > #include <stdio.h>
  > struct inner { int tag; union { struct { int x; } B; } u; };
  > #pragma pack(1)
  > struct holder { char c; struct inner i; };
  > #pragma pack()
  > static int selected(const struct holder *h) {
  >   const struct inner *const m = &(h->i);
  >   return m->tag == 1 ? m->u.B.x : 1;
  > }
  > int main(void) {
  >   struct holder h = { 'a', { 1, { { 42 } } } };
  >   printf("%d\n", selected(&h));
  >   return 0;
  > }
  > EOF
  $ "$clang" -std=c11 -g -Wno-address-of-packed-member $sanitize \
  >   -o member-c member.c && ./member-c 2>&1 | grep -c misaligned
  1
