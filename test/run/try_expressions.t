SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A try inside an expression on each backend (design 5.1 rule 3, 13.5).

  $ . ./backends.sh

A try that initialises an object of a braced list is evaluated whole
before the next begins, the conversion of its value to the object's
type included. Below f stores 1 in x and yields 0x1.000001p0, which no
float holds, and g yields x, plus 2 where the inexact exception is
raised: the list leaves 3 in a[1], one of the two values that
{ f(), g() } may leave. The same holds in a compound literal under a
condition.

  $ cat > fenv.tc <<'EOF'
  > #include <fenv.h>
  > #include <stdio.h>
  > #pragma STDC FENV_ACCESS ON
  > typedef result(double, int) result_double;
  > typedef result(float, int) result_float;
  > static double x;
  > static result_double f(void) {
  >   x = 1;
  >   return Ok(0x1.000001p0);
  > }
  > static result_double g(void) {
  >   return Ok(x + (fetestexcept(FE_INEXACT) ? 2 : 0));
  > }
  > static result_float listed(void) {
  >   float a[2] = { try f(), try g() };
  >   return Ok(a[1]);
  > }
  > static result_float conditioned(int c) {
  >   float v = c ? (float[2]){ try f(), try g() }[1] : 0;
  >   return Ok(v);
  > }
  > static void show(result_float r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("%g\n", (double)v);
  >     break;
  >   case Err(e):
  >     printf("error %d\n", e);
  >     break;
  >   }
  > }
  > int main(void) {
  >   x = 0;
  >   feclearexcept(FE_ALL_EXCEPT);
  >   show(listed());
  >   x = 0;
  >   feclearexcept(FE_ALL_EXCEPT);
  >   show(conditioned(1));
  >   return 0;
  > }
  > EOF

Apple Clang keeps the order at -O0 and at -O2, and GCC at -O0.

  $ for o in -O0 -O2; do
  >   typec --cc=$clang -std=c11 -pedantic-errors -Wall -Wextra -Werror $o \
  >     -o fenv fenv.tc && ./fenv
  > done
  3
  3
  3
  3
  $ typec --cc=$gcc -std=c11 -pedantic-errors -Wall -Wextra -Werror \
  >   -Wno-unknown-pragmas -O0 -o fenv fenv.tc && ./fenv
  3
  3

The partner, the lowered text with the two Ok fields read in the list
and no __tc_v temporary, leaves 1: both conversions come after both
calls, an order that C does not allow.

  $ typec --cc=$clang --emit-c -o fenv.i fenv.tc
  $ sed -e 's/const float __tc_v[0-9]* = [^;]*;//g' \
  >   -e 's/float __tc_v[0-9]*;//g' -e 's/__tc_v[0-9]* = [^;]*;//g' \
  >   -e 's/__tc_v\([0-9]*\)/__tc_t\1.u.Ok.value/g' fenv.i > fenv_read.i
  $ grep -c __tc_v fenv_read.i
  0
  [1]
  $ for o in -O0 -O2; do
  >   $clang -std=c11 -Wno-gnu-line-marker $o -x cpp-output -o fenv_read \
  >     fenv_read.i && ./fenv_read
  > done
  1
  1
  1
  1

GCC from -O1 leaves 1 in float a[2] = { f(), g() }; written in C as well
(design 13.5): it moves the conversion after the second call. This
asserts it at -O2, so that a GCC that keeps the order fails here and
joins the runs above.

  $ cat > fenv_c.c <<'EOF'
  > #include <fenv.h>
  > #include <stdio.h>
  > #pragma STDC FENV_ACCESS ON
  > static double x;
  > static double f(void) { x = 1; return 0x1.000001p0; }
  > static double g(void) { return x + (fetestexcept(FE_INEXACT) ? 2 : 0); }
  > int main(void) {
  >   feclearexcept(FE_ALL_EXCEPT);
  >   float a[2] = { f(), g() };
  >   printf("%g\n", (double)a[1]);
  >   return 0;
  > }
  > EOF
  $ $gcc -std=c11 -O2 -Wno-unknown-pragmas -o fenv_c fenv_c.c && ./fenv_c
  1

