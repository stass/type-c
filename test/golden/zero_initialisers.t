SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The zero initialiser of a type parameter (design 7.1 rule 3, 13.5).
Where the type of an object or subobject mentions a type parameter, an
instance writes its {0} or {} as {}, with __extension__ before what
holds the list most closely: the compound literal whose list holds it,
or else the declaration whose initialiser does, once for the lists of
one declaration. test/run/zero_initialisers.t holds what the backends
do with the form.

  $ cat > places.tc <<'EOF'
  > void use(const void *);
  > generic(T) void places(void)
  > {
  >     T u = {0};
  >     const T c = {};
  >     static T s = {0};
  >     T row[2] = {0}, *p = &(T){0};
  >     struct { T a; int b; } head = {0};
  >     struct { T a; int b; } sub = { {0}, 5 };
  >     use(&(struct { T a; int b; }){ {}, 5 });
  >     use(&u); use(&c); use(&s); use(row); use(p); use(&head); use(&sub);
  > }
  > void f(void) { places(double)(); }
  > EOF
  $ ./golden.exe places.tc | grep -e extension -e '{}'
  __extension__ __tc_arg__d __tc_local_u = { } ;
  __extension__ const __tc_arg__d __tc_local_c = { } ;
  __extension__ static __tc_arg__d __tc_local_s = { } ;
  __extension__ __tc_arg__d __tc_local_row [ 2 ] = { } , * __tc_local_p = & __extension__ ( __tc_arg__d ) { } ;
  __extension__ struct { __tc_arg__d a ; int b ; } __tc_local_head = { } ;
  __extension__ struct { __tc_arg__d a ; int b ; } __tc_local_sub = { { } , 5 } ;
  use ( & __extension__ ( struct { __tc_arg__d a ; int b ; } ) { { } , 5 } ) ;

