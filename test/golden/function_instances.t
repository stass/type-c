SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Instances of generic functions (design 7.3, 10.3). Each instance that
the unit uses is a static function under its instance name: its
prototype stands before the external declaration that holds its first
use, then what the reading of its definition needs there, then its
definition. A generic function that is not used leaves no text.

  $ cat > swap.tc <<'EOF'
  > generic(T) void swap(T *a, T *b) { T t = *a; *a = *b; *b = t; }
  > generic(T) void unused(T *p) { }
  > void f(int *a, int *b) { swap(a, b); (swap)(a, b); }
  > EOF
  $ ./golden.exe swap.tc | grep -v '^#' | grep -v '^ *$'
  typedef int __tc_arg__i;
  static void swap__i ( __tc_arg__i * a , __tc_arg__i * b )
  ;
  static void swap__i ( __tc_arg__i * a , __tc_arg__i * b ) { __tc_arg__i t = * a ; * a = * b ; * b = t ; }
  void f(int *a, int *b) { 
  swap__i
  (a, b); (
  swap__i
  )(a, b); }
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

Design 7.1 rule 6: `static` may stand among the specifiers of the
definition, in any place, and changes nothing: the instance is written
with the one `static` that every instance has.

  $ cat > static.tc <<'EOF'
  > generic(T) inline static T id(T x) { return x; }
  > int g(int a) { return id(a); }
  > EOF
  $ ./golden.exe static.tc | grep -v '^#' | grep -v '^ *$' | head -4
  typedef int __tc_arg__i;
  inline static __tc_arg__i id__i ( __tc_arg__i x )
  ;
  inline static __tc_arg__i id__i ( __tc_arg__i x ) { return x ; }

Generic functions that call each other: each instance's prototype
stands before the definition that calls it.

  $ cat > parity.tc <<'EOF'
  > generic(T) int is_even(const T *p, int n);
  > generic(T) int is_odd(const T *p, int n) { return n ? is_even(p, n - 1) : 0; }
  > generic(T) int is_even(const T *p, int n) { return n ? is_odd(p, n - 1) : 1; }
  > int f(const long *p) { return is_odd(p, 3); }
  > EOF
  $ ./golden.exe parity.tc | grep -v '^#' | grep -v '^ *$'
  typedef long __tc_arg__l;
  static int is_odd__l ( const __tc_arg__l * p , int n )
  ;
  static int is_even__l ( const __tc_arg__l * p , int n )
  ; static int is_odd__l ( const __tc_arg__l * p , int n ) { return n ? is_even__l ( p , n - 1 ) : 0 ; }
  static int is_even__l ( const __tc_arg__l * p , int n ) { return n ? is_odd__l ( p , n - 1 ) : 1 ; }
  int f(const long *p) { return 
  is_odd__l
  (p, 3); }
  struct __tc_pack_probe_1 { char c; int i; };
  struct __tc_pack_probe_2 { char c; int i; };
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

Rule 2: the definition of a generic function precedes the first use of
each of its instances.

  $ cat > undefined.tc <<'EOF'
  > generic(T) void clear(T *p);
  > void f(int *p) { clear(p); }
  > generic(T) void clear(T *p) { }
  > EOF
  $ ./golden.exe undefined.tc
  undefined.tc:2: error: the first use of an instance of the generic function 'clear', which is not defined before it: the instance is defined at its first use [generic-undefined]
  [1]

A generic type's definition and a generic function's head use no
generic function: the instance would be named before its prototype.

  $ cat > in_type.tc <<'EOF'
  > generic(T) int one(T x) { return 1; }
  > type box(T) = struct { T v; char pad[sizeof(one(0))]; };
  > box(long) b;
  > EOF
  $ ./golden.exe in_type.tc
  in_type.tc:2: error: a generic function is used in the definition of a generic type or in the head of a generic function, where the instance that it names would stand before its prototype [function-instance-place]
  [1]
  $ cat > in_head.tc <<'EOF'
  > generic(T) int one(T x) { return 1; }
  > generic(T) int f(T x, int a[sizeof(one(0))]) { return 0; }
  > EOF
  $ ./golden.exe in_head.tc
  in_head.tc:2: error: a generic function is used in the definition of a generic type or in the head of a generic function, where the instance that it names would stand before its prototype [function-instance-place]
  [1]

