SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The bindings of a match arm or a single-pattern test are declared in a
block of their own around the body, so the body begins its block as it
was written (design 13.5): a pragma that must begin a compound
statement, as #pragma STDC FENV_ACCESS and #pragma clang fp must on
Clang, and GNU local labels, which come first in a block, keep their
place on each backend. GCC ignores the two pragmas. A pragma before the
controlled statement of a test, as #pragma GCC unroll before a loop,
stays directly before it.

  $ . ./backends.sh

  $ cat > pragmas.tc <<'EOF'
  > #include <stdio.h>
  > type option = | None | Some(double value);
  > static double third(const option *o) {
  >   if (case Some(v) = *o) {
  > #pragma STDC FENV_ACCESS ON
  >     return v / 3.0;
  >   }
  >   return 0;
  > }
  > static double scaled(option o) {
  >   match (o) {
  >   case Some(v):
  > #pragma clang fp contract(fast)
  >     return v * 2.0 + 1.0;
  >   case None:
  >     return 0;
  >   }
  > }
  > int main(void) {
  >   option three = Some(3.0);
  >   printf("%g %g\n", third(&three), scaled(three));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -pedantic-errors -Werror -o clang-pragmas \
  >   pragmas.tc
  $ ./clang-pragmas
  1 7
  $ typec --cc=$gcc -Wall -Wextra -pedantic-errors -Werror \
  >   -Wno-unknown-pragmas -o gcc-pragmas pragmas.tc
  $ ./gcc-pragmas
  1 7

  $ cat > labels.tc <<'EOF'
  > #include <stdio.h>
  > type option = | None | Some(int value);
  > static int counted(option o) {
  >   int n = 0;
  >   if (case Some(v) = o) {
  >     __label__ done;
  >     if (v > 1)
  >       goto done;
  >     n++;
  >   done:
  >     n++;
  >   }
  >   return n;
  > }
  > int main(void) {
  >   printf("%d %d %d\n", counted(Some(1)), counted(Some(2)), counted(None));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -Werror -o clang-labels labels.tc
  $ ./clang-labels
  2 1 0
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-labels labels.tc
  $ ./gcc-labels
  2 1 0

  $ cat > unrolled.tc <<'EOF'
  > #include <stdio.h>
  > type option = | None | Some(int value);
  > static int sum(option o) {
  >   int total = 0;
  >   if (case Some(v) = o)
  > #pragma GCC unroll 4
  >     for (int i = 0; i < 4; i++)
  >       total += v;
  >   return total;
  > }
  > int main(void) {
  >   printf("%d %d\n", sum(Some(2)), sum(None));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -pedantic-errors -Werror -o clang-unrolled \
  >   unrolled.tc
  $ ./clang-unrolled
  8 0
  $ typec --cc=$gcc -Wall -Wextra -pedantic-errors -Werror -o gcc-unrolled \
  >   unrolled.tc
  $ ./gcc-unrolled
  8 0
