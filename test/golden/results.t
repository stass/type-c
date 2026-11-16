SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type-C text discards no value of a result type (design 5.2): not as an
expression statement, the left operand of a comma, or the first or
third clause of for.

  $ cat > statement.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   f();
  > }
  > EOF
  $ ./golden.exe statement.tc
  statement.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > comma.tc <<'EOF'
  > result(int, int) f(void);
  > int h(void) {
  >   return (f(), 1);
  > }
  > EOF
  $ ./golden.exe comma.tc
  comma.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > first_clause.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   for (f(); 0;) {}
  > }
  > EOF
  $ ./golden.exe first_clause.tc
  first_clause.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > third_clause.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   for (; 0; f()) {}
  > }
  > EOF
  $ ./golden.exe third_clause.tc
  third_clause.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

A conditional whose type is void, as GNU C makes one with a void
branch, discards the value of the other branch.

  $ cat > void_branch.tc <<'EOF'
  > result(int, int) f(void);
  > void h(int c) {
  >   c ? (void)0 : f();
  > }
  > EOF
  $ ./golden.exe void_branch.tc
  void_branch.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

Where the value of a conditional is discarded and typec does not know
the type of the other branch, the result is dropped whether the
conditional is void or not, and typec refuses it (design 13.3).

  $ cat > unknown_branch.tc <<'EOF'
  > result(int, int) f(void);
  > int u __attribute__((vector_size(16)));
  > void h(int c) {
  >   c ? f() : u;
  > }
  > EOF
  $ ./golden.exe unknown_branch.tc
  unknown_branch.tc:4: the type of a discarded conditional with a branch of a result type depends on the attribute 'vector_size' at unknown_branch.tc:2, which typec does not type yet (design 13.3) [TC0031]
  [1]

The association that a selection selects and the last expression
statement of a statement expression give their value to the expression
around them, so theirs is discarded where that one's is.

  $ cat > unknown_selected.tc <<'EOF'
  > result(int, int) g(void);
  > void v(void) __attribute__((ms_abi));
  > void f(int c) {
  >   _Generic(0, int: c ? g() : v());
  > }
  > EOF
  $ ./golden.exe unknown_selected.tc
  unknown_selected.tc:4: the type of a discarded conditional with a branch of a result type depends on the attribute 'ms_abi' at unknown_selected.tc:2, which typec does not type yet (design 13.3) [TC0031]
  [1]

  $ cat > unknown_last.tc <<'EOF'
  > result(int, int) g(void);
  > void v(void) __attribute__((ms_abi));
  > void f(int c) {
  >   ({ c ? g() : v(); });
  > }
  > EOF
  $ ./golden.exe unknown_last.tc
  unknown_last.tc:4: the type of a discarded conditional with a branch of a result type depends on the attribute 'ms_abi' at unknown_last.tc:2, which typec does not type yet (design 13.3) [TC0031]
  [1]

  $ cat > selected.tc <<'EOF'
  > result(int, int) g(void);
  > void f(void) {
  >   _Generic(0, int: g());
  > }
  > EOF
  $ ./golden.exe selected.tc
  selected.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > last.tc <<'EOF'
  > result(int, int) g(void);
  > void f(void) {
  >   ({ g(); });
  > }
  > EOF
  $ ./golden.exe last.tc
  last.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > selected_used.tc <<'EOF'
  > result(int, int) g(void);
  > void v(void) __attribute__((ms_abi));
  > void f(int c) {
  >   result(int, int) r;
  >   (void)_Generic(0, int: g());
  >   (void)_Generic(0, int: c ? g() : v());
  >   r = ({ g(); });
  >   (void)r;
  > }
  > EOF
  $ ./golden.exe selected_used.tc > /dev/null && echo accepted
  accepted

A function that returns void discards the value of a return statement,
as GNU C returns a void expression and GCC and Clang accept any other
under -Wno-return-mismatch.

  $ cat > return_void.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   return f();
  > }
  > EOF
  $ ./golden.exe return_void.tc
  return_void.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

The rule goes by position, also in an operand that is not evaluated.

  $ cat > sizeof.tc <<'EOF'
  > result(int, int) f(void);
  > unsigned long h(void) {
  >   return sizeof(f(), 1);
  > }
  > EOF
  $ ./golden.exe sizeof.tc
  sizeof.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

A cast to void discards on purpose. A declaration or an assignment
stores the value, and the value of an assignment is the one stored, so
an assignment discards none, parenthesized or not. A void function
returns a void expression.

  $ cat > handled.tc <<'EOF'
  > result(int, int) f(void);
  > int g(void);
  > void v(void);
  > void h(void) {
  >   (void)f();
  >   result(int, int) r = f();
  >   r = f();
  >   (r = f());
  >   (r = f(), g());
  >   for (r = f(); 0; r = f()) {}
  >   (void)r;
  > }
  > void k(void) {
  >   return v();
  > }
  > EOF
  $ ./golden.exe handled.tc > /dev/null && echo accepted
  accepted

A result type is the universe's result where a declaration hides that
name, under a typedef name, and with qualifiers.

  $ cat > hidden.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   int result = 0;
  >   f();
  >   (void)result;
  > }
  > EOF
  $ ./golden.exe hidden.tc
  hidden.tc:4: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > typedef.tc <<'EOF'
  > typedef result(int, int) status;
  > status f(void);
  > void h(void) {
  >   f();
  > }
  > EOF
  $ ./golden.exe typedef.tc
  typedef.tc:4: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > qualified.tc <<'EOF'
  > typedef result(int, int) status;
  > extern const status saved;
  > void h(void) {
  >   saved;
  > }
  > EOF
  $ ./golden.exe qualified.tc
  qualified.tc:4: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

