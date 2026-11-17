SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Generic functions (design 7.1): the definition is read once against an
opaque value type for each type parameter. A unit whose generic
functions pass the check is accepted; test/golden/function_instances.t
shows the instances that it writes (design 7.3).

A definition that uses its type parameters only as every value type
allows is checked and accepted.

  $ cat > last.tc <<'EOF'
  > generic(T)
  > T *last(T *items, unsigned long n)
  > {
  >     T copy = items[0];
  >     return n ? &items[n - 1] : &copy;
  > }
  > generic(K, V) void put(K *key, V *value);
  > EOF
  $ ./golden.exe last.tc > /dev/null

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
  $ ./golden.exe discard.tc > /dev/null

A cast of a value of a type parameter, other than to void, is refused,
and so is a cast to a type parameter.

  $ cat > cast_int.tc <<'EOF'
  > generic(T) int f(T t) { return (int)t; }
  > EOF
  $ ./golden.exe cast_int.tc
  cast_int.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > cast_to.tc <<'EOF'
  > generic(T) void f(T t) { (T)t; }
  > EOF
  $ ./golden.exe cast_to.tc
  cast_to.tc:1: error: a cast to a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

So are the operations that C refuses of a structure: arithmetic,
comparison, member access, calls and truth tests.

  $ cat > arithmetic.tc <<'EOF'
  > generic(T) void f(T a, T b) { a + b; }
  > EOF
  $ ./golden.exe arithmetic.tc
  arithmetic.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > compare.tc <<'EOF'
  > generic(T) int f(T a, T b) { return a == b; }
  > EOF
  $ ./golden.exe compare.tc
  compare.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > member.tc <<'EOF'
  > generic(T) int f(T a) { return a.x; }
  > EOF
  $ ./golden.exe member.tc
  member.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > called.tc <<'EOF'
  > generic(T) void f(T a) { a(); }
  > EOF
  $ ./golden.exe called.tc
  called.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > truth.tc <<'EOF'
  > generic(T) int f(T a) { if (a) return 1; return 0; }
  > EOF
  $ ./golden.exe truth.tc
  truth.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
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
  variadic.tc:2: error: a value of a type parameter is an argument that no parameter type receives, which the default argument promotions or a builtin read by its type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > unprototyped.tc <<'EOF'
  > int g();
  > generic(T) void f(T t) { g(t); }
  > EOF
  $ ./golden.exe unprototyped.tc
  unprototyped.tc:2: error: a value of a type parameter is an argument that no parameter type receives, which the default argument promotions or a builtin read by its type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > va_arg.tc <<'EOF'
  > generic(T) void f(T *p, __builtin_va_list ap) { *p = __builtin_va_arg(ap, T); }
  > EOF
  $ ./golden.exe va_arg.tc
  va_arg.tc:1: error: va_arg of a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > old_pointer.tc <<'EOF'
  > generic(T) void f(T t, void (*take)(T))
  > {
  >     (void)t;
  >     void (*old)() = take;
  >     (void)old;
  > }
  > EOF
  $ ./golden.exe old_pointer.tc
  old_pointer.tc:4: error: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

Provisionally, the conditional operator takes no value of a type
parameter: its type is that of the usual arithmetic conversions.

  $ cat > conditional.tc <<'EOF'
  > generic(T) void f(int c, T a, T b, T *p) { *p = c ? a : b; }
  > EOF
  $ ./golden.exe conditional.tc
  conditional.tc:1: error: a value of a type parameter is a branch of the conditional operator, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

A construct that compares types is an error where the argument decides
the answer: where a type parameter meets another type in a part of the
comparison that decides it, among the associations of _Generic too.

  $ cat > selection.tc <<'EOF'
  > generic(T) int f(int x) { return _Generic(x, T: 1, default: 0); }
  > EOF
  $ ./golden.exe selection.tc
  selection.tc:1: error: _Generic compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]

  $ cat > compatible.tc <<'EOF'
  > generic(T) int f(void) { return __builtin_types_compatible_p(T, int); }
  > EOF
  $ ./golden.exe compatible.tc
  compatible.tc:1: error: __builtin_types_compatible_p compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]
  $ cat > associations.tc <<'EOF'
  > generic(T) int f(T t) { return _Generic(&t, T *: 1, int *: 2); }
  > EOF
  $ ./golden.exe associations.tc
  associations.tc:1: error: _Generic compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]

A comparison that a type parameter does not decide stands: a type
parameter with itself, and two types that differ in a part where no
type parameter meets another type, as an array and a pointer in
ARRAY_SIZE.

  $ cat > compared.tc <<'EOF'
  > generic(T) unsigned long f(T t)
  > {
  >     T row[4];
  >     row[0] = t;
  >     return 0 * sizeof(char[1 - 2 * __builtin_types_compatible_p(
  >                __typeof__(row), __typeof__(&row[0]))])
  >         + _Generic(&t, T *: 1, default: 0)
  >         + __builtin_types_compatible_p(T (*)(int), int (*)(long));
  > }
  > EOF
  $ ./golden.exe compared.tc > /dev/null

The argument decides wherever a type parameter enters the comparison,
not only as a bare parameter: in an instance of a generic type, against
a type that typec does not know, and as a parameter of a prototype
compared with a function type without one, whose promoted types the
argument decides.

  $ cat > instances.tc <<'EOF'
  > type vector(T) = struct { T *data; unsigned long length; };
  > generic(T) int f(void)
  > {
  >     return __builtin_types_compatible_p(vector(T), vector(int));
  > }
  > EOF
  $ ./golden.exe instances.tc
  instances.tc:4: error: __builtin_types_compatible_p compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]
  $ cat > handles.tc <<'EOF'
  > type handle(T) = distinct T *;
  > generic(T) int f(void)
  > {
  >     return __builtin_types_compatible_p(handle(T), handle(int));
  > }
  > EOF
  $ ./golden.exe handles.tc
  handles.tc:4: error: __builtin_types_compatible_p compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]
  $ cat > unknown.tc <<'EOF'
  > generic(T) int f(void)
  > {
  >     return __builtin_types_compatible_p(T, _Float16)
  >         + __builtin_types_compatible_p(T, _Complex int);
  > }
  > EOF
  $ ./golden.exe unknown.tc
  unknown.tc:3: error: __builtin_types_compatible_p compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]
  $ cat > unprototyped.tc <<'EOF'
  > generic(T) int f(void)
  > {
  >     return __builtin_types_compatible_p(void (*)(T), void (*)());
  > }
  > EOF
  $ ./golden.exe unprototyped.tc
  unprototyped.tc:3: error: __builtin_types_compatible_p compares a type parameter with another type, which is compatible with it for some arguments and not for others [type-parameter-constant]
  [1]