Design 7.1 rule 9: a system header defines no generic function, as
typec passes its body through unread and an instance reads it again.

  $ cat > system.tc <<'EOF'
  > # 1 "system.tc"
  > typedef long T;
  > # 1 "sys.h" 1 3
  > generic(T) unsigned long size(T *p) { return sizeof(T); }
  > # 3 "system.tc" 2
  > unsigned long f(int *p) { return size(p); }
  > EOF
  $ ./golden.exe system.tc
  sys.h:1: error: a system header defines the body of a generic function, which typec passes through unread, while each instance reads it again under its type arguments [generic-system-body]
  [1]

Nor does a generic function hold a block literal, which C text that an
include puts there may write: typing does not read its body.

  $ cat > block.tc <<'EOF'
  > void use(const void *);
  > generic(T) void f(void)
  > {
  > # 1 "blk.h" 1
  >     int (^b)(void) = ^{ int a[] = {1, 2}; return a[0]; };
  > # 5 "block.tc" 2
  >     use(&b);
  > }
  > EOF
  $ ./golden.exe block.tc
  blk.h:1: error: a block literal in a generic function, whose body typing does not read, while each instance reads the definition again under its type arguments [generic-block-literal]
  [1]

Rule 4: no `#pragma` line that sets state stands between the
definition of the generic and the place where the instance is written.
A `pack` or diagnostic line sets none, nor does a statement pragma in
a function body, read or passed through unread.

  $ cat > pragma.tc <<'EOF'
  > generic(T) void clear(T *p) { }
  > #pragma GCC optimize("fast-math")
  > void f(int *p) { clear(p); }
  > EOF
  $ ./golden.exe pragma.tc
  pragma.tc:3: error: the instance 'clear(int)' is written before this external declaration, and the `#pragma` line at pragma.tc:2, which sets state, stands between that place and the definition of its generic, whose pragmas the instance is compiled under [instance-pragma]
  [1]
  $ cat > skipped.tc <<'EOF'
  > # 1 "skipped.tc"
  > generic(T) void clear(T *p) { }
  > # 1 "sys.h" 1 3
  > static inline void spin(void) {
  > #pragma GCC unroll 4
  >   for (int i = 0; i < 4; i++) ;
  > }
  > # 3 "skipped.tc" 2
  > void f(int *p) { clear(p); }
  > EOF
  $ ./golden.exe skipped.tc | grep -c 'clear__i'
  3
  $ cat > pack.tc <<'EOF'
  > generic(T) void clear(T *p) { }
  > #pragma pack(1)
  > #pragma GCC diagnostic ignored "-Wunused"
  > void f(int *p) { clear(p); }
  > EOF
  $ ./golden.exe pack.tc > /dev/null

The first use of a function instance goes through the checks of a type
instance's: its argument is declared before the external declaration
that holds the use, where the instance is written.

  $ cat > undeclared.tc <<'EOF'
  > generic(T) unsigned long size(T x) { return sizeof x; }
  > enum e3 { C } v3, w3 = sizeof(size(v3));
  > EOF
  $ ./golden.exe undeclared.tc
  undeclared.tc:2: error: the type argument names 'enum e3', which is declared in the external declaration of the instance's first use; declare it in an earlier one [instance-placement]
  [1]
  $ cat > declared.tc <<'EOF'
  > generic(T) unsigned long size(T x) { return sizeof x; }
  > enum e3 { C } v3;
  > unsigned long w3 = sizeof(size(v3));
  > EOF
  $ ./golden.exe declared.tc > /dev/null

