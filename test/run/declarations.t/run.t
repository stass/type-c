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
