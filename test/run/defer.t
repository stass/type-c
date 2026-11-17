SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A defer statement runs its statement at each exit of its scope, the
latest first (design 6, 13.5), on each backend with -Wall -Wextra
-Werror, under AddressSanitizer and UndefinedBehaviorSanitizer. Each
function appends to a log, so a line shows the exact order: the end of
a block, break and continue out of a loop and a switch, return with and
without a value (the value is computed before the cleanups, and they
see the state at the exit), a goto out of nested scopes past a block
that cannot complete, whose trap is not taken, the error path of a try,
a match arm, and `_Defer` in C text that the Type-C file includes.
The resource example counts what it allocates and opens, and every path
out of it gives each back.

  $ . ./backends.sh
  $ flags="-std=gnu11 -Wall -Wextra -Werror -g"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
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
  typec: pack.tc:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  typec: pack.tc:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  [80]
