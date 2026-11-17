SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type-C code builds variants through constructors, qualified and
unqualified, in the positions that have a target type (design 3.3), and
C code reads them through the representation of design 10.6, on each
backend. Static objects take constructors as constant initialisers.

  $ . ./backends.sh

  $ cat > reader.h <<'EOF'
  > static long eval(const expr *e) {
  >   switch (e->tag) {
  >   case expr_Number: return e->u.Number.value;
  >   case expr_Nil: return 0;
  >   case expr_Add: return eval(e->u.Add.left) + eval(e->u.Add.right);
  >   }
  >   return -1;
  > }
  > static int is_on(flag f) { return f.tag == flag_On; }
  > static long first(pair p) { return eval(&p.u.Both.left); }
  > EOF
  $ cat > build.tc <<'EOF'
  > #include <stdio.h>
  > type expr =
  >     | Number(long value)
  >     | Nil
  >     | Add(expr *left, expr *right);
  > type flag = | Off | On;
  > type pair = | Both(expr left, expr right);
  > #include "reader.h"
  > static expr one = Number(1), two = expr.Number(2);
  > static expr three = Add(&one, &two);
  > static pair both = Both(Number(4), expr.Nil);
  > static flag toggle(flag f) { return is_on(f) ? Off : On; }
  > static long sum(expr e) { return eval(&e); }
  > int main(void) {
  >   expr a = Number(10), b;
  >   b = Add(&a, &three);
  >   flag f = toggle(Off);
  >   expr n = (Nil);
  >   expr c = is_on(f) ? Number(5) : Nil;
  >   printf("%ld %ld %ld %d %ld\n", eval(&b), sum(Number(7)), eval(&c),
  >          is_on(f), eval(&n) + first(both));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-build build.tc && ./clang-build
  13 7 5 1 4
  $ typec --cc=$gcc -Wall -Werror -o gcc-build build.tc && ./gcc-build
  13 7 5 1 4

Under elided braces an unqualified constructor is chosen by the type of
the subobject that the initialiser reaches, so it means the same as in a
direct initialiser even where an object of the same name is visible
(design 3.3).

  $ cat > tag.h <<'EOF'
  > static int tagof(e v) { return v.tag; }
  > EOF
  $ cat > elided.tc <<'EOF'
  > #include <stdio.h>
  > type e = | A | B(int i);
  > #include "tag.h"
  > e A = e.B(7);
  > struct S { e v; int n; };
  > struct W { struct S s; };
  > int main(void) {
  >   e direct = A;
  >   e m[2][2] = { A, A, A, A };
  >   struct W w = { A, 1 };
  >   printf("%d %d %d\n", tagof(direct), tagof(m[1][1]), tagof(w.s.v));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -Wno-missing-braces -o clang-elided elided.tc && ./clang-elided
  0 0 0
  $ typec --cc=$gcc -Wall -Werror -Wno-missing-braces -o gcc-elided elided.tc && ./gcc-elided
  0 0 0

A constructor lowers to the structure tag and the enumerators of its
variant, which no declaration in the variant's scope may hide, so a
block that hides the variant's typedef name still builds it (design
10.1 rule 6, 13.5).

  $ cat > payload.h <<'EOF'
  > static int payload(e v) { return v.u.B.i; }
  > EOF
  $ cat > hidden.tc <<'EOF'
  > #include <stdio.h>
  > type e = | A | B(int i);
  > #include "tag.h"
  > #include "payload.h"
  > int main(void) {
  >   e x = A;
  >   {
  >     int e = 3;
  >     x = B(e);
  >   }
  >   printf("%d %d\n", tagof(x), payload(x));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-hidden hidden.tc && ./clang-hidden
  1 3
  $ typec --cc=$gcc -Wall -Werror -o gcc-hidden hidden.tc && ./gcc-hidden
  1 3

A block that declares a derived enumerator is refused, as it would
hide the one that the lowered constructor names.

  $ cat > enumerator.tc <<'EOF'
  > type e = | A;
  > int main(void) {
  >   e x;
  >   {
  >     int e_A = 1;
  >     x = A;
  >   }
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -o clang-enumerator enumerator.tc
  enumerator.tc:5: error: the enumerator `e_A` is declared again, as a type declaration claims it [claimed-name]
  [80]