Design 3.5 rule 7: every instance of `deep` calls one of a new type, so
the chain reaches the nesting limit; one that calls itself again does
not. The check of the definition follows the chain of its calls, so the
chain is refused at the call in the definition, with no use of `deep`.

  $ cat > deep.tc <<'EOF'
  > generic(T) void deep(T *p) { deep(&p); }
  > EOF
  $ ./golden.exe deep.tc
  deep.tc:1: error: the use would define the instance 'deep(T *********************************************************...' after a chain of 64 instances that each define the next, which the use at deep.tc:1 began; a chain holds at most 64 [instance-nesting]
  [1]
  $ cat > same.tc <<'EOF'
  > generic(T) void same(T *p) { same(p); }
  > void f(int *p) { same(p); }
  > EOF
  $ ./golden.exe same.tc > /dev/null

The shallow branching chain: each of `g0` to `g23` calls the next twice,
over `T *` and `const T *`, so a use of `g0` defines 2^25 - 1 instances
in chains of at most 25, which the nesting limit allows. The definition
checks follow their chains in the order of the definitions, so one of
them passes the budget before the use is read: the error and the call
that began its chain both stand in definitions (lines 1 to 25), and no
lowered text is written. Without the count of function instances the
check would not end within the time bound.

  $ chain() {
  >   n=$1; last=$((n - 1))
  >   echo "generic(T) void g$last(T *p) { }"
  >   i=$((n - 2))
  >   while [ $i -ge 0 ]; do
  >     echo "generic(T) void g$i(T *p) { const T *q = p;" \
  >       "g$((i + 1))(&p); g$((i + 1))(&q); }"
  >     i=$((i - 1))
  >   done
  > }
  $ { chain 25; echo 'int x; void use(void) { g0(&x); }'; } > chain25.tc
  $ (ulimit -t 20; ./golden.exe chain25.tc > chain25.err 2>&1)
  [1]
  $ sed -E "s/tc:[0-9]+/tc:N/g; s/'g[0-9]+\\([^']*\\)'/'g...'/" chain25.err
  chain25.tc:N: error: the use would define the instance 'g...', whose reading would pass the instance budget of typec, 16777216 bytes of text for the instances of the unit, those that definition checks read included, in a chain of instances that the use at chain25.tc:N began
  $ grep -oE 'tc:[0-9]+' chain25.err | cut -d: -f2 | awk '$1 > 25'

The chain of 10 defines its 1023 instances. Used with as many types as
pass the budget, it is refused at a call in an instance, and the message
cites the use that began the chain (line 51).

  $ { chain 10; echo 'int x; void use(void) { g0(&x); }'; } > chain10.tc
  $ ./golden.exe chain10.tc | grep -oE 'void g[0-9]__[A-Za-z0-9_]* \([^)]*\) \{' | grep -c .
  1023
  $ { chain 10; k=1; while [ $k -le 40 ]; do
  >     echo "struct s$k { int a; } x$k;"; k=$((k + 1)); done
  >   printf 'void use(void) {'; k=1; while [ $k -le 40 ]; do
  >     printf ' g0(&x%d);' $k; k=$((k + 1)); done; echo ' }'
  > } > uses.tc
  $ ./golden.exe uses.tc 2>&1 | sed -E "s/'g([0-9]+)\\([^']*\\)'/'g\\1(...)'/"
  uses.tc:3: error: the use would define the instance 'g8(...)', whose reading would pass the instance budget of typec, 16777216 bytes of text for the instances of the unit, those that definition checks read included, in a chain of instances that the use at uses.tc:51 began

The error stands at the call that defines the instance, not at a later
call of the same instance: each instance of `big` is charged its 16385
tokens, and the 32nd passes the budget at its first call (line 74).

  $ { printf 'generic(T) void big(T *p) { int a;'; i=0
  >   while [ $i -lt 4095 ]; do printf ' a = 0;'; i=$((i + 1)); done
  >   echo ' }'; k=1; while [ $k -le 40 ]; do
  >     echo "struct s$k { int a; } x$k;"; k=$((k + 1)); done
  >   echo 'void use(void) {'; for pass in 1 2; do k=1
  >     while [ $k -le 40 ]; do echo "big(&x$k);"; k=$((k + 1)); done
  >   done; echo '}'
  > } > again.tc
  $ ./golden.exe again.tc 2>&1
  again.tc:74: error: the use would define the instance 'big(struct s32)', whose reading would pass the instance budget of typec, 16777216 bytes of text for the instances of the unit, those that definition checks read included, in a chain of instances that the use at again.tc:74 began
  [1]

