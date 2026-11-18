SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A constructor expression (design 3.3) becomes a compound literal, or
the braced list alone where it is the whole initialiser of an object of
its variant, also as an argument of another constructor (design 13.5).
The arguments keep their tokens and lines.

  $ cat > construct.tc <<'EOF'
  > type e = | A | B(int i, e *next);
  > type pair = | P(e first, e second);
  > static e a = A;
  > static pair p = P(e.B(1, &a), A);
  > e f(int n) {
  >   e x = n ? A : B(n,
  >                   &a);
  >   x = e.A;
  >   return (x = B(2, 0), A);
  > }
  > EOF
  $ ./golden.exe construct.tc | grep -v '^# ' | grep .
  struct e; typedef struct e e;
   
  enum e_tag { e_A, e_B, __tc_tag_max__e_tag = 2147483647 }; struct e { enum e_tag tag; union {
   
   
  struct {
  int i
  ;
   e *next
  ; } B;
  } u; };
  struct pair; typedef struct pair pair;
   
  enum pair_tag { pair_P, __tc_tag_max__pair_tag = 2147483647 }; struct pair { enum pair_tag tag; union {
   
  struct {
  e first
  ;
   e second
  ; } P;
  } u; };
  static e a = 
  { .tag = e_A }
  ;
  static pair p = 
  { .tag = pair_P, .u.P = { 
  { .tag = e_B, .u.B = { 
  1, &a
   } }
  , 
  { .tag = e_A }
   } }
  ;
  e f(int n) {
    e x = n ? 
  ((struct e){ .tag = e_A })
   : 
  ((struct e){ .tag = e_B, .u.B = { 
  n,
                    &a
   } })
  ;
    x = 
  ((struct e){ .tag = e_A })
  ;
    return (x = 
  ((struct e){ .tag = e_B, .u.B = { 
  2, 0
   } })
  , 
  ((struct e){ .tag = e_A })
  );
  }

The braced list replaces the parentheses around the constructor too:
inside them it would be a statement expression of GNU C, and GCC under
`-pedantic-errors` refuses a compound literal there at file scope.

  $ printf 'type e = | A | B(int i);\nstatic e x = (B(1));\nstatic e y = ((A));\nstruct s { e v; } z = { (B(2)) };\n' > parenthesized.tc
  $ ./golden.exe parenthesized.tc | grep -v '^# ' | grep -v '^ *$' | tr -s ' \n' ' '; echo
  struct e; typedef struct e e; enum e_tag { e_A, e_B, __tc_tag_max__e_tag = 2147483647 }; struct e { enum e_tag tag; union { struct { int i ; } B; } u; }; static e x = { .tag = e_B, .u.B = { 1 } } ; static e y = { .tag = e_A } ; struct s { e v; } z = { { .tag = e_B, .u.B = { 2 } } }; 

An unqualified constructor may share its name with a visible typedef
name: where the target type is a variant with that constructor, the
name is the constructor (design 3.3), in an initialiser, on the
right of `=`, as an argument and as the operand of `return`.

  $ cat > typedef_named.tc <<'EOF'
  > typedef struct Member Member;
  > struct Member { int offset; };
  > typedef int A;
  > type K = | A | Member(K *self, Member *m);
  > void take(K k);
  > K f(Member *m) {
  >   K a = Member(0, m);
  >   a = Member(&a, m);
  >   take(Member(&a, m));
  >   a = A;
  >   return Member(&a, m);
  > }
  > EOF
  $ ./golden.exe typedef_named.tc | grep -o 'tag = K_[A-Za-z]*'
  tag = K_Member
  tag = K_Member
  tag = K_Member
  tag = K_A
  tag = K_Member

