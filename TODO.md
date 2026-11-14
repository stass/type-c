<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# TODO

Work that is worth doing and is not a work package of
[type-c-implementation-plan.md](type-c-implementation-plan.md). "Design"
is [type-c-language-design.md](type-c-language-design.md).

## Before Stage 0 starts

- [High] Check the licence and provenance of each pilot candidate named
  in the plan before fetching any of them.
- [Medium] Decide where the Linux and FreeBSD test hosts run, and where
  the corpus repository is hosted: it exists locally at
  `/Volumes/Optaine/type-c-corpus`, with no remote, and its README says
  what it holds.

## Driver

- [Medium] A backend that resolves to `typec` itself, such as a `cc`
  symlink to `typec` first on `PATH`, makes the driver exec itself forever
  with no message. Detect it, or document how to install `typec` as `cc`.
- [Low] `Target_query.query` starts and waits for the backend itself,
  so in a compilation it hands the backend `typec`'s stdin, not
  `/dev/null`, and does not pass on a caught signal as `Process.wait`
  does: a wrapper backend that blocks or reads stdin during the dump
  delays the signal or takes the stdin of a `-` input. Run it through
  `Process` with the step's stdin.
- [Low] Options that name a side output after the input
  (`-fdiagnostics-format=sarif-file`, Clang's `-gen-cdb-fragment-path`)
  make the target query write one for `/dev/null` and the compile step
  one for the temporary emitted file. Run the steps in the temporary
  directory, or document it.
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

- [Low] `Target.t` is a public record, so code can build a model that
  skips the checks of `Target.of_predefined_macros`. Make it private,
  preferably with separate signed and unsigned types for the typedef
  fields, once the tests build their models from dumps only.
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
  operators, assignments, the last operands of conditionals, the
  pointer, array and function derivations of a declarator, and the
  statements that end in a substatement: `if (a) if (b) ...`, `else if`
  chains, loops and labels), so a chain is not bounded by
  `Parser.max_nesting`, and its tree is as deep as it is long. A pass
  that recurses over the tree can exhaust the stack on a long chain: the
  constant evaluator of `Declarations` counts its depth against
  `max_expression_depth`, and expression typing (0.9b) and the test dump
  must count too or walk chains in loops.
- [Medium] Nothing checks the constraints of statements that the parser
  accepts: the storage classes of a `for` declaration (6.8.5p3), `case`
  and `default` outside a `switch` (6.8.1p2), `break` and `continue`
  outside a loop (6.8.6.2p1, 6.8.6.3p1), duplicate and missing labels
  (6.8.1p3, 6.8.6.1p1) and `return` with or without a value (6.8.6.4p1),
  and the GNU label rules: a label address (`&&a`) outside a function
  body, a duplicate or undefined `__label__` label, `&&a` as a use of
  `a`, and a jump into a statement expression from outside it. Check
  them where bodies are typed (0.9b). `Declarations` checks those of
  declarations.
- [High] One implementation of the scope rules (6.2.1), step 2: the
  parser drives `Parser.scopes`, and `Parser.parse` uses syntactic rules
  of its own, while `Declarations` keeps its own scope boundaries, so
  where a scope starts and ends is still implemented twice. Make the
  declaration reader an implementation of `Parser.scopes` that declares
  enumerators and tags when the parser hands them over; tags need a new
  case of `Parser.scoped_declaration`, at the point where a tag enters
  scope (6.2.1p7).
- [High] Scope rules, step 3: the reader declares parameters,
  declarators and the re-entered scope of a function body when the
  parser hands them over; block-scope entities are bound by kind only,
  untyped, until 0.9b types bodies. A `Declarator` is handed over before
  the parser knows whether a function definition follows, so the rules
  on defining an identifier twice (6.7p3, 6.9p3) need a separate event
  for a definition; and every declarator of a declaration carries the
  same specifiers, so a tag they define must enter scope once, through
  the tag case of step 2, not once per declarator.
- [High] Scope rules, step 4: the type names inside expressions (casts,
  `sizeof`, compound literals) declare their tags and enumerators
  through the same interface.
- [High] Scope rules, step 5: delete the reader's own scope boundaries:
  `within_scope`, its use of `Scope.reenter`, and the scope of
  `read_parameters`.
