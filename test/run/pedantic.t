SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The lowered code of a program that uses the forms of the lowering (design
13.5) compiles as ISO C11 under -pedantic-errors on each backend, as
design 2.4 asks of everything Type-C lowers to.

typec gives the backend the emitted file as preprocessed output, so the
backend checks it as it is, and its line markers keep the system headers
exempt. The backend reads those markers, which no user wrote, without a
diagnostic, so typec adds no option to quiet them; the last command
shows it for Clang with -Wgnu-line-marker, which of the Clang releases
only Clang 20, below the minimum, applies to preprocessed input.

The forms are those of a variant with a union and one without (10.1),
one declared before it is completed, constructors bare and qualified,
nested ones in a static initialiser, a match with bindings and its trap
for a bad tag, one with a default, one on a pointer and one on a value
that is no object, a distinct type with its casts, and a generic
selection and a compatibility test that typec answers for it.

The golden tests lower for a canned target and show fragments of the
result, and the other run tests write their programs inside them, so this
test names its own program.

  $ . ./backends.sh

  $ cat > forms.tc <<'EOF'
  > #include <stdio.h>
  > type colour;
  > type shape = private
  >     | Circle(int radius)
  >     | Rect(int width, int height)
  >     | Empty;
  > type colour = | Red | Green;
  > type pair = | Two(shape first, shape second);
  > type metres = distinct int;
  > static pair stored = Two(Circle(1), shape.Empty);
  > static shape made(int n) {
  >   if (n > 1) return shape.Rect(n, n + 1);
  >   return n ? Circle(n) : Empty;
  > }
  > static int area(shape s) {
  >   match (s) {
  >   case Circle(r):
  >     return 3 * r * r;
  >   case Rect(w, h):
  >     return w * h;
  >   case Empty:
  >     return 0;
  >   }
  > }
  > static int corners(const shape *s) {
  >   match (*s) {
  >   case Rect(_, _):
  >     return 4;
  >   default:
  >     return 0;
  >   }
  > }
  > static int green(colour c) {
  >   match (c) {
  >   case Green:
  >     return 1;
  >   case Red:
  >     return 0;
  >   }
  > }
  > static int first_area(void) {
  >   match (stored) {
  >   case Two(shape f, _):
  >     return area(f);
  >   }
  > }
  > static metres twice(metres m) { return (metres)((int)m * 2); }
  > int main(void) {
  >   shape r = made(2);
  >   metres m = twice((metres)3);
  >   int steered = _Generic(m, metres: 1, default: 2);
  >   int same = __builtin_types_compatible_p(metres, int);
  >   int kept;
  >   match (made(3)) {
  >   case Rect(w, _):
  >     kept = w;
  >     break;
  >   default:
  >     kept = 0;
  >     break;
  >   }
  >   printf("%d %d %d %d %d %d\n", area(made(1)), area(r), corners(&r),
  >          (int)m, steered * 10 + same, green(colour.Green));
  >   printf("%d %d\n", first_area(), kept);
  >   return 0;
  > }
  > EOF
  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -std=c11 -pedantic-errors -Wall -Wextra -Werror \
  >     -o forms forms.tc && ./forms
  > done
  3 6 4 6 10 1
  3 3
  3 6 4 6 10 1
  3 3
  $ typec --cc="$clang" --emit-c -std=c11 forms.tc | grep -q '^# [0-9]' &&
  >   echo markers
  markers
  $ typec --cc="$clang" -std=c11 -pedantic-errors -Wgnu-line-marker -Werror \
  >   -fsyntax-only forms.tc
