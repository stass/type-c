SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The reader takes what Clang and GCC write for -E, system headers
included.

  $ . ./backends.sh

  $ cat > t.c <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > #include <string.h>
  > static const char greeting[] = "hello";
  > #line 100 "renamed.c"
  > int main(void) {
  >   char *copy = malloc(sizeof greeting);
  >   strcpy(copy, greeting);
  >   puts(copy);
  >   free(copy);
  >   return 0;
  > }
  > #pragma typec checked
  > EOF

read_check fails unless the tokens and the gaps between them spell the
file exactly and the gaps hold only white space and line markers. Then it
prints the owners of the tokens presumed to come from each named file:
#line renames the main file without changing the owner of its tokens, and
the tokens of stdio.h belong to a system header.

  $ "$clang" -E -x c t.c > clang.i
  $ ./read_check.exe clang.i t.c renamed.c stdio.h
  t.c: t.c
  renamed.c: t.c
  stdio.h: stdio.h (system header)
  #pragma typec lines: 1

  $ "$gcc" -E -x c t.c > gcc.i
  $ ./read_check.exe gcc.i t.c renamed.c stdio.h
  t.c: t.c
  renamed.c: t.c
  stdio.h: stdio.h (system header)
  #pragma typec lines: 1

Output that is not cc -E output is refused with its presumed location.

  $ printf '# 1 "t.c"\nint x;\nint @;\n' > bad.i
  $ ./read_check.exe bad.i
  read_check: t.c:2: unexpected character '@'
  [1]