The lowered text draws one -Wconversion warning for each __tc_v
temporary from both backends, as float a[2] = { f(), g() }; draws one
for each initialiser; the partner, with a cast in each temporary's
initialiser, draws none.

  $ for cc in $clang $gcc; do
  >   typec --cc=$cc --emit-c -o fenv.i fenv.tc &&
  >   $cc -std=c11 -Wconversion -Wno-unknown-pragmas -Wno-gnu-line-marker \
  >     -fsyntax-only -x cpp-output fenv.i 2>&1 | grep -c 'warning:.*conversion'
  >   sed 's/\(__tc_v[0-9]* = \)\(__tc_t\)/\1(float)\2/g' fenv.i > fenv_cast.i &&
  >   $cc -std=c11 -Wconversion -Wno-unknown-pragmas -Wno-gnu-line-marker \
  >     -fsyntax-only -x cpp-output fenv_cast.i 2>&1 | grep -c 'warning:.*conversion'
  > done
  4
  0
  4
  0
  [1]

A bit-field takes its declared type: b, an int, needs no __tc_v for an
int value, and u, an unsigned, takes one for a double. The list then
fits each value to the width. The partner, with d returning an
unsigned, holds none.

  $ cat > bits.tc <<'EOF'
  > #include <stdio.h>
  > typedef result(int, int) result_int;
  > static result_int i(void) { return Ok(13); }
  > static result(double, int) d(void) { return Ok(5.5); }
  > static result(unsigned, int) e(void) { return Ok(5u); }
  > static result_int bits(void) {
  >   struct { int b : 3; unsigned u : 3; } s = { try i(), try d() };
  >   struct { int b : 3; unsigned u : 3; } t = { try i(), try e() };
  >   printf("%d %u %d %u\n", s.b, s.u, t.b, t.u);
  >   return Ok(0);
  > }
  > int main(void) {
  >   (void)bits();
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for o in -O0 -O2; do
  >     typec --cc=$cc -std=c11 -pedantic-errors -Wall -Wextra -Werror $o \
  >       -o bits bits.tc && ./bits
  >   done
  > done
  -3 5 -3 5
  -3 5 -3 5
  -3 5 -3 5
  -3 5 -3 5
  $ typec --cc=$clang --emit-c -o bits.i bits.tc
  $ grep -o '[a-z ]* __tc_v[0-9]* =' bits.i
   const unsigned int __tc_v1 =

The holders below each hold a try somewhere other than at their top. A
log shows which operands ran and in what order; each runs on both
backends at -O0 and at -O2, under AddressSanitizer and
UndefinedBehaviorSanitizer as well. The tries of one holder run in the
order of the operands, left before right, and the first that fails
returns its error (two); an operand left of a try in the same holder
runs after it, in the holder, so a failure leaves pos as it was (emit),
where the same call after int at = pos++; finds it one higher;
a try under && or ?: runs only where C would evaluate its operand
(guard, choose); a try in the scope of a defer runs the deferred
statement once on its error path (deferred); and an index in the
holder is checked after the try, so a failing try returns before the
index traps (index). The array member of a try's value converts to a
pointer to char that the callee may write through (use).

  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Werror"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $ cat > holders.tc <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > #include <string.h>
  > typedef result(int, int) result_int;
  > static char log_text[64];
  > static void note(const char *text) {
  >   strncat(log_text, text, sizeof log_text - strlen(log_text) - 1);
  > }
  > static void show(const char *name, result_int r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("%s: %d [%s]\n", name, v, log_text);
  >     break;
  >   case Err(e):
  >     printf("%s: error %d [%s]\n", name, e, log_text);
  >     break;
  >   }
  >   log_text[0] = '\0';
  > }
  > static result_int a(void) { note("a"); return Err(1); }
  > static result_int b(void) { note("b"); return Err(2); }
  > static result_int f(void) { note("f"); return Ok(1); }
  > static result_int g(void) { note("g"); return Ok(2); }
  > static result_int fail(void) { note("x"); return Err(5); }
  > static void mark(void) { note("m"); }
  > static int two(int left, int right) { return left + right; }
  > static result_int both(void) {
  >   return Ok(two(try a(), try b()));
  > }
  > static int pos;
  > static void put(int *out, int at, int value) { out[at] = value; }
  > static result_int emitted(result_int (*next)(void)) {
  >   int out[4] = { 0 };
  >   put(out, pos++, try next());
  >   return Ok(pos);
  > }
  > static result_int counted(result_int (*next)(void)) {
  >   int out[4] = { 0 };
  >   int at = pos++;
  >   put(out, at, try next());
  >   return Ok(pos);
  > }
  > static result_int check(int *p) {
  >   note("k");
  >   return Ok(p ? *p : 0);
  > }
  > static result_int guarded(int *p) {
  >   return Ok(p && try check(p) > 0);
  > }
  > static result_int chosen(int c) {
  >   return Ok(c ? try f() : (mark(), try g()));
  > }
  > static result_int deferred(void) {
  >   defer note("d");
  >   int n = two(try f(), try fail());
  >   return Ok(n);
  > }
  > static int all[3] = { 10, 20, 30 };
  > static result_int maybe(int ok) {
  >   if (ok)
  >     return Ok(1);
  >   return Err(6);
  > }
  > static result_int indexed(size_t i, int ok) {
  >   slice(int) s = slice_from_array(all);
  >   return Ok(s[i] + try maybe(ok));
  > }
  > struct named { char name[8]; };
  > static result(struct named, int) named(void) {
  >   struct named n = { "abc" };
  >   return Ok(n);
  > }
  > static size_t use(char *s) { return strlen(s); }
  > static result_int used(void) {
  >   return Ok((int)use((try named()).name));
  > }
  > static result_int alone(int c) {
  >   try f();
  >   c ? try f() : 1;
  >   return Ok(0);
  > }
  > int main(int argc, char **argv) {
  >   if (argc > 1) {
  >     show("index", indexed(5, 1));
  >     return 0;
  >   }
  >   int seven = 7;
  >   show("two", both());
  >   show("emit", emitted(fail));
  >   printf("pos %d\n", pos);
  >   show("counted", counted(fail));
  >   printf("pos %d\n", pos);
  >   show("guard", guarded(NULL));
  >   show("guard", guarded(&seven));
  >   show("choose 1", chosen(1));
  >   show("choose 0", chosen(0));
  >   show("deferred", deferred());
  >   show("index", indexed(5, 0));
  >   show("index", indexed(1, 1));
  >   show("use", used());
  >   show("alone", alone(argc < 1));
  >   (void)argv;
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for build in "-O0 $sanitize" "-O2 $sanitize" "-O2"; do
  >     typec --cc=$cc $flags $build -o holders holders.tc && ./holders &&
  >     sh -c "ulimit -c 0; ./holders trap; exit \$?" 2>/dev/null
  >     case $? in
  >     132 | 133) echo "index trapped" ;;
  >     *) echo "index did not trap" ;;
  >     esac
  >   done
  > done
  two: error 1 [a]
  emit: error 5 [x]
  pos 0
  counted: error 5 [x]
  pos 1
  guard: 0 []
  guard: 1 [k]
  choose 1: 1 [f]
  choose 0: 2 [mg]
  deferred: error 5 [fxd]
  index: error 6 []
  index: 21 []
  use: 3 []
  alone: 0 [f]
  index trapped
  two: error 1 [a]
  emit: error 5 [x]
  pos 0
  counted: error 5 [x]
  pos 1
  guard: 0 []
  guard: 1 [k]
  choose 1: 1 [f]
  choose 0: 2 [mg]
  deferred: error 5 [fxd]
  index: error 6 []
  index: 21 []
  use: 3 []
  alone: 0 [f]
  index trapped
  two: error 1 [a]
  emit: error 5 [x]
  pos 0
  counted: error 5 [x]
  pos 1
  guard: 0 []
  guard: 1 [k]
  choose 1: 1 [f]
  choose 0: 2 [mg]
  deferred: error 5 [fxd]
  index: error 6 []
  index: 21 []
  use: 3 []
  alone: 0 [f]
  index trapped
  two: error 1 [a]
  emit: error 5 [x]
  pos 0
  counted: error 5 [x]
  pos 1
  guard: 0 []
  guard: 1 [k]
  choose 1: 1 [f]
  choose 0: 2 [mg]
  deferred: error 5 [fxd]
  index: error 6 []
  index: 21 []
  use: 3 []
  alone: 0 [f]
  index trapped
  two: error 1 [a]
  emit: error 5 [x]
  pos 0
  counted: error 5 [x]
  pos 1
  guard: 0 []
  guard: 1 [k]
  choose 1: 1 [f]
  choose 0: 2 [mg]
  deferred: error 5 [fxd]
  index: error 6 []
  index: 21 []
  use: 3 []
  alone: 0 [f]
  index trapped
  two: error 1 [a]
  emit: error 5 [x]
  pos 0
  counted: error 5 [x]
  pos 1
  guard: 0 []
  guard: 1 [k]
  choose 1: 1 [f]
  choose 0: 2 [mg]
  deferred: error 5 [fxd]
  index: error 6 []
  index: 21 []
  use: 3 []
  alone: 0 [f]
  index trapped

