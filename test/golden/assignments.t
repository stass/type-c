SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Conversions as if by assignment (C11 6.5.16.1p1): an assignment, an
initialiser and each of its braced members, an argument to a prototyped
parameter and a returned value. In Type-C text `typec` checks every one
in full and refuses what C refuses, which GNU C only warns of in part;
in C text that a unit includes they keep C's rules, as the backend
reads them.

A type that an instance spells through a type argument reaches the
backend as an encoding, so each conversion to or from one is refused
by `typec`, naming the types as Type-C writes them: a member of an
instance assigned,

  $ cat > member_assigned.tc <<'EOF'
  > type box(T) = struct { T v; };
  > box(int) bx;
  > void f(int *p) { bx.v = p; }
  > EOF
  $ ./golden.exe member_assigned.tc
  member_assigned.tc:3: error: a value of type 'int *' does not convert to 'int' without a cast (C11 6.5.16.1p1)
  [1]

a braced member of an instance initialised,

  $ cat > member_initialised.tc <<'EOF'
  > type box(T) = struct { T v; };
  > void f(int *p) { box(int) c = { p }; }
  > EOF
  $ ./golden.exe member_initialised.tc
  member_initialised.tc:2: error: a value of type 'int *' does not convert to 'int' without a cast (C11 6.5.16.1p1)
  [1]

the value that a call of an instance returns,

  $ cat > instance_returned.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) T get(box(T) *b) { return b->v; }
  > box(int) bx;
  > void f(void) { int *q = get(&bx); }
  > EOF
  $ ./golden.exe instance_returned.tc
  instance_returned.tc:4: error: a value of type 'int' does not convert to 'int *' without a cast (C11 6.5.16.1p1)
  [1]

an argument of an instance called through its address,

  $ cat > address_called.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > box(int) bx;
  > void f(int *p) { (&put(int))(&bx, p); }
  > EOF
  $ ./golden.exe address_called.tc
  address_called.tc:4: error: a value of type 'int *' does not convert to 'int' without a cast (C11 6.5.16.1p1)
  [1]

and one of an instance called through a pointer of its type.

  $ cat > pointer_called.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > box(int) bx;
  > void f(int *p) {
  >   typeof(put(int)) *call = put(int);
  >   call(&bx, p);
  > }
  > EOF
  $ ./golden.exe pointer_called.tc
  pointer_called.tc:6: error: a value of type 'int *' does not convert to 'int' without a cast (C11 6.5.16.1p1)
  [1]

What C converts, they convert.

  $ cat > instance_converted.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > generic(T) T get(box(T) *b) { return b->v; }
  > box(int) bx;
  > box(int *) bp;
  > void f(int *p, long n) {
  >   bx.v = n;
  >   bp.v = p;
  >   bp.v = 0;
  >   box(int) c = { n };
  >   box(int *) d = { p };
  >   long m = get(&bx);
  >   const int *q = get(&bp);
  >   (&put(int))(&bx, n);
  >   typeof(put(int)) *call = put(int);
  >   call(&bx, 'c');
  > }
  > EOF
  $ ./golden.exe instance_converted.tc > /dev/null

The same check covers every type in Type-C text: a pointer to a type
that differs in signedness alone, which GNU C only warns of
(-Wpointer-sign),

  $ cat > pointer_sign.tc <<'EOF'
  > void f(unsigned char *u) { char *s = u; }
  > EOF
  $ ./golden.exe pointer_sign.tc
  pointer_sign.tc:1: error: a value of type 'unsigned char *' does not convert to 'char *' without a cast (C11 6.5.16.1p1)
  [1]

a pointer that drops a qualifier of the type it points to,

  $ cat > qualifier_dropped.tc <<'EOF'
  > void take(char *s);
  > void f(const char *c) { take(c); }
  > EOF
  $ ./golden.exe qualifier_dropped.tc
  qualifier_dropped.tc:2: error: a value of type 'const char *' does not convert to 'char *' without a cast (C11 6.5.16.1p1)
  [1]