A variant of a file that is no result is not one.

  $ cat > other_variant.tc <<'EOF'
  > type outcome(T) = | Failed | Done(T value);
  > outcome(int) f(void);
  > void h(void) {
  >   f();
  > }
  > EOF
  $ ./golden.exe other_variant.tc > /dev/null && echo accepted
  accepted

The last expression statement of a statement expression gives its value
and discards none, also past a label; the statement expression is
judged where it stands. Every other expression statement in it
discards its value.

  $ cat > last_stored.tc <<'EOF'
  > result(int, int) f(void);
  > int g(void);
  > void h(void) {
  >   result(int, int) r = ({ g(); f(); });
  >   r = ({ g(); done: f(); });
  >   (void)r;
  > }
  > EOF
  $ ./golden.exe last_stored.tc > /dev/null && echo accepted
  accepted

  $ cat > last_dropped.tc <<'EOF'
  > result(int, int) f(void);
  > int g(void);
  > void h(void) {
  >   ({ g(); f(); });
  > }
  > EOF
  $ ./golden.exe last_dropped.tc
  last_dropped.tc:4: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > not_last.tc <<'EOF'
  > result(int, int) f(void);
  > int g(void);
  > int h(void) {
  >   return ({ f(); g(); });
  > }
  > EOF
  $ ./golden.exe not_last.tc
  not_last.tc:4: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

A declaration after the call is the last block item, so the call is
not.

  $ cat > declared_last.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   ({ f(); int y = 0; (void)y; int z = 0; });
  > }
  > EOF
  $ ./golden.exe declared_last.tc
  declared_last.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

  $ cat > nested.tc <<'EOF'
  > result(int, int) f(void);
  > int h(int c) {
  >   return ({ if (c) f(); c; });
  > }
  > EOF
  $ ./golden.exe nested.tc
  nested.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

The rule binds Type-C text, judged by the first token of the discarded
expression: C text drops a structure value as C does.

  $ cat > c_text.tc <<'EOF'
  > result(int, int) f(void);
  > # 1 "header.h" 1
  > static void c_text(void) { f(); }
  > # 3 "c_text.tc" 2
  > void h(void) { c_text(); }
  > EOF
  $ ./golden.exe c_text.tc > /dev/null && echo accepted
  accepted

  $ cat > c_first.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  > # 1 "callee.h" 1
  >   f
  > # 4 "c_first.tc" 2
  >   ();
  > }
  > EOF
  $ ./golden.exe c_first.tc > /dev/null && echo accepted
  accepted

  $ cat > type_c_first.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   f
  > # 1 "arguments.h" 1
  >   ()
  > # 4 "type_c_first.tc" 2
  >   ;
  > }
  > EOF
  $ ./golden.exe type_c_first.tc
  type_c_first.tc:3: a value of a result type is discarded; handle it with try or match, store it, or cast it to void (design 5.2) [TC0048]
  [1]

Type-C text holds no excess initialiser, which GCC and Clang drop with
a warning, a result among them (C11 6.7.9p2). It is judged by the first
token of the excess initialiser; C text keeps the backend's warning.

  $ cat > excess_result.tc <<'EOF'
  > result(int, int) f(void);
  > struct p { int a; };
  > void h(void) {
  >   struct p s = { 1, f() };
  >   (void)s;
  > }
  > EOF
  $ ./golden.exe excess_result.tc
  excess_result.tc:4: an initialiser has no element or member left to initialise, and GCC drops it (C11 6.7.9p2) (design 5.2) [TC0050]
  [1]

  $ cat > excess.tc <<'EOF'
  > int a[1] = { 1, 2 };
  > EOF
  $ ./golden.exe excess.tc
  excess.tc:1: an initialiser has no element or member left to initialise, and GCC drops it (C11 6.7.9p2) (design 5.2) [TC0050]
  [1]

An initialiser that the walk places, braces elided, into a zero-length
array, which GCC drops and Clang refuses, is excess too.

  $ cat > zero_length.tc <<'EOF'
  > result(int, int) f(void);
  > void h(void) {
  >   struct z { int a[0]; int b; } s = { f(), 3 };
  >   (void)s;
  > }
  > EOF
  $ ./golden.exe zero_length.tc
  zero_length.tc:3: an initialiser has no element or member left to initialise, and GCC drops it (C11 6.7.9p2) (design 5.2) [TC0050]
  [1]

  $ cat > c_excess.tc <<'EOF'
  > result(int, int) f(void);
  > # 1 "header.h" 1
  > static int a[1] = { 1, 2 };
  > static void c_text(void) { int b[1] = { 1, f() }; (void)b; }
  > # 3 "c_excess.tc" 2
  > void h(void) { c_text(); (void)a; }
  > EOF
  $ ./golden.exe c_excess.tc > /dev/null && echo accepted
  accepted

  $ cat > c_excess_first.tc <<'EOF'
  > int a[1] = { 1,
  > # 1 "excess.h" 1
  >   2
  > # 2 "c_excess_first.tc" 2
  > };
  > EOF
  $ ./golden.exe c_excess_first.tc > /dev/null && echo accepted
  accepted