Each line above has a partner that fails where the prelude is missing
or wrong. Written where it stands as a statement expression that
returns, each try of two runs in the order of the arguments that the
backend chooses, and GCC gives the error of b.

  $ typec --cc=$gcc --emit-c -o holders.i holders.tc
  $ sed '/^static result_int both(void)/,/^}/c\
  > static result_int both(void) { return ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { two(\
  >   ({ struct result__ii __tc_t0 = a(); if (__tc_t0.tag != result__ii_Ok) return __tc_t0; __tc_t0.u.Ok.value; }),\
  >   ({ struct result__ii __tc_t1 = b(); if (__tc_t1.tag != result__ii_Ok) return __tc_t1; __tc_t1.u.Ok.value; })) } }); }
  > ' holders.i > two.i
  $ $gcc -std=gnu11 -o two -x cpp-output two.i && ./two | grep two
  two: error 2 [b]

Without the if of its prelude, the try under && calls check with a null
pointer.

  $ sed '/^static result_int guarded/,/^}/s/if (__tc_c0) //' holders.i \
  >   > guard.i
  $ $gcc -std=c11 -o guard -x cpp-output guard.i && ./guard | grep guard
  guard: 0 [k]
  guard: 1 [k]

Without the else of its prelude, choose calls g after f; with mark()
kept in the holder as well, it calls mark twice.

  $ sed '/^static result_int chosen/,/^}/s/} else {/} {/' holders.i \
  >   > choose.i
  $ $gcc -std=c11 -o choose -x cpp-output choose.i && ./choose | grep choose
  choose 1: 1 [fmg]
  choose 0: 2 [mg]
  $ sed '/^static result_int chosen/,/^}/s/^(void)0$/mark ( )/' holders.i \
  >   > marked.i
  $ $gcc -std=c11 -o marked -x cpp-output marked.i && ./marked | grep choose
  choose 1: 1 [f]
  choose 0: 2 [mgm]

