SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The parser reads what Clang and GCC write for -E of a C11 file and of a
file that uses the GNU profile (design 13.3). headers.t parses the
system headers.

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
  > static inline int pick(int a, int b) { return a ?: b; }
  > EOF
  $ printf '#include <barrier.h>\nint main(void) { return pick(0, 1); }\n' > h.c
  $ "$clang" -std=gnu11 -E -isystem include h.c > h-clang.i
  $ ./parse_check.exe h-clang.i
  function pick
  function main
  $ "$gcc" -std=gnu11 -E -isystem include h.c > h-gcc.i
  $ ./parse_check.exe h-gcc.i
  function pick
  function main

The GNU profile: attributes, __extension__, alternate keywords, asm
labels, assembler statements and file-scope assembler, typeof, statement
expressions, case ranges, range designators, the GNU forms of empty
structures, initialisers and declarations, _Float16, the va_arg and
offsetof builtins, label addresses and computed goto in a dispatch table
as an interpreter writes it, local labels and the conditional without a
middle operand. Both backends compile the file without a warning.

  $ cat > gnu.c <<'EOF'
  > __extension__ typedef long long wide;
  > typedef __builtin_va_list arguments;
  > struct __attribute__((packed)) packed { char c; int i; }
  >   __attribute__((aligned(4)));
  > struct empty {};
  > union __attribute__((transparent_union)) either { int *i; long *l; };
  > enum __attribute__((unused)) level {
  >   LOW __attribute__((deprecated)) = 1, HIGH
  > };
  > struct aligned {
  >   __extension__ int a __attribute__((aligned(8)));
  >   unsigned b : 3 __attribute__((packed));
  > };
  > extern int renamed(void) __asm__("_renamed_symbol") __attribute__((cold));
  > __attribute__((noreturn)) void stop(void);
  > int printf_like(const char *, ...)
  >   __attribute__((__format__(__printf__, 1, 2)));
  > __const int constant = 1;
  > static __inline__ int twice(int x) { return 2 * x; }
  > __typeof__(constant) copy;
  > typeof(int *) pointer;
  > _Float16 half;
  > int alignment = __alignof__(long);
  > int empty_list[1] = {};
  > int ranges[8] = { [0 ... 3] = 1, [4 ... 7] = 2 };
  > int offset = __builtin_offsetof(struct aligned, a);
  > __asm__(".globl typec_marker\ntypec_marker:");
  > ;
  > static int sum(int count, ...) {
  >   arguments list;
  >   __builtin_va_start(list, count);
  >   int total = 0;
  >   for (int i = 0; i < count; i++) total += __builtin_va_arg(list, int);
  >   __builtin_va_end(list);
  >   return total;
  > }
  > static int statements(int n) {
  >   int out = 0;
  >   int value = ({ int t = twice(n); t + 1; });
  >   __asm__ __volatile__("" ::: "memory");
  >   __asm__ ("" : "=r"(out) : "0"(value) : "cc");
  >   __asm__ goto ("" :::: done);
  >   switch (n) {
  >   case 0 ... 9: out += 1; __attribute__((fallthrough));
  >   default: out += 2;
  >   }
  > done:
  >   return out + sum(2, 1, 2) + __extension__ 0;
  > }
  > static const unsigned char program[] = { 0, 0, 1 };
  > static int run(const unsigned char *code) {
  >   __label__ step, stop;
  >   static void *const table[] = { &&step, &&stop };
  >   int total = 0;
  >   goto *table[*code];
  > step:
  >   total += 1;
  >   goto *table[*++code];
  > stop:
  >   return ({ __label__ out; goto out; out: total; }) ?: -1;
  > }
  > int main(void) {
  >   return statements(3) + offset + ranges[0] + run(program);
  > }
  > EOF
  $ "$clang" -std=gnu11 -fsyntax-only gnu.c
  $ "$gcc" -std=gnu11 -fsyntax-only gnu.c
  $ "$clang" -std=gnu11 -E gnu.c > gnu-clang.i
  $ ./parse_check.exe gnu-clang.i > gnu-clang.out
  $ "$gcc" -std=gnu11 -E gnu.c > gnu-gcc.i
  $ ./parse_check.exe gnu-gcc.i > gnu-gcc.out
  $ cmp gnu-clang.out gnu-gcc.out
  $ cat gnu-clang.out
  declaration wide
  declaration arguments
  declaration of a tag
  declaration of a tag
  declaration of a tag
  declaration of a tag
  declaration of a tag
  declaration renamed
  declaration stop
  declaration printf_like
  declaration constant
  function twice
  declaration copy
  declaration pointer
  declaration half
  declaration alignment
  declaration empty_list
  declaration ranges
  declaration offset
  assembler
  empty declaration
  function sum
  function statements
  declaration program
  function run
  function main

The macOS SDK's Clang extensions: block pointers, nullability
qualifiers, a fixed underlying type of an enumeration and a parameter
list of `...` alone. GCC accepts none of them.

  $ cat > clang.c <<'EOF'
  > int (^ _Nonnull callback)(int);
  > void with_block(void (^ _Nullable block)(void) __attribute__((noescape)));
  > int * _Nullable maybe;
  > char * _Nonnull const sure = "";
  > typedef enum : unsigned char { SMALL } small;
  > __attribute__((overloadable)) int promote(...);
  > EOF
  $ "$clang" -std=gnu11 -fsyntax-only clang.c
  $ "$clang" -std=gnu11 -E clang.c > clang-only.i
  $ ./parse_check.exe clang-only.i
  declaration callback
  declaration with_block
  declaration maybe
  declaration sure
  declaration small
  declaration promote

A parse error is reported at its presumed location. A block literal is
an extension outside the profile.

  $ printf '# 1 "t.c"\nint x;\nvoid *y = ^{ };\n' > bad.i
  $ ./parse_check.exe bad.i
  parse_check: t.c:2: expected an expression, found `^`
  [1]
