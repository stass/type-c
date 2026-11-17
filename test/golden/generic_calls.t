SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Calls of generic functions (design 7.2): the type arguments are deduced
from the arguments, from left to right, or written in an explicit
instance. A unit whose calls are valid is accepted;
test/golden/function_instances.t shows the instances that it writes
(design 7.3).

Rule 1: the first argument that mentions a type parameter deduces it,
and a later argument converts to the substituted parameter type, as a
call of `int max(int, int)` converts `n`.

  $ cat > first.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > unsigned long n;
  > int f(void) { return max(0, n); }
  > EOF
  $ ./golden.exe first.tc > /dev/null

The call has the instance's return type: `max(0, n)` is an `int`.

  $ cat > return_type.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > unsigned long n;
  > _Static_assert(_Generic(max(0, n), int: 1, default: 0), "int");
  > EOF
  $ ./golden.exe return_type.tc > /dev/null

  $ cat > return_type_refused.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > unsigned long n;
  > _Static_assert(_Generic(max(0, n), unsigned long: 1, default: 0), "long");
  > EOF
  $ ./golden.exe return_type_refused.tc
  return_type_refused.tc:3: error: static assertion failed: '"long"'
  [1]

The match is exact: a `char` argument deduces `char`, with no
promotion.

  $ cat > exact.tc <<'EOF'
  > generic(T) T id(T t) { return t; }
  > char c;
  > _Static_assert(_Generic(id(c), char: 1, default: 0), "char");
  > EOF
  $ ./golden.exe exact.tc > /dev/null

  $ cat > exact_refused.tc <<'EOF'
  > generic(T) T id(T t) { return t; }
  > char c;
  > _Static_assert(_Generic(id(c), int: 1, default: 0), "int");
  > EOF
  $ ./golden.exe exact_refused.tc
  exact_refused.tc:3: error: static assertion failed: '"int"'
  [1]

Typedefs are expanded and an enumerator is an `int`; a value of an
enumerated type deduces that type.

  $ cat > typedefs.tc <<'EOF'
  > typedef unsigned long size;
  > enum colour { RED, GREEN };
  > generic(T) T id(T t) { return t; }
  > size n;
  > enum colour c;
  > _Static_assert(_Generic(id(n), unsigned long: 1, default: 0), "size");
  > _Static_assert(_Generic(id(GREEN), int: 1, default: 0), "enumerator");
  > _Static_assert(_Generic(id(c), enum colour: 1, default: 0), "enum");
  > EOF
  $ ./golden.exe typedefs.tc > /dev/null

  $ cat > enumerator_refused.tc <<'EOF'
  > enum colour { RED, GREEN };
  > generic(T) T id(T t) { return t; }
  > _Static_assert(_Generic(id(GREEN), enum colour: 1, default: 0), "enum");
  > EOF
  $ ./golden.exe enumerator_refused.tc
  enumerator_refused.tc:3: error: static assertion failed: '"enum"'
  [1]

A null pointer constant is an `int` on its own, so it deduces no pointer
type.

  $ cat > null.tc <<'EOF'
  > generic(T) void clear(T *p);
  > void f(void) { clear(0); }
  > EOF
  $ ./golden.exe null.tc
  null.tc:2: error: the argument's type does not match its parameter's: it has 'int' where the parameter type has 'T *' [deduction-mismatch]
  [1]

An array and a function decay, and an lvalue loses its qualifiers.

  $ cat > decay.tc <<'EOF'
  > generic(T) T *at(T *p, int i) { return p + i; }
  > generic(T) T id(T t) { return t; }
  > int a[4];
  > const long c = 1;
  > int h(int);
  > int *f(void) { return at(a, 1); }
  > long g(void) { return id(c); }
  > int (*k(void))(int) { return id(h); }
  > EOF
  $ ./golden.exe decay.tc > /dev/null

Rule 2: a pointer parameter may add qualifiers to the pointed-to type, as
C assignment allows.

  $ cat > adds.tc <<'EOF'
  > generic(T) T get(const T *p) { return *p; }
  > int f(int *p) { return get(p); }
  > int g(const int *p) { return get(p); }
  > EOF
  $ ./golden.exe adds.tc > /dev/null

