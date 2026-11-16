SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A result that is discarded with a cast to void or stored by a
declaration or an assignment (design 5.2) compiles on each backend with
-Wall -Wextra -pedantic-errors -Werror; one that the last statement of
a statement expression gives does too, in GNU C without
-pedantic-errors, which refuses the statement expression.

  $ . ./backends.sh
  $ gnu="-std=gnu11 -Wall -Wextra -Werror"
  $ pedantic="-std=c11 -Wall -Wextra -pedantic-errors -Werror"
  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > static int calls;
  > static result(int, int) f(void) {
  >   calls++;
  >   return Ok(calls);
  > }
  > static int value(result(int, int) r) {
  >   match (r) {
  >   case Err(e): return -e;
  >   case Ok(v): return v;
  >   }
  > }
  > int main(void) {
  >   (void)f();
  >   result(int, int) stored = f();
  >   int first = value(stored);
  >   stored = f();
  >   int second = value(stored);
  >   stored = ({ (void)f(); f(); });
  >   printf("%d %d %d %d\n", first, second, value(stored), calls);
  >   return 0;
  > }
  > EOF
  $ cat > pedantic.tc <<'EOF'
  > static result(int, int) f(void) { return Ok(1); }
  > int main(void) {
  >   (void)f();
  >   result(int, int) stored = f();
  >   stored = f();
  >   (void)stored;
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $gnu -o program program.tc && ./program &&
  >     typec --cc=$cc $pedantic -c pedantic.tc
  > done
  2 3 5 5
  2 3 5 5
