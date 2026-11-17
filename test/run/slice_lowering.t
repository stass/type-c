SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The lowered forms of a slice (design 8, 13.5, "The check of a slice"),
each with a partner that fails where the form or the rule is missing,
on each backend at -O0 and at -O2. A partner fails in one of four ways:
the program traps (design 10.5: the process ends by SIGILL or SIGTRAP,
whichever the target's trap instruction raises), typec refuses the
source, a backend refuses the lowered text, or a backend reports a
named warning. A partner that a backend refuses is the text that
`typec --emit-c` writes, changed by one `sed` where the design says
what the text would be without the form.

  $ . ./backends.sh
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Wshadow -Wconversion"
  $ flags="$flags -Wsign-conversion -Werror"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $ traps() {
  >   sh -c "ulimit -c 0; $*; exit \$?" 2>/dev/null
  >   case $? in
  >   132 | 133) echo "trapped" ;;
  >   *) echo "did not trap" ;;
  >   esac
  > }
  $ refusal() {
  >   sed -n 's/.* error: .*\[\([a-z-]*\)\]$/refused [\1]/p'
  > }
  $ errors() {
  >   sed -n 's/^[^:]*:\([0-9]*\):[0-9]*: error: /line \1: /p'
  > }

A compound literal in an operand of an index or of a `slice_sub`
belongs to the block around the use, so the elements that the
expression reaches are alive after it: through a pointer that the
index yields, through the slice that a `slice_sub` yields, and through
a pointer that an index operand stores. GCC's AddressSanitizer reports
a read of a literal that had died. The partner indexes one past the
literal and traps.

  $ cat > literal.tc <<'EOF'
  > #include <stdio.h>
  > static int numbers[3] = { 1, 2, 3 };
  > static slice(int) all = slice_from_array(numbers);
  > static void read_after(int k) {
  >   int *element = &slice_from_array((int[]){ k, k + 1, k + 2 })[1];
  >   slice(int) tail =
  >       slice_sub(slice_from_array((int[]){ k, k + 1, k + 2 }), 1, 3);
  >   int *stored;
  >   int first = all[(stored = (int[]){ 42 }, 0)];
  >   printf("literal: %d %d %d %d %d\n", *element, tail[0], tail[1],
  >          *stored, first);
  > }
  > static void past(size_t n) {
  >   printf("%d\n", slice_from_array((int[]){ 1, 2, 3 })[n]);
  > }
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   if (argc > 1)
  >     past(3);
  >   else
  >     read_after(5);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level $sanitize -o literal literal.tc &&
  >     ./literal && traps ./literal past
  >   done
  > done
  literal: 6 6 7 42 1
  trapped
  literal: 6 6 7 42 1
  trapped
  literal: 6 6 7 42 1
  trapped
  literal: 6 6 7 42 1
  trapped

An index and a `slice_sub` in the operand of `sizeof` are not
evaluated, so they need no function and size arrays of file scope
without a diagnostic. The partner is an index out of range in a
`sizeof` whose operand is a variable length array, which C evaluates:
it has the test, and traps.

  $ cat > file_sizes.tc <<'EOF'
  > #include <stdio.h>
  > int numbers[3] = { 1, 2, 3 };
  > slice(int) s = slice_from_array(numbers);
  > char by_index[sizeof(s[0])];
  > char by_sub[sizeof(slice_sub(s, 0, 1))];
  > static size_t vla_size(size_t n) {
  >   void *p = numbers;
  >   return sizeof(*(int (*)[s[n]])p);
  > }
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   if (argc > 1)
  >     printf("%zu\n", vla_size(3));
  >   else
  >     printf("sizes: %zu %zu %zu\n", sizeof by_index, sizeof by_sub,
  >            vla_size(2));
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level $sanitize -o file_sizes file_sizes.tc &&
  >     ./file_sizes && traps ./file_sizes vla
  >   done
  > done
  sizes: 4 16 12
  trapped
  sizes: 4 16 12
  trapped
  sizes: 4 16 12
  trapped
  sizes: 4 16 12
  trapped