A definition check reads each instance once: a ladder of 40 generic
functions that each call the next twice with one type defines 40
instances, which a check that read each call again would not.

  $ { echo 'generic(T) void h39(T *p) { }'; i=38; while [ $i -ge 0 ]; do
  >     echo "generic(T) void h$i(T *p) { h$((i + 1))(p); h$((i + 1))(p); }"
  >     i=$((i - 1)); done; echo 'int x; void use(void) { h0(&x); }'
  > } > ladder.tc
  $ (ulimit -t 20; ./golden.exe ladder.tc) |
  >   grep -oE 'void h[0-9]*__[A-Za-z0-9_]* \([^)]*\) \{' | grep -c .
  40

No reading of a definition begins while another reading of it is open:
the instance that a body uses is read once the reading that uses it
ends, so `f__l` keeps its own parameters across the call of `f__c`.

  $ cat > recursive.tc <<'EOF'
  > generic(T) unsigned long g(T *p) { return sizeof *p; }
  > generic(T) unsigned long f(T *p, int n) { if (n) f((char *)p, 0); return g(p); }
  > unsigned long h(long *p) { return f(p, 1); }
  > EOF
  $ ./golden.exe recursive.tc | grep -v '^#' | grep 'f__l.*{'
  ; static unsigned long f__l ( __tc_arg__l * p , int n ) { if ( n ) f__c ( ( char * ) p , 0 ) ; return g__l ( p ) ; } static unsigned long f__c ( __tc_arg__c * p , int n ) { if ( n ) f__c ( ( char * ) p , 0 ) ; return g__c ( p ) ; }

The check of a definition reads it against its opaque types before any
instance that its calls define, which neither changes what the check
finds.

  $ cat > opaque.tc <<'EOF'
  > struct s { int a; };
  > generic(T) int f(T *p, int n) { if (n) f((struct s *)0, 0); return p->a; }
  > EOF
  $ ./golden.exe opaque.tc
  opaque.tc:2: error: 'a' is not a member of the structure or union (C11 6.5.2.3p1)
  [1]
  $ cat > self.tc <<'EOF'
  > generic(T) void f(T *p, int n) { if (n) f(&n, 0); T t = *p; }
  > EOF
  $ ./golden.exe self.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  [1]

The check writes no text of an instance that mentions a type parameter,
and reads the body as a trial: a generic function that no use
instantiates leaves no text of what it applies over its own types.

  $ cat > unused.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) void touch(T *p) { box(T) b; }
  > generic(T) box(T) *peek(T *p);
  > EOF
  $ ./golden.exe unused.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  [1]

The prototype of an instance stands after the instances that its head
needs.

  $ cat > head.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) box(T) wrap(T x) { box(T) b; b.v = x; return b; }
  > int f(void) { return wrap(1).v; }
  > EOF
  $ ./golden.exe head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i; struct box__i; typedef struct box__i box__i;
  struct box__i { __tc_arg__i v ; } ;
  static box__i wrap__i ( __tc_arg__i x )
  ;
  static box__i wrap__i ( __tc_arg__i x ) { box__i b ; b . v = x ; return b ; }
  int f(void) { return 
  wrap__i
  (1).v; }

The check reads the head where the definition stands, so an instance
that the head applies to concrete types is used there, and a prototype
and the definition agree on it.

  $ cat > concrete_head.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) box(int) count(T x);
  > generic(T) box(int) count(T x) { box(int) b; b.v = 1; return b; }
  > int f(void) { return count(1).v; }
  > EOF
  $ ./golden.exe concrete_head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i; struct box__i; typedef struct box__i box__i;
  struct box__i { __tc_arg__i v ; } ;
  static box__i count__i ( __tc_arg__i x )
  ;
  static box__i count__i ( __tc_arg__i x ) { box__i b ; b . v = 1 ; return b ; }
  int f(void) { return 
  count__i
  (1).v; }