Two instances that differ in a part that mentions no type parameter
are incompatible for every argument, and so are two structures of
different tags, though both hold a type parameter.

  $ cat > tags.tc <<'EOF'
  > generic(T) int f(T t)
  > {
  >     struct a { T x; } u = { t };
  >     struct b { T y; };
  >     return _Generic(u, struct b: 1, default: 0);
  > }
  > EOF
  $ ./golden.exe tags.tc > /dev/null

  $ cat > apart.tc <<'EOF'
  > type vector(T) = struct { T *data; unsigned long length; };
  > generic(T) unsigned long f(void)
  > {
  >     return sizeof(char[1 - 2 * __builtin_types_compatible_p(
  >                vector(T) *, vector(T) **)]);
  > }
  > EOF
  $ ./golden.exe apart.tc > /dev/null

No declaration in the body gives its identifier linkage, whatever its
type, as every instance would declare the one object or function again,
and a type that the body declares is each instance's own. A static
object and a pointer to a function have no linkage, and stand.

  $ cat > linked.tc <<'EOF'
  > generic(T) T *keep(T *t)
  > {
  >     static T cache;
  >     T (*pick)(T *);
  >     cache = *t;
  >     return &cache;
  > }
  > EOF
  $ ./golden.exe linked.tc > /dev/null

  $ cat > extern_int.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     extern int count;
  > }
  > EOF
  $ ./golden.exe extern_int.tc
  extern_int.tc:3: error: a declaration in a generic function gives its identifier linkage, so every instance would declare the one object or function again [type-parameter-operation]
  [1]
  $ cat > extern_body_type.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     struct s { int a; };
  >     extern struct s x;
  > }
  > EOF
  $ ./golden.exe extern_body_type.tc
  extern_body_type.tc:4: error: a declaration in a generic function gives its identifier linkage, so every instance would declare the one object or function again [type-parameter-operation]
  [1]
  $ cat > block_int_function.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     int helper(int);
  > }
  > EOF
  $ ./golden.exe block_int_function.tc
  block_int_function.tc:3: error: a declaration in a generic function gives its identifier linkage, so every instance would declare the one object or function again [type-parameter-operation]
  [1]

  $ cat > extern_object.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     extern T shared;
  > }
  > EOF
  $ ./golden.exe extern_object.tc
  extern_object.tc:3: error: a declaration in a generic function gives its identifier linkage, so every instance would declare the one object or function again [type-parameter-operation]
  [1]

  $ cat > block_function.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     T helper(T);
  > }
  > EOF
  $ ./golden.exe block_function.tc
  block_function.tc:3: error: a declaration in a generic function gives its identifier linkage, so every instance would declare the one object or function again [type-parameter-operation]
  [1]

No initialiser enters a type parameter but the zero initialiser, {0}
or {}, which zeroes whole any object or subobject whose type mentions
one, through elided braces too; an expression of the type parameter
initialises it whole.

  $ cat > zeroed.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     T u = {0};
  >     T v = {};
  >     T row[4] = {0};
  >     T one[1] = {0};
  >     T both[] = { t, t };
  >     T *fresh = &(T){0};
  >     struct { T a; int b; } w = { t, 5 };
  >     struct { T a; int b; } z = {0};
  >     struct { T a; int b; } y = { .b = 5 };
  >     struct { T a; int b; } x = { {0}, 5 };
  >     struct { T a[2]; int b; } r = { {}, 5 };
  >     (void)u; (void)v; (void)row; (void)one; (void)both; (void)fresh;
  >     (void)w; (void)z; (void)y; (void)x; (void)r;
  > }
  > EOF
  $ ./golden.exe zeroed.tc > /dev/null

Any other initialiser that reaches a type parameter is for one of its
members, in its own braces or through elided ones, and is an error.

  $ cat > braced.tc <<'EOF'
  > generic(T) void f(T *p, T t) { T u = { t }; *p = u; }
  > EOF
  $ ./golden.exe braced.tc
  braced.tc:1: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
  [1]
  $ cat > elided_array.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     T both[] = { 0, 0 };
  > }
  > EOF
  $ ./golden.exe elided_array.tc
  elided_array.tc:3: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
  [1]
  $ cat > unsized.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     T one[] = {0};
  > }
  > EOF
  $ ./golden.exe unsized.tc
  unsized.tc:3: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
  [1]
  $ cat > elided_member.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     struct { T a; int b; } w = { 0, 5 };
  > }
  > EOF
  $ ./golden.exe elided_member.tc
  elided_member.tc:3: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
  [1]
  $ cat > designated.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     struct { T a; int b; } y = { .a = 0 };
  > }
  > EOF
  $ ./golden.exe designated.tc
  designated.tc:3: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
  [1]
  $ cat > literal.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     T *q = (T[]){ 0, 0 }; (void)q;
  > }
  > EOF
  $ ./golden.exe literal.tc
  literal.tc:3: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
  [1]
  $ cat > nested.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     T u = { {0} };
  > }
  > EOF
  $ ./golden.exe nested.tc
  nested.tc:3: error: an initialiser reaches into a value of a type parameter, which only a value of its type or the zero initialiser {0} or {} initialises [type-parameter-operation]
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
  $ ./golden.exe sizes.tc > /dev/null

An expression that holds the size, alignment or offset of a type that
mentions a type parameter is no constant expression: not an array
bound, a case value, the operand of _Static_assert or a static
initialiser, and _Alignas takes no such type.

  $ cat > bound.tc <<'EOF'
  > generic(T) void f(T *p) { char b[sizeof(T *)]; (void)b; (void)p; }
  > EOF
  $ ./golden.exe bound.tc
  bound.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

  $ cat > case.tc <<'EOF'
  > generic(T) int f(int x) { switch (x) { case sizeof(T): return 1; } return 0; }
  > EOF
  $ ./golden.exe case.tc
  case.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

  $ cat > static_assert.tc <<'EOF'
  > generic(T) void f(T *p) { _Static_assert(sizeof(T) > 0, ""); (void)p; }
  > EOF
  $ ./golden.exe static_assert.tc
  static_assert.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

  $ cat > alignas.tc <<'EOF'
  > generic(T) void f(T *p) { _Alignas(T *) char c; (void)c; (void)p; }
  > EOF
  $ ./golden.exe alignas.tc
  alignas.tc:1: error: the type of `_Alignas` mentions a type parameter, so the alignment differs between arguments [type-parameter-constant]
  [1]

  $ cat > static.tc <<'EOF'
  > generic(T) void f(T *p) { static unsigned long n = sizeof(T); (void)n; (void)p; }
  > EOF
  $ ./golden.exe static.tc
  static.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
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
  local.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

