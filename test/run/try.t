SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type-C code propagates errors with try on each backend (design 5.1):
in each of its three positions, a statement try e; that discards an
Ok value among them, as the substatement of an if and under
a label, with a void T and a void E, and with a T that is a result of
its own. An Ok gives its value where the try stands; an Err returns it
from the function, and what follows the try does not run. A value whose
tag is neither Ok nor Err, here written by C code, traps and does not
take the error path (10.5): the program stops on a signal. It flushes
its output first.

  $ . ./backends.sh

  $ cat > corrupt.h <<'EOF'
  > #include <string.h>
  > static void corrupt(result_int *r) { memset(&r->tag, 0x7f, sizeof r->tag); }
  > EOF
  $ cat > tries.tc <<'EOF'
  > #include <stdio.h>
  > typedef result(int, int) result_int;
  > #include "corrupt.h"
  > static int steps;
  > static result_int half(int n) {
  >   if (n % 2)
  >     return Err(n);
  >   return Ok(n / 2);
  > }
  > static result(void, int) step(int n) {
  >   steps++;
  >   if (n < 0)
  >     return Err(n);
  >   return Ok;
  > }
  > static result_int quarter(int n) {
  >   int h = try half(n);
  >   int q;
  >   q = try half(h);
  >   return Ok(q);
  > }
  > static result_int even(int n) {
  >   try half(n);
  >   return Ok(n);
  > }
  > static result_int checked(int n, int c) {
  >   try step(n);
  >   if (c)
  >     n = try half(n);
  >   else
  >   again: try step(n - 100);
  >   if (c > 1) {
  >     c = 0;
  >     goto again;
  >   }
  >   return Ok(n);
  > }
  > static result(int, void) positive(int n) {
  >   if (n > 0)
  >     return Ok(n);
  >   return Err;
  > }
  > static result(long, void) doubled(int n) {
  >   long d = try positive(n);
  >   return Ok(2 * d);
  > }
  > static result(result_int, int) outer(int n) {
  >   if (n < 0)
  >     return Err(n);
  >   return Ok(half(n));
  > }
  > static result(char, int) layered(int n) {
  >   result_int inner = try outer(n);
  >   match (inner) {
  >   case Ok(v):
  >     return Ok('0' + v);
  >   case Err(e):
  >     return Ok('a' + e);
  >   }
  > }
  > static result_int corrupted(void) {
  >   result_int r = Ok(1);
  >   corrupt(&r);
  >   int v = try r;
  >   return Ok(v + 1);
  > }
  > static void show_int(result_int r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("Ok(%d) ", v);
  >     break;
  >   case Err(e):
  >     printf("Err(%d) ", e);
  >     break;
  >   }
  > }
  > static void show_long(result(long, void) r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("Ok(%ld) ", v);
  >     break;
  >   case Err:
  >     printf("Err ");
  >     break;
  >   }
  > }
  > static void show_char(result(char, int) r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("Ok(%c) ", v);
  >     break;
  >   case Err(e):
  >     printf("Err(%d) ", e);
  >     break;
  >   }
  > }
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   show_int(quarter(8)); show_int(quarter(6)); show_int(quarter(5));
  >   printf("\n");
  >   show_int(checked(4, 1)); show_int(checked(3, 1));
  >   show_int(checked(-1, 1)); show_int(checked(200, 0));
  >   show_int(checked(50, 0)); printf("%d\n", steps);
  >   show_long(doubled(3)); show_long(doubled(0));
  >   show_char(layered(4)); show_char(layered(3)); show_char(layered(-2));
  >   show_int(even(4)); show_int(even(3));
  >   printf("\n");
  >   if (argc > 1) {
  >     fflush(stdout);
  >     show_int(corrupted());
  >   }
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Wextra -Werror -o clang-tries tries.tc
  $ ./clang-tries
  Ok(2) Err(3) Err(5) 
  Ok(2) Err(3) Err(-1) Ok(200) Err(-50) 7
  Ok(6) Err Ok(2) Ok(d) Err(-2) Ok(4) Err(3) 
  $ sh -c './clang-tries trap; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  Ok(2) Err(3) Err(5) 
  Ok(2) Err(3) Err(-1) Ok(200) Err(-50) 7
  Ok(6) Err Ok(2) Ok(d) Err(-2) Ok(4) Err(3) 
  trapped
  $ typec --cc=$gcc -Wall -Wextra -Werror -o gcc-tries tries.tc
  $ ./gcc-tries
  Ok(2) Err(3) Err(5) 
  Ok(2) Err(3) Err(-1) Ok(200) Err(-50) 7
  Ok(6) Err Ok(2) Ok(d) Err(-2) Ok(4) Err(3) 
  $ sh -c './gcc-tries trap; exit $?' 2>/dev/null; test $? -gt 128 && echo trapped
  Ok(2) Err(3) Err(5) 
  Ok(2) Err(3) Err(-1) Ok(200) Err(-50) 7
  Ok(6) Err Ok(2) Ok(d) Err(-2) Ok(4) Err(3) 
  trapped