Where C's grammar reads the typedef name as beginning a type name, it
still does: a block item `T (n);` declares `n`, and `(T)(x)`,
`sizeof(T)` and `(T){...}` are a cast, a size and a compound literal.

  $ cat > typedef_readings.tc <<'EOF'
  > typedef int T;
  > type e = | T(int i);
  > int f(int x) {
  >   T (n);
  >   n = (T)(x) + (int)sizeof(T) + (T){2};
  >   e v = e.T(n);
  >   (void)v;
  >   return n;
  > }
  > EOF
  $ ./golden.exe typedef_readings.tc | grep -v '^# ' | sed -n '/^int f/,/^}/p'
  int f(int x) {
    T (n);
    n = (T)(x) + (int)sizeof(T) + (T){2};
    e v = 
  { .tag = e_T, .u.T = { 
  n
   } }
  ;
    (void)v;
    return n;
  }

So after `(` the constructor is written qualified, and where no target
type has it, the typedef name is no expression.

  $ printf 'typedef int T;\ntype e = | T(int i);\ne v = (T(1));\n' > typedef_parenthesized.tc
  $ ./golden.exe typedef_parenthesized.tc
  typedef_parenthesized.tc:3: error: expected a declarator, found `1`
  [1]
  $ printf 'typedef int T;\ntype e = | T(int i);\nint n = T(1);\n' > typedef_untargeted.tc
  $ ./golden.exe typedef_untargeted.tc
  typedef_untargeted.tc:3: error: expected an expression, found the type name 'T'
  [1]

Constructors are refused where they do not fit.

  $ printf 'type e = | A | B(int i);\ne x = B;\n' > arguments.tc
  $ ./golden.exe arguments.tc
  arguments.tc:2: error: the constructor 'B' takes arguments [constructor-expression]
  [1]
  $ printf 'type e = | A | B(int i);\ne x = e.C;\n' > missing.tc
  $ ./golden.exe missing.tc
  missing.tc:2: error: the variant 'e' has no constructor 'C' [constructor-expression]
  [1]
  $ printf 'type e = | A | B(int i);\ne x = A();\n' > empty.tc
  $ ./golden.exe empty.tc
  empty.tc:2: error: the constructor 'A' has no fields, so it is written without parentheses [constructor-expression]
  [1]
  $ printf 'type e = | A;\nint n = A;\n' > untargeted.tc
  $ ./golden.exe untargeted.tc
  untargeted.tc:2: error: 'A' is a constructor of 'e', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
  [1]

