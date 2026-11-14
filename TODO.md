<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# TODO

Work that is worth doing and is not a work package of
[type-c-implementation-plan.md](type-c-implementation-plan.md). "Design"
is [type-c-language-design.md](type-c-language-design.md).

## Before Stage 0 starts

- [High] Verify GCC as a backend: the lowering of design 13.5 under
  `-std=c11 -pedantic-errors`, including a constructor nested in a static
  initialiser, and `-E -x c` followed by `-x cpp-output`. Only Clang has
  been tried.
- [High] Check the licence and provenance of each corpus and pilot
  candidate named in the plan before fetching any of them.
- [Medium] Decide where the Linux and FreeBSD test hosts run, and create
  the repository that pins corpora and holds pilots.

## Driver

- [Medium] A backend that resolves to `typec` itself, such as a `cc`
  symlink to `typec` first on `PATH`, makes the driver exec itself forever
  with no message. Detect it, or document how to install `typec` as `cc`.
- [Low] When `.tc` inputs are recognised, the driver must know which C
  compiler options take a separate value, so that `-o --cc=x` or
  `-o x.tc` is not misread; keep that table in one place.
- [Low] `Unix.execvp` hands an executable without a `#!` line to
  `/bin/sh` with glibc, macOS and FreeBSD libc but not with musl, so such
  a backend works on some hosts only. Document it or decide one behaviour.

## Design questions without a gate yet

- [High] Write the formal model for checked-mode lifetimes before any
  implementation of tier 2 (design 11.3). Nothing about lifetimes may be
  claimed until it exists.
- [Medium] Specify the instance-name encoding for every type of the GNU
  profile (`__int128`, the `_Float` types, vector types) and for block
  pointers (design 10.3).
- [Medium] Decide whether to offer an option that zeroes padding and the
  inactive part of a variant on construction, against disclosure of stale
  memory (design 10.1 rule 5).
- [Medium] Nested patterns need a rule that tells a binding from a
  constructor without fields; a misspelled constructor must not become a
  catch-all binding (design 12).
- [Medium] Define which GNU attributes the front end must understand
  rather than merely carry: `noreturn` for reachability, and any that
  change a type.
- [Medium] Header macros that collide with constructor names, such as
  `None` in the X11 headers, break those constructors with an obscure
  error. Find a way to report the macro (design 3.3).
- [Low] Decide whether a small library of `.tci` files (vector, map,
  region) ships with the compiler or stays a test.
- [Low] Consider C2y named loops (`break name;`) as the way to leave an
  outer `match` or loop from an inner one, once backends accept them.
