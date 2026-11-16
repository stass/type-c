SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The universe generics option and result (design 3.6) on each backend
with -Wall -Wextra -pedantic-errors -Werror: their instances are written
from the universe text under flag 3, as typec's own text is (design
13.4), so they draw no warning.

  $ . ./backends.sh
  $ flags="-std=c11 -Wall -Wextra -pedantic-errors -Werror"

The zero value of an option is None, and that of a result is Err of a
zero error, whether static, braced with zero or from calloc. The layout
is that of 10.1, which a hand-written structure of option(int) reads
(design 10.6). A unit that also uses option(int) links with the first,
each with its own instance text.

  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > typedef int error_code;
  > int value_by_hand(const option(int) *o);
  > int some_elsewhere(void);
  > static option(int) unset;
  > static int is_none(option(int) o) {
  >   match (o) {
  >   case None: return 1;
  >   case Some(v): return v < 0;
  >   }
  > }
  > static int zero_error(result(int, error_code) r) {
  >   match (r) {
  >   case Err(e): return e == 0;
  >   case Ok(v): return v < 0;
  >   }
  > }
  > int main(void) {
  >   result(int, error_code) braced = {0};
  >   result(int, error_code) *allocated = calloc(1, sizeof *allocated);
  >   option(int) three = Some(3);
  >   if (!allocated) return 1;
  >   printf("%d %d %d %d %d\n", is_none(unset), zero_error(braced),
  >          zero_error(*allocated), value_by_hand(&three), some_elsewhere());
  >   free(allocated);
  >   return 0;
  > }
  > EOF
  $ cat > other.tc <<'EOF'
  > int some_elsewhere(void) {
  >   option(int) o = Some(5);
  >   match (o) {
  >   case Some(v): return v;
  >   case None: return 0;
  >   }
  > }
  > EOF
  $ cat > hand.c <<'EOF'
  > struct option__i {
  >   enum option__i_tag { option__i_None, option__i_Some } tag;
  >   union { struct { int value; } Some; } u;
  > };
  > int value_by_hand(const struct option__i *o);
  > int value_by_hand(const struct option__i *o) {
  >   return o->tag == option__i_Some ? o->u.Some.value : -1;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -c -o program.o program.tc &&
  >     typec --cc=$cc $flags -c -o other.o other.tc &&
  >     $cc $flags -c -o hand.o hand.c &&
  >     $cc -o program program.o other.o hand.o && ./program
  > done
  1 1 1 3 5
  1 1 1 3 5

A result whose value type is void has no value field: Ok is written
bare, as a constructor and as a pattern.

  $ cat > void.tc <<'EOF'
  > #include <stdio.h>
  > typedef int error_code;
  > static result(void, error_code) check(int x) {
  >   if (x < 0) return Err(x);
  >   return Ok;
  > }
  > int main(void) {
  >   match (check(2)) {
  >   case Ok: printf("ok\n"); break;
  >   case Err(e): printf("error %d\n", e); break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o void void.tc && ./void
  > done
  ok
  ok