Below the pointed-to type the match is exact, as C assignment does not
add a qualifier there.

  $ cat > deep.tc <<'EOF'
  > generic(T) void put(const T **p);
  > void f(int **p) { put(p); }
  > EOF
  $ ./golden.exe deep.tc
  deep.tc:2: error: the argument's type does not match its parameter's: it has 'int' where the parameter type has 'const T' [deduction-mismatch]
  [1]

A type parameter that occurs twice in one parameter type matches identical
types.

  $ cat > twice.tc <<'EOF'
  > generic(T) void apply(T (*fn)(T)) { }
  > long same(long);
  > void f(void) { apply(same); }
  > EOF
  $ ./golden.exe twice.tc > /dev/null

  $ cat > twice_refused.tc <<'EOF'
  > generic(T) void apply(T (*fn)(T));
  > long other(int);
  > void f(void) { apply(other); }
  > EOF
  $ ./golden.exe twice_refused.tc
  twice_refused.tc:3: error: a type parameter that the parameter type holds twice meets 'long' and 'int' [deduction-mismatch]
  [1]

An argument whose type has another shape than its parameter's is
refused.

  $ cat > shape.tc <<'EOF'
  > generic(T) void put(T *p, T v);
  > void f(int x) { put(x, 1); }
  > EOF
  $ ./golden.exe shape.tc
  shape.tc:2: error: the argument's type does not match its parameter's: it has 'int' where the parameter type has 'T *' [deduction-mismatch]
  [1]

The match reaches into an instance of a generic type, argument by
argument, and the substitution applies the generic to the substituted
arguments, as `vector_push(&v, 0)` deduces `long` and converts `0`.

  $ cat > applied.tc <<'EOF'
  > type vector(T) = struct { T *data; unsigned long len; };
  > type id(T) = distinct unsigned;
  > generic(T) void vector_push(vector(T) *v, T x) { }
  > generic(T) vector(T) *self(vector(T) *v) { return v; }
  > generic(T) vector(T *) *pointers(T *p) { return 0; }
  > generic(T) T *lookup(id(T) key) { return 0; }
  > vector(long) v;
  > id(int) k;
  > void f(void) { vector_push(&v, 0); }
  > _Static_assert(_Generic(self(&v), vector(long) *: 1, default: 0), "self");
  > _Static_assert(_Generic(pointers(&v), vector(vector(long) *) *: 1,
  >                         default: 0), "pointers");
  > _Static_assert(_Generic(lookup(k), int *: 1, default: 0), "lookup");
  > EOF
  $ ./golden.exe applied.tc > /dev/null

An instance that the substitution puts in an array is completed first,
as a declarator completes the element of an array.

  $ cat > applied_array.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void f(T *a, box(T) (*b)[2]) { }
  > long l;
  > void g(void) { f(&l, 0); }
  > EOF
  $ ./golden.exe applied_array.tc > /dev/null

An instance of another generic, or of other arguments, does not match.

  $ cat > applied_refused.tc <<'EOF'
  > type vector(T) = struct { T *data; unsigned long len; };
  > type list(T) = struct { T *head; };
  > generic(T) void vector_push(vector(T) *v, T x);
  > list(long) l;
  > void f(void) { vector_push(&l, 0); }
  > EOF
  $ ./golden.exe applied_refused.tc
  applied_refused.tc:5: error: the argument's type does not match its parameter's: it has 'list(long)' where the parameter type has 'vector(T)' [deduction-mismatch]
  [1]

  $ cat > applied_twice.tc <<'EOF'
  > type pair(A, B) = struct { A first; B second; };
  > generic(T) void same(pair(T, T) *p);
  > pair(int, long) p;
  > void f(void) { same(&p); }
  > EOF
  $ ./golden.exe applied_twice.tc
  applied_twice.tc:4: error: a type parameter that the parameter type holds twice meets 'int' and 'long' [deduction-mismatch]
  [1]

Rule 3: every type parameter is deduced by the end of the arguments.

  $ cat > undeduced.tc <<'EOF'
  > generic(T) T *make(void);
  > void f(void) { make(); }
  > EOF
  $ ./golden.exe undeduced.tc
  undeduced.tc:2: error: no argument deduces the type parameter 'T' of 'make'; give it its type arguments in an explicit instance [undeduced-type-parameter]
  [1]

