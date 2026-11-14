SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The parser reads what Clang and GCC write for -E of a C11 file without
system headers, which need the GNU profile.

  $ clang=/usr/bin/clang
  $ gcc=/usr/local/bin/gcc-16

  $ cat > t.c <<'EOF'
  > typedef unsigned long size_type;
  > typedef struct node node, *node_pointer;
  > struct node {
  >   node_pointer next;
  >   unsigned flags : 3, : 0;
  >   union { int as_int; float as_float; };
  >   _Alignas(8) char tag[SIZE];
  > };
  > enum colour { RED, GREEN = RED + 2, BLUE, };
  > _Static_assert(sizeof(node) >= sizeof(void *), "node " "fits");
  > static const int primes[] = { [0] = 2, [1] = 3, 5, 7, };
  > struct point { int x, y; } origin = { .y = 1, .x = 0 };
  > extern _Thread_local int counter;
  > _Atomic(int) shared;
  > int (*handlers[4])(int, char **);
  > void (*signal_like(int, void (*)(int)))(int);
  > void with_arrays(int n, int a[static SIZE], int b[const n], int c[*]);
  > #define TYPE_NAME(x) _Generic((x), int: "int", default: "other")
  > const char *kind = TYPE_NAME(1);
  > int sum = 1 + _Pragma("unknown_to_both") 2 * 3;
  > struct point *corner = &(struct point){ 4, 5 };
  > size_type length = sizeof(struct point) + _Alignof(double);
  > _Noreturn void stop(void);
  > static inline int NAME(node_pointer list, size_type n) {
  >   int total = 0;
  >   for (size_type i = 0; i < n && list; i++, list = list->next) {
  >     total += list->flags ? (int)list->tag[0] : -1;
  >   }
  >   return total;
  > }
  > int shadow(int size_type) { return size_type * 2; }
  > static int statements(int n, enum colour level) {
  >   typedef int count;
  >   count total = 0;
  >   { typedef char count; count c = 'a'; total += c; }
  >   for (count i = 0; i < n; i++) {
  >     if (i % 2) continue; else if (i > 10) break;
  >     switch (i) { case 0: case RED ? 1 : 2: total++; break; default: ; }
  >   }
  >   while (total > 100) total /= 2;
  >   do total--; while (total > 50);
  >   if (level == BLUE) goto done;
  >   ;
  >   _Static_assert(sizeof(count) == sizeof(int), "count");
  > done:
  >   return total;
  > }
  > int old_style(a, b) int a; char *b; { return a + (b != 0) + shadow(a); }
  > int main(void) {
  >   return NAME(0, 0) + colour_unused + statements(3, RED) + old_style(1, 0);
  > }
  > EOF

The file is C11: both backends compile it with ISO C pedantic errors.
Clang warns that the old-style definition is obsolescent.

  $ "$clang" -std=c11 -pedantic-errors -DSIZE=4 -DNAME=count \
  >   -Dcolour_unused=RED -fsyntax-only -Wno-unknown-pragmas \
  >   -Wno-deprecated-non-prototype t.c
  $ "$gcc" -std=c11 -pedantic-errors -DSIZE=4 -DNAME=count \
  >   -Dcolour_unused=RED -fsyntax-only -Wno-unknown-pragmas t.c

parse_check fails unless the spans nest in order and every token outside
the external declarations is a pragma. The pragma that _Pragma writes
stands in the middle of the initialiser of sum.

  $ "$clang" -std=c11 -E -x c -DSIZE=4 -DNAME=count -Dcolour_unused=RED \
  >   t.c > clang.i
  $ grep -c '^#pragma' clang.i
  1
  $ ./parse_check.exe clang.i
  declaration size_type
  declaration node node_pointer
  declaration of a tag
  declaration of a tag
  static assertion
  declaration primes
  declaration origin
  declaration counter
  declaration shared
  declaration handlers
  declaration signal_like
  declaration with_arrays
  declaration kind
  declaration sum
  declaration corner
  declaration length
  declaration stop
  function count
  function shadow
  function statements
  function old_style
  function main

  $ "$gcc" -std=c11 -E -x c -DSIZE=4 -DNAME=count -Dcolour_unused=RED \
  >   t.c > gcc.i
  $ grep -c '^#pragma' gcc.i
  1
  $ ./parse_check.exe gcc.i
  declaration size_type
  declaration node node_pointer
  declaration of a tag
  declaration of a tag
  static assertion
  declaration primes
  declaration origin
  declaration counter
  declaration shared
  declaration handlers
  declaration signal_like
  declaration with_arrays
  declaration kind
  declaration sum
  declaration corner
  declaration length
  declaration stop
  function count
  function shadow
  function statements
  function old_style
  function main

The body of a function that a system header defines is not parsed: it
is written for its own compiler and may use its extensions.

  $ mkdir include
  $ cat > include/barrier.h <<'EOF'
  > static inline void barrier(void) { __asm__ volatile ("" ::: "memory"); }
  > EOF
  $ printf '#include <barrier.h>\nint main(void) { barrier(); }\n' > h.c
  $ "$clang" -std=c11 -E -isystem include h.c > h-clang.i
  $ ./parse_check.exe h-clang.i
  function barrier
  function main
  $ "$gcc" -std=c11 -E -isystem include h.c > h-gcc.i
  $ ./parse_check.exe h-gcc.i
  function barrier
  function main

A parse error is reported at its presumed location.

  $ printf '# 1 "t.c"\nint x;\nint f(void) __attribute__((noreturn));\n' > bad.i
  $ ./parse_check.exe bad.i
  parse_check: t.c:2: expected `;` after a declaration, found `__attribute__`
  [1]
