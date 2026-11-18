SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A defer statement runs its statement at each exit of its scope, the
latest first (design 6, 13.5), on each backend with -Wall -Wextra
-Werror, under AddressSanitizer and UndefinedBehaviorSanitizer where the
backend links them (backends.sh). Each function appends to a log, so a
line shows the exact order: the end of a block, break and continue out
of a loop and a switch, return with and without a value (the value is
computed before the cleanups, and they see the state at the exit), a
goto out of nested scopes past a block that cannot complete, whose trap
is not taken, the error path of a try, a match arm, and `_Defer` in C
text that the Type-C file includes. The resource example counts what it
allocates and opens, and every path out of it gives each back.

  $ . ./backends.sh
  $ flags="-std=gnu11 -Wall -Wextra -Werror -g"
  $ cat > cleanup.h <<'EOF'
  > static void header_cleanup(void (*note)(const char *)) {
  >   _Defer note("h");
  >   note("H");
  > }
  > EOF
  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > #include <string.h>
  > static char log_text[64];
  > static void note(const char *text) {
  >   strncat(log_text, text, sizeof log_text - strlen(log_text) - 1);
  > }
  > static void show(const char *name) {
  >   printf("%s: %s\n", name, log_text);
  >   log_text[0] = '\0';
  > }
  > #include "cleanup.h"
  > static void block_end(void) {
  >   note("a");
  >   {
  >     defer note("1");
  >     defer note("2");
  >     note("b");
  >   }
  >   note("c");
  > }
  > static void loops(void) {
  >   for (int i = 0; i < 3; i++) {
  >     defer note(")");
  >     note("(");
  >     if (i == 0)
  >       continue;
  >     if (i == 1)
  >       break;
  >   }
  >   int k = 0;
  >   while (k < 5) {
  >     k++;
  >     defer note("w");
  >     switch (k) {
  >     case 1: {
  >       defer note("s");
  >       note("1");
  >       break;
  >     }
  >     case 2:
  >       continue;
  >     default:
  >       goto done;
  >     }
  >     note("+");
  >   }
  > done:
  >   note(".");
  > }
  > static int counter;
  > static int returned_value(void) {
  >   counter = 1;
  >   defer counter = 10;
  >   return counter + 1;
  > }
  > static void returned_void(int *p) {
  >   defer *p += 1;
  >   *p = 5;
  >   if (*p)
  >     return;
  >   *p = 100;
  > }
  > static int state_at_exit(void) {
  >   int x = 1;
  >   defer note(x == 3 ? "3" : "?");
  >   x = 3;
  >   return x;
  > }
  > static void nested_goto(int c) {
  >   {
  >     defer note("o");
  >     {
  >       defer note("i");
  >       for (;;) {
  >         defer note("l");
  >         if (c)
  >           goto out;
  >       }
  >     }
  >   }
  > out:
  >   note("!");
  > }
  > static result(int, int) parse(int v) {
  >   if (v < 0)
  >     return Err(-v);
  >   return Ok(v);
  > }
  > static result(int, int) with_try(int v) {
  >   defer note("x");
  >   {
  >     defer note("y");
  >     int got = try parse(v);
  >     note("g");
  >     return Ok(got);
  >   }
  > }
  > static int value(result(int, int) r) {
  >   match (r) {
  >   case Ok(v):
  >     defer note("k");
  >     note("v");
  >     return v;
  >   case Err(e):
  >     defer note("e");
  >     note("r");
  >     return -e;
  >   }
  > }
  > static int live_blocks, open_files;
  > static void *counted_alloc(size_t size) {
  >   void *p = malloc(size);
  >   if (p)
  >     live_blocks++;
  >   return p;
  > }
  > static void counted_free(void *p) {
  >   live_blocks--;
  >   free(p);
  > }
  > static void counted_close(FILE *f) {
  >   open_files--;
  >   fclose(f);
  > }
  > static int resource(int fail_at) {
  >   char *buffer = counted_alloc(64);
  >   if (!buffer)
  >     return -1;
  >   defer counted_free(buffer);
  >   FILE *f = fopen("resource.txt", "w+");
  >   if (!f)
  >     return -2;
  >   open_files++;
  >   defer counted_close(f);
  >   for (int i = 0; i < 3; i++) {
  >     char *line = counted_alloc(16);
  >     if (!line)
  >       return -3;
  >     defer counted_free(line);
  >     snprintf(line, 16, "%d\n", i);
  >     if (i == fail_at)
  >       return 100 + i;
  >     fputs(line, f);
  >   }
  >   rewind(f);
  >   size_t read = fread(buffer, 1, 63, f);
  >   buffer[read] = '\0';
  >   return (int)strlen(buffer);
  > }
  > int main(void) {
  >   block_end();
  >   show("block");
  >   loops();
  >   show("loops");
  >   int r = returned_value();
  >   int v = 0;
  >   returned_void(&v);
  >   int s = state_at_exit();
  >   printf("return: %d %d %d %d\n", r, counter, v, s);
  >   show("state");
  >   nested_goto(1);
  >   show("goto");
  >   int ok = value(with_try(7));
  >   show("try ok");
  >   int err = value(with_try(-3));
  >   show("try err");
  >   printf("values: %d %d\n", ok, err);
  >   header_cleanup(note);
  >   show("header");
  >   int whole = resource(-1);
  >   printf("resource: %d live %d open %d\n", whole, live_blocks, open_files);
  >   int failed = resource(1);
  >   printf("resource: %d live %d open %d\n", failed, live_blocks, open_files);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   sanitize=$(sanitizer_flags $cc)
  >   typec --cc=$cc $flags $sanitize -o program program.tc && ./program
  > done
  block: ab21c
  loops: ()()1s+www.
  return: 2 10 6 3
  state: 3
  goto: lio!
  try ok: gyxvk
  try err: yxre
  values: 7 -3
  header: Hh
  resource: 6 live 0 open 0
  resource: 101 live 0 open 0
  block: ab21c
  loops: ()()1s+www.
  return: 2 10 6 3
  state: 3
  goto: lio!
  try ok: gyxvk
  try err: yxre
  values: 7 -3
  header: Hh
  resource: 6 live 0 open 0
  resource: 101 live 0 open 0

A jump that stands before a defer statement in its block runs no copy
of it, and a defer statement that a path does not reach has no copy on
that path: one in the body of an `if` or of a loop that may not run. The
log shows the cleanups that did run.

  $ cat > reached.tc <<'EOF'
  > #include <stdio.h>
  > #include <string.h>
  > static char log_text[64];
  > static void note(const char *text) {
  >   strncat(log_text, text, sizeof log_text - strlen(log_text) - 1);
  > }
  > static void show(const char *name) {
  >   printf("%s: %s\n", name, log_text);
  >   log_text[0] = '\0';
  > }
  > static int return_before(int c) {
  >   defer note("o");
  >   if (c)
  >     return 1;
  >   defer note("i");
  >   return 2;
  > }
  > static void break_before(void) {
  >   for (int i = 0; i < 3; i++) {
  >     defer note("o");
  >     if (i == 1)
  >       break;
  >     defer note("d");
  >     note("b");
  >   }
  >   note(".");
  > }
  > static void continue_before(void) {
  >   for (int i = 0; i < 3; i++) {
  >     defer note("o");
  >     if (i == 1)
  >       continue;
  >     defer note("d");
  >     note("b");
  >   }
  >   note(".");
  > }
  > static void goto_before(int c) {
  >   {
  >     defer note("o");
  >     if (c)
  >       goto out;
  >     defer note("d");
  >     note("b");
  >   }
  > out:
  >   note(".");
  > }
  > static int in_if(int c) {
  >   if (c) {
  >     defer note("d");
  >     if (c > 1)
  >       return 2;
  >     note("b");
  >   }
  >   note(".");
  >   return 0;
  > }
  > static void in_loop(int n) {
  >   for (int i = 0; i < n; i++) {
  >     defer note("d");
  >     note("b");
  >   }
  >   note(".");
  > }
  > int main(void) {
  >   return_before(1);
  >   show("return taken");
  >   return_before(0);
  >   show("return passed");
  >   break_before();
  >   show("break");
  >   continue_before();
  >   show("continue");
  >   goto_before(1);
  >   show("goto taken");
  >   goto_before(0);
  >   show("goto passed");
  >   in_if(0);
  >   show("if skipped");
  >   in_if(1);
  >   show("if entered");
  >   in_if(2);
  >   show("if returned");
  >   in_loop(0);
  >   show("loop skipped");
  >   in_loop(2);
  >   show("loop entered");
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   sanitize=$(sanitizer_flags $cc)
  >   typec --cc=$cc $flags $sanitize -o reached reached.tc && ./reached
  > done
  return taken: o
  return passed: io
  break: bdoo.
  continue: bdoobdo.
  goto taken: o.
  goto passed: bdo.
  if skipped: .
  if entered: bd.
  if returned: d
  loop skipped: .
  loop entered: bdbd.
  return taken: o
  return passed: io
  break: bdoo.
  continue: bdoobdo.
  goto taken: o.
  goto passed: bdo.
  if skipped: .
  if entered: bd.
  if returned: d
  loop skipped: .
  loop entered: bdbd.

A pragma that applies to the loop after it is copied with the deferred
statement to each exit, and both backends compile each copy.

  $ cat > unroll.tc <<'EOF'
  > #include <stdio.h>
  > static int total;
  > static int sum(int n) {
  >   defer {
  > #pragma GCC unroll 4
  >     for (int i = 0; i < n; i++)
  >       total += i;
  >   }
  >   if (n > 5)
  >     return 1;
  >   return 0;
  > }
  > int main(void) {
  >   sum(4);
  >   sum(8);
  >   printf("total: %d\n", total);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   sanitize=$(sanitizer_flags $cc)
  >   typec --cc=$cc $flags $sanitize -o unroll unroll.tc && ./unroll
  > done
  total: 34
  total: 34

A pragma that sets state for the text after it is refused: a copy of
`pack(push, 1)` at each of two exits would push twice, and the one
`pack(pop)` after the function would leave `struct s` packed.

  $ cat > pack.tc <<'EOF'
  > #include <stdio.h>
  > static void f(int c) {
  >   defer {
  > #pragma pack(push, 1)
  >     ;
  >   }
  >   if (c)
  >     return;
  > }
  > #pragma pack(pop)
  > struct s { char c; int i; };
  > int main(void) {
  >   f(0);
  >   printf("size: %zu\n", sizeof(struct s));
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o pack pack.tc
  > done
  pack.tc:4: error: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them [deferred-pragma]
      4 | #pragma pack(push, 1)
  pack.tc:4: error: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them [deferred-pragma]
      4 | #pragma pack(push, 1)
  [80]

A return in the operand of `slice_from_array` runs the copy of the
deferred statement in each text of the operand: in place, where it
gives the data, and in the length, which writes the operand again
under `sizeof`, where C does not evaluate it. Each copy is made once
every edit of the function is, so the length's holds the copy that the
return runs, as the data's does: one copy at each of two exits, and
one more in the length.

  $ cat > length.tc <<'EOF'
  > #include <stdio.h>
  > static int m[2][3];
  > static int length(int c) {
  >   defer puts("left");
  >   slice(int) s = slice_from_array(m[({ if (c) return -1; 0; })]);
  >   return (int)s.len;
  > }
  > int main(void) {
  >   printf("%d\n", length(0));
  >   printf("%d\n", length(1));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang --emit-c -o length.i length.tc
  $ grep -c 'puts ( "left" )' length.i
  3
  $ for cc in $clang $gcc; do
  >   sanitize=$(sanitizer_flags $cc)
  >   typec --cc=$cc $flags $sanitize -o length length.tc && ./length
  > done
  left
  3
  left
  -1
  left
  3
  left
  -1

A defer statement in a block of the operand is lowered in the length
as in the data: the length writes no `defer`, which the backend would
refuse, and the copy of the deferred statement runs once, at the end
of the block in the data, which C evaluates.

  $ cat > inner.tc <<'EOF'
  > #include <stdio.h>
  > static int m[2][3];
  > static int length(int c) {
  >   slice(int) s = slice_from_array(m[({ { defer puts("in"); } c; })]);
  >   return (int)s.len;
  > }
  > int main(void) {
  >   printf("%d\n", length(1));
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang --emit-c -o inner.i inner.tc
  $ grep -c 'defer' inner.i
  0
  [1]
  $ for cc in $clang $gcc; do
  >   sanitize=$(sanitizer_flags $cc)
  >   typec --cc=$cc $flags $sanitize -o inner inner.tc && ./inner
  > done
  in
  3
  in
  3

A name that a deferred statement declares hides at each copy only what
it hides at the defer statement (design 6 rule 8), so a different name
after the defer, the same name in a block that holds no exit, and the
same name declared by a declaration that holds a try, whose error path
copies the statement in front of it, compile under -Wshadow on each
backend.

  $ cat > apart.tc <<'EOF'
  > #include <stdio.h>
  > static int total;
  > static void note(int n) { total += n; }
  > static int apart(int c) {
  >   defer {
  >     int y = 100;
  >     note(y);
  >   }
  >   int z = 2;
  >   {
  >     int y = c;
  >     note(y);
  >   }
  >   return z;
  > }
  > static result(int, int) get(int c) {
  >   if (c < 0)
  >     return Err(c);
  >   return Ok(c);
  > }
  > static result(int, int) held(int c) {
  >   defer {
  >     int y = 1000;
  >     note(y);
  >   }
  >   {
  >     int y = try get(c);
  >     note(y);
  >   }
  >   return Ok(0);
  > }
  > int main(void) {
  >   int z = apart(3);
  >   printf("%d %d\n", z, total);
  >   (void)held(4);
  >   (void)held(-1);
  >   printf("%d\n", total);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -Wshadow -o apart apart.tc && ./apart
  > done
  2 103
  2107
  2 103
  2107
