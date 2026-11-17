SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Generic functions (design 7.1): the definition is read once against an
opaque value type for each type parameter. Instances are not written
yet, so a unit that holds a generic function stops after its check
(TC0023), and so does a use of its name (design 7.2).

A definition that uses its type parameters only as every value type
allows is checked and stops at the sentinel.

  $ cat > last.tc <<'EOF'
  > generic(T)
  > T *last(T *items, unsigned long n)
  > {
  >     T copy = items[0];
  >     return n ? &items[n - 1] : &copy;
  > }
  > generic(K, V) void put(K *key, V *value);
  > EOF
  $ ./golden.exe last.tc
  last.tc:1: a generic function is checked, but typec does not write its instances yet (design 7.3; work package 3.3) [TC0023]
  [1]

A use of the name of a generic function, a call included, is refused.

  $ cat > call.tc <<'EOF'
  > generic(T) T *first(T *items) { return items; }
  > int *f(int *p) { return first(p); }
  > EOF
  $ ./golden.exe call.tc
  call.tc:2: 'first' is a generic function, whose calls and instances typec does not build yet (design 7.2; work package 3.2) [TC0023]
  [1]

Design 7.1 rule 3: a value of a type parameter is used only as C uses a
structure, and as every value type gives the same meaning.

A value of a type parameter is discarded under a cast to void, typed
with __typeof__, and yielded by a comma.

  $ cat > discard.tc <<'EOF'
  > generic(T) void f(T *p, T t, int i)
  > {
  >     (void)t;
  >     __typeof__(t) u = t;
  >     i++, *p = u;
  > }
  > EOF
  $ ./golden.exe discard.tc
  discard.tc:1: a generic function is checked, but typec does not write its instances yet (design 7.3; work package 3.3) [TC0023]
  [1]

A cast of a value of a type parameter, other than to void, is refused,
and so is a cast to a type parameter.

  $ cat > cast_int.tc <<'EOF'
  > generic(T) int f(T t) { return (int)t; }
  > EOF
  $ ./golden.exe cast_int.tc
  cast_int.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > cast_to.tc <<'EOF'
  > generic(T) void f(T t) { (T)t; }
  > EOF
  $ ./golden.exe cast_to.tc
  cast_to.tc:1: a cast to a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

So are the operations that C refuses of a structure: arithmetic,
comparison, member access, calls and truth tests.

  $ cat > arithmetic.tc <<'EOF'
  > generic(T) void f(T a, T b) { a + b; }
  > EOF
  $ ./golden.exe arithmetic.tc
  arithmetic.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > compare.tc <<'EOF'
  > generic(T) int f(T a, T b) { return a == b; }
  > EOF
  $ ./golden.exe compare.tc
  compare.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > member.tc <<'EOF'
  > generic(T) int f(T a) { return a.x; }
  > EOF
  $ ./golden.exe member.tc
  member.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > called.tc <<'EOF'
  > generic(T) void f(T a) { a(); }
  > EOF
  $ ./golden.exe called.tc
  called.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > truth.tc <<'EOF'
  > generic(T) int f(T a) { if (a) return 1; return 0; }
  > EOF
  $ ./golden.exe truth.tc
  truth.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

The default argument promotions convert some value types and not
others: through `...`, to a function without a prototype, by va_arg,
and where a function type with such a parameter meets one without a
prototype.

  $ cat > variadic.tc <<'EOF'
  > int printf(const char *, ...);
  > generic(T) void f(T t) { printf("", t); }
  > EOF
  $ ./golden.exe variadic.tc
  variadic.tc:2: a value of a type parameter is an argument that no parameter type receives, which the default argument promotions or a builtin read by its type, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > unprototyped.tc <<'EOF'
  > int g();
  > generic(T) void f(T t) { g(t); }
  > EOF
  $ ./golden.exe unprototyped.tc
  unprototyped.tc:2: a value of a type parameter is an argument that no parameter type receives, which the default argument promotions or a builtin read by its type, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > va_arg.tc <<'EOF'
  > generic(T) void f(T *p, __builtin_va_list ap) { *p = __builtin_va_arg(ap, T); }
  > EOF
  $ ./golden.exe va_arg.tc
  va_arg.tc:1: va_arg of a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > old_pointer.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     void take(T);
  >     void (*old)() = take;
  >     (void)old;
  > }
  > EOF
  $ ./golden.exe old_pointer.tc
  old_pointer.tc:4: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

