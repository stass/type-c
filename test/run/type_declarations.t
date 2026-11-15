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

A distinct type is the typedef of its representation (design 10.2): the
same size and alignment on each backend, and a C header reads its value
as the representation, while Type-C text compares and crosses it only
as design 3.4 allows.

  $ cat > reader.h <<'EOF'
  > #include <stdint.h>
  > _Static_assert(sizeof (reg_id) == sizeof (uint32_t), "size");
  > _Static_assert(_Alignof (reg_id) == _Alignof (uint32_t), "align");
  > static uint32_t next(reg_id r) { return r + 1; }
  > EOF
  $ cat > distinct.tc <<'EOF'
  > #include <stdio.h>
  > #include <stdint.h>
  > type reg_id = distinct uint32_t;
  > type block_id = distinct uint32_t;
  > #include "reader.h"
  > struct slot { reg_id r : 8; block_id b; };
  > static reg_id first = (reg_id)7;
  > int main(void) {
  >   struct slot s = {0};
  >   s.r = first;
  >   s.b = (block_id)(uint32_t)s.r;
  >   reg_id r = (reg_id)next(s.r);
  >   printf("%u %u %d %d\n", (unsigned)r, (unsigned)s.b, r == first,
  >          !s.r);
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-distinct distinct.tc && ./clang-distinct
  8 7 0 0
  $ typec --cc=$gcc -Wall -Werror -o gcc-distinct distinct.tc && ./gcc-distinct
  8 7 0 0

Type-C text tells a distinct type from its representation in a generic
selection and __builtin_types_compatible_p, and typec answers them
(design 13.5): alone, Clang and GCC would take the int association for
a value of reg_id and the reg_id one for an int, and refuse a selection
that names both. A selected function designator, lvalue and string
literal keep what they are.

  $ cat > select.tc <<'EOF'
  > #include <stdio.h>
  > type reg_id = distinct int;
  > static int twice(int n) { return 2 * n; }
  > static int same(int n) { return n; }
  > int main(void) {
  >   reg_id r = (reg_id)1;
  >   int n = 0, m = 0;
  >   char s[] = _Generic(r, reg_id: "reg_id", default: "other");
  >   _Generic(r, reg_id: n, int: m) = 5;
  >   printf("%s %s %s %d %d %d %d %d\n", s,
  >          _Generic(r, int: "int", default: "not int"),
  >          _Generic(n, reg_id: "reg_id", default: "not reg_id"),
  >          n, m, _Generic(r, reg_id: twice, default: same)(3),
  >          __builtin_types_compatible_p(reg_id, int),
  >          __builtin_types_compatible_p(const reg_id, reg_id));
  >   return same((int)r) - 1;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-select select.tc && ./clang-select
  reg_id not int not reg_id 5 0 6 0 1
  $ typec --cc=$gcc -Wall -Werror -o gcc-select select.tc && ./gcc-select
  reg_id not int not reg_id 5 0 6 0 1
