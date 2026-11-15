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
  struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum e_tag tag; union {
   
   
  struct {
  int i
  ;
   e *next
  ; } B;
  } u; };
  struct pair; typedef struct pair pair; enum pair_tag { pair_P }; struct pair { enum pair_tag tag; union {
   
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

Constructors are refused where they do not fit.

  $ printf 'type e = | A | B(int i);\ne x = B;\n' > arguments.tc
  $ ./golden.exe arguments.tc
  arguments.tc:2: the constructor 'B' takes arguments (design 3.3) [TC0009]
  [1]
  $ printf 'type e = | A | B(int i);\ne x = e.C;\n' > missing.tc
  $ ./golden.exe missing.tc
  missing.tc:2: the variant 'e' has no constructor 'C' (design 3.3) [TC0009]
  [1]
  $ printf 'type e = | A | B(int i);\ne x = A();\n' > empty.tc
  $ ./golden.exe empty.tc
  empty.tc:2: the constructor 'A' has no fields, so it is written without parentheses (design 3.3) [TC0009]
  [1]
  $ printf 'type e = | A;\nint n = A;\n' > untargeted.tc
  $ ./golden.exe untargeted.tc
  untargeted.tc:2: 'A' is not declared (C11 6.5.1p2)
  [1]

A type name followed by `.` is a constructor in Type-C text only.

  $ printf 'type e = | A;\n# 1 "c.h" 1\ne x = e.A;\n' > c_text.tc
  $ ./golden.exe c_text.tc
  c.h:1: expected an expression, found the type name `e`
  [1]

`{0}` is the only braced initialiser of a variant (design 3.2 rule 7);
it zeroes a structure whose first member is a variant too.

  $ printf 'type e = | A | B(int i);\nstruct s { e v; int n; } z = {0};\ne x = {0};\n' > zero.tc
  $ ./golden.exe zero.tc | grep -v '^# ' | grep .
  struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum e_tag tag; union {
   
   
  struct {
  int i
  ; } B;
  } u; };
  struct s { e v; int n; } z = {0};
  e x = {0};
  $ printf 'type e = | A | B(int i);\ne x = { 1, 2 };\n' > braced.tc
  $ ./golden.exe braced.tc
  braced.tc:2: an initialiser reaches into the variant 'e'; the only braced initialiser of a variant is {0} (design 3.2 rule 7) [TC0008]
  [1]
  $ printf 'type e = | A | B(int i);\nstruct s { e v; int n; } z = { 0, 1 };\n' > elided.tc
  $ ./golden.exe elided.tc
  elided.tc:2: an initialiser reaches into the variant 'e'; the only braced initialiser of a variant is {0} (design 3.2 rule 7) [TC0008]
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
  header.h:1: the enumerator `e_A` is declared again, as a type declaration claims it (design 10.1 rule 6) [TC0004]
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
  carried.tc:3: the constructor expression is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant (design 3.3) [TC0024]
  [1]
  $ cat > assigned.tc <<'EOF'
  > void f(void) {
  >   typedef __typeof__(({ type e = | A; e v = A; v; })) t;
  >   t y;
  >   y = A;
  > }
  > EOF
  $ ./golden.exe assigned.tc
  assigned.tc:4: the constructor expression is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant (design 3.3) [TC0024]
  [1]
  $ cat > qualified.tc <<'EOF'
  > void f(void) {
  >   typedef __typeof__(({ type e = | A; e v = A; v; })) t;
  >   t y = t.A;
  > }
  > EOF
  $ ./golden.exe qualified.tc
  qualified.tc:3: the constructor expression is outside the scope of the declaration of the variant 'e', where the names that it lowers to do not denote the variant (design 3.3) [TC0024]
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
