SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec agrees with its backends on the types of expressions. expression_probe
reads the target model from a backend's predefined macros and the
preprocessed expressions.c, and writes the text with static assertions of
the type typec gives each expression statement of a body, and a use of
the address of each that it calls an lvalue. The backend compiles the
result only if it agrees on every one. The backends are those that
backends.sh names, on an x86-64 host so that -m32 gives a second target;
the warnings that these expressions draw are not of interest here.

  $ probe() {
  >   "$@" -std=gnu11 -dM -E -x c /dev/null > macros &&
  >   "$@" -std=gnu11 -E expressions.c > expressions.i &&
  >   ../expression_probe.exe macros expressions.i > probe.c &&
  >   "$@" -std=gnu11 -w -fsyntax-only probe.c
  > }
  $ . ../backends.sh
  $ probe "$clang"
  $ probe "$clang" -m32 -funsigned-char
  $ probe "$gcc"
  $ probe "$gcc" -m32 -funsigned-char
