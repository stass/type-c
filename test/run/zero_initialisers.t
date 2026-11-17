SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The zero initialiser of a type parameter (design 7.1 rule 3) is
lowered to {} under __extension__ (13.5), which holds only as long as
the backends give {} the meaning of C23 in the C11 and C17 dialects
and zero the bits of an unnamed bit-field. These tests hold that
assumption for the backends of the test host;
test/golden/zero_initialisers.t shows the lowered text.

  $ . ./backends.sh

Every byte that rule 3 promises is zero: each byte of the object but
those inside a long double that hold none of its value. The program
writes each place of 13.5 for each type of 13.5, the three structures
with unnamed bit-fields among them, and calls each through a pointer,
so that it is compiled on its own, after a function that fills the
stack with a byte that is not zero. A control, a union whose first
member alone is assigned, must leave bytes that are not zero, which
shows that the test reads the bytes that it claims to read.

The bytes passed over in a long double are counted and printed only
by `./zeroes record`, which asserts nothing of them: how many are left
depends on the harness as well as on the backend. That is the record
of 13.5.

  $ cat > zeroes.tc <<'EOF'
  > #include <float.h>
  > #include <stddef.h>
  > #include <stdio.h>
  > 
  > /* The bytes at the start of a long double that hold its value: 10 in
  >    the format of x87, every byte in the others that this test knows. */
  > #if LDBL_MANT_DIG == 64
  > enum { long_double_value = 10 };
  > #else
  > _Static_assert(LDBL_MANT_DIG == DBL_MANT_DIG || LDBL_MANT_DIG == 113,
  >                "a format of long double that this test does not know");
  > enum { long_double_value = sizeof(long double) };
  > #endif
  > 
  > union wide { char c; long l[4]; };
  > struct gap { char c; long l; };
  > struct tail { long l; char c; };
  > type choice = | Small(char c) | Large(long l, char d);
  > struct gap32 { char a; unsigned : 32; char b; };
  > struct gap40 { unsigned long long : 40; unsigned long long x : 8; };
  > struct tail24 { char c; unsigned : 0; unsigned : 24; };
  > struct one_ld { long double x; };
  > struct one_cld { _Complex long double x; };
  > 
  > /* A type of the test: its size, and how many long doubles stand at its
  >    start, one after another, whose bytes past long_double_value hold
  >    none of their value and are not promised (design 7.1 rule 3). */
  > struct shape {
  >   const char *name;
  >   size_t size;
  >   size_t long_doubles;
  > };
  > 
  > static int record;
  > static unsigned long left_bytes;
  > 
  > static int passed_over(const struct shape *shape, size_t index) {
  >   return index < shape->long_doubles * sizeof(long double) &&
  >          index % sizeof(long double) >= long_double_value;
  > }
  > 
  > /* Counts the bytes of the object that are not zero: those promised, and
  >    those passed over, which only a record prints. */
  > __attribute__((noinline)) static unsigned long
  > check(const char *place, const struct shape *shape, const void *object) {
  >   const volatile unsigned char *bytes = object;
  >   unsigned long left = 0, passed = 0;
  >   for (size_t i = 0; i < shape->size; i++) {
  >     if (bytes[i] == 0)
  >       continue;
  >     if (passed_over(shape, i))
  >       passed++;
  >     else
  >       left++;
  >   }
  >   if (record)
  >     printf("%s %s: %lu passed over\n", place, shape->name, passed);
  >   return left;
  > }
  > 
  > /* Each place where the zero initialiser stands (design 13.5). */
  > static void promised(const char *place, const struct shape *shape,
  >                      const void *object) {
  >   unsigned long left = check(place, shape, object);
  >   if (left != 0)
  >     printf("%s %s: %lu bytes not zero\n", place, shape->name, left);
  >   left_bytes += left;
  > }
  > 
  > generic(T) void at_object(const struct shape *shape) {
  >   T u = {0};
  >   promised("object", shape, &u);
  > }
  > generic(T) void at_const(const struct shape *shape) {
  >   const T u = {};
  >   promised("const", shape, &u);
  > }
  > generic(T) void at_static(const struct shape *shape) {
  >   static T u = {0};
  >   promised("static", shape, &u);
  > }
  > generic(T) void at_array(const struct shape *shape) {
  >   T row[3] = {0};
  >   for (int i = 0; i < 3; i++)
  >     promised("array", shape, &row[i]);
  > }
  > generic(T) void at_head(const struct shape *shape) {
  >   struct { T a; int b; } w = {0};
  >   promised("head", shape, &w.a);
  > }
  > generic(T) void at_subobject(const struct shape *shape) {
  >   struct { int b; T a; } w = { 5, {0} };
  >   promised("subobject", shape, &w.a);
  > }
  > generic(T) void at_literal(const struct shape *shape) {
  >   promised("literal", shape, &(T){0});
  > }
  > generic(T) void at_literal_subobject(const struct shape *shape) {
  >   promised("literal-subobject", shape,
  >            &(struct { int b; T a; }){ 5, {} }.a);
  > }
  > 
  > typedef void place_function(const struct shape *);
  > 
  > enum { places = 8 };
  > 
  > struct row {
  >   struct shape shape;
  >   place_function *places[places];
  > };
  > 
  > #define ROW(T, long_doubles)                                        \
  >   { { #T, sizeof(T), long_doubles },                                \
  >     { at_object(T), at_const(T), at_static(T), at_array(T),         \
  >       at_head(T), at_subobject(T), at_literal(T),                   \
  >       at_literal_subobject(T) } }
  > 
  > static const struct row rows[] = {
  >   ROW(union wide, 0),
  >   ROW(struct gap, 0),
  >   ROW(struct tail, 0),
  >   ROW(choice, 0),
  >   ROW(double, 0),
  >   ROW(void *, 0),
  >   ROW(struct gap32, 0),
  >   ROW(struct gap40, 0),
  >   ROW(struct tail24, 0),
  >   ROW(long double, 1),
  >   ROW(_Complex long double, 2),
  >   ROW(struct one_ld, 1),
  >   ROW(struct one_cld, 2),
  > };
  > 
  > /* Fills the stack below the caller with a byte that is not zero. */
  > __attribute__((noinline)) static void poison(void) {
  >   volatile unsigned char stack[8192];
  >   for (size_t i = 0; i < sizeof stack; i++)
  >     stack[i] = 0xa5;
  > }
  > 
  > /* The control: a form that does not zero, a member assigned alone,
  >    must leave bytes, so that the test reads the bytes it claims to. */
  > __attribute__((noinline)) static void control(const struct shape *shape) {
  >   union wide u;
  >   u.c = 0;
  >   if (check("control", shape, &u) == 0)
  >     printf("the control leaves no byte\n");
  > }
  > 
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   record = argc > 1;
  >   for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
  >     for (int j = 0; j < places; j++) {
  >       place_function *volatile place = rows[i].places[j];
  >       poison();
  >       place(&rows[i].shape);
  >     }
  >   }
  >   place_function *volatile against = control;
  >   poison();
  >   against(&rows[0].shape);
  >   printf("%lu bytes not zero\n", left_bytes);
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for level in -O0 -O2 -O3; do
  >     typec --cc="$cc" -std=c11 $level -o zeroes zeroes.tc 2> log ||
  >       cat log
  >     ./zeroes
  >   done
  > done
  0 bytes not zero
  0 bytes not zero
  0 bytes not zero
  0 bytes not zero
  0 bytes not zero
  0 bytes not zero

