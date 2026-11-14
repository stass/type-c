SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

typec agrees with its backends on the lengths that initialisers give
arrays of unknown size (C11 6.7.9p22) and on the types of compound
literals. initialisers.c declares such arrays at file scope and in
blocks, with static assertions on their sizes that the backend checks,
and names each in an expression statement, after which expression_probe
writes a static assertion of the type that typec gives it, the length
included. The backends are those that backends.sh names, on an x86-64
host so that -m32 gives a second target.

  $ probe() {
  >   "$@" -std=gnu11 -dM -E -x c /dev/null > macros &&
  >   "$@" -std=gnu11 -E initialisers.c > initialisers.i &&
  >   ../expression_probe.exe macros initialisers.i > probe.c &&
  >   "$@" -std=gnu11 -w -fsyntax-only probe.c
  > }
  $ . ../backends.sh
  $ probe "$clang"
  $ probe "$clang" -m32 -funsigned-char
  $ probe "$gcc"
  $ probe "$gcc" -m32 -funsigned-char