a pointer to an incompatible type,

  $ cat > pointer_incompatible.tc <<'EOF'
  > int compare(const int *a, const int *b);
  > int (*f(void))(const void *, const void *) { return compare; }
  > EOF
  $ ./golden.exe pointer_incompatible.tc
  pointer_incompatible.tc:2: error: a value of type 'int (*)(const int *, const int *)' does not convert to 'int (*)(const void *, const void *)' without a cast (C11 6.5.16.1p1)
  [1]

and an integer that is no null pointer constant, for a pointer, or a
pointer for an integer.

  $ cat > integer_for_pointer.tc <<'EOF'
  > void f(int n) { int *p = n; }
  > EOF
  $ ./golden.exe integer_for_pointer.tc
  integer_for_pointer.tc:1: error: a value of type 'int' does not convert to 'int *' without a cast (C11 6.5.16.1p1)
  [1]
  $ cat > pointer_for_integer.tc <<'EOF'
  > long f(int *p) { return p; }
  > EOF
  $ ./golden.exe pointer_for_integer.tc
  pointer_for_integer.tc:1: error: a value of type 'int *' does not convert to 'long' without a cast (C11 6.5.16.1p1)
  [1]

What C allows stays: a null pointer constant, a `void *` to or from a
pointer to an object, a pointer that adds qualifiers, the arithmetic
conversions, a pointer to `_Bool`, and a `void *` to or from a pointer
to a function, as GNU C and POSIX (`dlsym`) let it.

  $ cat > allowed.tc <<'EOF'
  > void take(const char *s);
  > int compare(const void *a, const void *b);
  > void f(char *s, void *v, int *p, double d) {
  >   int *q = 0;
  >   int *r = (void *)0;
  >   int *w = v;
  >   void *x = p;
  >   const volatile int *y = p;
  >   take(s);
  >   long n = d;
  >   char c = n;
  >   _Bool b = p;
  >   int (*g)(const void *, const void *) = v;
  >   void *h = compare;
  >   g = compare;
  > }
  > EOF
  $ ./golden.exe allowed.tc > /dev/null

C11 is the rule, not C23, which lets a pointer to an array take the
qualifiers of its elements.

  $ cat > array_qualified.tc <<'EOF'
  > int a[3];
  > const int (*p)[3] = &a;
  > EOF
  $ ./golden.exe array_qualified.tc
  array_qualified.tc:2: error: a value of type 'int (*)[3]' does not convert to 'const int (*)[3]' without a cast (C11 6.5.16.1p1)
  [1]

What typec does not compute, such as a type that an attribute outside
its table changes, converts as the backend decides, qualifiers and all.

  $ cat > unknown_referenced.tc <<'EOF'
  > typedef const int ci __attribute__((weird_attr));
  > void f(const int *q) { ci *p = q; }
  > EOF
  $ ./golden.exe unknown_referenced.tc > /dev/null

A conditional converts as one value, of the type that its branches
make together (C11 6.5.15p6), so a `void *` and a `char *` make a
`void *`, which converts to any pointer to an object.

  $ cat > conditional.tc <<'EOF'
  > void take(int *p);
  > int *f(void *v, char *c, int k) {
  >   int *p = k ? v : c;
  >   int *q = v ?: c;
  >   take(k ? v : c);
  >   return k ? v : c;
  > }
  > EOF
  $ ./golden.exe conditional.tc > /dev/null

C text keeps C's rules: the same conversions in a C header that a unit
includes are left to the backend, which only warns of them under GNU C.

  $ cat > header.i <<'EOF'
  > # 1 "header.tc"
  > # 1 "header.h" 1
  > void take(char *s);
  > static inline void f(unsigned char *u, const char *c) {
  >   char *s = u;
  >   take(c);
  > }
  > # 2 "header.tc" 2
  > void g(char *s) { take(s); }
  > EOF
  $ ./golden.exe header.i > /dev/null