The lowered form compiles under -pedantic-errors in the four dialects
that typec accepts, in each place, and the same text without
__extension__ does not: the backends take {} in C11 and C17 only as an
extension. Each place is refused in each of the two instances.

  $ cat > pedantic.tc <<'EOF'
  > union wide { char c; long l[4]; };
  > type choice = | Small(char c) | Large(long l, char d);
  > void use(const void *);
  > generic(T) void places(void) {
  >   T u = {0};
  >   const T c = {};
  >   static T s = {0};
  >   T row[3] = {0};
  >   struct { T a; int b; } head = {0};
  >   struct { int b; T a; } sub = { 5, {0} };
  >   use(&u); use(&c); use(&s); use(row); use(&head); use(&sub);
  >   use(&(T){0});
  >   use(&(struct { int b; T a; }){ 5, {} });
  > }
  > void f(void) {
  >   places(union wide)();
  >   places(choice)();
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for std in c11 gnu11 c17 gnu17; do
  >     typec --cc="$cc" -std=$std -pedantic-errors -Wall -Wextra -Werror \
  >       -fsyntax-only pedantic.tc && echo "$std lowered"
  >     typec --cc="$cc" --emit-c -std=$std pedantic.tc |
  >       sed 's/__extension__//g' > stripped.i
  >     compile_emitted "$cc" stripped.i -std=$std 2> refusals ||
  >       echo "$std stripped: $(grep -c 'error:' refusals) errors"
  >   done
  > done
  c11 lowered
  c11 stripped: 16 errors
  gnu11 lowered
  gnu11 stripped: 16 errors
  c17 lowered
  c17 stripped: 16 errors
  gnu17 lowered
  gnu17 stripped: 16 errors
  c11 lowered
  c11 stripped: 16 errors
  gnu11 lowered
  gnu11 stripped: 16 errors
  c17 lowered
  c17 stripped: 16 errors
  gnu17 lowered
  gnu17 stripped: 16 errors

The prelude of a try that the statement holds goes before the
__extension__ of a compound literal that begins the statement, which
stays next to the literal.

  $ cat > prelude.tc <<'EOF'
  > result(int, int) g(void);
  > generic(T) result(int, int) f(void) {
  >   (struct { T a; int b; }){0}.b = try g();
  >   return Ok(0);
  > }
  > result(int, int) h(void) { return f(long)(); }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -std=c11 -pedantic-errors -Wall -Wextra -Werror \
  >     -fsyntax-only prelude.tc && echo lowered
  > done
  lowered
  lowered

The lists of test/golden/zero_initialisers.t that stand behind nested
designators, in an array of structures inside a structure and in a
compound literal in a statement expression zero their objects too.

  $ cat > deep.tc <<'EOF'
  > #include <stdio.h>
  > #include <string.h>
  > 
  > union wide { char c; long l[4]; };
  > static const union wide zero;
  > 
  > __attribute__((noinline)) static void poison(void) {
  >   volatile unsigned char stack[8192];
  >   for (size_t i = 0; i < sizeof stack; i++)
  >     stack[i] = 0xa5;
  > }
  > __attribute__((noinline)) static int zeroed(const void *object) {
  >   return memcmp(object, &zero, sizeof zero) == 0;
  > }
  > 
  > generic(T) int designated(void) {
  >   struct { struct { int k; T a[2]; } in[2]; int n; } d =
  >     { .in[1].a[1] = {0}, .n = 1 };
  >   return zeroed(&d.in[1].a[1]);
  > }
  > generic(T) int rows(void) {
  >   struct { int n; struct { T a; int b; } row[2]; } r =
  >     { 1, { {0}, {} } };
  >   return zeroed(&r.row[0].a) && zeroed(&r.row[1].a);
  > }
  > generic(T) int statement(void) {
  >   return ({ const T *p = &(T){0}; zeroed(p); });
  > }
  > 
  > typedef int place_function(void);
  > static place_function *const places[] = {
  >   designated(union wide), rows(union wide), statement(union wide)
  > };
  > 
  > int main(void) {
  >   for (size_t i = 0; i < sizeof places / sizeof places[0]; i++) {
  >     place_function *volatile place = places[i];
  >     poison();
  >     printf("%d", place());
  >   }
  >   printf("\n");
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   for level in -O0 -O2; do
  >     typec --cc="$cc" -std=c11 $level -o deep deep.tc \
  >       2> log || cat log
  >     ./deep
  >   done
  > done
  111
  111
  111
  111
