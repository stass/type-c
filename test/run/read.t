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
  read_check: t.c:2: error: unexpected character '@'
  [1]

Both backends write a '#' or '%:' that a macro expands to after a blank,
and Clang reads the line that it begins as a directive. Preprocessed C
holds no such punctuator outside a directive, so typec refuses it rather
than let the backend apply a line marker or a pragma that typec has not
read: here, inside the arguments of an attribute, which typec keeps as
tokens, a marker that would make Clang read the rest of the file as a
system header and so drop the warning about 'unused'.

  $ cat > hash.tc <<'EOF'
  > #define H #
  > int x __attribute__((aligned(4
  > H 7 "other.h" 1 3
  > )));
  > static int unused(void) { return 0; }
  > EOF
  $ cat > digraph.tc <<'EOF'
  > #define D %:
  > int x __attribute__((aligned(4
  > D pragma GCC system_header
  > )));
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc -Wall -Werror -c hash.tc -o hash.o
  >   typec --cc=$cc -c digraph.tc -o digraph.o
  > done
  hash.tc:3: error: stray '#' outside a directive, as when a macro expands to it
  digraph.tc:3: error: stray '%:' outside a directive, as when a macro expands to it
  hash.tc:3: error: stray '#' outside a directive, as when a macro expands to it
  digraph.tc:3: error: stray '%:' outside a directive, as when a macro expands to it
  [80]
