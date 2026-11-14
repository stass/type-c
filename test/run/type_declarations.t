SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A Type-C program with type declarations builds through typec with each
backend and runs. The aliases are the types they name, so the C that
the program calls sees its own types; the structure refers to itself
through the declared name, and a block declares an alias of its own.

  $ . ./backends.sh

  $ cat > list.tc <<'EOF'
  > #include <stdio.h>
  > type count = unsigned long;
  > type visit = void (*)(count);
  > type node;
  > type list = struct {
  >   count value;
  >   list *next;
  > };
  > static void print(count n) { printf("%lu\n", n); }
  > static count sum(const list *l, visit each) {
  >   type total = count;
  >   total t = 0;
  >   for (; l; l = l->next) {
  >     each(l->value);
  >     t += l->value;
  >   }
  >   return t;
  > }
  > int main(void) {
  >   node *opaque = 0;
  >   list c = { 3, 0 }, b = { 2, &c }, a = { 1, &b };
  >   print(sum(&a, print));
  >   return opaque != 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-list list.tc && ./clang-list
  1
  2
  3
  6
  $ typec --cc=$gcc -Wall -Werror -o gcc-list list.tc && ./gcc-list
  1
  2
  3
  6

A variant is the tagged structure of design 10.1, which C code builds
and reads through its documented representation (design 10.6). The
header is C text, so it may name the tag, the enumerators and the
members; its assertions compare the layout with the structure that
10.1 writes out, on each backend.

  $ cat > client.h <<'EOF'
  > #include <stddef.h>
  > struct expr_layout {
  >   enum expr_tag tag;
  >   union {
  >     struct { long value; } Number;
  >     struct { expr *left; expr *right; } Add;
  >   } u;
  > };
  > _Static_assert(sizeof (expr) == sizeof (struct expr_layout), "size");
  > _Static_assert(_Alignof (expr) == _Alignof (struct expr_layout), "align");
  > _Static_assert(offsetof(struct expr, tag) == 0, "tag first");
  > _Static_assert(offsetof(struct expr, u)
  >                == offsetof(struct expr_layout, u), "union");
  > _Static_assert(offsetof(struct expr, u.Add.right)
  >                == offsetof(struct expr_layout, u.Add.right), "field");
  > _Static_assert(expr_Number == 0 && expr_Nil == 1 && expr_Add == 2,
  >                "tags in order");
  > _Static_assert(sizeof (flag) == sizeof (enum flag_tag), "no union");
  > static expr number(long value) {
  >   expr e = { .tag = expr_Number, .u.Number = { value } };
  >   return e;
  > }
  > static expr add(expr *left, expr *right) {
  >   expr e = { .tag = expr_Add, .u.Add = { left, right } };
  >   return e;
  > }
  > static long eval(const expr *e) {
  >   switch (e->tag) {
  >   case expr_Number: return e->u.Number.value;
  >   case expr_Nil: return 0;
  >   case expr_Add: return eval(e->u.Add.left) + eval(e->u.Add.right);
  >   }
  >   return -1;
  > }
  > static int is_on(flag f) { return f.tag == flag_On; }
  > EOF
  $ cat > variant.tc <<'EOF'
  > #include <stdio.h>
  > type expr;
  > type expr =
  >     | Number(long value)
  >     | Nil
  >     | Add(expr *left, expr *right);
  > type flag = | Off | On;
  > #include "client.h"
  > int main(void) {
  >   type local = | None | Some(int value);
  >   expr zero = {0};
  >   expr two = number(2), three = number(3);
  >   expr sum = add(&two, &three);
  >   flag off = {0};
  >   local none = {0};
  >   printf("%ld %ld %d\n", eval(&sum), eval(&zero), is_on(off));
  >   return sizeof none != sizeof (int) * 2;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-variant variant.tc && ./clang-variant
  5 0 0
  $ typec --cc=$gcc -Wall -Werror -o gcc-variant variant.tc && ./gcc-variant
  5 0 0

--emit-c shows the typedef that an alias becomes, at its own line.

  $ printf 'type count = unsigned long;\ncount n;\n' > emit.tc
  $ typec --cc=$clang --emit-c -o - emit.tc | grep -v '^# ' | grep .
  typedef
   unsigned long
  count
  ;
  count n;
