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

Apple's Clang follows the error with a note that offers the missing
cases, which LLVM's Clang does not print, so of Clang's diagnostics only
the error line is checked.

  $ typec --cc=$clang -Wall -Werror -o clang-variant variant.tc 2> clang.err
  [1]
  $ grep error: clang.err
  ./client.h:28:11: error: enumeration value '__tc_tag_max__expr_tag' not handled in switch [-Werror,-Wswitch]
  $ typec --cc=$gcc -Wall -Werror -o gcc-variant variant.tc && ./gcc-variant
  In file included from variant.tc:8:
  client.h: In function 'eval':
  client.h:28:3: error: enumeration value '__tc_tag_max__expr_tag' not handled in switch [-Werror=switch]
     28 |   switch (e->tag) {
        |   ^~~~~~
  cc1: all warnings being treated as errors
  [1]

The empty initialiser `{}` gives a variant its zero value, the first
constructor with every field zero, as `{0}` does (design 3.2 rule 7).

  $ cat > empty.tc <<'EOF'
  > #include <stdio.h>
  > type shape = | Dot(int x, int y) | Circle(int r);
  > struct holder { shape s; int n; };
  > static shape kept = {};
  > static int dot_sum(shape s) {
  >   match (s) {
  >   case Dot(x, y):
  >     return x + y;
  >   case Circle(_):
  >     return -1;
  >   }
  > }
  > int main(void) {
  >   shape local = Circle(5);
  >   local = (shape){};
  >   shape fresh = {};
  >   struct holder h = {};
  >   shape row[2] = { {}, Circle(1) };
  >   printf("%d %d %d %d %d %d\n", dot_sum(kept), dot_sum(local),
  >          dot_sum(fresh), dot_sum(h.s), dot_sum(row[0]), h.n);
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-empty empty.tc && ./clang-empty
  0 0 0 0 0 0
  $ typec --cc=$gcc -Wall -Werror -o gcc-empty empty.tc && ./gcc-empty
  0 0 0 0 0 0

--emit-c shows the typedef that an alias becomes, at its own line, and
the assertions that end every unit with a Type-C construct.

  $ printf 'type count = unsigned long;\ncount n;\n' > emit.tc
  $ typec --cc=$clang --emit-c -o - emit.tc | grep -v '^# ' | grep .
  typedef
   unsigned long
  count
  ;
  count n;
  _Static_assert(_Generic(+(struct { int __tc_bits : 32; }){ 0 }.__tc_bits, int: 1, default: 0), "typec assumes plain int bit-fields are signed (-funsigned-bitfields?)");
  _Static_assert(_Generic(1.5, double: 1, default: 0), "typec assumes unsuffixed floating constants are double (-fsingle-precision-constant?)");
  enum __tc_enum_probe { __tc_enum_probe };
  _Static_assert(_Generic((enum __tc_enum_probe)0, unsigned int: 1, default: 0), "typec assumes int-sized enumerations: an enumeration of small nonnegative values is compatible with unsigned int (-fshort-enums?)");

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

The atomic builtins that only move a value load, store, exchange and
compare-exchange a distinct object with values of its type, and an asm
operand takes a distinct value, which the backend sees as its
representation (design 3.4). The asm template is empty, so it runs on
every architecture.

  $ cat > atomic.tc <<'EOF'
  > #include <stdio.h>
  > type id = distinct unsigned;
  > int main(void) {
  >   id x = (id)1, r = (id)0, e = (id)2, d = (id)3;
  >   __atomic_store_n(&x, d, __ATOMIC_SEQ_CST);
  >   __atomic_store(&x, &e, __ATOMIC_SEQ_CST);
  >   __atomic_load(&x, &r, __ATOMIC_SEQ_CST);
  >   id n = __atomic_load_n(&x, __ATOMIC_SEQ_CST);
  >   id old = __atomic_exchange_n(&x, d, __ATOMIC_SEQ_CST);
  >   __atomic_exchange(&x, &e, &r, __ATOMIC_SEQ_CST);
  >   _Bool swapped = __atomic_compare_exchange_n(&x, &e, d, 0,
  >       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  >   _Bool failed = __atomic_compare_exchange(&x, &e, &d, 0,
  >       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  >   d = (id)4;
  >   id before = __sync_val_compare_and_swap(&x, d, e);
  >   _Bool again = __sync_bool_compare_and_swap(&x, e, d);
  >   id held = __sync_lock_test_and_set(&x, e);
  >   __sync_lock_release(&x);
  >   id out;
  >   __asm__("" : "=r"(out) : "0"(held));
  >   printf("%u %u %u %u %d %d %u %d %u %u\n", (unsigned)n, (unsigned)old,
  >          (unsigned)r, (unsigned)e, swapped, failed, (unsigned)before,
  >          again, (unsigned)out, (unsigned)x);
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-atomic atomic.tc && ./clang-atomic
  2 2 3 3 1 0 3 1 4 0
  $ typec --cc=$gcc -Wall -Werror -o gcc-atomic atomic.tc && ./gcc-atomic
  2 2 3 3 1 0 3 1 4 0

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

A selection that typec answers keeps its controlling expression and
every association, and the backend selects typec's answer (design
13.5), so it sees the names they use and the tags they declare: under
-Wall -Werror a variable used only in the controlling expression and a
function used only in an association not selected would fail the build
as unused, and a later use of a tag would not find it.

  $ cat > kept.tc <<'EOF'
  > #include <stdio.h>
  > type reg_id = distinct int;
  > static int unselected(void) { return 1; }
  > int main(void) {
  >   reg_id r = (reg_id)2;
  >   reg_id only_controlling = (reg_id)3;
  >   int a = _Generic(only_controlling, reg_id: 7, int: unselected());
  >   int b = _Generic((struct held { reg_id r; }){ r }.r,
  >                    int: (struct skipped { int n; }){ 1 }.n,
  >                    reg_id: 8);
  >   struct held h = { r };
  >   struct skipped d = { 4 };
  >   printf("%d %d %d %d\n", a, b, (int)h.r, d.n);
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-kept kept.tc && ./clang-kept
  7 8 2 4
  $ typec --cc=$gcc -Wall -Werror -o gcc-kept kept.tc && ./gcc-kept
  7 8 2 4