An expression depends on a type parameter whether its sizeof is
evaluated or not.

  $ cat > unevaluated.tc <<'EOF'
  > generic(T) int f(int x) { switch (x) { case 1 || sizeof(T): return 1; } return 0; }
  > EOF
  $ ./golden.exe unevaluated.tc
  unevaluated.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

A value of a type parameter converts to no other type, nor does another
type convert to it.

  $ cat > to_int.tc <<'EOF'
  > generic(T) int f(T t) { int x = t; return x; }
  > EOF
  $ ./golden.exe to_int.tc
  to_int.tc:1: error: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > from_int.tc <<'EOF'
  > generic(T) T f(T t) { t = 3; return t; }
  > EOF
  $ ./golden.exe from_int.tc
  from_int.tc:1: error: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > two_parameters.tc <<'EOF'
  > generic(T, U) void f(T t, U u) { t = u; (void)t; }
  > EOF
  $ ./golden.exe two_parameters.tc
  two_parameters.tc:1: error: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > to_option.tc <<'EOF'
  > generic(T) void f(T t) { option(int) o = t; (void)o; }
  > EOF
  $ ./golden.exe to_option.tc
  to_option.tc:1: error: a value converts to or from a type parameter of another type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

Nor does an instance that mentions a type parameter convert to one
that it matches only for some arguments; an instance of the same
arguments converts.

  $ cat > instances.tc <<'EOF'
  > type list(T) = struct { T *head; };
  > generic(T) void f(list(T) a, list(int) b) { a = b; (void)a; }
  > EOF
  $ ./golden.exe instances.tc
  instances.tc:2: error: a value converts between types that a type argument decides are compatible or not, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]
  $ cat > same_instances.tc <<'EOF'
  > type list(T) = struct { T *head; };
  > generic(T) void f(list(T) a, list(T) b) { a = b; (void)a; }
  > EOF
  $ ./golden.exe same_instances.tc > /dev/null

  $ cat > classify.tc <<'EOF'
  > generic(T) int f(T *p) { return __builtin_classify_type(*p); }
  > EOF
  $ ./golden.exe classify.tc
  classify.tc:1: error: a value of a type parameter is an argument that no parameter type receives, which the default argument promotions or a builtin read by its type, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

Every constant that C asks for refuses such an expression: a bit-field
width, an enumerator's value and an _Alignas expression too.

  $ cat > width.tc <<'EOF'
  > generic(T) void f(T *p) { struct b { unsigned x : sizeof(T); } b = {0}; (void)b; (void)p; }
  > EOF
  $ ./golden.exe width.tc
  width.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

  $ cat > enumerator.tc <<'EOF'
  > generic(T) int f(T *p) { enum { size = sizeof(T) }; (void)p; return size; }
  > EOF
  $ ./golden.exe enumerator.tc
  enumerator.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

  $ cat > alignas_expression.tc <<'EOF'
  > generic(T) void f(T *p) { _Alignas(sizeof(T)) char c; (void)c; (void)p; }
  > EOF
  $ ./golden.exe alignas_expression.tc
  alignas_expression.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
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
  union.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

Two pointers meet, by a conversion or an operation on both, only
where their referenced types are compatible or one is void.

  $ cat > pointer_difference.tc <<'EOF'
  > generic(T) long f(T *p, int *q) { return p - q; }
  > EOF
  $ ./golden.exe pointer_difference.tc
  pointer_difference.tc:1: error: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > pointer_equality.tc <<'EOF'
  > generic(T) int f(T *p, int *q) { return p == q; }
  > EOF
  $ ./golden.exe pointer_equality.tc
  pointer_equality.tc:1: error: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > pointer_branch.tc <<'EOF'
  > generic(T) void f(int c, T *p, int *q) { void *r = c ? p : q; (void)r; }
  > EOF
  $ ./golden.exe pointer_branch.tc
  pointer_branch.tc:1: error: pointers to incompatible types meet where one mentions a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

Where typec does not know whether the referenced types are compatible,
the pointers do not meet either.

  $ cat > pointer_unknown.tc <<'EOF'
  > generic(T) void f(T *p) { _Complex int *q = p; (void)q; }
  > EOF
  $ ./golden.exe pointer_unknown.tc
  pointer_unknown.tc:1: error: pointers meet where one mentions a type parameter, and whether their types are compatible depends on '_Complex int', whose type typec does not compute, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

A builtin that reads the object a pointer points to does not read a
value of a type parameter.

  $ cat > atomic_load.tc <<'EOF'
  > generic(T) void f(T *p, T *q) { *q = __atomic_load_n(p, 0); }
  > EOF
  $ ./golden.exe atomic_load.tc
  atomic_load.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

  $ cat > sync_add.tc <<'EOF'
  > generic(T) void f(T *p) { (void)__sync_fetch_and_add(p, 1); }
  > EOF
  $ ./golden.exe sync_add.tc
  sync_add.tc:1: error: a value of a type parameter is the operand of an operation, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

An asm constraint asks of its operand a size and a kind, which differ
between arguments.

  $ cat > asm_operand.tc <<'EOF'
  > generic(T) void f(T *p) { __asm__("" : : "r"(p)); }
  > EOF
  $ ./golden.exe asm_operand.tc
  asm_operand.tc:1: error: an asm operand has a type that mentions a type parameter, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]

An expression depends on a type parameter wherever its sizeof stands,
an index of an offsetof included.

  $ cat > order.tc <<'EOF'
  > generic(T) int f(int x, int n) { switch (x) { case n + sizeof(T): return 1; } return 0; }
  > EOF
  $ ./golden.exe order.tc
  order.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

  $ cat > offsetof_index.tc <<'EOF'
  > struct s { int a[8]; };
  > generic(T) void f(T *p) { _Static_assert(__builtin_offsetof(struct s, a[sizeof(T)]) > 0, ""); (void)p; }
  > EOF
  $ ./golden.exe offsetof_index.tc
  offsetof_index.tc:2: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

Dependence is a fact of a value. Arithmetic on a pointer to a type
that mentions a type parameter asks for its size, and the address of a
member of one for an offset, as sizeof does.

  $ cat > pointer_bound.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     char b[(unsigned long)((T *)0 + 1) > 1000 ? 1 : -1];
  > }
  > EOF
  $ ./golden.exe pointer_bound.tc
  pointer_bound.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > pool_address.tc <<'EOF'
  > generic(T) T *f(T t)
  > {
  >     static T pool[8];
  >     static T *next = &pool[3];
  >     return next;
  > }
  > EOF
  $ ./golden.exe pool_address.tc
  pool_address.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > member_address.tc <<'EOF'
  > generic(T) unsigned long f(T t)
  > {
  >     struct box { T v; int n; };
  >     static unsigned long at = (unsigned long)&((struct box *)0)->n;
  >     return at;
  > }
  > EOF
  $ ./golden.exe member_address.tc
  member_address.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

