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
- [Low] When a stage reads the target model during a compilation, query
  it (`Target_query.query`) with the options of the compile step of
  `Pipeline` (its Common and Dialect options and the `-std=` default), so
  that the model and the compilation see the same options.
- [Medium] A command that compiles a `.tc` input and links loses the
  side outputs of the compile step, which are written next to the
  temporary object and removed with it: with `-g` on macOS the debug
  information (Clang runs `dsymutil` for a one-step build, the final
  command links objects and does not), and the `.dwo` files of
  `-gsplit-dwarf` and GCC's `-fstack-usage` and `-fcallgraph-info`
  files. Run `dsymutil` when the backend would, or keep the objects
  beside the output.
- [Medium] Several `-arch` options make the `-E` step fail ("cannot use
  'cpp-output' output with multiple -arch options"), where cc builds a
  universal object. Refuse them with a `.tc` input with a clear message,
  or run one translation per architecture and join the objects with
  `lipo`.
- [Low] The steps of the pipeline get `-Wno-unused-command-line-argument`
  so that Clang does not warn about the options of the whole command
  line that a step does not use; GCC ignores it, but adds a note that
  names it to any diagnostic of that step. Pass it to Clang only once
  the driver knows the backend's family.
- [Low] The pipeline stops at the first `.tc` input that fails, where cc
  compiles every input and reports every error.
- [Low] GCC names the dependency file of a link without `-o` `a-x.d`;
  `typec` names it `x.d`, as Clang does.
- [Low] The option table leaves out GCC's unique abbreviations of long
  options (`--for-link X`), the options of GCC's other front ends, and
  Apple Clang's `-cc1-args`, which takes the rest of the line.
- [Medium] `test/run/target.t`, `test/run/read.t`, `test/run/types.t`,
  `test/run/pipeline.t` and `test/run/parse.t` run `/usr/bin/clang` and
  `/usr/local/bin/gcc-16`, and `target.t` expects the model of the x86-64
  macOS host. Choose the backends and the expected facts per host once
  the Linux and FreeBSD test hosts exist; `types.t` then confirms the
  provisional enumeration rule (`Arithmetic.enum_compatible_type`) on
  each.
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
- [Medium] `Target.integer_width` raises `Invalid_argument` for the
  `__int128` types on a target without them, and `Ctype.integer` builds
  such a type on any target, so a type that reaches the promotions there
  stops the compiler. Before the declaration code and the builtin table
  can name `__int128`, make one constructor that takes the target the
  only way to build the type.
- [Medium] Backend options that change C's types without changing a
  predefined macro make the model wrong without a message:
  `-fshort-enums` (the integer type of enumerations) and
  `-funsigned-bitfields` (plain `int` bit-fields, which
  `Arithmetic.promote` takes as signed). Reject them in the driver or
  find a probe that reads them.
- [Low] GCC and Clang promote bit-fields of types ranked above `int`
  differently (`Arithmetic.promote`): GCC keeps `long : 32` on ILP32 as
  `long`, and gives `unsigned long : 40` on LP64 a 40-bit type whose
  arithmetic wraps at 2^40. typec follows Clang. Decide whether the
  target model records the backend family, or whether such bit-fields
  are an error.
- [Low] The target query gives the backend typec's stdin, which it never
  needs; a stray `-` among the options makes it read the terminal. Give
  it `/dev/null`.
- [Low] An empty macro dump, as from `--print-target -o FILE`, reports
  one missing macro chosen by record field evaluation order. Report an
  empty dump as such.

## Reader of preprocessed text

- [Medium] `Number.classify` finds no constant in a number with a
  floating suffix of the `_Float` types (`f16`, `f32`, `f64`, `f128`,
  `f32x`, `f64x`, `bf16`), GCC's `q`, `w` and `d`, or the decimal
  floating suffixes `df`, `dd` and `dl`. Decide which the GNU profile
  accepts once it has those types (0.7), and how `floating_type` names
  them.
- [Medium] `Number.classify` says which constant a number is but not
  where its digits end, and the type of an integer constant depends on
  its value (C11 6.4.4.1). When constant evaluation needs the value,
  have the classifier return the digits too, so that the grammar of a
  constant stays in one place.
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
  main file, which is not a system header. The driver refuses both with
  a `.tc` input, but `-Wp,-P` and `-Xpreprocessor -P` still reach the
  `-E` step, and so do `-C` and `-dD` that way, which the reader refuses
  with a message about the text instead of the option. Classify the
  options inside `-Wp,` and `-Xpreprocessor` with the same table, or
  make the reader refuse output without a line marker before its first
  token.
- [Medium] Tokens record the owner but not the flags of the last line
  marker, so a file after `#pragma GCC system_header` is not a system
  header to typec. The markers that the emitter writes around an edit
  carry no flags, and both GCC and Clang turn the system header state
  off at a marker without flag 3, so lowered text in a system header (a
  `.tci` found through `-isystem`) ends that state for the rest of the
  header. Add the flags in effect to `Location.t` and repeat them in
  those markers when Stage 1 lowers such text.
- [Low] Diagnostics of later stages print names and spellings from the
  text; route them through the escaping of `Reader.error_message`, and
  cut a quoted spelling, such as a number that is no constant, to a
  bounded length so that a huge token cannot make a huge message.
- [Low] `#ident` and `#sccs`, which `cc -E` passes through, are refused
  as unsupported directives. Pass them through like a pragma if a corpus
  uses them.

## Parser

- [Medium] The parser reads chains in loops (left-associative binary
  operators, the comma operator, postfix operators, casts and the prefix
  operators, assignments, the last operands of conditionals, and the
  pointer, array and function derivations of a declarator), so a chain is
  not
  bounded by `Parser.max_nesting`, and its tree is as deep as it is long.
  A pass that recurses over the tree, such as typing (0.9) or the test
  dump, can exhaust the stack on a long chain. Before 0.9, either count
  chain length against the bound or have such passes walk chains in
  loops.
- [High] The parser's recursion is bounded because it recurses only
  inside a bracket or a `?` that the cursor counts. Statements (0.6)
  recurse without one (`if (a) if (b) ...`, `while`, labels), so 0.6
  must read those in loops or count them against the same bound, and add
  them to the nesting tests in `test/unit/test_parser.ml`.
- [Medium] The parser does not check the constraints on what it accepts:
  combinations of type specifiers (C11 6.7.2p2) and storage classes
  (6.7.1p2), qualifiers, `static` and `[*]` outside the outermost array
  derivation of a parameter (6.7.6.2p1), identifier lists outside a
  definition (6.7.6.3p3), alignment specifiers outside the places of
  6.7.5p2, storage classes other than `extern` and `static` in a function
  definition (6.9.1p4; `typedef int f(void) { }` makes `f` a typedef
  name). Check them where types are built (0.8, 0.9).
- [Medium] The prototype scope of a function declarator ends at its `)`.
  Everything a definition's parameter list declares, enumerators
  included, is in scope in its body (6.2.1p4): with `typedef int A;`,
  `int f(enum { A } x) { A * y; }` multiplies. When 0.6 reads bodies,
  keep the scope at the `)` of the function derivation applied to the
  name (the one `declares_function` finds) and parse the body in it,
  rather than declaring the parameters again from the tree.
- [Medium] The parser decides typedef names by C's scope rules (6.2.1)
  with its own scope map and start points, and typing (0.9) must resolve
  the same identifiers by the same rules. Before 0.9, have the parser
  record what each identifier resolved to, or share one scope module, so
  that the rules have one implementation.
- [Medium] GCC and Clang accept in their GNU modes, and the parser
  refuses, a lone `;` at file scope, empty initialiser braces `{}` and a
  struct or union without members. Add them to the GNU profile (0.7)
  with the constructs its row names.
- [Low] `Tree.Constant` holds a `Number.t` that is never
  `Not_a_constant`. Have `Number.classify` return an option, so that the
  tree cannot represent the case.
- [Low] The parser passes over `#pragma typec` lines like other
  pragmas, and they stay inside the spans of the nodes around them, so
  emission copies them to the backend. Stage 5, which gives them a
  meaning, decides where they may stand and what emission does with
  them.
- [Low] `Parser.error` is `Reader.error`, whose documentation describes
  text that is not `cc -E` output. When a third stage reports located
  errors, give the type a module of its own.

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