A constructor alone where no variant with it is expected names nothing;
the message says which variant in scope has it, the one declared last,
and what is expected there. C text names no constructor, so its message
says where constructors are written. Out of its variant's scope, the
name is undeclared.

  $ printf 'void f(void) { (void)Err(1); }\n' > untargeted_err.tc
  $ ./golden.exe untargeted_err.tc
  untargeted_err.tc:1: error: 'Err' is a constructor of 'result(T, E)', written without its variant only where a variant with it is expected; here none is, so write the variant before it, as 'result(T, E).Err' with its type arguments [constructor-expression]
  [1]
  $ printf 'int n = None;\n' > untargeted_none.tc
  $ ./golden.exe untargeted_none.tc
  untargeted_none.tc:1: error: 'None' is a constructor of 'option(T)', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
  [1]
  $ cat > other_variant.tc <<'EOF'
  > type err = | NoMemory | BadInput(int code);
  > err g(void) { return (Err(NoMemory)); }
  > EOF
  $ ./golden.exe other_variant.tc
  other_variant.tc:2: error: 'Err' is a constructor of 'result(T, E)', written without its variant only where a variant with it is expected; here a value of type 'err' is expected [constructor-expression]
  [1]
  $ printf '# 1 "c.h" 1\nint n = None;\n' > c_text_none.tc
  $ ./golden.exe c_text_none.tc
  c.h:1: error: 'None' is not declared (C11 6.5.1p2); as a constructor of 'option(T)' it is written only in a Type-C file, a .tc or .tci
  [1]
  $ cat > c_text_err.tc <<'EOF'
  > type e2 = | Bad;
  > # 1 "c.h" 1
  > static result(int, e2) h(void) { return (Err(Bad)); }
  > EOF
  $ ./golden.exe c_text_err.tc
  c.h:1: error: 'Err' is not declared (C11 6.5.1p2); as a constructor of 'result(T, E)' it is written only in a Type-C file, a .tc or .tci
  [1]
  $ cat > own_variant.tc <<'EOF'
  > type err = | NoMemory | Bad;
  > int f(void) {
  >   int x = NoMemory;
  >   return x;
  > }
  > EOF
  $ ./golden.exe own_variant.tc
  own_variant.tc:3: error: 'NoMemory' is a constructor of 'err', written without its variant only where a variant with it is expected; here a value of type 'int' is expected [constructor-expression]
  [1]
  $ cat > own_ok.tc <<'EOF'
  > type res = | Ok | Failed;
  > void f(void) { (void)Ok; }
  > EOF
  $ ./golden.exe own_ok.tc
  own_ok.tc:2: error: 'Ok' is a constructor of 'res', written without its variant only where a variant with it is expected; here none is, so write the variant before it, as 'res.Ok' [constructor-expression]
  [1]
  $ cat > own_generic.tc <<'EOF'
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > void f(void) { (void)Nil; }
  > EOF
  $ ./golden.exe own_generic.tc
  own_generic.tc:2: error: 'Nil' is a constructor of 'list(T)', written without its variant only where a variant with it is expected; here none is, so write the variant before it, as 'list(T).Nil' with its type arguments [constructor-expression]
  [1]
  $ cat > out_of_scope.tc <<'EOF'
  > void f(void) {
  >   {
  >     type err = | NoMemory | Bad;
  >   }
  >   int x = NoMemory;
  > }
  > EOF
  $ ./golden.exe out_of_scope.tc
  out_of_scope.tc:5: error: 'NoMemory' is not declared (C11 6.5.1p2)
  [1]
  $ cat > c_text_own.tc <<'EOF'
  > type e3 = | Missing;
  > # 1 "c.h" 1
  > static int h(void) { return Missing; }
  > EOF
  $ ./golden.exe c_text_own.tc
  c.h:1: error: 'Missing' is not declared (C11 6.5.1p2); as a constructor of 'e3' it is written only in a Type-C file, a .tc or .tci
  [1]

A name that is not declared is suggested as no constructor, even one a
few edits away, as a nearer name of another declaration may be meant.

  $ cat > misspelt.tc <<'EOF'
  > type shape = | Circle(double r) | Rect(double w, double h);
  > shape f(void) { return Circel(1.0); }
  > EOF
  $ ./golden.exe misspelt.tc
  misspelt.tc:2: error: 'Circel' is not declared (C11 6.5.1p2)
  [1]
  $ printf 'option(int) g(void) { return Smoe(1); }\n' > misspelt_universe.tc
  $ ./golden.exe misspelt_universe.tc
  misspelt_universe.tc:1: error: 'Smoe' is not declared (C11 6.5.1p2)
  [1]
  $ cat > misspelt_inner.tc <<'EOF'
  > type s1 = | Circle(double r);
  > void f(void) {
  >   type s2 = | Circle(int n);
  >   (void)Circel;
  > }
  > EOF
  $ ./golden.exe misspelt_inner.tc
  misspelt_inner.tc:4: error: 'Circel' is not declared (C11 6.5.1p2)
  [1]
  $ printf 'type e4 = | Circle;\n# 1 "c.h" 1\nstatic int h(void) { return Circel; }\n' > misspelt_c_text.tc
  $ ./golden.exe misspelt_c_text.tc
  c.h:1: error: 'Circel' is not declared (C11 6.5.1p2)
  [1]