The same constructs over a type that mentions no type parameter stand,
and so does the address of a static array of a type parameter, which
asks for no layout.

  $ cat > plain_addresses.tc <<'EOF'
  > generic(T) T *f(T t)
  > {
  >     struct box { int v; int n; };
  >     static char text[8];
  >     static char *next = &text[3];
  >     static unsigned long at = (unsigned long)&((struct box *)0)->n;
  >     static T pool[8];
  >     static T *first = pool;
  >     (void)next;
  >     (void)at;
  >     return first;
  > }
  > EOF
  $ ./golden.exe plain_addresses.tc > /dev/null

A builtin depends unless the values of its arguments alone decide it.

  $ cat > classify_bound.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     char b[__builtin_object_size(&t, 0) > 1000 ? 1 : -1];
  > }
  > EOF
  $ ./golden.exe classify_bound.tc
  classify_bound.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > value_builtins.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     static int bits = __builtin_popcount(7) + __builtin_bswap32(1);
  >     (void)bits;
  > }
  > void g(int t) { char b[__builtin_classify_type(t) == 1 ? 1 : -1]; }
  > EOF
  $ ./golden.exe value_builtins.tc > /dev/null

A `const` object carries the dependence of its initialiser, which the
backends read as a constant; an object that is not `const` is a
constant to neither, so its use declares a variable length array.

  $ cat > const_bound.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     const int j = sizeof(T) > 1000 ? 1 : -1;
  >     char b[j];
  > }
  > EOF
  $ ./golden.exe const_bound.tc
  const_bound.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > const_array_static.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     const int k[2] = { 1, sizeof(T) };
  >     static int s = k[1];
  > }
  > EOF
  $ ./golden.exe const_array_static.tc
  const_array_static.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > variable_bound.tc <<'EOF'
  > generic(T) void f(T t, unsigned long count)
  > {
  >     unsigned long n = count * sizeof(T);
  >     const int four = 4;
  >     char scratch[n];
  >     char fixed[four];
  >     (void)scratch;
  >     (void)fixed;
  > }
  > EOF
  $ ./golden.exe variable_bound.tc > /dev/null

Whether an expression that depends is a null pointer constant, which
of two operands __builtin_choose_expr selects, and the index of a
designator differ between arguments.

  $ cat > null_pointer.tc <<'EOF'
  > generic(T) void *f(T *p, int c)
  > {
  >     return c ? p : (void *)(sizeof(T) > 1000);
  > }
  > EOF
  $ ./golden.exe null_pointer.tc
  null_pointer.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > plain_null_pointer.tc <<'EOF'
  > generic(T) void *f(T *p, int c)
  > {
  >     return c ? p : (void *)(sizeof(int) > 1000);
  > }
  > EOF
  $ ./golden.exe plain_null_pointer.tc > /dev/null

An integer converts to a pointer only as a null pointer constant, so
each conversion of one that depends refuses it: an initialiser, an
assignment, an argument, an equality and the integer branch of ?:.

  $ cat > null_initialised.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     T *q = (sizeof(T) > 1000);
  >     (void)q;
  > }
  > EOF
  $ ./golden.exe null_initialised.tc
  null_initialised.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_assigned.tc <<'EOF'
  > generic(T) void f(T *q)
  > {
  >     q = (sizeof(T) > 1000);
  > }
  > EOF
  $ ./golden.exe null_assigned.tc
  null_assigned.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_compared.tc <<'EOF'
  > generic(T) int f(T *q)
  > {
  >     return q == (sizeof(T) > 1000);
  > }
  > EOF
  $ ./golden.exe null_compared.tc
  null_compared.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_branch.tc <<'EOF'
  > generic(T) T *f(T *q, int c)
  > {
  >     return c ? q : (sizeof(T) > 1000);
  > }
  > EOF
  $ ./golden.exe null_branch.tc
  null_branch.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_argument.tc <<'EOF'
  > void g(int *);
  > generic(T) void f(void)
  > {
  >     g(sizeof(T) > 1000);
  > }
  > EOF
  $ ./golden.exe null_argument.tc
  null_argument.tc:4: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_elided.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     struct { struct { T *q; } in; int b; } s = { sizeof(T) - 4, 5 };
  > }
  > EOF
  $ ./golden.exe null_elided.tc
  null_elided.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_designated.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     struct { struct { T *q; } in; } s = { .in = sizeof(T) - 4 };
  > }
  > EOF
  $ ./golden.exe null_designated.tc
  null_designated.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_function.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     void (*g)(void) = (void *)(sizeof(T) - 4);
  > }
  > EOF
  $ ./golden.exe null_function.tc
  null_function.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_function_compared.tc <<'EOF'
  > generic(T) int f(void (*g)(void))
  > {
  >     return g == (void *)(sizeof(T) - 4);
  > }
  > EOF
  $ ./golden.exe null_function_compared.tc
  null_function_compared.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > null_plain.tc <<'EOF'
  > generic(T) int f(T *q, int c)
  > {
  >     T *r = 0;
  >     q = c ? q : (sizeof(int) > 1000);
  >     return q == r && r != (sizeof(int) > 1000) && sizeof(T) > 4;
  > }
  > EOF
  $ ./golden.exe null_plain.tc > /dev/null
  $ cat > choose.tc <<'EOF'
  > generic(T) unsigned long f(T t)
  > {
  >     return sizeof(__builtin_choose_expr(sizeof(T) > 1000, (char)0, 0L));
  > }
  > EOF
  $ ./golden.exe choose.tc
  choose.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > designator_index.tc <<'EOF'
  > generic(T) void f(T t)
  > {
  >     int a[4] = { [sizeof(T) > 1000] = 1 };
  > }
  > EOF
  $ ./golden.exe designator_index.tc
  designator_index.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

No generic function has a universe name (design 3.6), the name of a
slice operation no more than that of a universe type, while a function
that is not generic may take one.

  $ printf 'generic(T) static T option(T *p) { return *p; }\n' \
  >   > universe_definition.tc
  $ ./golden.exe universe_definition.tc
  universe_definition.tc:1: error: `option` is a universe name, which no generic has [generic-universe-name]
  [1]

  $ printf 'generic(T) static void slice_sub(T *p);\n' > universe_prototype.tc
  $ ./golden.exe universe_prototype.tc
  universe_prototype.tc:1: error: `slice_sub` is a universe name, which no generic has [generic-universe-name]
  [1]

  $ printf 'static int slice_sub(int *p) { return *p; }\n' > universe_plain.tc
  $ ./golden.exe universe_plain.tc > /dev/null