Rule 4: an explicit instance is a function designator, called or taken
the address of.

  $ cat > explicit.tc <<'EOF'
  > generic(T) T *make(void) { return 0; }
  > generic(T) T max(T a, T b) { return a; }
  > int *f(void) { return make(int)(); }
  > int (*p)(int, int) = max(int);
  > long (*q)(long, long) = &max(long);
  > EOF
  $ ./golden.exe explicit.tc > /dev/null

The instance has the instance's type.

  $ cat > explicit_type.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > _Static_assert(_Generic(max(long), long (*)(long, long): 1, default: 0),
  >                "long");
  > _Static_assert(_Generic(max(long)(1, 2), long: 1, default: 0), "call");
  > EOF
  $ ./golden.exe explicit_type.tc > /dev/null

  $ cat > explicit_type_refused.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > _Static_assert(_Generic(max(long), int (*)(int, int): 1, default: 0),
  >                "int");
  > EOF
  $ ./golden.exe explicit_type_refused.tc
  explicit_type_refused.tc:2: error: static assertion failed: '"int"'
  [1]

An explicit instance gives one type argument for each type parameter.

  $ cat > explicit_count.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > int (*p)(int, int) = max(int, long);
  > EOF
  $ ./golden.exe explicit_count.tc
  explicit_count.tc:2: error: the number of type arguments, 2, differs from the number of type parameters of the generic function 'max', 1 [instance-arguments]
  [1]

Rule 5: a type argument, deduced or explicit, is a value type.

  $ cat > deduced_const.tc <<'EOF'
  > generic(T) T *first(T *p) { return p; }
  > const int *f(const int *p) { return first(p); }
  > EOF
  $ ./golden.exe deduced_const.tc
  deduced_const.tc:2: error: the type argument 'const int' is not a value type: it is qualified [type-argument]
  [1]

  $ cat > deduced_void.tc <<'EOF'
  > generic(T) void clear(T *p);
  > void f(void *p) { clear(p); }
  > EOF
  $ ./golden.exe deduced_void.tc
  deduced_void.tc:2: error: the type argument 'void' is not a value type: it is not a complete object type [type-argument]
  [1]

  $ cat > explicit_array.tc <<'EOF'
  > generic(T) T *make(void);
  > void f(void) { make(int[2])(); }
  > EOF
  $ ./golden.exe explicit_array.tc
  explicit_array.tc:2: error: the type argument 'int[2]' is not a value type: it is an array; wrap it in a struct, which is one [type-argument]
  [1]

A deduced type argument is placed as a written one is: a forward
declaration that lowering writes for its tag may not change a mention
before it.

  $ cat > deduced_mention.tc <<'EOF'
  > generic(T) T *f(T *p);
  > unsigned long a = sizeof(void (*)(struct s *)), b = sizeof(f((struct s *)0));
  > EOF
  $ ./golden.exe deduced_mention.tc
  deduced_mention.tc:2: error: the type argument names 'struct s', and a mention before it in this external declaration declares the tag in a nested scope (C11 6.7.2.3p8), which the forward declaration of the instance would change; declare the tag at file scope before it [instance-placement]
  [1]

The name of a generic function is called or names an instance; alone it
is no function. Parentheses around the called name are no other use.

  $ cat > bare.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > void *p = max;
  > EOF
  $ ./golden.exe bare.tc
  bare.tc:2: error: 'max' is a generic function, whose name alone is no function: it is called, or names an instance with type arguments [generic-function-use]
  [1]

  $ cat > parenthesized.tc <<'EOF'
  > generic(T) T max(T a, T b) { return a; }
  > int f(void) { return (max)(1, 2); }
  > EOF
  $ ./golden.exe parenthesized.tc > /dev/null

A generic function calls itself and other generic functions: a type
parameter is deduced as a type parameter of the caller.

  $ cat > recursion.tc <<'EOF'
  > generic(T) T *first(T *p) { return p; }
  > generic(T) T *walk(T *p, int n) { return n ? walk(p, n - 1) : first(p); }
  > EOF
  $ ./golden.exe recursion.tc > /dev/null