Without the copy of the deferred statement on the error path of the
second try, deferred returns without running it.

  $ sed '/^static result_int deferred/,/^}/{
  > /__tc_t1.tag != result__ii_Err/,/__tc_t1.u.Err.error/{
  > /note/d
  > }
  > }' holders.i > deferred.i
  $ $gcc -std=c11 -o deferred -x cpp-output deferred.i &&
  > ./deferred | grep deferred
  deferred: error 5 [fx]

The preludes compile without a diagnostic in the ISO and the GNU form
of C11 and of C17 under the strictest options; the read of the Ok field
of a try in a branch of the conditional c ? try f() : 1; that the
holder keeps draws -Wunused-value from both backends without the cast
to void around it.
A const temporary would refuse the pointer to char that use takes.

  $ for cc in $clang $gcc; do
  >   for std in c11 gnu11 c17 gnu17; do
  >     typec --cc=$cc -std=$std $flags -Wshadow -Wconversion \
  >       -Wsign-conversion -o holders holders.tc || echo "$cc $std"
  >   done
  >   typec --cc=$cc --emit-c -o holders.i holders.tc
  >   sed '/^static result_int alone/,/^}/{/^(void)($/d;/^)$/d;}' \
  >     holders.i > alone.i
  >   $cc -std=c11 -Wall -Wno-gnu-line-marker -fsyntax-only \
  >     -x cpp-output alone.i 2>&1 | grep -o '\[-Wunused-value\]'
  >   sed '/^static result_int used/,/^}/s/^struct/const struct/' \
  >     holders.i > used.i
  >   compile_emitted $cc used.i -Wno-gnu-line-marker 2>/dev/null ||
  >     echo refused
  > done
  [-Wunused-value]
  refused
  [-Wunused-value]
  refused