Design 7.1 rule 6: what follows generic( ) is one function, which its
instances are written from. It has a prototype; static is its only
storage class, and inline, _Noreturn and attributes stand on the
definition.

  $ cat > forms.tc <<'EOF'
  > generic(T) static inline void put(T *p, T t);
  > generic(T) static inline _Noreturn __attribute__((cold)) void put(T *p, T t) { *p = t; for (;;) {} }
  > generic(T) void none(void);
  > EOF
  $ ./golden.exe forms.tc > /dev/null

  $ cat > empty_list.tc <<'EOF'
  > generic(T) void f();
  > EOF
  $ ./golden.exe empty_list.tc
  empty_list.tc:1: error: a generic function has a prototype, `(void)` where it takes no argument, and neither `()` nor an identifier list [generic-function-form]
  [1]

  $ cat > identifiers.tc <<'EOF'
  > generic(T) void f(p) T *p; { (void)p; }
  > EOF
  $ ./golden.exe identifiers.tc
  identifiers.tc:1: error: a generic function has a prototype, `(void)` where it takes no argument, and neither `()` nor an identifier list [generic-function-form]
  [1]

  $ cat > extern.tc <<'EOF'
  > generic(T) extern void f(T *p);
  > EOF
  $ ./golden.exe extern.tc
  extern.tc:1: error: `static` is the only storage class of a generic function, whose instances have internal linkage [generic-function-form]
  [1]

  $ cat > noreturn.tc <<'EOF'
  > generic(T) _Noreturn void f(T *p);
  > EOF
  $ ./golden.exe noreturn.tc
  noreturn.tc:1: error: `_Noreturn` and attributes stand on the definition of a generic function, which its instances are written from [generic-function-form]
  [1]

  $ cat > attribute.tc <<'EOF'
  > generic(T) void f(T *p) __attribute__((cold));
  > EOF
  $ ./golden.exe attribute.tc
  attribute.tc:1: error: `_Noreturn` and attributes stand on the definition of a generic function, which its instances are written from [generic-function-form]
  [1]

  $ cat > asm_label.tc <<'EOF'
  > generic(T) void f(T *p) __asm__("g");
  > EOF
  $ ./golden.exe asm_label.tc
  asm_label.tc:1: error: an assembler label would give every instance of a generic function one name [generic-function-form]
  [1]

No parameter has a variably modified type once C has adjusted it, so
`T a[n]` is `T *a` and stands.

  $ cat > adjusted.tc <<'EOF'
  > generic(T) void f(unsigned long n, T a[n], T b[][4], T c[static 4]);
  > EOF
  $ ./golden.exe adjusted.tc > /dev/null

A parameter of a type that typec does not compute is left to rule 7,
which agrees it with no other declaration.

  $ cat > unknown_parameter.tc <<'EOF'
  > generic(T) void f(T *t, _Complex int z) { (void)t; (void)z; }
  > EOF
  $ ./golden.exe unknown_parameter.tc > /dev/null

  $ cat > variable_pointer.tc <<'EOF'
  > generic(T) void f(unsigned long n, T (*m)[n]);
  > EOF
  $ ./golden.exe variable_pointer.tc
  variable_pointer.tc:1: error: no parameter of a generic function is variably modified [generic-function-form]
  [1]

  $ cat > variable_matrix.tc <<'EOF'
  > generic(T) void f(unsigned long n, unsigned long k, T m[n][k]) {}
  > EOF
  $ ./golden.exe variable_matrix.tc
  variable_matrix.tc:1: error: no parameter of a generic function is variably modified [generic-function-form]
  [1]

Where the parameter list ends in an ellipsis, the last named parameter
does not have the type of a type parameter, qualified or not, read from
the type and not from how the head spells it: `va_start` on it is
undefined in the instance for `char`, which a call deduces.

  $ printf 'generic(T) int f(T last, ...);\n' > last_type_parameter.tc
  $ ./golden.exe last_type_parameter.tc
  last_type_parameter.tc:1: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

  $ printf 'generic(T) int f(const T last, ...);\n' > last_const.tc
  $ ./golden.exe last_const.tc
  last_const.tc:1: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

  $ printf 'generic(T) int f(volatile T last, ...);\n' > last_volatile.tc
  $ ./golden.exe last_volatile.tc
  last_volatile.tc:1: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

  $ printf 'generic(T) int f(T first, __typeof__(first) last, ...);\n' \
  >   > last_typeof_first.tc
  $ ./golden.exe last_typeof_first.tc
  last_typeof_first.tc:1: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

  $ printf 'type same(T) = T;\ngeneric(T) int f(same(T) last, ...);\n' \
  >   > last_alias.tc
  $ ./golden.exe last_alias.tc
  last_alias.tc:2: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

  $ printf 'generic(T) int f(T *p, __typeof__(*p) last, ...);\n' \
  >   > last_through_pointer.tc
  $ ./golden.exe last_through_pointer.tc
  last_through_pointer.tc:1: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

  $ cat > last_definition.tc <<'EOF'
  > generic(T) int f(T last, ...) { (void)last; return 0; }
  > EOF
  $ ./golden.exe last_definition.tc
  last_definition.tc:1: error: the last named parameter before the ellipsis of a generic function does not have the type of a type parameter, which the default argument promotions change in some instances [generic-function-form]
  [1]

A type that typec does not compute may be that of a type parameter in
C, so it is refused there too (13.3), even where it is the same in
every instance.

  $ cat > last_unknown.tc <<'EOF'
  > generic(T) int f(T *p,
  >     __typeof__(_Generic((_Float16)0, int: *p, default: *p)) last, ...);
  > EOF
  $ ./golden.exe last_unknown.tc
  last_unknown.tc:1: error: whether a generic function ends in an ellipsis after a parameter of the type of a type parameter depends on '_Float16', whose type typec does not compute [generic-function-form]
  [1]
  $ printf 'generic(T) int f(_Float16 last, ...);\n' > last_float16.tc
  $ ./golden.exe last_float16.tc
  last_float16.tc:1: error: whether a generic function ends in an ellipsis after a parameter of the type of a type parameter depends on '_Float16', whose type typec does not compute [generic-function-form]
  [1]