An instance that the head uses first has its texts, and its definition
read, there as at any first use: one whose definition the head needs
complete, an alias or distinct one, whose definition is its type, one
first completed there, and one that the reading of an instance that
mentions a type parameter uses. A prototype that no use follows uses
them too.

  $ cat > by_value_head.tc <<'EOF'
  > type box(T) = struct { T v; };
  > generic(T) int get(box(int) b, T x) { return b.v; }
  > EOF
  $ ./golden.exe by_value_head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i; struct box__i; typedef struct box__i box__i;
  struct box__i { __tc_arg__i v ; } ;

  $ cat > alias_head.tc <<'EOF'
  > type ptr(T) = T *;
  > type handle(T) = distinct T *;
  > generic(T) int get(ptr(int) p, handle(int) h, T x) { return 0; }
  > EOF
  $ ./golden.exe alias_head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i;
  typedef __tc_arg__i * ptr__i ;
  typedef __tc_arg__i * handle__i ;

  $ cat > completed_head.tc <<'EOF'
  > type box(T) = struct { T v; };
  > box(int) *gp;
  > generic(T) int get(box(int) b, T x) { return b.v; }
  > EOF
  $ ./golden.exe completed_head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i; struct box__i; typedef struct box__i box__i;
  box__i
   *gp;
  struct box__i { __tc_arg__i v ; } ;

  $ cat > nested_head.tc <<'EOF'
  > type ptr(T) = T *;
  > type handle(T) = distinct ptr(int);
  > generic(T) int get(handle(T) h, T x) { return 0; }
  > int f(handle(long) h) { return get(h, 1L); }
  > EOF
  $ ./golden.exe nested_head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i;
  typedef __tc_arg__i * ptr__i ;
  typedef long __tc_arg__l;
  typedef ptr__i handle__l ;
  static int get__l ( handle__l h , __tc_arg__l x )
  ;
  static int get__l ( handle__l h , __tc_arg__l x ) { return 0 ; }
  int f(
  handle__l
   h) { return 
  get__l
  (h, 1L); }

  $ cat > prototype_head.tc <<'EOF'
  > type handle(T) = distinct T *;
  > generic(T) int get(handle(int) h, T x);
  > EOF
  $ ./golden.exe prototype_head.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i;
  typedef __tc_arg__i * handle__i ;

The head of a function declarator in the body is no head of the generic
function: a use there is a use in the body.

  $ cat > body_declarator.tc <<'EOF'
  > generic(T) int one(T x) { return 1; }
  > generic(T) int g(T x) { int (*fp)(int a[sizeof(one(x))]) = 0; return fp == 0; }
  > int f(void) { return g(1); }
  > EOF
  $ ./golden.exe body_declarator.tc | grep -v '^#' | grep -v '^ *$' | grep -v pack_probe
  typedef int __tc_arg__i;
  static int g__i ( __tc_arg__i x )
  ;
  static int one__i ( __tc_arg__i x )
  ; static int g__i ( __tc_arg__i x ) { int ( * fp ) ( int a [ sizeof ( one__i ( x ) ) ] ) = 0 ; return fp == 0 ; }
  static int one__i ( __tc_arg__i x ) { return 1 ; }
  int f(void) { return 
  g__i
  (1); }

An instance is read under its own name, which a function's type and
`__func__` name.

  $ cat > named.tc <<'EOF'
  > generic(T) T id(T x) { defer (void)0; return x; }
  > int f(void) { return id(1); }
  > EOF
  $ ./golden.exe named.tc | grep -o '__typeof__(id[_a-z]*)'
  __typeof__(id__i)

The `static` of an instance follows the attributes that begin its
definition, which C23 puts before every specifier.

  $ cat > attribute.tc <<'EOF'
  > generic(T) [[maybe_unused]] void id(T *x) { }
  > void f(int *p) { id(p); }
  > EOF
  $ ./golden.exe attribute.tc | grep 'id__i ('
  [ [ maybe_unused ] ] static void id__i ( __tc_arg__i * x )
  [ [ maybe_unused ] ] static void id__i ( __tc_arg__i * x ) { }

