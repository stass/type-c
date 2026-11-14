<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# TODO

Work that is worth doing and is not a work package of
[type-c-implementation-plan.md](type-c-implementation-plan.md). "Design"
is [type-c-language-design.md](type-c-language-design.md).

## Before Stage 0 starts

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
  `-o x.tc` is not misread; keep that table in one place. The same table
  chooses the options of the target query (`Target_query.query`): those
  of the compilation without its inputs, `-o`, `-c`, `-S`, `-E` and the
  `-M` family, plus the `-std=` that design 2.4 adds, so that the model
  and the compilation see the same options.
- [Medium] `test/run/target.t` and `test/run/read.t` run `/usr/bin/clang`
  and `/usr/local/bin/gcc-16`, and `target.t` expects the model of the
  x86-64 macOS host.
  Choose the backends and the expected facts per host once the Linux and
  FreeBSD test hosts exist.
- [Low] `Unix.execvp` hands an executable without a `#!` line to
  `/bin/sh` with glibc, macOS and FreeBSD libc but not with musl, so such
  a backend works on some hosts only. Document it or decide one behaviour.

## Target model

- [Medium] `Target.of_predefined_macros` accepts any positive sizes and
  any integer type behind each typedef, so a wrong backend can give
  `char_bit: 1` or a signed `size_t`. Before constant evaluation reads
  the model, check C's guarantees once there (`CHAR_BIT >= 8`, minimum
  widths and the order short <= int <= long <= long long, a cap on sizes,
  unsigned `size_t`, `uintmax_t`, `char16_t` and `char32_t`, signed
  `ptrdiff_t`, `intmax_t` and `intptr_t`), preferably by separate signed
  and unsigned types for the typedef fields, and make `Target.t` private.
- [Low] The target query gives the backend typec's stdin, which it never
  needs; a stray `-` among the options makes it read the terminal. Give
  it `/dev/null`.
- [Low] An empty macro dump, as from `--print-target -o FILE`, reports
  one missing macro chosen by record field evaluation order. Report an
  empty dump as such.

## Reader of preprocessed text

- [Medium] The reader refuses the floating suffixes of the `_Float`
  types (`f16`, `f32`, `f64`, `f128`, `f32x`, `f64x`, `bf16`) and GCC's
  `q` and `w`, which the GNU profile needs once it has those types (0.7).
- [Medium] A token records the file it belongs to, not the inclusion:
  two inclusions of one header have one owner. Design 11.1 keeps the
  checked state per file and does not carry it into or out of an
  included file, so the checker needs the inclusion boundaries; decide
  whether tokens carry an inclusion number or the parser tracks the
  owner changes.
- [Medium] Raw string literals (`R"x(...)x"` with any encoding prefix),
  which Clang and GCC accept in gnu11, are misread: as an identifier and
  a string, as an unterminated literal, or with their inner lines taken
  as directives. Lex them, counting their newlines.
- [Medium] With `-P` or Clang's `-fuse-line-directives` the `-E` output
  has no enter and return flags, and every token silently belongs to the
  main file, which is not a system header. The driver must keep both
  options out of its `-E` run, or the reader must refuse such output.
- [Medium] Tokens record the owner but not the flags of the last line
  marker, so a file after `#pragma GCC system_header` is not a system
  header to typec, and the emitter (0.3) cannot repeat the flags in
  effect in the markers it writes for lowered code; GCC turns the system
  header state off at a marker without flag 3. Add the flags in effect
  to `Location.t` when the emitter needs them.
- [Medium] `Token.Punctuator` keeps only the spelling, so the parser
  (0.5) must map `<:`, `<%`, `%:` and `%:%:` itself. Give the kind one
  constructor per punctuator, digraphs mapped to their canonical form,
  from the table the reader matches.
- [Low] Diagnostics of later stages print names and spellings from the
  text; route them through the escaping of `Reader.error_message`.
- [Low] `#ident` and `#sccs`, which `cc -E` passes through, are refused
  as unsupported directives. Pass them through like a pragma if a corpus
  uses them.

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