The index of the form that C does not evaluate stands under a unary
plus, so an index of type `char` draws no -Wchar-subscripts, which
-Wall turns on. The partner is the lowered text without the plus,
which both backends report.

  $ cat > char_index.tc <<'EOF'
  > #include <stdio.h>
  > int numbers[3];
  > slice(int) s = slice_from_array(numbers);
  > static size_t width(char c) { return sizeof(s[c]); }
  > int main(void) {
  >   printf("width: %zu\n", width('a'));
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level -o char_index char_index.tc &&
  >     ./char_index &&
  >     typec --cc=$cc $flags --emit-c -o char_index.i char_index.tc &&
  >     compile_emitted $cc char_index.i -std=c11 $level &&
  >     sed 's/\.data\[+(/.data[(/' char_index.i >unplussed.i &&
  >     compile_emitted $cc unplussed.i -std=c11 $level 2>&1 |
  >       grep -q char-subscripts && echo "reported: char-subscripts"
  >   done
  > done
  width: 4
  reported: char-subscripts
  width: 4
  reported: char-subscripts
  width: 4
  reported: char-subscripts
  width: 4
  reported: char-subscripts

Where C evaluates the operand of a `sizeof` by the value of a layout
constant that typec holds opaque (design 13.3), typec gives the index
its test: `sizeof(struct four) - 4` is 0, so the third operand is a
null pointer constant, the conditional has the type of a pointer to a
variable length array, and C evaluates the store in its bound. In range
it stores once; out of range it traps before the store, which
AddressSanitizer would otherwise report.

  $ cat > layout.tc <<'EOF'
  > #include <stdio.h>
  > struct four { int x; };
  > static void store(int c, size_t i) {
  >   int cells[5] = { 0 };
  >   slice(int) s = slice_from_array(cells);
  >   void *p = cells;
  >   size_t size = sizeof(
  >       *(c ? (int (*)[s[i] = 5])p : (void *)(sizeof(struct four) - 4)));
  >   printf("layout: size %zu cells %d %d %d %d %d\n", size, cells[0],
  >          cells[1], cells[2], cells[3], cells[4]);
  > }
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   if (argc > 1)
  >     store(1, 5);
  >   else
  >     store(1, 2);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level $sanitize -o layout layout.tc &&
  >     ./layout && traps ./layout out
  >   done
  > done
  layout: size 20 cells 0 0 5 0 0
  trapped
  layout: size 20 cells 0 0 5 0 0
  trapped
  layout: size 20 cells 0 0 5 0 0
  trapped
  layout: size 20 cells 0 0 5 0 0
  trapped

The form of an index and of a `slice_sub` that C does not evaluate
starts with the trap. Compiled by typec in a `sizeof`, it runs nothing.
Taken from the lowered text and compiled where C evaluates it, with
`sizeof` deleted, it traps before it evaluates an operand: each
operand prints when it is evaluated, and nothing is printed. The
partner, the same text without its trap, evaluates the operands. The
order of the slice and the index of `[]` is unspecified, so their lines
are sorted.

  $ cat > unevaluated.tc <<'EOF'
  > #include <stdio.h>
  > #include <string.h>
  > static int numbers[3] = { 1, 2, 3 };
  > slice(int) all = slice_from_array(numbers);
  > slice(int) counted(slice(int) s) {
  >   puts("slice");
  >   return s;
  > }
  > size_t at(size_t i) {
  >   printf("index %zu\n", i);
  >   return i;
  > }
  > static void index_form(void) { (void)sizeof(counted(all)[at(1)]); }
  > static void sub_form(void) {
  >   (void)sizeof(slice_sub(counted(all), at(0), at(1)));
  > }
  > int main(int argc, char **argv) {
  >   setvbuf(stdout, NULL, _IONBF, 0);
  >   if (argc > 1 && strcmp(argv[1], "index") == 0)
  >     index_form();
  >   if (argc > 1 && strcmp(argv[1], "sub") == 0)
  >     sub_form();
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level -o unevaluated unevaluated.tc &&
  >     ./unevaluated index && ./unevaluated sub &&
  >     typec --cc=$cc $flags --emit-c -o unevaluated.i unevaluated.tc &&
  >     sed 's/(void)sizeof(/(void)(/' unevaluated.i >evaluated.i &&
  >     $cc $level -x cpp-output -o evaluated evaluated.i &&
  >     traps ./evaluated index && traps ./evaluated sub &&
  >     sed 's/(void)__builtin_trap(), //' evaluated.i >untrapped.i &&
  >     $cc $level -x cpp-output -o untrapped untrapped.i &&
  >     ./untrapped index >order && sort order && ./untrapped sub
  >   done
  > done
  trapped
  trapped
  index 1
  slice
  slice
  index 0
  index 1
  trapped
  trapped
  index 1
  slice
  slice
  index 0
  index 1
  trapped
  trapped
  index 1
  slice
  slice
  index 0
  index 1
  trapped
  trapped
  index 1
  slice
  slice
  index 0
  index 1

Operands that count their evaluations are evaluated once in an index,
a `slice_sub` and a `slice_from_array`, whose length writes its
operand a second time, in a `sizeof` that C does not evaluate. The partner, a
`slice_from_array` of a variable length array, which that `sizeof`
would evaluate, is refused by typec (design 8 rule 2).

  $ cat > once.tc <<'EOF'
  > #include <stdio.h>
  > static int calls;
  > static int numbers[3] = { 1, 2, 3 };
  > static int grid[2][3] = { { 1, 2, 3 }, { 4, 5, 6 } };
  > static slice(int) all = slice_from_array(numbers);
  > static slice(int) counted(slice(int) s) {
  >   calls++;
  >   return s;
  > }
  > static size_t at(size_t i) {
  >   calls++;
  >   return i;
  > }
  > static int (*row(size_t i))[3] {
  >   calls++;
  >   return &grid[i];
  > }
  > int main(void) {
  >   calls = 0;
  >   int x = counted(all)[at(1)];
  >   printf("index: %d calls %d\n", x, calls);
  >   calls = 0;
  >   slice(int) m = slice_sub(counted(all), at(1), at(3));
  >   printf("sub: %zu %d calls %d\n", m.len, m[0], calls);
  >   calls = 0;
  >   slice(int) r = slice_from_array(*row(1));
  >   printf("from array: %zu %d calls %d\n", r.len, r[0], calls);
  >   return 0;
  > }
  > EOF
  $ cat > variable.tc <<'EOF'
  > #include <stddef.h>
  > size_t length(int n) {
  >   int a[n];
  >   return slice_from_array(a).len;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level $sanitize -o once once.tc && ./once
  >     typec --cc=$cc $flags $level -c -o variable.o variable.tc 2>&1 |
  >       refusal
  >   done
  > done
  index: 2 calls 2
  sub: 2 2 calls 3
  from array: 3 4 calls 1
  refused [slice-operand]
  index: 2 calls 2
  sub: 2 2 calls 3
  from array: 3 4 calls 1
  refused [slice-operand]
  index: 2 calls 2
  sub: 2 2 calls 3
  from array: 3 4 calls 1
  refused [slice-operand]
  index: 2 calls 2
  sub: 2 2 calls 3
  from array: 3 4 calls 1
  refused [slice-operand]

A `slice_from_array` holds no test, so it initialises an object of file
scope under -pedantic-errors. The partner, an index that C evaluates in
the head of a function, has a test that needs the temporaries of a
function body, and typec refuses it (design 8 rule 9).

  $ cat > whole.tc <<'EOF'
  > #include <stdio.h>
  > static int numbers[3] = { 1, 2, 3 };
  > static slice(int) whole = slice_from_array(numbers);
  > int main(void) {
  >   printf("whole: %zu %d\n", whole.len, whole[2]);
  >   return 0;
  > }
  > EOF
  $ cat > head.tc <<'EOF'
  > #include <stddef.h>
  > static int numbers[3] = { 1, 2, 3 };
  > static slice(int) whole = slice_from_array(numbers);
  > int head(size_t n, int a[whole[n]]) { return a[0]; }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level -o whole whole.tc && ./whole
  >     typec --cc=$cc $flags $level -c -o head.o head.tc 2>&1 | refusal
  >   done
  > done
  whole: 3 3
  refused [slice-check-place]
  whole: 3 3
  refused [slice-check-place]
  whole: 3 3
  refused [slice-check-place]
  whole: 3 3
  refused [slice-check-place]

An initialiser of file scope in parentheses, of a slice and of a
variant, and a `slice_from_array` as the argument of a constructor,
are lowered to braced lists, which both backends take at file scope
under -pedantic-errors. The partners are the lowered text with the
compound literal inside the parentheses and as the payload, which GCC
refuses there; Clang takes them, so they are GCC's alone.

  $ cat > initialisers.tc <<'EOF'
  > type e = | A | B(int i);
  > static int a[3] = { 1, 2, 3 };
  > static char letters[] = { 'x', 'y' };
  > slice(int) b = (slice_from_array(a));
  > e x = (B(1));
  > option(str) o = Some(slice_from_array(letters));
  > EOF
  $ cat initialisers.tc - >parens.tc <<'EOF'
  > #include <stdio.h>
  > int main(void) {
  >   printf("b: %zu %d\n", b.len, b[2]);
  >   match (x) {
  >   case A:
  >     puts("x: A");
  >     break;
  >   case B(i):
  >     printf("x: B(%d)\n", i);
  >     break;
  >   }
  >   match (o) {
  >   case None:
  >     puts("o: None");
  >     break;
  >   case Some(s):
  >     printf("o: %zu %.*s\n", s.len, (int)s.len, s.data);
  >     break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level -o parens parens.tc && ./parens
  >   done
  > done
  b: 3 3
  x: B(1)
  o: 2 xy
  b: 3 3
  x: B(1)
  o: 2 xy
  b: 3 3
  x: B(1)
  o: 2 xy
  b: 3 3
  x: B(1)
  o: 2 xy
  $ typec --cc=$gcc $flags --emit-c -o initialisers.i initialisers.tc
  $ compile_emitted $gcc initialisers.i -std=c11
  $ for level in -O0 -O2; do
  >   sed -e '/ b = $/,/^;$/s/^{ (/((struct slice__i){ (/' \
  >     -e '/ b = $/,/^;$/s/  }$/  })/' initialisers.i >paren_slice.i
  >   compile_emitted $gcc paren_slice.i -std=c11 $level 2>&1 | errors
  >   sed -e '/ x = $/,/^;$/s/^{ .tag/((e){ .tag/' \
  >     -e '/ x = $/,/^;$/s/ } }$/ } })/' initialisers.i >paren_variant.i
  >   compile_emitted $gcc paren_variant.i -std=c11 $level 2>&1 | errors
  >   sed -e '/ o = $/,/^;$/s/^{ (/(struct slice__Kc){ (/' \
  >     initialisers.i >payload.i
  >   compile_emitted $gcc payload.i -std=c11 $level 2>&1 | errors
  > done
  line 4: initializer element is not constant [-Wpedantic]
  line 5: initializer element is not constant [-Wpedantic]
  line 6: initializer element is not constant [-Wpedantic]
  line 4: initializer element is not constant [-Wpedantic]
  line 5: initializer element is not constant [-Wpedantic]
  line 6: initializer element is not constant [-Wpedantic]

A `slice(int)` converts to `slice(const int)` in an argument, an
assignment, a `return` and either operand of a conditional operator
whose other operand is a `slice(const int)`, evaluating its operand
once, and `slice_from_array` initialises a `slice(const int)` of file
scope under -pedantic-errors. The partners are the lowered text with
the compound literal of `slice(int)` in that initialiser, and with the
operand of the conditional operator as the source has it; both
backends refuse each.

  $ cat > conversions.tc <<'EOF'
  > #include <stdio.h>
  > static int calls;
  > static int numbers[3] = { 1, 2, 3 };
  > static int others[4] = { 7, 8, 9, 10 };
  > static slice(const int) fixed = slice_from_array(others);
  > static slice(int) counted(slice(int) s) {
  >   calls++;
  >   return s;
  > }
  > static int first(slice(const int) s) { return s[0]; }
  > static slice(const int) give(slice(int) s) { return counted(s); }
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   slice(int) m = slice_from_array(numbers);
  >   int k = argc;
  >   calls = 0;
  >   int v = first(counted(m));
  >   slice(const int) d;
  >   d = counted(m);
  >   slice(const int) r = give(m);
  >   slice(const int) e = k ? counted(m) : fixed;
  >   slice(const int) f = !k ? fixed : counted(m);
  >   printf("const: %d %d %d %d %d %zu calls %d\n", v, d[1], r[2], e[0], f[2],
  >          fixed.len, calls);
  >   return 0;
  > }
  > EOF
  $ cat > conversion.tc <<'EOF'
  > extern slice(int) m;
  > static int numbers[3] = { 1, 2, 3 };
  > slice(const int) c = slice_from_array(numbers);
  > slice(const int) pick(int k) { return k ? m : c; }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level $sanitize -o conversions conversions.tc &&
  >     ./conversions &&
  >     typec --cc=$cc $flags --emit-c -o conversion.i conversion.tc &&
  >     compile_emitted $cc conversion.i -std=c11 $level &&
  >     sed '/ c = $/,/^;$/s/^{ (/(struct slice__i){ (/' conversion.i \
  >       >literal_init.i &&
  >     compile_emitted $cc literal_init.i -std=c11 $level 2>&1 | errors
  >     sed 's/(struct slice__Ki){ __tc_s0.data, __tc_s0.len }/__tc_s0/' \
  >       conversion.i >as_written.i &&
  >     compile_emitted $cc as_written.i -std=c11 $level 2>&1 | errors
  >   done
  > done
  const: 1 2 3 1 3 4 calls 5
  line 3: initializing 'slice__Ki' (aka 'struct slice__Ki') with an expression of incompatible type 'struct slice__i'
  line 4: incompatible operand types ('struct slice__i' and 'slice__Ki' (aka 'struct slice__Ki'))
  const: 1 2 3 1 3 4 calls 5
  line 3: initializing 'slice__Ki' (aka 'struct slice__Ki') with an expression of incompatible type 'struct slice__i'
  line 4: incompatible operand types ('struct slice__i' and 'slice__Ki' (aka 'struct slice__Ki'))
  const: 1 2 3 1 3 4 calls 5
  line 3: invalid initializer
  line 4: type mismatch in conditional expression
  const: 1 2 3 1 3 4 calls 5
  line 3: invalid initializer
  line 4: type mismatch in conditional expression

A string literal initialises a `str` of file scope under
-pedantic-errors and holds its length without the NUL. The partner,
`slice_from_array` of an array of arrays, is refused by typec: an
array is no type argument (design 8 rule 2, 3.5 rule 2).

  $ cat > greeting.tc <<'EOF'
  > #include <stdio.h>
  > static str greeting = "hello";
  > int main(void) {
  >   printf("greeting: %zu %.*s\n", greeting.len, (int)greeting.len,
  >          greeting.data);
  >   return 0;
  > }
  > EOF
  $ cat > rows.tc <<'EOF'
  > #include <stddef.h>
  > static int rows[3][4];
  > size_t count(void) { return slice_from_array(rows).len; }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level -o greeting greeting.tc && ./greeting
  >     typec --cc=$cc $flags $level -c -o rows.o rows.tc 2>&1 | refusal
  >   done
  > done
  greeting: 5 hello
  refused [type-argument]
  greeting: 5 hello
  refused [type-argument]
  greeting: 5 hello
  refused [type-argument]
  greeting: 5 hello
  refused [type-argument]

`slice_from_array` of an array of `int` compiles without a diagnostic
in a block, at file scope, in a return type, in the size of a member
and in a parameter list. Its length has a term that names an array type
of negative size where an element has the size 0, so the partner, one
of an array whose elements have size 0, is refused by both backends in
a block, at file scope and in a parameter list. The elements are a
structure without members, which typec sees, and a structure whose one
member is `int[sizeof(struct four) - 4]`, whose size is a layout
constant that typec does not compute (design 13.3). Both are GNU C, so
the partner is compiled without -pedantic-errors. The array
`int[sizeof(struct four) - 4]` itself is no element: typec refuses it
as a type argument (design 8 rule 2, 3.5 rule 2) before the backend
sees its size.

  $ cat > places.tc <<'EOF'
  > #include <stdio.h>
  > int a[3] = { 1, 2, 3 };
  > slice(int) at_file = slice_from_array(a);
  > struct member { char size[sizeof(slice_from_array(a))]; };
  > char (*returned(void))[sizeof(slice_from_array(a))] {
  >   static char storage[sizeof(slice_from_array(a))];
  >   return &storage;
  > }
  > static void parameter(char x[sizeof(slice_from_array(a))]) { (void)x; }
  > int main(void) {
  >   slice(int) in_block = slice_from_array(a);
  >   struct member m;
  >   char buffer[sizeof(slice_from_array(a))] = { 0 };
  >   char (*storage)[sizeof(slice_from_array(a))] = returned();
  >   parameter(buffer);
  >   printf("places: %zu %zu %zu %zu\n", in_block.len, at_file.len,
  >          sizeof m.size, sizeof *storage);
  >   return 0;
  > }
  > EOF
  $ cat > zero.tc <<'EOF'
  > #include <stddef.h>
  > struct four { int x; };
  > #if defined(EMPTY)
  > typedef struct { } element;
  > #elif defined(LAYOUT)
  > typedef struct { int m[sizeof(struct four) - 4]; } element;
  > #elif defined(ARRAY)
  > typedef int element[sizeof(struct four) - 4];
  > #else
  > #error "no element"
  > #endif
  > extern element buffer[8];
  > #if defined(BLOCK)
  > size_t block(void) { return slice_from_array(buffer).len; }
  > #elif defined(FILE_SCOPE)
  > slice(element) whole = slice_from_array(buffer);
  > #elif defined(PARAMETER)
  > void sized(char x[sizeof(slice_from_array(buffer))]) { (void)x; }
  > #else
  > #error "no place"
  > #endif
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $level -o places places.tc && ./places
  >     for element in EMPTY LAYOUT; do
  >       for place in BLOCK FILE_SCOPE PARAMETER; do
  >         typec --cc=$cc -std=gnu11 $level -D$element -D$place -c \
  >           -o zero.o zero.tc 2>&1 | grep -q 'is negative' &&
  >           echo "$element $place: negative size"
  >       done
  >     done
  >   done
  > done
  places: 3 3 16 16
  EMPTY BLOCK: negative size
  EMPTY FILE_SCOPE: negative size
  EMPTY PARAMETER: negative size
  LAYOUT BLOCK: negative size
  LAYOUT FILE_SCOPE: negative size
  LAYOUT PARAMETER: negative size
  places: 3 3 16 16
  EMPTY BLOCK: negative size
  EMPTY FILE_SCOPE: negative size
  EMPTY PARAMETER: negative size
  LAYOUT BLOCK: negative size
  LAYOUT FILE_SCOPE: negative size
  LAYOUT PARAMETER: negative size
  places: 3 3 16 16
  EMPTY BLOCK: negative size
  EMPTY FILE_SCOPE: negative size
  EMPTY PARAMETER: negative size
  LAYOUT BLOCK: negative size
  LAYOUT FILE_SCOPE: negative size
  LAYOUT PARAMETER: negative size
  places: 3 3 16 16
  EMPTY BLOCK: negative size
  EMPTY FILE_SCOPE: negative size
  EMPTY PARAMETER: negative size
  LAYOUT BLOCK: negative size
  LAYOUT FILE_SCOPE: negative size
  LAYOUT PARAMETER: negative size
  $ typec --cc=$clang -std=gnu11 -DARRAY -DBLOCK -c -o zero.o zero.tc 2>&1 |
  >   refusal
  refused [type-argument]

An index whose operand returns a second time reaches the element of
its index again where its function has not begun to evaluate it in
between (design 13.5, "An evaluation that is resumed"): with `setjmp`
in a statement expression and with a call of `getcontext` in the
operand. The partner, the same run with an index out of range at the
second return, traps. The statement expression needs -std=gnu11, so
this section drops -pedantic-errors and the conversion warnings, and
macOS marks the ucontext functions deprecated. A `resume()` that
returns, as where `getcontext` failed, aborts the run.

  $ cat > resume.tc <<'EOF'
  > #define _XOPEN_SOURCE 700
  > #include <setjmp.h>
  > #include <stdio.h>
  > #include <stdlib.h>
  > #include <ucontext.h>
  > static int cells[4] = { 10, 11, 12, 13 };
  > static slice(int) s;
  > static int phase;
  > static int later;
  > #ifdef SETJMP
  > static jmp_buf env;
  > #else
  > static ucontext_t context;
  > #endif
  > __attribute__((noinline)) static void resume(void) {
  > #ifdef SETJMP
  >   longjmp(env, 1);
  > #else
  >   setcontext(&context);
  > #endif
  > }
  > /* Yields 0; at phase 0 it marks the place that resume() returns to,
  >    and after that return it yields later. */
  > #ifdef SETJMP
  > #define OPERAND __extension__ ({ \
  >     if (!phase) { if (setjmp(env)) phase = 2; } \
  >     phase == 2 ? later : 0; })
  > #else
  > #define OPERAND (phase ? 0 : \
  >     (getcontext(&context), phase = phase ? 2 : 0, \
  >      phase == 2 ? later : 0))
  > #endif
  > int main(int argc, char **argv) {
  >   (void)argv;
  >   setvbuf(stdout, NULL, _IONBF, 0);
  >   if (argc > 1)
  >     later = 9;
  >   s = slice_from_array(cells);
  >   for (;;) {
  >     int v = s[OPERAND];
  >     printf("phase %d reads %d\n", phase, v);
  >     if (phase == 2)
  >       return 0;
  >     phase = 1;
  >     resume();
  >     abort();
  >   }
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     for route in SETJMP GETCONTEXT; do
  >       typec --cc=$cc -std=gnu11 -Wall -Wextra -Werror \
  >         -Wno-deprecated-declarations $level -D$route -o resume resume.tc &&
  >       ./resume && traps ./resume out
  >     done
  >   done
  > done
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
  phase 0 reads 10
  phase 2 reads 10
  phase 0 reads 10
  trapped