- [Medium] GNU forms that common code uses and the profile leaves out,
  each an error that names its first token: `__real__` and `__imag__`,
  `__builtin_types_compatible_p`, `__alignof__` of an expression, block
  literals (`^{ ... }`), an extra `;` in a member list, attributes in a
  pointer's qualifier list (`int *__attribute__((aligned(8))) p`) and at
  the start of a parenthesized declarator, attributes before a declarator
  after the first (`int a, __attribute__((unused)) b;`), and attributes
  after a label or before a statement other than `;` (`case 1:
  __attribute__((fallthrough));`, `__attribute__((musttail)) return`).
  Decide which belong to the profile (design 13.3) before the corpus
  sweep (0.11) finds them.
- [Medium] `asm` and `typeof` are keywords in every dialect, as in
  gnu11, the default; under `-std=c11` GCC and Clang read them as
  identifiers, so a C11 program that declares `typeof` or `asm` does not
  parse. Either pass the dialect to the parser and select the keyword
  table by it, or document the restriction in design 2.4.
- [Low] The parser accepts GNU forms that GCC and Clang refuse: a
  statement expression outside a function, a range designator in
  `__builtin_offsetof`, a repeated asm qualifier, a labels section of
  `asm` without `goto`, and qualifiers and operands on file-scope `asm`.
  Check them with the other constraints (0.9b).
- [Low] `__alignof__` is `_Alignof` in the tree, but GCC and Clang give
  the preferred alignment for it, which differs from `_Alignof` on i386
  (`double`, `long long`). No supported target has the difference;
  revisit if one does.
- [Low] `Tree.Constant` holds a `Number.t` that is never
  `Not_a_constant`. Have `Number.classify` return an option, so that the
  tree cannot represent the case.
- [Low] The parser passes over `#pragma typec` lines like other
  pragmas, and they stay inside the spans of the nodes around them, so
  emission copies them to the backend. Stage 5, which gives them a
  meaning, decides where they may stand and what emission does with
  them.
- [Low] `Parser.error` and `Declarations.error` are `Reader.error`,
  whose documentation describes text that is not `cc -E` output. Give
  the located error a module of its own in `typec_cpp`.

## Declarations

- [Medium] `Declarations` accepts the GNU attributes of a table that
  gives each one's effect (`attribute_effects`): `noreturn` and
  `gnu_inline` mark a function, the rest change no type or constant it
  computes. It refuses every other one, `packed`, `mode`, `vector_size`
  and Clang's `overloadable` among them, so the SDK's `tgmath.h` is refused.
  The table is the answer to the design question on attributes until
  0.7b reads them; `aligned` is on it only while record layout is the
  backend's. `noreturn` on a pointer to a function or on a function
  typedef is not recorded, though GCC and Clang make it part of the type
  and treat a call through it as not returning. The table checks no
  attribute's arguments (`noreturn(1)` is accepted). The rest of the GNU
  profile that no type models (`_Float16`, `typeof`, block pointers,
  fixed enumeration types) is an error that names it.
- [Medium] Attributes inside what the reader does not read, such as an
  initialiser or the operand of `sizeof`, are not checked against the
  table. Checking them in the parser, where every attribute is made,
  would cover every position by construction; the reader's full record
  patterns cover only the positions it reads, and not a field read by
  projection.
- [Low] `struct s;` alone declares a new tag (6.7.2.3p7) by GCC's
  reading in `Declarations` (attributes on either side, no qualifier or
  storage class), which Clang reads differently: it requires the `;`
  right after the tag and allows qualifiers and storage classes before
  it. Only block scope shows the difference; decide which to follow, and
  test it, when block-scope declarations are read.
- [High] The reader accepts everything the parser parses, entering
  what it cannot type yet with an opaque type, so that the scope rules
  of steps 2 to 5 run on every translation unit the parser reads. It
  refuses `_Float16`, `typeof` and block pointers.
- [Medium] `Function.gnu_inline` records the attribute, under which an
  inline definition is external unless it says `extern inline` (GNU89),
  in place of C11 6.7.4p7, but nothing reads it. Whatever decides
  which inline definition is external (the rule on one external
  definition, 6.9p5, and any emission or lowering of an inline function)
  must honour it. Two `inline` declarations that disagree on it are
  merged, as Clang does; GCC refuses them, and the backend reports it.
