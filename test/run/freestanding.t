SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A freestanding build leaves no undefined symbol that the program did
not introduce (design 10.4). The program uses constructs whose lowering
traps or copies: a slice index and `slice_sub`, string literals as
`str`, a `match` with nested patterns over a variant whose tag C code
corrupts, a single-pattern test, `try`, `defer`, a generic function
with two instances and a zero initialiser of its type parameter. Each
backend compiles it at -O0 and -O2 with -ffreestanding -nostdlib
-fno-builtin, without and with --trap-function=stop.

The expected names are those the program declares with `extern`: put
and input, which its environment supplies; stop, the trap function,
which only the build with --trap-function calls; and memcpy, memmove,
memset and memcmp, which GCC and Clang require of every freestanding
environment (design 10.4). Clang at -O0 calls memset here, for the
padding of a compound literal, as it does for C.

-fno-stack-protector turns off the stack protector that some hosts
enable by default. It calls __stack_chk_fail, which a freestanding
program should supply rather than lose the protector; its names differ
by host, so the test leaves it out.

The check reads the undefined symbols of the object rather than
linking it: with -nostdlib nothing else is linked, so they are what
such a link leaves unresolved, while the entry point and start-up code
of a -nostdlib executable differ by host and macOS has no static
executables. Each build must also show put and input, so that an nm
output the check cannot read fails it, and stop exactly where it is
built with --trap-function. The object is then linked with a hosted
harness that supplies put, input and stop, and runs: the corrupted tag
and the index out of range trap (design 10.5), so -O2 kept them. Under
--trap-function they call stop, which exits with 3, also in evaluate,
whose local named stop hides the function where its match traps.
-Wredundant-decls checks that the program may declare stop itself.

  $ . ./backends.sh
  $ export LC_ALL=C
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Wredundant-decls -Werror"
  $ freestanding="-ffreestanding -nostdlib -fno-builtin -fno-stack-protector"
  $ cat > corrupt.h <<'EOF'
  > static void corrupt(expr *e) { e->tag = (enum expr_tag)7; }
  > EOF
  $ cat > program.tc <<'EOF'
  > #include <stddef.h>
  > extern void put(long value);
  > extern long input(int which);
  > extern _Noreturn void stop(void);
  > extern void *memcpy(void *to, const void *from, size_t n);
  > extern void *memmove(void *to, const void *from, size_t n);
  > extern void *memset(void *s, int c, size_t n);
  > extern int memcmp(const void *a, const void *b, size_t n);
  > type expr = | Num(long value) | Neg(expr *e) | Add(expr *l, expr *r);
  > type parsed = | Digit(long value) | Bad(int code);
  > type pair(T) = struct { T first, second; };
  > #include "corrupt.h"
  > static long digits[4] = { 1, 2, 3, 4 };
  > static str word = "four";
  > generic(T) pair(T) both(T value) {
  >   pair(T) p = {};
  >   p.first = value;
  >   p.second = value;
  >   return p;
  > }
  > static long evaluate(const expr *e) {
  >   long stop = 0;
  >   match (*e) {
  >   case Add(*Num(a), *Num(b)):
  >     return a + b + stop;
  >   case Add(l, r):
  >     return evaluate(l) + evaluate(r);
  >   case Neg(*Neg(inner)):
  >     return evaluate(inner);
  >   case Neg(inner):
  >     return -evaluate(inner);
  >   case Num(value):
  >     return value;
  >   }
  > }
  > static result(long, int) parse(parsed p) {
  >   if (case Digit(value) = p)
  >     return Ok(value);
  >   return Err(-1);
  > }
  > static result(long, int) twice(parsed p) {
  >   long value = try parse(p);
  >   return Ok(2 * value);
  > }
  > long run(int how) {
  >   slice(long) all = slice_from_array(digits);
  >   slice(long) tail = slice_sub(all, 1, all.len);
  >   expr one = Num(input(1)), two = Num(input(2));
  >   expr sum = Add(&one, &two), negated = Neg(&sum);
  >   pair(long) twins = both(input(3));
  >   pair(double) halves = both(0.5);
  >   defer put(halves.first > 0);
  >   if (how == 1)
  >     corrupt(&one);
  >   put(evaluate(&negated));
  >   match (twice(Digit(input(4)))) {
  >   case Ok(value):
  >     put(value);
  >     break;
  >   case Err(code):
  >     put(code);
  >     break;
  >   }
  >   put((long)word.len);
  >   return tail[(size_t)input(how == 2 ? 5 : 0)] + twins.second;
  > }
  > EOF
  $ cat > harness.c <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > long run(int how);
  > void put(long value) { printf("%ld\n", value); }
  > long input(int which) { return which; }
  > _Noreturn void stop(void) { exit(3); }
  > int main(int argc, char **argv) {
  >   if (argc != 2)
  >     return 2;
  >   printf("run %ld\n", run(atoi(argv[1])));
  >   return 0;
  > }
  > EOF