An attribute that typec does not know makes a function type that it
does not compute, which may end in such a parameter, so it is refused
with an ellipsis and without one.

  $ cat > unknown_function.tc <<'EOF'
  > generic(T) __attribute__((unknown_to_typec)) int f(
  >     __typeof__(_Generic((_Float16)0, int: *(T *)0, default: *(T *)0))
  >         last, ...) { return 0; }
  > EOF
  $ ./golden.exe unknown_function.tc
  unknown_function.tc:1: error: whether a generic function ends in an ellipsis after a parameter of the type of a type parameter depends on the attribute 'unknown_to_typec', whose type typec does not compute [generic-function-form]
  [1]
  $ cat > unknown_function_fixed.tc <<'EOF'
  > generic(T) int f(int x) __attribute__((unknown_to_typec)) { return x; }
  > EOF
  $ ./golden.exe unknown_function_fixed.tc
  unknown_function_fixed.tc:1: error: whether a generic function ends in an ellipsis after a parameter of the type of a type parameter depends on the attribute 'unknown_to_typec', whose type typec does not compute [generic-function-form]
  [1]

The head refuses these forms of a type parameter before rule 6 reads
it (design 3.5 rule 4).

  $ printf 'generic(T) int f(_Atomic(T) last, ...);\n' > last_atomic.tc
  $ ./golden.exe last_atomic.tc
  last_atomic.tc:1: error: the type name of `_Atomic( )` depends on a type parameter [generic-definition]
  [1]
  $ printf 'generic(T) int f(_Atomic T last, ...);\n' > last_atomic_q.tc
  $ ./golden.exe last_atomic_q.tc
  last_atomic_q.tc:1: error: the type qualified by `_Atomic` depends on a type parameter [generic-definition]
  [1]
  $ printf 'generic(T) int f(__typeof__(T) last, ...);\n' > last_typeof.tc
  $ ./golden.exe last_typeof.tc
  last_typeof.tc:1: error: the type name of `typeof( )` depends on a type parameter [generic-definition]
  [1]

No other type that mentions a type parameter is promoted in one
instance and not in another, so a pointer, an adjusted array, a type
application, a parameter between the value and the ellipsis, the
ellipsis of a function type in the head, and a function without
`generic` all stand.

  $ cat > last_stands.tc <<'EOF'
  > type vector(T) = struct { T *data; unsigned long count; };
  > generic(T) int a(T first, __typeof__(&first) last, ...);
  > generic(T) int b(T *last, ...);
  > generic(T) int c(T last[4], ...);
  > generic(T) int d(vector(T) last, ...);
  > generic(T) int e(T first, int count, ...);
  > generic(T) int g(void (*log)(T last, ...), ...);
  > int h(char last, ...);
  > EOF
  $ ./golden.exe last_stands.tc > /dev/null

The head defines no structure, union or enumeration, which an instance
would define twice, as its prototype and at its definition. The body
may define one, and the head may name one declared before.

  $ cat > head_enumeration.tc <<'EOF'
  > generic(T) enum e { A } f(T);
  > EOF
  $ ./golden.exe head_enumeration.tc
  head_enumeration.tc:1: error: the head of a generic function defines no structure, union or enumeration, which every instance would define twice [generic-function-form]
  [1]

  $ cat > head_parameter_structure.tc <<'EOF'
  > generic(T) void f(T t, struct { int x; } *p);
  > EOF
  $ ./golden.exe head_parameter_structure.tc
  head_parameter_structure.tc:1: error: the head of a generic function defines no structure, union or enumeration, which every instance would define twice [generic-function-form]
  [1]

A tag that the head is the first to mention is declared there, in the
scope of the parameter list or at file scope, and is refused too.

  $ cat > head_parameter_tag.tc <<'EOF'
  > generic(T) void f(T t, struct s *p);
  > EOF
  $ ./golden.exe head_parameter_tag.tc
  head_parameter_tag.tc:1: error: the head of a generic function declares no structure, union or enumeration tag, which every instance would declare twice [generic-function-form]
  [1]
  $ cat > head_return_tag.tc <<'EOF'
  > generic(T) union u *f(T t);
  > EOF
  $ ./golden.exe head_return_tag.tc
  head_return_tag.tc:1: error: the head of a generic function declares no structure, union or enumeration tag, which every instance would declare twice [generic-function-form]
  [1]

  $ cat > named_tags.tc <<'EOF'
  > struct s { int x; };
  > generic(T) struct s *f(T *t)
  > {
  >     struct inner { T v; } box = { *t };
  >     enum { B } e = B;
  >     (void)box;
  >     (void)e;
  >     return 0;
  > }
  > EOF
  $ ./golden.exe named_tags.tc > /dev/null

  $ cat > two.tc <<'EOF'
  > generic(T) void f(T *p), g(T *p);
  > EOF
  $ ./golden.exe two.tc
  two.tc:1: error: `generic( )` prefixes one function: its definition, or a declaration with one declarator, which declares a function [generic-function-form]
  [1]

  $ cat > object.tc <<'EOF'
  > generic(T) T *p;
  > EOF
  $ ./golden.exe object.tc
  object.tc:1: error: `generic( )` prefixes one function: its definition, or a declaration with one declarator, which declares a function [generic-function-form]
  [1]

  $ cat > tag_only.tc <<'EOF'
  > generic(T) struct s;
  > EOF
  $ ./golden.exe tag_only.tc
  tag_only.tc:1: error: the head of a generic function declares no structure, union or enumeration tag, which every instance would declare twice [generic-function-form]
  [1]