Each place below refuses a try under its name, and the partner of each,
which the next program holds, compiles and runs. A list whose object
has a type that a designator typec does not compute selects is refused
by the profile (design 5.1 rule 5).

  $ cat > refused.h <<'EOF'
  > #include <stddef.h>
  > typedef result(int, int) result_int;
  > struct s { int a[2]; };
  > result_int f(void);
  > result_int g(int n);
  > result_int more(int *r);
  > result(void, int) v(void);
  > result(int *, int) wrap(int *p);
  > result_int read_value(int *p);
  > struct s make(void);
  > void consume(int *p);
  > result_int set_two(void);
  > result_int read_x(void);
  > int peek_x(void);
  > int plain(void);
  > result(double, int) d(void);
  > extern int x;
  > EOF
  $ refuse() {
  >   cat refused.h - > "$1.tc"
  >   typec --cc=$clang --emit-c -o "$1.i" "$1.tc" 2>&1 |
  >     grep -o '\[[a-z-]*\]$'
  > }
  $ refuse loop <<'EOF'
  > result_int h(int r) {
  >   while (try more(&r))
  >     r--;
  >   return Ok(r);
  > }
  > EOF
  [try-loop]
  $ refuse constant <<'EOF'
  > result_int h(void) { return Ok(__builtin_constant_p(try f())); }
  > EOF
  [try-position]
  $ refuse sized <<'EOF'
  > result_int h(void) { return Ok((int)sizeof(try f())); }
  > EOF
  [try-position]
  $ refuse statement <<'EOF'
  > result_int h(void) { return Ok(({ try f(); })); }
  > EOF
  [try-position]
  $ refuse declarators <<'EOF'
  > result_int h(void) {
  >   int a = plain(), b = try f();
  >   return Ok(a + b);
  > }
  > EOF
  [try-position]
  $ refuse address <<'EOF'
  > result_int h(void) {
  >   int *p = &try f();
  >   return Ok(*p);
  > }
  > EOF
  [try-lvalue]
  $ refuse void <<'EOF'
  > result_int h(void) {
  >   int y;
  >   y = try v();
  >   return Ok(y);
  > }
  > EOF
  [try-void]
  $ refuse capture <<'EOF'
  > result_int h(void) {
  >   return Ok((int)sizeof(enum { K = 5 }) + try g(K));
  > }
  > EOF
  [try-name-capture]
  $ refuse conditioned <<'EOF'
  > result_int h(int c) {
  >   consume(c ? try wrap((int[]){7}) : NULL);
  >   return Ok(0);
  > }
  > EOF
  [try-lifetime]
  $ refuse member <<'EOF'
  > result_int h(void) {
  >   consume(try wrap(make().a));
  >   return Ok(0);
  > }
  > EOF
  [try-lifetime]
  $ refuse comma <<'EOF'
  > result_int h(void) {
  >   int *p;
  >   (p = make().a, try read_value(p));
  >   return Ok(0);
  > }
  > EOF
  [try-lifetime]
  $ refuse list <<'EOF'
  > result_int h(void) {
  >   int a[2] = { (try set_two(), x = 1), try read_x() };
  >   return Ok(a[1]);
  > }
  > EOF
  [try-list]
  $ refuse list_plain <<'EOF'
  > result_int h(void) {
  >   int a[2] = { (try set_two(), x = 1), peek_x() };
  >   return Ok(a[1]);
  > }
  > EOF
  [try-list]
  $ refuse operand <<'EOF'
  > result_int h(int c) {
  >   int y;
  >   y = try c ? f() : g(9);
  >   return Ok(y);
  > }
  > EOF
  [try-operand]
  $ refuse designated <<'EOF'
  > result_int h(void) {
  >   float a[99] = { [sizeof(struct s)] = 0, try d() };
  >   return Ok((int)a[0]);
  > }
  > EOF
  [unsupported]