Provisionally, the conditional operator takes no value of a type
parameter: its type is that of the usual arithmetic conversions.

  $ cat > conditional.tc <<'EOF'
  > generic(T) void f(int c, T a, T b, T *p) { *p = c ? a : b; }
  > EOF
  $ ./golden.exe conditional.tc
  conditional.tc:1: a value of a type parameter is a branch of the conditional operator, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

A construct that compares types gives the argument's answer where a
type in it mentions a type parameter.

  $ cat > selection.tc <<'EOF'
  > generic(T) int f(int x) { return _Generic(x, T: 1, default: 0); }
  > EOF
  $ ./golden.exe selection.tc
  selection.tc:1: _Generic compares a type that mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > compatible.tc <<'EOF'
  > generic(T) int f(void) { return __builtin_types_compatible_p(T, int); }
  > EOF
  $ ./golden.exe compatible.tc
  compatible.tc:1: __builtin_types_compatible_p compares a type that mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

The only braced initialisers of a type parameter are {0} and {}.

  $ cat > braced.tc <<'EOF'
  > generic(T) void f(T *p, T t) { T u = { t }; *p = u; }
  > EOF
  $ ./golden.exe braced.tc
  braced.tc:1: an initialiser reaches into a value of a type parameter; the only braced initialisers of one are {0} and {} (design 7.1 rule 3) [TC0075]
  [1]

Design 7.1 rule 4: sizes, alignments and offsets.

A size that is not a constant expression may depend on a type
parameter, as may the length of a variable length array; {0} and {}
initialise a value of one.

  $ cat > sizes.tc <<'EOF'
  > void *malloc(unsigned long);
  > generic(T) T *f(T *p, unsigned long n)
  > {
  >     T tmp[n];
  >     T zero = {0}, empty = {};
  >     tmp[0] = zero;
  >     tmp[0] = empty;
  >     *p = tmp[0];
  >     return malloc(n * sizeof(T));
  > }
  > EOF
  $ ./golden.exe sizes.tc
  sizes.tc:2: a generic function is checked, but typec does not write its instances yet (design 7.3; work package 3.3) [TC0023]
  [1]