- [Medium] `__builtin_va_list` is opaque (design P20): a `va_list`
  parameter is not adjusted to a pointer where the target's `va_list` is
  an array (x86-64), and it is compatible only with itself. The reader
  accepts `int f(va_list); int f(const va_list);`, which x86-64 refuses
  and leaves to the backend, and refuses `int g(va_list); int g(char
  *);`, which i386 and arm64 Darwin accept. Typing `__builtin_va_arg`
  and bodies (0.9b, 0.7b) must check that no expression needs more:
  `&ap` of a parameter (`va_list *` on arm64, not on x86-64),
  `char *p = ap;` and `va_copy` are the cases to try. If one does, the
  representation must come from the backend (a target table is ruled
  out by design 13.3).
- [High] Initialisers are not read: an array of unknown size keeps its
  incomplete type where its initialiser completes it (6.7.9p22), and the
  tags and enumerators that an initialiser declares, inside `sizeof` or a
  cast, are not declared. Read initialisers with compound literals
  (0.9b), which need the same rule.
- [Medium] In an integer constant expression `sizeof` of an expression
  is opaque, without a check of its operand, and `_Generic` is an error,
  because only 0.9b types expressions. Take both from expression typing
  there, so that `sizeof x` of a scalar `x` has its value and that of a
  variable length array is no constant (6.5.3.4p2).
- [High] Before 0.9b reads function bodies, decide how a body sees the
  translation unit at its own point. `body_scope` is a persistent
  snapshot, but `Ctype.tags` is one mutable table in its state at the end
  of the file, so in `struct s; void f(void) { sizeof (struct s); }
  struct s { int a; };` the structure would look complete inside `f`.
  Either record completion in the scope or type each body during `read`.
- [High] 0.9b needs a table of the objects and functions with linkage
  that does not depend on scope (6.2.2p4, 6.2.7p2): a block-scope
  `extern int x;`, even where the file-scope `x` is hidden, denotes the
  same entity and merges its composite type. `Declarations.t` should
  carry it.
- [Medium] An `entity` and an `item` carry no location or tree node, so
  no message can point at a previous declaration and a consumer lines
  `items` up with the tree by position; and the parameter frame of
  `body_scope` is a map, which loses the order of the parameters that
  lowering needs. Add both when 0.9b or Stage 1 first needs them.
- [Medium] `derive` reads a declarator outside in, so array lengths and
  parameter lists are read from last to first, against the order of
  scopes (6.2.1p7): `int a[sizeof (enum { A = 2 })][A];` finds `A`
  undeclared, which both backends accept. Walk from the name outward
  first, collecting the derivations, then apply them in reverse; that
  also removes `applies_to_name`.
- [Low] `specified.storage` holds a `Tree.storage_class`, which can say
  `_Thread_local` although `storage_class` never puts it there. Give it a
  type without that case.
- [Low] `Declarations` refuses some code that both backends accept with
  a warning: `sizeof (void)` and `sizeof` of a function type, unknown
  escape sequences such as `'\q'`, `_Complex` alone and `_Complex int`
  (the last two for the GNU profile, 0.7).
- [Medium] GCC and Clang fold floating arithmetic in an array length, an
  enumerator value or a bit-field width (`(int)(1.5 * 2)`), and accept a
  signed overflow there with a warning (`INT_MAX + 1`). `Declarations`
  follows C11 (6.6p6, p4) and refuses both. If the corpus (0.11) has
  them, decide whether the GNU profile folds them.
- [Medium] Evidence for P16 (no aggregate layout), for the Stage 0 gate.
  The places where the declarations need a layout value and leave it to
  the backend as `Integer_constant.Opaque`: an array length of the size
  of a structure, union or array (`char b[sizeof (struct s)]`, the
  `sizeof a / sizeof a[0]` idiom), which gives `Ctype.Opaque`, compatible
  with every constant length, so typec misses a conflict such as
  `int a[sizeof (struct s)]; int a[4];`; an enumerator value from a size
  (`enum { SIZE = sizeof (struct s) }`, a common idiom), which is an
  error, as it decides the integer type of the enumeration and the types
  and sizes that follow; a bit-field width from a size, which is an
  error; a `_Static_assert` on a size, which passes through unchecked;
  `offsetof`, which GCC and Clang expand to `__builtin_offsetof` (0.7). The target model has no
  alignments and no size of `_Bool` or of an atomic type, so `_Alignof`
  of any type and those sizes are opaque too, although they are not
  aggregates. How often real code needs each is for the corpus to show.

