SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec agrees with its backends on the declarations of C. declaration_probe
reads the target model from a backend's predefined macros and the
preprocessed declarations.c, and writes the text followed by static
assertions of the types and values typec computes for that target. The
backend compiles the result only if it agrees on every one. The backends
are those that backends.sh names, for two targets (its second_target); the
warnings that these declarations draw are not of interest here.

  $ probe() {
  >   "$@" -std=gnu11 -dM -E -x c /dev/null > macros &&
  >   "$@" -std=gnu11 -E declarations.c > declarations.i &&
  >   ../declaration_probe.exe macros declarations.i > probe.c &&
  >   "$@" -std=gnu11 -w -fsyntax-only probe.c
  > }
  $ . ../backends.sh
  $ probe "$clang"
  $ probe "$clang" $second_target
  $ probe "$gcc"
  $ probe "$gcc" $second_target

A function type keeps the qualifiers of its return type in Clang, and
GCC drops all but _Atomic of them (C17 6.7.6.3p5), so Clang refuses
these declarations and GCC accepts them. typec refuses the two that it
checks with Clang as the backend and leaves them to GCC with GCC; both
backends check the initialiser of a pointer.

  $ printf 'const int cf(void);\nint cf(void);\n' > redeclared.tc
  $ printf 'typedef const int F(void);\ntypedef int F(void);\n' > typedef.tc
  $ printf 'const int cf(void);\nint (*p)(void) = cf;\n' > pointer.tc
  $ typec --cc="$clang" -c redeclared.tc -o redeclared.o
  typec: redeclared.tc:2: 'cf' is redeclared with an incompatible type (C11 6.7p4)
  [80]
  $ typec --cc="$clang" -c typedef.tc -o typedef.o
  typec: typedef.tc:2: 'F' is redefined as a typedef of another type (C11 6.7p3)
  [80]
  $ typec --cc="$clang" -c pointer.tc -o pointer.o 2> /dev/null || echo refused
  refused
  $ typec --cc="$gcc" -c redeclared.tc -o redeclared.o
  $ typec --cc="$gcc" -c typedef.tc -o typedef.o
  $ typec --cc="$gcc" -c pointer.tc -o pointer.o
