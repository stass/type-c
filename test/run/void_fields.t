SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

An instance whose type argument void removes variant fields (design 3.5
rule 6), built on each backend with -Wall -Wextra -pedantic-errors: the
structures are those of 10.1 without the removed fields, as another
unit that declares them by hand finds, and the constructors and
patterns without the fields build and match at run time.

  $ . ./backends.sh

  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > #include <stddef.h>
  > type opt(T) = | No | Yes(T value);
  > type two(A, B) = | Two(A a, B b) | One(B only);
  > type three(A) = | Three(char first, A middle, long last, A end);
  > size_t opt_size(void);
  > size_t opt_alignment(void);
  > size_t two_size(void);
  > size_t two_alignment(void);
  > long two_b_by_hand(const two(void, long) *t);
  > long three_by_hand(const three(void) *t);
  > static opt(void) check(int ok) {
  >   if (ok)
  >     return Yes;
  >   return No;
  > }
  > static int is_yes(opt(void) o) {
  >   match (o) {
  >   case No: return 0;
  >   case Yes: return 1;
  >   }
  > }
  > static long value(two(void, long) t) {
  >   match (t) {
  >   case Two(b): return b;
  >   case One(only): return -only;
  >   }
  > }
  > int main(void) {
  >   two(void, long) t = Two(5), u = two(void, long).One(6);
  >   three(void) h = Three('a', 7);
  >   int tested = 0;
  >   if (case Yes = check(1))
  >     tested = 1;
  >   printf("%d %d %d %ld %ld %ld %ld %d %d\n", is_yes(check(1)),
  >          is_yes(check(0)), tested, value(t), value(u), two_b_by_hand(&t),
  >          three_by_hand(&h),
  >          sizeof(opt(void)) == opt_size()
  >              && _Alignof(opt(void)) == opt_alignment(),
  >          sizeof(two(void, long)) == two_size()
  >              && _Alignof(two(void, long)) == two_alignment());
  >   return 0;
  > }
  > EOF

  $ cat > hand.c <<'EOF'
  > #include <stddef.h>
  > struct opt__v { enum opt__v_tag { opt__v_No, opt__v_Yes } tag; };
  > struct two__vl {
  >   enum two__vl_tag { two__vl_Two, two__vl_One } tag;
  >   union { struct { long b; } Two; struct { long only; } One; } u;
  > };
  > struct three__v {
  >   enum three__v_tag { three__v_Three } tag;
  >   union { struct { char first; long last; } Three; } u;
  > };
  > size_t opt_size(void);
  > size_t opt_alignment(void);
  > size_t two_size(void);
  > size_t two_alignment(void);
  > long two_b_by_hand(const struct two__vl *t);
  > long three_by_hand(const struct three__v *t);
  > long three_by_hand(const struct three__v *t) {
  >   return t->u.Three.first + t->u.Three.last;
  > }
  > size_t opt_size(void) { return sizeof(struct opt__v); }
  > size_t opt_alignment(void) { return _Alignof(struct opt__v); }
  > size_t two_size(void) { return sizeof(struct two__vl); }
  > size_t two_alignment(void) { return _Alignof(struct two__vl); }
  > long two_b_by_hand(const struct two__vl *t) {
  >   return t->tag == two__vl_Two ? t->u.Two.b : -1;
  > }
  > EOF
  $ flags="-std=c11 -Wall -Wextra -pedantic-errors -Werror"
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -c -o program.o program.tc &&
  >     $cc $flags -c -o hand.o hand.c &&
  >     $cc -o program program.o hand.o && ./program
  > done
  1 0 1 5 -6 5 104 1 1
  1 0 1 5 -6 5 104 1 1