An expression that holds the size, alignment or offset of a type that
mentions a type parameter is no constant expression: not an array
bound, a case value, the operand of _Static_assert or a static
initialiser, and _Alignas takes no such type.

  $ cat > bound.tc <<'EOF'
  > generic(T) void f(T *p) { char b[sizeof(T *)]; (void)b; (void)p; }
  > EOF
  $ ./golden.exe bound.tc
  bound.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > case.tc <<'EOF'
  > generic(T) int f(int x) { switch (x) { case sizeof(T): return 1; } return 0; }
  > EOF
  $ ./golden.exe case.tc
  case.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > static_assert.tc <<'EOF'
  > generic(T) void f(T *p) { _Static_assert(sizeof(T) > 0, ""); (void)p; }
  > EOF
  $ ./golden.exe static_assert.tc
  static_assert.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > alignas.tc <<'EOF'
  > generic(T) void f(T *p) { _Alignas(T *) char c; (void)c; (void)p; }
  > EOF
  $ ./golden.exe alignas.tc
  alignas.tc:1: the type of `_Alignas` mentions a type parameter, so the alignment differs between arguments (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > static.tc <<'EOF'
  > generic(T) void f(T *p) { static unsigned long n = sizeof(T); (void)n; (void)p; }
  > EOF
  $ ./golden.exe static.tc
  static.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

A structure declared in the body with a member of a type parameter
mentions it.

  $ cat > local.tc <<'EOF'
  > generic(T) void f(T *p)
  > {
  >     struct local { T x; int y; };
  >     char b[sizeof(struct local)];
  >     (void)b;
  >     (void)p;
  > }
  > EOF
  $ ./golden.exe local.tc
  local.tc:4: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

An expression depends on a type parameter whether its sizeof is
evaluated or not.

  $ cat > unevaluated.tc <<'EOF'
  > generic(T) int f(int x) { switch (x) { case 1 || sizeof(T): return 1; } return 0; }
  > EOF
  $ ./golden.exe unevaluated.tc
  unevaluated.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

A value of a type parameter converts to no other type, nor does another
type convert to it.

  $ cat > to_int.tc <<'EOF'
  > generic(T) int f(T t) { int x = t; return x; }
  > EOF
  $ ./golden.exe to_int.tc
  to_int.tc:1: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > from_int.tc <<'EOF'
  > generic(T) T f(T t) { t = 3; return t; }
  > EOF
  $ ./golden.exe from_int.tc
  from_int.tc:1: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > two_parameters.tc <<'EOF'
  > generic(T, U) void f(T t, U u) { t = u; (void)t; }
  > EOF
  $ ./golden.exe two_parameters.tc
  two_parameters.tc:1: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > classify.tc <<'EOF'
  > generic(T) int f(T *p) { return __builtin_classify_type(*p); }
  > EOF
  $ ./golden.exe classify.tc
  classify.tc:1: a value of a type parameter is an argument that no parameter type receives, which the default argument promotions or a builtin read by its type, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

Every constant that C asks for refuses such an expression: a bit-field
width, an enumerator's value and an _Alignas expression too.

  $ cat > width.tc <<'EOF'
  > generic(T) void f(T *p) { struct b { unsigned x : sizeof(T); } b = {0}; (void)b; (void)p; }
  > EOF
  $ ./golden.exe width.tc
  width.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > enumerator.tc <<'EOF'
  > generic(T) int f(T *p) { enum { size = sizeof(T) }; (void)p; return size; }
  > EOF
  $ ./golden.exe enumerator.tc
  enumerator.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > alignas_expression.tc <<'EOF'
  > generic(T) void f(T *p) { _Alignas(sizeof(T)) char c; (void)c; (void)p; }
  > EOF
  $ ./golden.exe alignas_expression.tc
  alignas_expression.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

A union with a member of a type parameter mentions it.

  $ cat > union.tc <<'EOF'
  > generic(T) void f(T *p)
  > {
  >     union local { T x; int y; };
  >     char b[sizeof(union local)];
  >     (void)b;
  >     (void)p;
  > }
  > EOF
  $ ./golden.exe union.tc
  union.tc:4: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

Two pointers meet, by a conversion or an operation on both, only
where their referenced types are compatible or one is void.

  $ cat > pointer_difference.tc <<'EOF'
  > generic(T) long f(T *p, int *q) { return p - q; }
  > EOF
  $ ./golden.exe pointer_difference.tc
  pointer_difference.tc:1: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > pointer_equality.tc <<'EOF'
  > generic(T) int f(T *p, int *q) { return p == q; }
  > EOF
  $ ./golden.exe pointer_equality.tc
  pointer_equality.tc:1: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > pointer_branch.tc <<'EOF'
  > generic(T) void f(int c, T *p, int *q) { void *r = c ? p : q; (void)r; }
  > EOF
  $ ./golden.exe pointer_branch.tc
  pointer_branch.tc:1: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

A builtin that reads the object a pointer points to does not read a
value of a type parameter.

  $ cat > atomic_load.tc <<'EOF'
  > generic(T) void f(T *p, T *q) { *q = __atomic_load_n(p, 0); }
  > EOF
  $ ./golden.exe atomic_load.tc
  atomic_load.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

  $ cat > sync_add.tc <<'EOF'
  > generic(T) void f(T *p) { (void)__sync_fetch_and_add(p, 1); }
  > EOF
  $ ./golden.exe sync_add.tc
  sync_add.tc:1: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

An asm constraint asks of its operand a size and a kind, which differ
between arguments.

  $ cat > asm_operand.tc <<'EOF'
  > generic(T) void f(T *p) { __asm__("" : : "r"(p)); }
  > EOF
  $ ./golden.exe asm_operand.tc
  asm_operand.tc:1: an asm operand has a type that mentions a type parameter, which is not valid C of one meaning for every value type (design 7.1 rule 3) [TC0075]
  [1]

An expression depends on a type parameter wherever its sizeof stands,
an index of an offsetof included.

  $ cat > order.tc <<'EOF'
  > generic(T) int f(int x, int n) { switch (x) { case n + sizeof(T): return 1; } return 0; }
  > EOF
  $ ./golden.exe order.tc
  order.tc:1: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

  $ cat > offsetof_index.tc <<'EOF'
  > struct s { int a[8]; };
  > generic(T) void f(T *p) { _Static_assert(__builtin_offsetof(struct s, a[sizeof(T)]) > 0, ""); (void)p; }
  > EOF
  $ ./golden.exe offsetof_index.tc
  offsetof_index.tc:2: the expression holds the size, alignment or offset of a type that mentions a type parameter, so it is no constant expression (design 7.1 rule 4) [TC0076]
  [1]

Design 7.1 rule 6: what follows generic( ) is one function, which its
instances are written from. It has a prototype; static is its only
storage class, and inline, _Noreturn and attributes stand on the
definition.

  $ cat > forms.tc <<'EOF'
  > generic(T) static inline void put(T *p, T t);
  > generic(T) static inline _Noreturn __attribute__((cold)) void put(T *p, T t) { *p = t; for (;;) {} }
  > generic(T) void none(void);
  > EOF
  $ ./golden.exe forms.tc
  forms.tc:1: a generic function is checked, but typec does not write its instances yet (design 7.3; work package 3.3) [TC0023]
  [1]

  $ cat > empty_list.tc <<'EOF'
  > generic(T) void f();
  > EOF
  $ ./golden.exe empty_list.tc
  empty_list.tc:1: a generic function has a prototype, `(void)` where it takes no argument, and neither `()` nor an identifier list (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > identifiers.tc <<'EOF'
  > generic(T) void f(p) T *p; { (void)p; }
  > EOF
  $ ./golden.exe identifiers.tc
  identifiers.tc:1: a generic function has a prototype, `(void)` where it takes no argument, and neither `()` nor an identifier list (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > extern.tc <<'EOF'
  > generic(T) extern void f(T *p);
  > EOF
  $ ./golden.exe extern.tc
  extern.tc:1: `static` is the only storage class of a generic function, whose instances have internal linkage (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > noreturn.tc <<'EOF'
  > generic(T) _Noreturn void f(T *p);
  > EOF
  $ ./golden.exe noreturn.tc
  noreturn.tc:1: `_Noreturn` and attributes stand on the definition of a generic function, which its instances are written from (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > attribute.tc <<'EOF'
  > generic(T) void f(T *p) __attribute__((cold));
  > EOF
  $ ./golden.exe attribute.tc
  attribute.tc:1: `_Noreturn` and attributes stand on the definition of a generic function, which its instances are written from (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > asm_label.tc <<'EOF'
  > generic(T) void f(T *p) __asm__("g");
  > EOF
  $ ./golden.exe asm_label.tc
  asm_label.tc:1: an assembler label would give every instance of a generic function one name (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > two.tc <<'EOF'
  > generic(T) void f(T *p), g(T *p);
  > EOF
  $ ./golden.exe two.tc
  two.tc:1: `generic( )` prefixes one function: its definition, or a declaration with one declarator, which declares a function (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > object.tc <<'EOF'
  > generic(T) T *p;
  > EOF
  $ ./golden.exe object.tc
  object.tc:1: `generic( )` prefixes one function: its definition, or a declaration with one declarator, which declares a function (design 7.1 rule 6) [TC0077]
  [1]

  $ cat > tag_only.tc <<'EOF'
  > generic(T) struct s { int x; };
  > EOF
  $ ./golden.exe tag_only.tc
  tag_only.tc:1: `generic( )` prefixes one function: its definition, or a declaration with one declarator, which declares a function (design 7.1 rule 6) [TC0077]
  [1]

Design 7.1 rule 7: declarations of a generic function agree where they
have as many type parameters and, by position, declare the same type.
A declaration in a block hides the name.

  $ cat > agree.tc <<'EOF'
  > generic(T) void f(T *p, const T t);
  > generic(U) void f(U *q, U u) { *q = u; }
  > void g(void) { int f = 0; (void)f; }
  > EOF
  $ ./golden.exe agree.tc
  agree.tc:1: a generic function is checked, but typec does not write its instances yet (design 7.3; work package 3.3) [TC0023]
  [1]

  $ cat > count.tc <<'EOF'
  > generic(T) void f(T *p);
  > generic(T, U) void f(T *p);
  > EOF
  $ ./golden.exe count.tc
  count.tc:2: 'f' is declared again with another number of type parameters (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > other_type.tc <<'EOF'
  > generic(T) void f(T *p);
  > generic(T) void f(int *p);
  > EOF
  $ ./golden.exe other_type.tc
  other_type.tc:2: 'f' is declared again with another type (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > swapped.tc <<'EOF'
  > generic(T, U) void f(T *p, U *q);
  > generic(U, T) void f(T *p, U *q);
  > EOF
  $ ./golden.exe swapped.tc
  swapped.tc:2: 'f' is declared again with another type (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > compatible_only.tc <<'EOF'
  > generic(T) void f(T (*p)[]);
  > generic(T) void f(T (*p)[4]);
  > EOF
  $ ./golden.exe compatible_only.tc
  compatible_only.tc:2: 'f' is declared again with another type (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > defined_twice.tc <<'EOF'
  > generic(T) void f(T *p) { (void)p; }
  > generic(T) void f(T *p) { (void)p; }
  > EOF
  $ ./golden.exe defined_twice.tc
  defined_twice.tc:2: 'f' is defined again (design 7.1 rule 7) [TC0078]
  [1]

No backend compares two declarations of a generic function, so a
length or a type that typec does not compute agrees with nothing.

  $ cat > opaque_length.tc <<'EOF'
  > generic(T) void f(T (*p)[_Alignof(long)]);
  > generic(T) void f(T (*p)[3]);
  > EOF
  $ ./golden.exe opaque_length.tc
  opaque_length.tc:2: 'f' is declared again with another type (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > unknown_type.tc <<'EOF'
  > generic(T) void f(T t);
  > generic(T) __attribute__((weird_unknown)) long f(T t, int y) { (void)t; return y; }
  > EOF
  $ ./golden.exe unknown_type.tc
  unknown_type.tc:2: 'f' is declared again, and whether with the same type depends on the attribute 'weird_unknown', whose type typec does not compute (design 7.1 rule 7) [TC0078]
  [1]

The name of a generic function denotes nothing else at file scope.

  $ cat > before.tc <<'EOF'
  > void f(int *p);
  > generic(T) void f(T *p);
  > EOF
  $ ./golden.exe before.tc
  before.tc:2: 'f' is a generic function, so no other declaration of its name stands at file scope (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > after.tc <<'EOF'
  > generic(T) void f(T *p);
  > void f(int *p);
  > EOF
  $ ./golden.exe after.tc
  after.tc:2: 'f' is a generic function, so no other declaration of its name stands at file scope (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > object_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > int f;
  > EOF
  $ ./golden.exe object_after.tc
  object_after.tc:2: 'f' is a generic function, so no other declaration of its name stands at file scope (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > typedef_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > typedef int f;
  > EOF
  $ ./golden.exe typedef_after.tc
  typedef_after.tc:2: 'f' is a generic function, so no other declaration of its name stands at file scope (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > enumerator_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > enum { f };
  > EOF
  $ ./golden.exe enumerator_after.tc
  enumerator_after.tc:2: 'f' is a generic function, so no other declaration of its name stands at file scope (design 7.1 rule 7) [TC0078]
  [1]

  $ cat > type_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > type f = int;
  > EOF
  $ ./golden.exe type_after.tc
  type_after.tc:2: `f` is declared twice in one scope, and one of them is a type declaration (design 3.1 rule 5) [TC0003]
  [1]
