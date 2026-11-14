SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A Type-C program with type declarations builds through typec with each
backend and runs. The aliases are the types they name, so the C that
the program calls sees its own types; the structure refers to itself
through the declared name, and a block declares an alias of its own.

  $ . ./backends.sh

  $ cat > list.tc <<'EOF'
  > #include <stdio.h>
  > type count = unsigned long;
  > type visit = void (*)(count);
  > type node;
  > type list = struct {
  >   count value;
  >   list *next;
  > };
  > static void print(count n) { printf("%lu\n", n); }
  > static count sum(const list *l, visit each) {
  >   type total = count;
  >   total t = 0;
  >   for (; l; l = l->next) {
  >     each(l->value);
  >     t += l->value;
  >   }
  >   return t;
  > }
  > int main(void) {
  >   node *opaque = 0;
  >   list c = { 3, 0 }, b = { 2, &c }, a = { 1, &b };
  >   print(sum(&a, print));
  >   return opaque != 0;
  > }
  > EOF
  $ typec --cc=$clang -Wall -Werror -o clang-list list.tc && ./clang-list
  1
  2
  3
  6
  $ typec --cc=$gcc -Wall -Werror -o gcc-list list.tc && ./gcc-list
  1
  2
  3
  6

--emit-c shows the typedef that an alias becomes, at its own line.

  $ printf 'type count = unsigned long;\ncount n;\n' > emit.tc
  $ typec --cc=$clang --emit-c -o - emit.tc | grep -v '^# ' | grep .
  typedef
   unsigned long
  count
  ;
  count n;
