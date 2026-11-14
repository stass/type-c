SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec agrees with its backends on the types of C. type_probe reads the
target model from a backend's predefined macros and writes static
assertions of what typec computes for that target: the integer promotions,
those of bit-fields, the usual arithmetic conversions, the integer type of
enumerations and the compatibility of pairs of types. The backend compiles
the file only if it agrees on every one. The backends are those that
backends.sh names, on an x86-64 host so that -m32 gives a second
target, in C11 so that `int ()` declares no prototype.

  $ probe() {
  >   "$@" -std=gnu11 -dM -E -x c /dev/null > macros &&
  >   ./type_probe.exe macros > probe.c &&
  >   "$@" -std=gnu11 -fsyntax-only probe.c
  > }
  $ . ./backends.sh
  $ probe "$clang"
  $ probe "$clang" -m32 -funsigned-char
  $ probe "$gcc"
  $ probe "$gcc" -m32 -funsigned-char