The names the program declares:

  $ sed -n 's/^extern .*[ *]\([A-Za-z_][A-Za-z0-9_]*\)(.*/\1/p' program.tc |
  >   sort > declared
  $ cat declared
  input
  memcmp
  memcpy
  memmove
  memset
  put
  stop

undefined CC OBJECT prints the undefined symbols of OBJECT without the
prefix that CC's target gives a C name, one per line, sorted; `w` and `v` are
weak undefined symbols.

  $ undefined() {
  >   prefix=$("$1" -dM -E -x c /dev/null |
  >     sed -n 's/^#define __USER_LABEL_PREFIX__ *//p')
  >   nm -P "$2" | awk -v prefix="$prefix" '
  >     $2 == "U" || $2 == "w" || $2 == "v" {
  >       name = $1
  >       if (prefix != "" && index(name, prefix) == 1)
  >         name = substr(name, length(prefix) + 1)
  >       print name
  >     }' | sort
  > }

Each build leaves no undefined name outside the declared ones, and runs.

  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     for trap in '' --trap-function=stop; do
  >       typec --cc=$cc $flags $freestanding $level $trap -c program.tc &&
  >       undefined $cc program.o > found && comm -23 found declared &&
  >       grep -x -e input -e put -e stop found &&
  >       $cc $flags harness.c program.o -o program && ./program 0 &&
  >       for how in 1 2; do
  >         sh -c "ulimit -c 0; ./program $how; exit \$?" >/dev/null 2>&1
  >         case $? in
  >         132 | 133) echo "$how trapped" ;;
  >         3) echo "$how called stop" ;;
  >         *) echo "$how did not trap" ;;
  >         esac
  >       done
  >     done
  >   done
  > done
  input
  put
  -3
  8
  4
  1
  run 5
  1 trapped
  2 trapped
  input
  put
  stop
  -3
  8
  4
  1
  run 5
  1 called stop
  2 called stop
  input
  put
  -3
  8
  4
  1
  run 5
  1 trapped
  2 trapped
  input
  put
  stop
  -3
  8
  4
  1
  run 5
  1 called stop
  2 called stop
  input
  put
  -3
  8
  4
  1
  run 5
  1 trapped
  2 trapped
  input
  put
  stop
  -3
  8
  4
  1
  run 5
  1 called stop
  2 called stop
  input
  put
  -3
  8
  4
  1
  run 5
  1 trapped
  2 trapped
  input
  put
  stop
  -3
  8
  4
  1
  run 5
  1 called stop
  2 called stop

A unit whose lowering writes no trap leaves __tc_trap unused, which
Clang reports under -Wunused-function outside a system header. Its
declarations stand under typec's own marker (design 10.5), so both
backends take the unit with -Werror, and its object refers to no stop.

  $ cat > no_trap.tc <<'EOF'
  > type flag = | On | Off;
  > flag on(void) { return On; }
  > EOF
  $ for cc in $clang $gcc; do
  >   for level in -O0 -O2; do
  >     typec --cc=$cc $flags $freestanding $level --trap-function=stop \
  >       -c no_trap.tc && undefined $cc no_trap.o
  >   done
  > done

The check finds a name that the lowering would introduce: the same C
with each trap written as a call of abort leaves abort undefined.

  $ typec --cc=$clang $flags $freestanding --emit-c -o program.c program.tc
  $ { echo '_Noreturn void abort(void);'
  >   sed 's/__builtin_trap()/abort()/g' program.c; } > aborts.c
  $ $clang $flags $freestanding -c -x cpp-output aborts.c
  $ undefined $clang aborts.o | comm -23 - declared
  abort