Design 7.1 rule 7: declarations of a generic function agree where they
have as many type parameters and, by position, declare the same type.
The name of the function is each instance's own. Where C converts
__func__, __FUNCTION__ or __PRETTY_FUNCTION__ to a pointer it stands, as
assert expands to it; where an operation reads its array whole, the
length is the instance's, and it is refused. Its contents depend on a
type parameter as those of a `const` object would.

  $ cat > func_pointer.tc <<'EOF'
  > void puts_name(const char *);
  > void __assert_rtn(const char *, const char *, int, const char *);
  > generic(T) void f(T *p)
  > {
  >     (__builtin_expect(!(p), 0) ? __assert_rtn(__func__, "f.c", 4, "p")
  >         : (void)0);
  >     puts_name(__func__);
  >     puts_name(__FUNCTION__ + 1);
  > }
  > EOF
  $ ./golden.exe func_pointer.tc > /dev/null
  $ cat > func_size.tc <<'EOF'
  > generic(T) unsigned long f(T t) { return sizeof __func__; }
  > EOF
  $ ./golden.exe func_size.tc
  func_size.tc:1: error: __func__ in a generic function is read as an array, whose length is that of the name of each instance, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]
  $ cat > func_address.tc <<'EOF'
  > generic(T) void f(T t) { const char (*name)[] = &__FUNCTION__; }
  > EOF
  $ ./golden.exe func_address.tc
  func_address.tc:1: error: __FUNCTION__ in a generic function is read as an array, whose length is that of the name of each instance, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]
  $ cat > func_typeof.tc <<'EOF'
  > generic(T) void f(T t) { __typeof__(__PRETTY_FUNCTION__) copy; }
  > EOF
  $ ./golden.exe func_typeof.tc
  func_typeof.tc:1: error: __PRETTY_FUNCTION__ in a generic function is read as an array, whose length is that of the name of each instance, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]
  $ cat > func_array.tc <<'EOF'
  > generic(T) void f(T t) { char n[] = __func__; }
  > EOF
  $ ./golden.exe func_array.tc
  func_array.tc:1: error: an array is initialised by an expression that is not a string literal (C11 6.7.9p16)
  [1]
  $ cat > func_static.tc <<'EOF'
  > generic(T) void f(T t) { static int k = __func__[0]; }
  > EOF
  $ ./golden.exe func_static.tc
  func_static.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > plain_name.tc <<'EOF'
  > const char *g(void) { return __func__; }
  > unsigned long h(void) { return sizeof __func__; }
  > generic(T) void f(T t);
  > EOF
  $ ./golden.exe plain_name.tc > /dev/null

A declaration in a block hides the name.

  $ cat > agree.tc <<'EOF'
  > generic(T) void f(T *p, const T t);
  > generic(U) void f(U *q, U u) { *q = u; }
  > void g(void) { int f = 0; (void)f; }
  > EOF
  $ ./golden.exe agree.tc > /dev/null

  $ cat > count.tc <<'EOF'
  > generic(T) void f(T *p);
  > generic(T, U) void f(T *p);
  > EOF
  $ ./golden.exe count.tc
  count.tc:2: error: 'f' is declared again with another number of type parameters [generic-function-agreement]
  [1]

  $ cat > other_type.tc <<'EOF'
  > generic(T) void f(T *p);
  > generic(T) void f(int *p);
  > EOF
  $ ./golden.exe other_type.tc
  other_type.tc:2: error: 'f' is declared again with another type [generic-function-agreement]
  [1]

  $ cat > swapped.tc <<'EOF'
  > generic(T, U) void f(T *p, U *q);
  > generic(U, T) void f(T *p, U *q);
  > EOF
  $ ./golden.exe swapped.tc
  swapped.tc:2: error: 'f' is declared again with another type [generic-function-agreement]
  [1]

  $ cat > compatible_only.tc <<'EOF'
  > generic(T) void f(T (*p)[]);
  > generic(T) void f(T (*p)[4]);
  > EOF
  $ ./golden.exe compatible_only.tc
  compatible_only.tc:2: error: 'f' is declared again with another type [generic-function-agreement]
  [1]

  $ cat > defined_twice.tc <<'EOF'
  > generic(T) void f(T *p) { (void)p; }
  > generic(T) void f(T *p) { (void)p; }
  > EOF
  $ ./golden.exe defined_twice.tc
  defined_twice.tc:2: error: 'f' is defined again [generic-function-agreement]
  [1]

No backend compares two declarations of a generic function, so a
length or a type that typec does not compute agrees with nothing.

  $ cat > opaque_length.tc <<'EOF'
  > generic(T) void f(T (*p)[_Alignof(long)]);
  > generic(T) void f(T (*p)[3]);
  > EOF
  $ ./golden.exe opaque_length.tc
  opaque_length.tc:2: error: 'f' is declared again with another type [generic-function-agreement]
  [1]

  $ cat > unknown_type.tc <<'EOF'
  > generic(T) void f(T t, int y);
  > generic(T) void f(T t, int y __attribute__((weird_unknown))) { (void)t; (void)y; }
  > EOF
  $ ./golden.exe unknown_type.tc
  unknown_type.tc:2: error: 'f' is declared again, and whether with the same type depends on the attribute 'weird_unknown', whose type typec does not compute [generic-function-agreement]
  [1]

The name of a generic function denotes nothing else at file scope.

  $ cat > before.tc <<'EOF'
  > void f(int *p);
  > generic(T) void f(T *p);
  > EOF
  $ ./golden.exe before.tc
  before.tc:2: error: 'f' is a generic function, so no other declaration of its name stands at file scope [generic-function-agreement]
  [1]

  $ cat > after.tc <<'EOF'
  > generic(T) void f(T *p);
  > void f(int *p);
  > EOF
  $ ./golden.exe after.tc
  after.tc:2: error: 'f' is a generic function, so no other declaration of its name stands at file scope [generic-function-agreement]
  [1]

  $ cat > object_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > int f;
  > EOF
  $ ./golden.exe object_after.tc
  object_after.tc:2: error: 'f' is a generic function, so no other declaration of its name stands at file scope [generic-function-agreement]
  [1]

  $ cat > typedef_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > typedef int f;
  > EOF
  $ ./golden.exe typedef_after.tc
  typedef_after.tc:2: error: 'f' is a generic function, so no other declaration of its name stands at file scope [generic-function-agreement]
  [1]

  $ cat > enumerator_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > enum { f };
  > EOF
  $ ./golden.exe enumerator_after.tc
  enumerator_after.tc:2: error: 'f' is a generic function, so no other declaration of its name stands at file scope [generic-function-agreement]
  [1]

  $ cat > type_after.tc <<'EOF'
  > generic(T) void f(T *p);
  > type f = int;
  > EOF
  $ ./golden.exe type_after.tc
  type_after.tc:2: error: `f` is declared twice in one scope, and one of them is a type declaration [type-redeclaration]
  [1]