## Fuzzing

- [Low] The parser test sets its 32K-word stack with `OCAMLRUNPARAM=l=32k`
  in `test/unit/dune`, apart from `Small_stack.limit_words`, which the
  fuzz harness runs the parser under. Run the parser test through
  `Small_stack.run` once the parser's scope rework has landed, so that
  one value says how deep the parser may recurse.

- [High] Decide where the OCaml AFL shm patch lives and offer it
  upstream. AFL++ on macOS hands the coverage map over only as a POSIX
  shared memory descriptor (`__AFL_SHM_FD`), and the runtime of OCaml
  (`runtime/afl.c`, 5.5.2 and trunk) attaches only a SysV segment, so
  the fuzz build needs a patched compiler (README, "Fuzzing"). The patch
  modifies LGPL sources and is kept outside this repository.

## Corpus

The front end refuses 65 of the 246 units of the corpus with Clang and
8 with GCC 16 (macOS x86-64); the first errors are below. With
`-fno-blocks` Clang refuses the 8 that GCC does. Reproducers are in
`/Volumes/Optaine/type-c-corpus-cache/probe/front-end-tail`.

- [High] With Clang, the SDK's `__BLOCKS__` declarations declare block
  pointers (`_stdlib.h:298`, `glob.h:61`): 59 units, all of zlib, qbe
  and chibicc among them, none with `-fno-blocks` (0.7b).
- [High] `math.h:645` declares `_Float16` functions: 6 lua units and
  sqlite's shell on each backend (0.7b).
- [Medium] `sqlite3.c` includes SDK headers that declare enumerations
  with a fixed type (`malloc/malloc.h:92` with GCC, `mach/port.h:417`
  with Clang under `-fno-blocks`): 1 unit on each backend (0.7b).
- [High] Pin the rest of the corpus of plan 0.11 in the corpus
  repository, each with its licence recorded there: musl (MIT, without
  `src/string/aarch64`, which has its own terms), programs generated by
  Csmith (BSD-2-Clause; its runtime headers keep the University of Utah
  notice), GCC's `c-torture/execute` (GPL-3.0 or later: the repository
  names the archive and holds no file of it), and the translation unit
  that includes every standard and POSIX header of a host.
- [Medium] SQLite's recipe runs a smoke test of ours: the amalgamation
  has no test suite. Its own suite needs the full source tree and Tcl.
- [Medium] chibicc's recipe runs its test suite only on Linux x86-64,
  which has not run yet; on other hosts its tests are only compiled to
  assembly.
- [Low] A `typec` option that compiles a `.c` input as Type-C would let
  a program's own build replace `cc` with `typec` without renaming its
  sources. The corpus runner copies each unit to a `.tc` file next to
  it instead, which also makes `__FILE__` name the copy.
- [Low] The corpus runner waits for every command without a time
  limit, so a test or a compile that hangs stops the run.
- [Low] A run record names `typec` by the revision of the checkout its
  binary sits in and by the binary's digest. `typec --version`, printing
  the revision it was built from, would name it exactly.
- [Low] The corpus runner's reference recipe repeats what
  `src/driver/pipeline.ml` passes to the backend (`-D__TYPEC__=1`, the
  default `-std=gnu11`), as `test/run/pipeline.t` does.

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
  rather than merely carry (the tree holds each one's name and its
  argument tokens unread). The macOS headers use four that typing needs:
  `aligned`, which changes a layout; `noreturn`, for reachability,
  which `Declarations` records on a function; Clang's `overloadable`,
  without which the SDK's `tgmath.h` declares one function with
  conflicting types; and `gnu_inline`, which changes what an inline
  definition defines (`sys/cdefs.h` uses it under GCC, not Clang) and
  which `Declarations` records on a function.
  Common code adds `packed`, `mode`, `vector_size` and
  `transparent_union`, which change a type or a layout. The rest the
  headers use (`availability`, `deprecated`, `format`, `noescape` and
  others) only shape diagnostics or code generation.
- [Medium] Header macros that collide with constructor names, such as
  `None` in the X11 headers, break those constructors with an obscure
  error. Find a way to report the macro (design 3.3).
- [Low] Decide whether a small library of `.tci` files (vector, map,
  region) ships with the compiler or stays a test.
- [Low] Consider C2y named loops (`break name;`) as the way to leave an
  outer `match` or loop from an inner one, once backends accept them.