A constructor that its variant lacks, after the variant or in a
pattern, is suggested as the one constructor of that variant a few
edits from it; one as close to two, or too short to say which was
meant, is not.

  $ printf 'type shape = | Circle(double r);\nshape s = shape.Circel(1.0);\n' > misspelt_qualified.tc
  $ ./golden.exe misspelt_qualified.tc
  misspelt_qualified.tc:2: error: the variant 'shape' has no constructor 'Circel'; did you mean 'Circle'? [constructor-expression]
  [1]
  $ cat > misspelt_pattern.tc <<'EOF'
  > type shape = | Circle(double r) | Rect(double w, double h);
  > double area(shape s) {
  >   match (s) {
  >   case Circel(r): return r;
  >   default: return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe misspelt_pattern.tc
  misspelt_pattern.tc:4: error: 'Circel' names no constructor of the variant 'shape'; did you mean 'Circle'? [match-pattern]
  [1]
  $ printf 'type pet = | Cat | Car;\npet p = pet.Cab;\n' > misspelt_tie.tc
  $ ./golden.exe misspelt_tie.tc
  misspelt_tie.tc:2: error: the variant 'pet' has no constructor 'Cab' [constructor-expression]
  [1]
  $ printf 'type e = | A;\ne v = e.B;\n' > misspelt_short.tc
  $ ./golden.exe misspelt_short.tc
  misspelt_short.tc:2: error: the variant 'e' has no constructor 'B' [constructor-expression]
  [1]

A constructor is no function, so its name in parentheses is not called.

  $ printf 'option(int) f(void) { return (Some)(1); }\n' > parenthesized.tc
  $ ./golden.exe parenthesized.tc
  parenthesized.tc:1: error: 'Some' is a constructor of 'option(T)', not a function, so it is not called in parentheses; write 'Some(...)' [constructor-expression]
  [1]
  $ printf 'type e = | A | B(int v);\ne f(void) { return (A)(1); }\n' > parenthesized_unit.tc
  $ ./golden.exe parenthesized_unit.tc
  parenthesized_unit.tc:2: error: 'A' is a constructor of 'e', not a function, so it is not called in parentheses; write 'A' [constructor-expression]
  [1]

  $ cat > targeted_none.tc <<'EOF'
  > option(int) o = None;
  > void f(void) { (void)result(int, int).Err(1); }
  > EOF
  $ ./golden.exe targeted_none.tc > /dev/null

A type name followed by `.` is a constructor in Type-C text only.

  $ printf 'type e = | A;\n# 1 "c.h" 1\ne x = e.A;\n' > c_text.tc
  $ ./golden.exe c_text.tc
  c.h:1: error: expected an expression, found the type name `e`
  [1]

`{0}` and `{}` are the only braced initialisers of a variant (design
3.2 rule 7); `{0}` zeroes a structure whose first member is a variant
too.

  $ printf 'type e = | A | B(int i);\nstruct s { e v; int n; } z = {0};\ne x = {0};\n' > zero.tc
  $ ./golden.exe zero.tc | grep -v '^# ' | grep .
  struct e; typedef struct e e;
   
  enum e_tag { e_A, e_B, __tc_tag_max__e_tag = 2147483647 }; struct e { enum e_tag tag; union {
   
   
  struct {
  int i
  ; } B;
  } u; };
  struct s { e v; int n; } z = {0};
  e x = {0};

The empty initialiser `{}` (GNU C, C23) is the zero value of a variant
wherever `{0}` is: on a variant object, static or automatic, on a
structure whose first member is a variant, and on an element of an
array of variants.

  $ cat > empty.tc <<'EOF'
  > type e = | A | B(int i);
  > struct s { e v; int n; } z = {};
  > static e w = {};
  > e a[2] = { {}, {0} };
  > void f(void) { e v = {}; (void)v; }
  > EOF
  $ ./golden.exe empty.tc | grep ' = {'
  struct s { e v; int n; } z = {};
  static e w = {};
  e a[2] = { {}, {0} };
  void f(void) { e v = {}; (void)v; }
  $ printf 'type e = | A | B(int i);\ne x = { 1, 2 };\n' > braced.tc
  $ ./golden.exe braced.tc
  braced.tc:2: error: an initialiser reaches into the variant 'e'; the only braced initialisers of a variant are {0} and {} [variant-initializer]
  [1]
  $ printf 'type e = | A | B(int i);\nstruct s { e v; int n; } z = { 0, 1 };\n' > elided.tc
  $ ./golden.exe elided.tc
  elided.tc:2: error: an initialiser reaches into the variant 'e'; the only braced initialisers of a variant are {0} and {} [variant-initializer]
  [1]

A constructor's lowering names the variant's structure tag and its
enumerators, which are claimed in the whole scope of the variant, so a
declaration in a nested block cannot hide them, in C text such as a
header included there either (design 10.1 rule 6). The typedef name is
not claimed, and a block may hide it.

  $ cat > hidden.tc <<'EOF'
  > type e = | A;
  > void f(e *p) {
  >   int e = 0;
  >   *p = A;
  > }
  > EOF
  $ ./golden.exe hidden.tc | grep '\.tag ='
  ((struct e){ .tag = e_A })
  $ cat > header.tc <<'EOF'
  > type e = | A;
  > void f(e *p) {
  > # 1 "header.h"
  > int e_A;
  > # 5 "header.tc"
  >   *p = A;
  > }
  > EOF
  $ ./golden.exe header.tc
  header.h:1: error: the enumerator `e_A` is declared again, as a type declaration claims it [claimed-name]
  [1]

A constructor expression stands within the scope of its variant's
declaration, from the declaration to the end of its block or of the
translation unit, where the names its lowering derives denote the
variant (design 3.3). A statement expression carries the type of its
block out of it; a construction there is refused, as the lowering
would name an unrelated `e_A` or no structure at all.

  $ cat > carried.tc <<'EOF'
  > int e_A = 7;
  > void f(void) {
  >   __typeof__(({ type e = | A; e v = A; v; })) y = A;
  > }
  > EOF
  $ ./golden.exe carried.tc
  carried.tc:3: error: the constructor expression is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant [constructor-scope]
  [1]
  $ cat > assigned.tc <<'EOF'
  > void f(void) {
  >   typedef __typeof__(({ type e = | A; e v = A; v; })) t;
  >   t y;
  >   y = A;
  > }
  > EOF
  $ ./golden.exe assigned.tc
  assigned.tc:4: error: the constructor expression is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant [constructor-scope]
  [1]
  $ cat > qualified.tc <<'EOF'
  > void f(void) {
  >   typedef __typeof__(({ type e = | A; e v = A; v; })) t;
  >   t y = t.A;
  > }
  > EOF
  $ ./golden.exe qualified.tc
  qualified.tc:3: error: the constructor expression is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant [constructor-scope]
  [1]

Within the scope, a construction stands anywhere: in the block of the
declaration, in a block nested in it or in a statement expression there
whose type it carries, in the arm that declares the variant, after the
definition that completes an incomplete variant, and after the
declaration at file scope.

  $ cat > scoped.tc <<'EOF'
  > type f_e = | F;
  > void f(void) {
  >   __typeof__(({ type e = | A; e v = A; { e w = e.A; v = w; } v; })) y;
  >   (void)y;
  > }
  > void l(void) {
  >   type e = | A;
  >   __typeof__(({ e v = A; v; })) y = A;
  >   type g;
  >   type g = | G;
  >   g z = G;
  >   (void)y;
  >   (void)z;
  > }
  > f_e g(void) { { return F; } }
  > static f_e h = f_e.F;
  > void k(f_e x) {
  >   match (x) {
  >   case F:
  >     type u = | X;
  >     u w = X;
  >     (void)w;
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe scoped.tc > /dev/null