Design 13.3, "Attributes in a generic": an attribute whose subject
mentions a type parameter, or whose arguments name what the definition
declares, stands only where the table of attributes records that both
backends take it alike for every type, every kind of subject and every
argument list. `_Alignas` is read as `aligned`. `noinline`, `cold` and
`unused` have that fact; on a subject that mentions no type parameter,
with arguments that name nothing of the definition, any attribute
stands.

  $ cat > stand_alike.tc <<'EOF'
  > generic(T) __attribute__((noinline, cold))
  > void f(T *p __attribute__((unused)))
  > {
  >     T o __attribute__((unused));
  >     (void)o;
  > }
  > EOF
  $ ./golden.exe stand_alike.tc > /dev/null
  $ cat > stand_other.tc <<'EOF'
  > struct s;
  > void close_s(struct s **);
  > generic(T) void f(T *p)
  > {
  >     struct s *h __attribute__((cleanup(close_s))) = 0;
  >     _Alignas(8) int n __attribute__((aligned(8))) = 0;
  >     switch (n) { case 1: __attribute__((fallthrough)); default: break; }
  >     (void)p; (void)h;
  > }
  > EOF
  $ ./golden.exe stand_other.tc > /dev/null
  $ cat > member.tc <<'EOF'
  > generic(T) void f(T *p) { struct { T v __attribute__((aligned(8))); } x; }
  > EOF
  $ ./golden.exe member.tc
  member.tc:1: error: the attribute 'aligned' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > typedef.tc <<'EOF'
  > generic(T) void f(T *p) { typedef T u __attribute__((aligned(8))); }
  > EOF
  $ ./golden.exe typedef.tc
  typedef.tc:1: error: the attribute 'aligned' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > buffer.tc <<'EOF'
  > generic(T) void f(T t) { char b[8] __attribute__((aligned(sizeof(t)))); }
  > EOF
  $ ./golden.exe buffer.tc
  buffer.tc:1: error: the attribute 'aligned' names 't', which the definition declares, and its arguments may name only what is declared outside the definition [generic-attribute]
  [1]
  $ cat > vector.tc <<'EOF'
  > generic(T) void f(T *p) { (void)sizeof(T __attribute__((vector_size(16)))); }
  > EOF
  $ ./golden.exe vector.tc
  vector.tc:1: error: the attribute 'vector_size' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > mode.tc <<'EOF'
  > generic(T) void f(T *p) { T o __attribute__((mode(DI))); }
  > EOF
  $ ./golden.exe mode.tc
  mode.tc:1: error: the attribute 'mode' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > cleanup.tc <<'EOF'
  > void g(void *);
  > generic(T) void f(T *p) { T o __attribute__((cleanup(g))); }
  > EOF
  $ ./golden.exe cleanup.tc
  cleanup.tc:2: error: the attribute 'cleanup' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > nonnull.tc <<'EOF'
  > generic(T) __attribute__((nonnull(1))) void f(T *p) { (void)p; }
  > EOF
  $ ./golden.exe nonnull.tc
  nonnull.tc:1: error: the attribute 'nonnull' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > returns_nonnull.tc <<'EOF'
  > generic(T) __attribute__((returns_nonnull)) T *f(T *p) { return p; }
  > EOF
  $ ./golden.exe returns_nonnull.tc
  returns_nonnull.tc:1: error: the attribute 'returns_nonnull' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > alignas.tc <<'EOF'
  > generic(T) void f(T *p) { _Alignas(8) T o; }
  > EOF
  $ ./golden.exe alignas.tc
  alignas.tc:1: error: the attribute 'aligned' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]
  $ cat > alignas_names.tc <<'EOF'
  > generic(T) void f(T *p)
  > {
  >     enum { A = 8 };
  >     char y;
  >     _Alignas(A) char a;
  >     _Alignas(sizeof(y)) char b;
  > }
  > EOF
  $ ./golden.exe alignas_names.tc
  alignas_names.tc:5: error: the attribute 'aligned' names 'A', which the definition declares, and its arguments may name only what is declared outside the definition [generic-attribute]
  [1]
  $ cat > alignas_tag.tc <<'EOF'
  > generic(T) void f(T *p)
  > {
  >     struct s { double d; };
  >     _Alignas(struct s) char a;
  > }
  > EOF
  $ ./golden.exe alignas_tag.tc
  alignas_tag.tc:4: error: the attribute 'aligned' names 's', which the definition declares, and its arguments may name only what is declared outside the definition [generic-attribute]
  [1]
  $ cat > pointer.tc <<'EOF'
  > generic(T) void f(T *p) { T *__attribute__((aligned(8))) q = p; }
  > EOF
  $ ./golden.exe pointer.tc
  pointer.tc:1: error: the attribute 'aligned' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]

A declaration that is no definition carries no attribute anywhere in it
(rule 6).

  $ cat > prototype_inner.tc <<'EOF'
  > generic(T) void (__attribute__((cold)) f)(T);
  > EOF
  $ ./golden.exe prototype_inner.tc
  prototype_inner.tc:1: error: `_Noreturn` and attributes stand on the definition of a generic function, which its instances are written from [generic-function-form]
  [1]
  $ cat > prototype_parameter.tc <<'EOF'
  > generic(T) void f(T x __attribute__((unused)));
  > EOF
  $ ./golden.exe prototype_parameter.tc
  prototype_parameter.tc:1: error: `_Noreturn` and attributes stand on the definition of a generic function, which its instances are written from [generic-function-form]
  [1]
  $ cat > generic_type.tc <<'EOF'
  > type g(T) = struct { T v __attribute__((vector_size(16))); };
  > EOF
  $ ./golden.exe generic_type.tc
  generic_type.tc:1: error: the attribute 'vector_size' stands on a subject that mentions a type parameter, and the table of attributes does not record that both backends take it alike for every type [generic-attribute]
  [1]

The rest of the uses of a predefined name of the function that design
7.1 rules 3 and 4 refuse: its alignment, and constants that depend on
its length or its address.

  $ cat > func_alignof.tc <<'EOF'
  > generic(T) void f(T *p) { (void)p; (void)__alignof__(__func__); }
  > EOF
  $ ./golden.exe func_alignof.tc
  func_alignof.tc:1: error: __func__ in a generic function is read as an array, whose length is that of the name of each instance, which is not valid C of one meaning for every value type [type-parameter-operation]
  [1]
  $ cat > func_strlen.tc <<'EOF'
  > generic(T) void f(T *p) {
  >     (void)p;
  >     _Static_assert(__builtin_strlen(__func__) == 1, "length");
  > }
  > EOF
  $ ./golden.exe func_strlen.tc
  func_strlen.tc:3: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > func_static.tc <<'EOF'
  > generic(T) void f(T *p) { (void)p; static const char *name = __func__; (void)name; }
  > EOF
  $ ./golden.exe func_static.tc
  func_static.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]

A builtin called through parentheses depends as its plain call does,
while one that the values of its arguments decide stands.

  $ cat > paren_builtin.tc <<'EOF'
  > generic(T) void f(T t) { char b[(__builtin_object_size)(&t, 0) > 1000 ? 1 : -1]; }
  > EOF
  $ ./golden.exe paren_builtin.tc
  paren_builtin.tc:1: error: the value depends on a type parameter here, through a layout, a builtin or a `const` object, and is another constant in each instance [type-parameter-constant]
  [1]
  $ cat > decided_builtin.tc <<'EOF'
  > generic(T) void f(T *p) { (void)p; char b[__builtin_popcount(3)]; (void)b; }
  > EOF
  $ ./golden.exe decided_builtin.tc > /dev/null
