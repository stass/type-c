SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec agrees with its backends on the types of expressions. expression_probe
reads the target model of a backend, as typec reads it, and a
preprocessed file, and writes the text with static assertions of the type
typec gives each expression statement of a body, and a use of the address
of each that it calls an lvalue. The backend compiles the result only if
it agrees on every one. The files are expressions.c and builtins.c, which
calls the builtins that a rule types or whose type is unknown, also in
C23 for its va_start. The backends are those that backends.sh names, for
two targets (its second_target); the warnings that these expressions
draw are not of interest here.

  $ check() {
  >   std=$1 source=$2
  >   shift 2
  >   "$@" $std -E $source.c > $source.i &&
  >   ../expression_probe.exe $source.i "$@" $std > probe.c &&
  >   "$@" $std -w -fsyntax-only probe.c
  > }
  $ probe() {
  >   check -std=gnu11 expressions "$@" && check -std=gnu11 builtins "$@"
  > }
  $ . ../backends.sh
  $ probe "$clang"
  $ probe "$clang" $second_target
  $ probe "$gcc"
  $ probe "$gcc" $second_target
  $ check -std=gnu23 builtins "$clang"
  $ check -std=gnu23 builtins "$gcc"

builtin_probe writes a call of each builtin of the table that has a
prototype and that the backend has, with arguments of its parameter
types, and a second call with an extra argument where it is variadic.
A pointer parameter that the table gives a wrong referenced type, or a
qualifier that the builtin's lacks, draws a warning, which the options
make an error; one that lacks a qualifier of the builtin's, and a
parameter of another type, draw none. expression_probe asserts the types
of the calls. builtins.c calls each builtin of the table that has no
prototype, and each that the table gives to the other compiler only is
undeclared in the backend.

  $ builtins() {
  >   cc=$1 errors=$2
  >   shift 2
  >   ../builtin_probe.exe calls "$cc" "$@" -std=gnu11 > calls.c &&
  >   "$cc" "$@" -std=gnu11 -E calls.c > calls.i &&
  >   ../expression_probe.exe calls.i "$cc" "$@" -std=gnu11 > probe.c &&
  >   "$cc" "$@" -std=gnu11 $errors -fsyntax-only probe.c 2> log ||
  >     grep error: log
  >   ../builtin_probe.exe others "$cc" "$@" -std=gnu11 | while read -r name; do
  >     grep -q -E "(^|[^A-Za-z0-9_])$name\(" builtins.c ||
  >       echo "builtins.c does not call $name"
  >   done
  >   ../builtin_probe.exe unavailable "$cc" "$@" -std=gnu11 |
  >   while read -r name; do
  >     printf 'void f(void) { %s(); }\n' "$name" > one.c
  >     LC_ALL=C "$cc" "$@" -std=gnu11 -fsyntax-only one.c 2>&1 |
  >       grep -q -E 'unknown builtin|implicit declaration' ||
  >       echo "$name is a builtin of the backend"
  >   done
  > }
  $ builtins "$clang" -Werror=incompatible-pointer-types
  $ builtins "$clang" -Werror=incompatible-pointer-types $second_target

Clang offers some builtins on some architectures only, such as
__builtin_setjmp, which it lacks on AArch64. The calls need no header, so
a target of another architecture needs no sysroot.

  $ builtins "$clang" -Werror=incompatible-pointer-types \
  >   --target=aarch64-linux-gnu
  $ builtins "$clang" -Werror=incompatible-pointer-types \
  >   --target=armv7-none-eabi

The backend refuses each call that the table withholds on the
architecture.

  $ withheld() {
  >   ../builtin_probe.exe withheld "$clang" "$@" -std=gnu11 > withheld.c &&
  >   "$clang" "$@" -std=gnu11 -fsyntax-only withheld.c 2>&1 |
  >     grep -o '__builtin_[a-z0-9_]* is not supported for the current target'
  > }
  $ withheld --target=aarch64-linux-gnu
  __builtin_setjmp is not supported for the current target
  __builtin_longjmp is not supported for the current target
  $ gcc_errors='-Werror=incompatible-pointer-types -Werror=discarded-qualifiers'
  $ builtins "$gcc" "$gcc_errors"
  $ builtins "$gcc" "$gcc_errors" $second_target