An instance has internal linkage, so no inline definition of a function
with external linkage uses one in its head or its body (C11 6.7.4p3);
a static one may, and so may an external definition, which `extern`
makes of it (6.7.4p7).

  $ cat > inline.tc <<'EOF'
  > generic(T) void clear(T *p) { }
  > inline void wipe(int *p) { clear(p); }
  > EOF
  $ ./golden.exe inline.tc
  inline.tc:2: error: an inline definition of a function with external linkage uses the instance 'clear(int)', which has internal linkage (C11 6.7.4p3) [instance-in-inline]
  [1]
  $ cat > inline_head.tc <<'EOF'
  > generic(T) int one(T x) { return 1; }
  > inline int count(int a[sizeof(one(0))]) { return 0; }
  > EOF
  $ ./golden.exe inline_head.tc
  inline_head.tc:2: error: an inline definition of a function with external linkage uses the instance 'one(int)', which has internal linkage (C11 6.7.4p3) [instance-in-inline]
  [1]
  $ cat > extern_inline.tc <<'EOF'
  > generic(T) void clear(T *p) { }
  > extern inline void wipe(int *p) { clear(p); }
  > EOF
  $ ./golden.exe extern_inline.tc | grep -c 'clear__i'
  3
  $ cat > static_inline.tc <<'EOF'
  > generic(T) void clear(T *p) { }
  > static inline void wipe(int *p) { clear(p); }
  > EOF
  $ ./golden.exe static_inline.tc | grep -c 'clear__i'
  3

Rule 3: an instance reads each name as the check of its definition
read it. The target type of `*out` is the opaque `T` in the check, no
variant, so `Overflow` there is the parameter (3.3), and in the instance
over `eval_error` it is still the parameter, not the constructor that
the target type of the instance has. Where the check's target type is a
variant, the name is the constructor in the check and in each instance.

  $ cat > readings.tc <<'EOF'
  > type eval_error = | DivByZero | Overflow;
  > generic(T) void put(T *out, T Overflow) { *out = Overflow; }
  > generic(T) void fail(eval_error *out, T Overflow) { *out = Overflow; }
  > void f(eval_error *e) { put(e, DivByZero); fail(e, 0); }
  > EOF
  $ ./golden.exe readings.tc | grep '{ \* out ='
  static void put__10eval_error ( __tc_arg__10eval_error * out , __tc_arg__10eval_error Overflow ) { * out = Overflow ; }
  static void fail__i ( eval_error * out , __tc_arg__i Overflow ) { * out = ((struct eval_error){ .tag = eval_error_Overflow }) ; }

Design 3.5 rule 8: a type declaration in the body of a generic
function is declared in each instance as it is at the definition,
lowered as in the body of any function: the distinct type to its
typedef, the variant to its structure.

  $ cat > body_types.tc <<'EOF'
  > generic(T) void put(T *out, T value) {
  >   type d = distinct int;
  >   type o = | Some(T x) | None;
  >   d n = (d)0;
  >   o w = Some(value);
  >   *out = value; (void)n; (void)w;
  > }
  > void f(int *out) { put(out, 1); }
  > EOF
  $ ./golden.exe body_types.tc | grep -v '^#' | grep -v '^ *$' |
  >   grep -v pack_probe
  typedef int __tc_arg__i;
  static void put__i ( __tc_arg__i * out , __tc_arg__i value )
  ;
  static void put__i ( __tc_arg__i * out , __tc_arg__i value ) {
  typedef int d ;
  struct o; typedef struct o o; enum o_tag { o_Some, o_None }; struct o { enum o_tag tag; union { struct { __tc_arg__i x ; } Some; } u; };
  d n = ( d ) 0 ;
  o w = { .tag = o_Some, .u.Some = {  value  } } ;
  * out = value ; ( void ) n ; ( void ) w ;
  }
  void f(int *out) { 
  put__i
  (out, 1); }