The partners: for (;;) with the try in an if counts down the loop
(loop); __builtin_expect calls f once (expect); a declaration of its
own holds the try (declared); &y after y = try f(); (address); a try
of a void T where a value is discarded, under ?: (void); the
enumeration declared before the statement (capture); a compound
literal whose life is that of its block, and m.a after
struct s m = make();, each of which consume and read_value read, and
an array member of the value of a try (lifetime); a try that initialises
each object of a list, also that of a compound literal, which leaves 2
in its second (list); the try applied to the whole conditional, which
calls one of f and g (operand); and an initialiser of a record type,
whose type a designator does not change (designated).

  $ cat > partners.tc <<'EOF'
  > #include <stdio.h>
  > #include <string.h>
  > typedef result(int, int) result_int;
  > struct s { int a[2]; };
  > struct named { char name[8]; };
  > struct p { int n; };
  > static int calls;
  > static int x;
  > static result_int f(void) { calls++; return Ok(4); }
  > static result_int g(int n) { calls += 10; return Ok(n); }
  > static result_int more(int *r) { return Ok((*r)-- > 0); }
  > static result(void, int) v(void) { calls++; return (Ok); }
  > static result(void, int) w(void) { calls += 10; return (Ok); }
  > static result(int *, int) wrap(int *q) { return Ok(q); }
  > static result_int read_value(int *q) { return Ok(*q); }
  > static struct s make(void) { struct s m = { { 7, 8 } }; return m; }
  > static int consumed;
  > static void consume(int *q) { consumed = *q; }
  > static result_int set_two(void) { x = 2; return Ok(0); }
  > static result_int read_x(void) { return Ok(x); }
  > static int plain(void) { return 1; }
  > static result(struct named, int) named(void) {
  >   struct named n = { "abcd" };
  >   return Ok(n);
  > }
  > static result_int length(char *text) { return Ok((int)strlen(text)); }
  > static result(struct p, int) record(void) {
  >   struct p r = { 6 };
  >   return Ok(r);
  > }
  > static result_int looped(int r) {
  >   int n = 0;
  >   for (;;) {
  >     if (!try more(&r))
  >       break;
  >     n++;
  >   }
  >   return Ok(n);
  > }
  > static result_int expected(void) {
  >   calls = 0;
  >   long y = __builtin_expect(try f(), 0);
  >   return Ok((int)y * 10 + calls);
  > }
  > static result_int declared(void) {
  >   int a = plain();
  >   int b = try f();
  >   return Ok(a + b);
  > }
  > static result_int addressed(void) {
  >   int y;
  >   y = try f();
  >   int *q = &y;
  >   return Ok(*q);
  > }
  > static result_int voided(int c) {
  >   calls = 0;
  >   c ? try v() : try w();
  >   return Ok(calls);
  > }
  > static result_int captured(void) {
  >   enum k { K = 5 };
  >   return Ok((int)sizeof(enum k) + try g(K));
  > }
  > static result_int lifetimes(void) {
  >   int total = 0;
  >   consume(try wrap((int[]){7}));
  >   total += consumed;
  >   struct s m = make();
  >   consume(try wrap(m.a));
  >   total += consumed;
  >   int *q;
  >   total += (q = m.a, try read_value(q));
  >   total += try length((try named()).name);
  >   return Ok(total);
  > }
  > static result_int listed(void) {
  >   x = 0;
  >   int a[2] = { try set_two(), try read_x() };
  >   x = 0;
  >   int b = (int[2]){ try set_two(), try read_x() }[1];
  >   return Ok(a[1] * 10 + b);
  > }
  > static result_int operand(int c) {
  >   int y;
  >   y = try (c ? f() : g(9));
  >   return Ok(y);
  > }
  > static result_int designated(void) {
  >   struct p b[99] = { [sizeof(struct s)] = { 0 }, try record() };
  >   return Ok(b[sizeof(struct s) + 1].n);
  > }
  > static void show(const char *name, result_int r) {
  >   match (r) {
  >   case Ok(value):
  >     printf("%s: %d\n", name, value);
  >     break;
  >   case Err(e):
  >     printf("%s: error %d\n", name, e);
  >     break;
  >   }
  > }
  > int main(void) {
  >   show("loop", looped(3));
  >   show("expect", expected());
  >   show("declared", declared());
  >   show("address", addressed());
  >   show("void 1", voided(1));
  >   show("void 0", voided(0));
  >   show("capture", captured());
  >   show("lifetime", lifetimes());
  >   show("list", listed());
  >   calls = 0;
  >   show("operand 1", operand(1));
  >   show("operand 0", operand(0));
  >   printf("calls %d\n", calls);
  >   show("designated", designated());
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for build in "-O0 $sanitize" "-O2 $sanitize" "-O2"; do
  >     typec --cc=$cc $flags $build -o partners partners.tc && ./partners |
  >       paste -s -d ' ' -
  >   done
  > done
  loop: 3 expect: 41 declared: 5 address: 4 void 1: 1 void 0: 10 capture: 9 lifetime: 25 list: 22 operand 1: 4 operand 0: 9 calls 11 designated: 6
  loop: 3 expect: 41 declared: 5 address: 4 void 1: 1 void 0: 10 capture: 9 lifetime: 25 list: 22 operand 1: 4 operand 0: 9 calls 11 designated: 6
  loop: 3 expect: 41 declared: 5 address: 4 void 1: 1 void 0: 10 capture: 9 lifetime: 25 list: 22 operand 1: 4 operand 0: 9 calls 11 designated: 6
  loop: 3 expect: 41 declared: 5 address: 4 void 1: 1 void 0: 10 capture: 9 lifetime: 25 list: 22 operand 1: 4 operand 0: 9 calls 11 designated: 6
  loop: 3 expect: 41 declared: 5 address: 4 void 1: 1 void 0: 10 capture: 9 lifetime: 25 list: 22 operand 1: 4 operand 0: 9 calls 11 designated: 6
  loop: 3 expect: 41 declared: 5 address: 4 void 1: 1 void 0: 10 capture: 9 lifetime: 25 list: 22 operand 1: 4 operand 0: 9 calls 11 designated: 6

A try converts its value where C does, and only a try that initialises
an object of a braced list holds a __tc_v temporary: an argument and
the initialiser of a declaration hold none, and the same initialiser
in braces holds one.

  $ cat > floats.tc <<'EOF'
  > typedef result(int, int) result_int;
  > static result(double, int) f(void) { return Ok(0.5); }
  > static int g(void) { return 1; }
  > static float h(float a, int b) { return a + (float)b; }
  > static result_int argument(void) { return Ok((int)h(try f(), g())); }
  > static result_int declared(void) {
  >   float x = try f();
  >   return Ok((int)x);
  > }
  > static result_int braced(void) {
  >   float x = { try f() };
  >   return Ok((int)x);
  > }
  > int main(void) {
  >   (void)argument();
  >   (void)declared();
  >   (void)braced();
  >   return 0;
  > }
  > EOF
  $ typec --cc=$clang $flags -o floats floats.tc && ./floats
  $ typec --cc=$clang --emit-c -o floats.i floats.tc
  $ for name in argument declared braced; do
  >   echo $name: $(sed -n "/^static result_int $name/,/^}/p" floats.i |
  >     grep -o '[a-z]* __tc_v[0-9]* =')
  > done
  argument:
  declared:
  braced: float __tc_v0 =

A try inside an expression of a generic function's definition is
lowered in each instance's text: the prelude and the copy of a deferred
statement on the error path are moved text inside the definition, which
holds no pragma line (design 10.3).

  $ cat > generic.tc <<'EOF'
  > #include <stdio.h>
  > typedef result(int, int) result_int;
  > static int cleanups;
  > static result_int f(int n) {
  >   if (n)
  >     return Ok(n);
  >   return Err(3);
  > }
  > generic(T) result_int sized(T *a, int n) {
  >   defer cleanups++;
  >   int v = (int)sizeof(*a) + try f(n);
  >   return Ok(v + try f(n));
  > }
  > static void show(result_int r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("%d\n", v);
  >     break;
  >   case Err(e):
  >     printf("error %d\n", e);
  >     break;
  >   }
  > }
  > int main(void) {
  >   double d = 0;
  >   char c = 0;
  >   show(sized(&d, 5));
  >   show(sized(&c, 0));
  >   printf("cleanups %d\n", cleanups);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for build in "-O0 $sanitize" "-O2"; do
  >     typec --cc=$cc $flags $build -o generic generic.tc && ./generic |
  >       paste -s -d ' ' -
  >   done
  > done
  18 error 3 cleanups 2
  18 error 3 cleanups 2
  18 error 3 cleanups 2
  18 error 3 cleanups 2

A try beside a construct that lowering writes around its operand: an
index of a slice that is the truth of && (truth), the operand of
slice_from_array that holds a try (length), an index of a slice that
begins the holder (store), a try in a branch of a conditional whose
value nothing reads (branch), and a try on the left of a comma, whose
value nothing reads, in a statement, in a branch and in an initialiser
(comma, ternc, decl). Each copy of an operand holds exactly the edits
inside it, once.

  $ cat > beside.tc <<'EOF'
  > #include <stdio.h>
  > typedef result(int, int) result_int;
  > static int calls;
  > static result_int f(int n) {
  >   calls++;
  >   if (n >= 0)
  >     return Ok(n);
  >   return Err(-n);
  > }
  > static int g(void) {
  >   calls += 10;
  >   return 7;
  > }
  > static result_int truth(slice(int) s, int i, int n) {
  >   int x = s[i] && try f(n);
  >   return Ok(x);
  > }
  > static result_int length(int n) {
  >   static int m[2][3] = { { 1, 2, 3 }, { 4, 5, 6 } };
  >   slice(int) s = slice_from_array(m[try f(n)]);
  >   return Ok((int)s.len * 10 + s[0]);
  > }
  > static result_int store(slice(int) s, int n) {
  >   s[0] = try f(n);
  >   return Ok(s[0]);
  > }
  > static result_int branch(int c, int n) {
  >   c ? try f(n) : g();
  >   return Ok(calls);
  > }
  > static result_int comma(int n) {
  >   try f(n), g();
  >   return Ok(calls);
  > }
  > static result_int ternc(int c, int n) {
  >   c ? (try f(n), 1) : g();
  >   return Ok(calls);
  > }
  > static result_int decl(int n) {
  >   int x = (try f(n), 1);
  >   return Ok(x);
  > }
  > static void show(const char *name, result_int r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("%s: %d\n", name, v);
  >     break;
  >   case Err(e):
  >     printf("%s: error %d\n", name, e);
  >     break;
  >   }
  > }
  > int main(void) {
  >   static int a[2] = { 0, 1 };
  >   show("truth", truth(slice_from_array(a), 1, 1));
  >   show("truth", truth(slice_from_array(a), 0, -2));
  >   show("truth", truth(slice_from_array(a), 1, -2));
  >   show("length", length(1));
  >   show("length", length(-3));
  >   show("store", store(slice_from_array(a), 3));
  >   calls = 0;
  >   show("branch", branch(1, 4));
  >   show("branch", branch(0, 4));
  >   show("branch", branch(1, -5));
  >   calls = 0;
  >   show("comma", comma(2));
  >   show("comma", comma(-6));
  >   show("ternc", ternc(1, 3));
  >   show("ternc", ternc(0, 3));
  >   show("decl", decl(8));
  >   show("decl", decl(-9));
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for build in "-O0 $sanitize" "-O2"; do
  >     typec --cc=$cc $flags $build -o beside beside.tc && ./beside |
  >       paste -s -d ' ' -
  >   done
  > done
  truth: 1 truth: 0 truth: error 2 length: 34 length: error 3 store: 3 branch: 1 branch: 11 branch: error 5 comma: 11 comma: error 6 ternc: 13 ternc: 23 decl: 1 decl: error 9
  truth: 1 truth: 0 truth: error 2 length: 34 length: error 3 store: 3 branch: 1 branch: 11 branch: error 5 comma: 11 comma: error 6 ternc: 13 ternc: 23 decl: 1 decl: error 9
  truth: 1 truth: 0 truth: error 2 length: 34 length: error 3 store: 3 branch: 1 branch: 11 branch: error 5 comma: 11 comma: error 6 ternc: 13 ternc: 23 decl: 1 decl: error 9
  truth: 1 truth: 0 truth: error 2 length: 34 length: error 3 store: 3 branch: 1 branch: 11 branch: error 5 comma: 11 comma: error 6 ternc: 13 ternc: 23 decl: 1 decl: error 9

A first operand that begins with something other than the first token
of the text the parser reads for it: __extension__, which makes no node,
and the C text of a header included in the middle of the expression.
Each is hoisted with the views that the parser took at it.

  $ echo c > operand.h
  $ cat > begins.tc <<'EOF'
  > #include <stdio.h>
  > typedef result(int, int) result_int;
  > static result_int f(int n) {
  >   if (n >= 0)
  >     return Ok(n);
  >   return Err(-n);
  > }
  > static result_int extension(int c, int n) {
  >   int x = __extension__ c && try f(n);
  >   return Ok(x);
  > }
  > static result_int included(int c, int n) {
  >   int x =
  > #include "operand.h"
  >     || try f(n);
  >   return Ok(x);
  > }
  > static void show(const char *name, result_int r) {
  >   match (r) {
  >   case Ok(v):
  >     printf("%s: %d\n", name, v);
  >     break;
  >   case Err(e):
  >     printf("%s: error %d\n", name, e);
  >     break;
  >   }
  > }
  > int main(void) {
  >   show("extension", extension(1, 2));
  >   show("extension", extension(0, -2));
  >   show("extension", extension(1, -3));
  >   show("included", included(1, -4));
  >   show("included", included(0, 0));
  >   show("included", included(0, -5));
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o begins begins.tc && ./begins |
  >     paste -s -d ' ' -
  > done
  extension: 1 extension: 0 extension: error 3 included: 1 included: 0 included: error 5
  extension: 1 extension: 0 extension: error 3 included: 1 included: 0 included: error 5