An initialiser of an object whose type mentions no type parameter is
kept as written, in a generic function as outside one, and so is the
definition's own text, which only its instances write.

  $ cat > kept.tc <<'EOF'
  > void use(const void *);
  > generic(T) void kept(T *p)
  > {
  >     int n = {0};
  >     struct { int a; long b; } w = {0};
  >     use(&n); use(&w); use(p);
  > }
  > void f(long *q) { long z = {0}; kept(q); use(&z); }
  > EOF
  $ ./golden.exe kept.tc | grep -c extension
  0
  [1]
  $ ./golden.exe kept.tc | grep -o -e '.* = { *0 *}'
  int __tc_local_n = { 0 }
  struct { int a ; long b ; } __tc_local_w = { 0 }
  void f(long *q) { long z = {0}

The text that lowering moves keeps the form: a deferred statement at
each of its copies and the operand of a try where its prelude holds it.

  $ cat > moved.tc <<'EOF'
  > void use(const void *);
  > generic(T) result(int, int) check(const T *p) { use(p); return Ok(0); }
  > generic(T) result(int, int) moved(int n)
  > {
  >     defer { T d = {0}; use(&d); }
  >     int y = try check((const T *)&(T){0});
  >     if (n)
  >         return Ok(1);
  >     return Ok(y);
  > }
  > result(int, int) f(void) { return moved(long)(3); }
  > EOF
  $ ./golden.exe moved.tc | grep -o -e '{ { __extension__[^}]*}' \
  >   -e 'check__l ( ( const __tc_arg__l \* ) & __extension__ ([^)]*) { } )'
  check__l ( ( const __tc_arg__l * ) & __extension__ ( __tc_arg__l ) { } )
  { { __extension__ __tc_arg__l __tc_local_d = { }
  { { __extension__ __tc_arg__l __tc_local_d = { }
  { { __extension__ __tc_arg__l __tc_local_d = { }

The braces of the list stay, with what lowering writes after them: the
end of the conversion of a slice whose compound literal the list ends.

  $ cat > conversion.tc <<'EOF'
  > void use(const void *);
  > generic(T) void f(void)
  > {
  >     slice(const T) c = (slice(T)){0};
  >     use(&c);
  > }
  > void g(void) { f(long)(); }
  > EOF
  $ ./golden.exe conversion.tc | grep -e ' __tc_local_c = '
  slice__Kl __tc_local_c = ((void)(__tc_s0 = ( __extension__ ( slice__l ) { } )), (struct slice__Kl){ __tc_s0.data, __tc_s0.len }) ;

The form sets three limits. A variable length array takes no
initialiser in C11, and the backends would give it {} as C23 does.

  $ cat > vla.tc <<'EOF'
  > generic(T) void f(int n) { T a[n] = {0}; (void)a; }
  > EOF
  $ ./golden.exe vla.tc
  vla.tc:1: error: the zero initialiser of a variable length array whose type mentions a type parameter, which C11 gives no initialiser [zero-initializer-vla]
  [1]

  $ cat > vla_inner.tc <<'EOF'
  > generic(T) void f(int n) { T a[2][n] = {}; (void)a; }
  > EOF
  $ ./golden.exe vla_inner.tc
  vla_inner.tc:1: error: the zero initialiser of a variable length array whose type mentions a type parameter, which C11 gives no initialiser [zero-initializer-vla]
  [1]

A pointer to a variable length array is no array, and takes it.

  $ cat > vla_pointer.tc <<'EOF'
  > generic(T) void f(int n) { T (*p)[n] = {0}; (void)p; }
  > void g(void) { f(int)(3); }
  > EOF
  $ ./golden.exe vla_pointer.tc | grep extension
  static void f__i ( int __tc_local_n ) { __extension__ __tc_arg__i ( * __tc_local_p ) [ __tc_local_n ] = { } ; ( void ) __tc_local_p ; }

Apple Clang 21 does not read __extension__ before a declaration in the
first clause of a for statement, so none there holds the form.

  $ cat > for.tc <<'EOF'
  > generic(T) void f(void) { for (T t = {0}; ;) break; }
  > EOF
  $ ./golden.exe for.tc
  for.tc:1: error: the zero initialiser of an object whose type mentions a type parameter, in a declaration in the first clause of a for statement: declare the object before the loop [zero-initializer-in-for]
  [1]

A compound literal holds its own, there as anywhere, and so does a
declaration in a statement expression there.

  $ cat > for_literal.tc <<'EOF'
  > void use(const void *);
  > generic(T) void f(void)
  > {
  >     for (const T *p = &(T){0}; p; p = 0)
  >         use(p);
  >     for (int i = ({ T t = {}; use(&t); 0; }); i < 1; i++)
  >         ;
  > }
  > void g(void) { f(int)(); }
  > EOF
  $ ./golden.exe for_literal.tc |
  >   grep -o -e 'p = & __extension__ ([^)]*) { }' -e '__extension__ [^=]*= { }'
  p = & __extension__ ( __tc_arg__i ) { }
  __extension__ __tc_arg__i __tc_local_t = { }

Apple Clang 21 refuses braces around the initialiser of an object
whose own type is atomic, as an object or as a subobject.

  $ cat > atomic.tc <<'EOF'
  > generic(T) void f(void) { T *_Atomic p = {0}; (void)&p; }
  > EOF
  $ ./golden.exe atomic.tc
  atomic.tc:1: error: the zero initialiser of an atomic object whose type mentions a type parameter, which Clang refuses in braces [zero-initializer-atomic]
  [1]

  $ cat > atomic_member.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     struct { _Atomic(T *) a; int b; } w = { {}, 1 };
  >     (void)&w;
  > }
  > EOF
  $ ./golden.exe atomic_member.tc
  atomic_member.tc:3: error: the zero initialiser of an atomic object whose type mentions a type parameter, which Clang refuses in braces [zero-initializer-atomic]
  [1]

A structure with an atomic member and an array of atomic elements take
it whole.

  $ cat > atomic_whole.tc <<'EOF'
  > generic(T) void f(void)
  > {
  >     struct { T *_Atomic a; int b; } w = {0};
  >     T *_Atomic row[2] = {};
  >     (void)&w; (void)&row;
  > }
  > void g(void) { f(int)(); }
  > EOF
  $ ./golden.exe atomic_whole.tc | grep extension
  __extension__ struct { __tc_arg__i * _Atomic a ; int b ; } __tc_local_w = { } ;
  __extension__ __tc_arg__i * _Atomic __tc_local_row [ 2 ] = { } ;

The check classifies every braced list that the parser reads in the
definition, head and body, as one that lowering writes as {} or one
that it keeps, wherever the list stands: behind nested designators, in
an array of structures that hold a type parameter inside a structure,
in a compound literal in a statement expression, and in the head.

  $ cat > deep.tc <<'EOF'
  > void use(const void *);
  > struct cell { int k; };
  > generic(T) void f(const void *head[sizeof((struct cell){0})])
  > {
  >     struct { struct { int k; T a[2]; } in[2]; int n; } d =
  >         { .in[1].a[1] = {0}, .n = 1 };
  >     struct { int n; struct { T a; int b; } row[2]; } r =
  >         { 1, { {0}, {} } };
  >     int s = ({ const T *p = &(T){0}; use(p); 1; });
  >     use(&d); use(&r); use(&s); use(head);
  > }
  > void g(void) { f(short)(0); }
  > EOF
  $ ./golden.exe deep.tc | grep -o -e 'head [^]]*]' -e '{ [.1] .*} ;' \
  >   -e 'p = [^;]*;'
  head [ sizeof ( ( struct cell ) { 0 } ) ]
  head [ sizeof ( ( struct cell ) { 0 } ) ]
  { . in [ 1 ] . a [ 1 ] = { } , . n = 1 } ;
  { 1 , { { } , { } } } ;
  p = & __extension__ ( __tc_arg__s ) { } ;

No initialiser enters a type parameter but the zero initialiser, and
what typec cannot see enter one is an error. A list for an object
whose type mentions a type parameter loses its place after an
initialiser whose subobject typec does not know, here an element of an
array whose length the backend computes, and what follows is an error
unless a designator places it: it may reach the `T`, and what it means
there is the argument's to decide.

  $ cat > lost.tc <<'EOF'
  > void use(const void *);
  > struct two { char c; long l[3]; };
  > generic(T) void f(int x)
  > {
  >     struct { int k[sizeof(struct two)]; T a; } w = { x, x, {0} };
  >     use(&w);
  > }
  > EOF
  $ ./golden.exe lost.tc
  lost.tc:5: error: the subobject that an initialiser reaches depends on what typec does not know, in an object whose type mentions a type parameter: place it with a designator [initializer-place-lost]
  [1]

  $ cat > placed.tc <<'EOF'
  > void use(const void *);
  > struct two { char c; long l[3]; };
  > generic(T) void f(int x)
  > {
  >     struct { int k[sizeof(struct two)]; T a; } w = { x, .a = {0} };
  >     struct { int k[sizeof(struct two)]; int b; } v = { x, x, {0} };
  >     use(&w); use(&v);
  > }
  > void g(void) { f(char)(1); }
  > EOF
  $ ./golden.exe placed.tc | grep -o -e '[^ ;]* = {.*} ;'
  __tc_local_w = { __tc_local_x , . a = { } } ;
  __tc_local_v = { __tc_local_x , __tc_local_x , { 0 } } ;

A braced initialiser of an object whose type typec does not compute,
or that holds one, is an error in a generic function, as the type may
mention a type parameter: here the type of a conditional whose null
pointer constant is a value that the backend computes, and a call of
an overloaded function.

  $ cat > unknown.tc <<'EOF'
  > void use(const void *);
  > struct two { char c; long l[3]; };
  > generic(T) void f(T *p, int c)
  > {
  >     __typeof__((c ? p : (void *)(sizeof(struct two)
  >         - sizeof(struct two)))[0]) y = {0};
  >     use(&y);
  > }
  > EOF
  $ ./golden.exe unknown.tc
  unknown.tc:6: error: a braced initialiser, in a generic function, of an object whose type typec does not compute or holds one, which may mention a type parameter [initializer-type-unknown]
  [1]

The head of the definition is part of it.

  $ cat > unknown_head.tc <<'EOF'
  > struct two { char c; long l[3]; };
  > int g(const void *);
  > generic(T) void f(T *p, int c,
  >     int a[g(&(__typeof__((c ? p : (void *)(sizeof(struct two)
  >         - sizeof(struct two)))[0])){0})])
  > {
  >     (void)a;
  > }
  > EOF
  $ ./golden.exe unknown_head.tc
  unknown_head.tc:5: error: a braced initialiser, in a generic function, of an object whose type typec does not compute or holds one, which may mention a type parameter [initializer-type-unknown]
  [1]

  $ cat > overloaded.tc <<'EOF'
  > void use(const void *);
  > long *h(long *) __attribute__((overloadable));
  > char *h(char *) __attribute__((overloadable));
  > generic(T) void f(T *p)
  > {
  >     struct { __typeof__(h(p)[0]) m; int b; } s = { .b = 1 };
  >     use(&s);
  > }
  > EOF
  $ ./golden.exe overloaded.tc
  overloaded.tc:6: error: a braced initialiser, in a generic function, of an object whose type typec does not compute or holds one, which may mention a type parameter [initializer-type-unknown]
  [1]

The definition of a generic type that the check of a generic function
applies is no part of that function, whichever use of the instance
comes first.

  $ cat > unknown_instance.tc <<'EOF'
  > long *h(long *) __attribute__((overloadable));
  > char *h(char *) __attribute__((overloadable));
  > type box(T) = struct {
  >     T v;
  >     char n[sizeof((__typeof__(h((long *)0)[0])[1]){0})];
  > };
  > generic(T) void g(T *p)
  > {
  >     box(int) b = {0};
  >     (void)p; (void)b;
  > }
  > EOF
  $ ./golden.exe unknown_instance.tc | grep -c error
  0
  [1]

An instance of a generic function that the check of another reads is
part of that check, and its instances write the form.

  $ cat > nested.tc <<'EOF'
  > generic(U) unsigned long f(void)
  > {
  >     U x = {0};
  >     struct { U a; int b; } y = {0};
  >     (void)x; (void)y;
  >     return sizeof(U) + sizeof(struct { U a; });
  > }
  > generic(T) unsigned long g(void) { return f(T)(); }
  > unsigned long h(void) { return g(int)(); }
  > EOF
  $ ./golden.exe nested.tc | grep -o -e '__extension__ [^=]*= { }'
  __extension__ __tc_arg__i __tc_local_x = { }
  __extension__ struct { __tc_arg__i a ; int b ; } __tc_local_y = { }

An expression initialises such an object, and outside a generic
function the type mentions no type parameter.

  $ cat > unknown_kept.tc <<'EOF'
  > void use(const void *);
  > long *h(long *) __attribute__((overloadable));
  > char *h(char *) __attribute__((overloadable));
  > generic(T) void f(T *p)
  > {
  >     __typeof__(h(p)[0]) y = p[0];
  >     use(&y);
  > }
  > void g(long *q)
  > {
  >     __typeof__(h(q)[0]) z = {0};
  >     f(q);
  >     use(&z);
  > }
  > EOF
  $ ./golden.exe unknown_kept.tc | grep -o -e '[yz] = [^;]*;'
  y = __tc_local_p [ 0 ] ;
  z = {0};

The prelude of a try that the statement holds goes before the
__extension__ of a compound literal that begins the statement, which
stands next to the literal.

  $ cat > prelude.tc <<'EOF'
  > result(int, int) g(void);
  > generic(T) result(int, int) f(void)
  > {
  >     (struct { T a; int b; }){0}.b = try g();
  >     return Ok(0);
  > }
  > result(int, int) h(void) { return f(long)(); }
  > EOF
  $ ./golden.exe prelude.tc | grep -o -e '} __extension__ ( struct[^)]*) { }'
  } __extension__ ( struct { __tc_arg__l a ; int b ; } ) { }
