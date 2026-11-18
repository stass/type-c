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

A later argument that does not convert is refused as in any call, in
the types that the unit writes: an instance converts to no other type
(design 5).

  $ cat > later_refused.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(T *at, box(T) b) { *at = b.v; }
  > box(long) b;
  > void f(int *p) { put(p, b); }
  > EOF
  $ ./golden.exe later_refused.tc
  later_refused.tc:4: error: a value of type 'box(long)' does not convert to 'box(int)' (C11 6.5.16.1p1)
  [1]

  $ cat > later.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(T *at, box(T) b) { *at = b.v; }
  > box(int) b;
  > void f(int *p) { put(p, b); }
  > EOF
  $ ./golden.exe later.tc > /dev/null

A later argument converts to its parameter's type as by assignment
(C11 6.5.16.1p1), and `typec` refuses one that does not, as it does
every conversion in Type-C text (test/golden/assignments.t). An
`int *` does not convert to the `int` that `put(&bx, p)` takes once
`&bx` deduces `int`.

  $ cat > pointer_for_integer.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > box(int) bx;
  > void f(int *p) { put(&bx, p); }
  > EOF
  $ ./golden.exe pointer_for_integer.tc
  pointer_for_integer.tc:4: error: a value of type 'int *' does not convert to 'int' without a cast (C11 6.5.16.1p1)
  [1]

An explicit instance takes its arguments as that call does.

  $ cat > explicit_pointer_for_integer.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > box(int) bx;
  > void f(int *p) { put(int)(&bx, p); }
  > EOF
  $ ./golden.exe explicit_pointer_for_integer.tc
  explicit_pointer_for_integer.tc:4: error: a value of type 'int *' does not convert to 'int' without a cast (C11 6.5.16.1p1)
  [1]

A pointer to a structure is no structure.

  $ cat > pointer_for_structure.tc <<'EOF'
  > struct job { int n; };
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > box(struct job) bx;
  > void f(struct job *j) { put(&bx, j); }
  > EOF
  $ ./golden.exe pointer_for_structure.tc
  pointer_for_structure.tc:5: error: a value of type 'struct job *' does not convert to 'struct job' (C11 6.5.16.1p1)
  [1]

A pointer keeps the qualifiers of the type it points to, and points
to a compatible type.

  $ cat > qualifier_dropped.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void take(box(T) *b, T *at) { b->v = *at; }
  > box(int) bx;
  > void f(const int *p) { take(&bx, p); }
  > EOF
  $ ./golden.exe qualifier_dropped.tc
  qualifier_dropped.tc:4: error: a value of type 'const int *' does not convert to 'int *' without a cast (C11 6.5.16.1p1)
  [1]

  $ cat > pointer_incompatible.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void take(box(T) *b, T *at) { b->v = *at; }
  > box(int) bx;
  > void f(unsigned *p) { take(&bx, p); }
  > EOF
  $ ./golden.exe pointer_incompatible.tc
  pointer_incompatible.tc:4: error: a value of type 'unsigned int *' does not convert to 'int *' without a cast (C11 6.5.16.1p1)
  [1]

_Atomic is no qualifier that a pointer may add: an `int *` points to a
type that `_Atomic int` is not compatible with.

  $ cat > atomic_added.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void keep(box(T) *b, T v) { b->v = v; }
  > box(_Atomic int *) ba;
  > void f(int *p) { keep(&ba, p); }
  > EOF
  $ ./golden.exe atomic_added.tc
  atomic_added.tc:4: error: a value of type 'int *' does not convert to '_Atomic int *' without a cast (C11 6.5.16.1p1)
  [1]

A distinct type converts to no other type (design 3.4), to a deduced
parameter as to any.

  $ cat > distinct_for_integer.tc <<'EOF'
  > type metres = distinct int;
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > box(int) bx;
  > void f(metres m) { put(&bx, m); }
  > EOF
  $ ./golden.exe distinct_for_integer.tc
  distinct_for_integer.tc:5: error: a value of type 'metres' does not convert to 'int' without a cast [distinct-conversion]
  [1]

What assignment converts, the argument converts: a null pointer
constant or a `void *` to a pointer to an object, a pointer to one with
more qualifiers, any arithmetic value to an arithmetic type, and a
pointer to `_Bool`. A `void *` converts to a pointer to a function as
well, as GNU C and POSIX (`dlsym`) let it.

  $ cat > converted.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void put(box(T) *b, T value) { b->v = value; }
  > generic(T) void take(box(T) *b, const T *at) { b->v = *at; }
  > box(int) bx;
  > box(double) bd;
  > box(_Bool) bb;
  > box(int *) bp;
  > box(int (*)(void)) bf;
  > void f(int *p, void *v, long n, char c) {
  >   take(&bx, 0);
  >   take(&bx, (void *)0);
  >   take(&bx, v);
  >   take(&bx, p);
  >   put(&bp, 0);
  >   put(&bp, v);
  >   put(&bx, n);
  >   put(&bx, c);
  >   put(&bx, 2.5);
  >   put(&bd, n);
  >   put(&bb, p);
  >   put(int)(&bx, n);
  >   (put(int))(&bx, c);
  >   put(&bf, 0);
  >   put(&bf, (void *)0);
  >   put(&bf, v);
  > }
  > EOF
  $ ./golden.exe converted.tc > /dev/null

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

A generic function's slice parameter meets an array or a pointer whose
slice would deduce it; the refusal names the builtin that makes one.

  $ printf 'generic(T) T first(slice(T) s) { return (s[0]); }\nint f(int *p) { int a[4] = { 0 }; return (first(a) + first(p)); }\n' > slice_array.tc
  $ ./golden.exe slice_array.tc
  slice_array.tc:2: error: the array 'a' does not match the parameter type 'slice(T)'; slice it with 'slice_from_array(a)' [deduction-mismatch]
  [1]
  $ printf 'generic(T) T first(slice(T) s) { return (s[0]); }\nint f(int *p) { return (first(p)); }\n' > slice_pointer.tc
  $ ./golden.exe slice_pointer.tc
  slice_pointer.tc:2: error: the pointer 'p' does not match the parameter type 'slice(T)'; slice the n elements it points to with 'slice_unchecked(p, n)' [deduction-mismatch]
  [1]
  $ printf 'generic(T) T first(slice(const T) s) { return (s[0]); }\nint f(int *p) { return (first(p)); }\n' > slice_const.tc
  $ ./golden.exe slice_const.tc
  slice_const.tc:2: error: the argument's type does not match its parameter's: it has 'int *' where the parameter type has 'slice(const T)' [deduction-mismatch]
  [1]
  $ printf 'generic(T) T first(slice(T) s) { return (s[0]); }\nchar f(void) { return (first(("abc"))); }\n' > slice_literal.tc
  $ ./golden.exe slice_literal.tc
  slice_literal.tc:2: error: the string literal '("abc")' does not match the parameter type 'slice(T)'; a string literal is a slice only where its target type is 'str' [deduction-mismatch]
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
