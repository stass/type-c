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
- [Medium] Decide where the arm64 Linux and the FreeBSD test hosts run
  (`tools/hosts` runs the x86-64 Linux ones in containers), and where
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
  each an error that names its first token: attributes before a
  statement that no named label precedes (`__attribute__((musttail))
  return`, GCC 15 and Clang), and attributes in the qualifiers of an
  array parameter (`int a[__attribute__((x)) 3]`, both). Clang alone
  also takes a block literal with a return type (`^ int (int x) { ...
  }`, `^ int { ... }`) or with attributes, which needs the parameter
  scope of an abstract function declarator, and attributes before a
  member declarator after the first, which GCC refuses. Decide which
  belong to the profile (design 13.3) before the corpus sweep (0.11)
  finds them.
- [Low] `-fgnu-keywords` and `-fno-gnu-keywords` make `asm` and
  `typeof` keywords or identifiers in every dialect under Clang, and GCC
  ignores them in C with a warning; `typec` passes them on and reads the
  keywords of `-std=`, so with Clang it disagrees with the backend.
  Refuse them with a `.tc` input, unless a consumer needs them.
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

- [Medium] `Declarations` knows the effects of the GNU attributes of a
  table (`attribute_effects`): `noreturn` and `gnu_inline` mark a
  function, the rest change no type or constant it computes. Any other
  one, `packed`, `mode`, `vector_size` and Clang's `overloadable` among
  them, makes the type it applies to unknown (design 13.3, P21). The
  table is the answer to the design question on attributes until 0.7b
  reads them; `aligned` is on it only while record layout is the
  backend's, and `packed` could join it on the same ground. Only the
  declaration of a function at file scope records `noreturn` and
  `gnu_inline`; anywhere else, on a pointer, a parenthesized
  declarator, a typedef, an object, a structure, either makes the type
  it applies to unknown, though GCC and Clang make `noreturn` part of
  the type of a pointer to a function and of a function typedef, and
  ignore both on an `int`. Inside the declarator of a function, as in
  `void * __attribute__((noreturn)) f(void);`, both move to the
  function in GCC and Clang, which typec refuses rather than record.
  Whether a declaration records the effects is decided twice, by
  `read_init_declarator` for `declare_type` and by `file_scope_declared`;
  block-scope declarations should get it from one place. The table
  checks no attribute's arguments (`noreturn(1)` is accepted).
- [Medium] Unknown types (design 13.3, P21) for 0.7b and 0.9b to
  replace by types where a point needs them: block pointers, `_Float16`,
  `typeof` of an expression, and what an attribute outside the table
  applies to. `typeof (x) y;` at file scope is an error, since whether
  `y` is a function depends on the type, though both backends accept
  it; `typeof` of an identifier could take its declared type. The tags
  that `typeof` of an expression declares are not declared, as in
  `sizeof`. An attribute outside the table on a structure or union
  specifier makes the type of that specifier unknown, while a later
  `struct s` names the record as declared: right for its identity,
  members and completeness, the facts typec computes, but
  `transparent_union` changes how 0.9b must convert arguments.
- [Medium] An anonymous structure or union member whose specifier has an
  attribute outside the table, such as `packed`, has an unknown type, so
  its members are not members of the containing type and a duplicate
  name among them is not reported. Keeping the record shape on a record
  specifier and recording the attribute apart, or a `Neutral` entry for
  `packed` restricted to records, would keep the members.
- [Medium] The composite with an unknown type is that type, so a known
  declaration after it is compared with nothing known:
  `int f(int); int f(int) __attribute__((foo)); int f(long);` is
  accepted, though the first and last conflict. Keep the last known type
  of an entity beside the composite and check each known declaration
  against it.
- [Medium] An attribute outside the table makes a whole function type
  unknown, return and parameters included, though most such attributes
  (`access`, `alias`, `target`, `overloadable`) belong to the
  declaration; the arity and return checks of those functions are lost.
  Decide in 13.3 whether an attribute on a function declarator keeps
  the function type and marks the declaration instead.
- [Low] An unknown type is not known to be other than `void`, so
  `void f(typeof((void)0));` is read as one parameter rather than
  `(void)`; asking would refuse `_Float16 f(_Float16);`. A kind for an
  unknown type that is known not to be `void` would settle it.
- [Low] A typedef redefined with an unknown type keeps the later type,
  where the known one, which must be the same (6.7p3), would keep more.
- [Low] The location of an unknown `_Float16` or `typeof` is that of the
  first specifier of its declaration, not of its own token.
- [Low] An enumeration with a fixed type whose list is given twice, or
  that has a fixed type in one declaration and none in another with the
  same compatible type, is not reported, and `enum e : int; enum e {
  A };` is reported as a tag defined twice; the backend reports each.
  Recording in the tags whether the type is fixed and whether the list
  was read would report them. `enum e : int x;`, a fixed type outside
  `enum e : int;` alone, which C23 and Clang refuse, is accepted.
- [Medium] `__builtin_types_compatible_p`, and `__real__` and
  `__imag__` of an integer constant, are integer constant expressions in
  GCC and Clang (`int a[__builtin_types_compatible_p(int, int)];`); the
  constant evaluator of `Declarations` calls them not constant. Answer
  the builtin where types are compared, in the front end when a Type-C
  type is involved (design 13.5).
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

- [Medium] Offer the OCaml AFL shm patch upstream
  (`tools/fuzz/patches/ocaml-5.5.2-afl-posix-shm.patch`). AFL++ on macOS
  hands the coverage map over only as a POSIX shared memory descriptor
  (`__AFL_SHM_FD`), and the runtime of OCaml (`runtime/afl.c`, 5.5.2 and
  trunk) attaches only a SysV segment, so the fuzz build needs a patched
  compiler (README, "Fuzzing"). Once OCaml takes it, drop the patch and
  pin the release that has it.

## Test hosts

`tools/hosts` runs the suite on Debian 13 (glibc) and Alpine 3.24
(musl), both x86-64.

- [High] With `-O`, Alpine's GCC and Clang define `_FORTIFY_SOURCE`,
  and musl's fortify-headers then declare `fgets` and others as
  `__typeof__(fgets) __orig_fgets` with `__attribute__((access))`
  (`/usr/include/fortify/stdio.h:40`, `:42`); typec cannot tell whether
  such a name is a function or an object (design 13.3), so a `.tc`
  input that includes `stdio.h` does not compile with `-O` there, and
  `test/run/pipeline.t` and `tools/corpus/runner.t` fail on Alpine.
  `-U_FORTIFY_SOURCE` or `-O0` avoids it. Reproducer:
  `/Volumes/Optaine/typec-hosts/repro/alpine-fortify/run.sh REPO`.
- [Medium] `test/run/headers.t` fails on Alpine in the ISO modes
  (`-std=c11`, with or without `_DARWIN_C_SOURCE`): musl's `aio.h:17`
  declares a member of `struct sigevent`, which `signal.h` defines only
  under a POSIX feature macro, and GCC refuses the unit too. The unit
  is chosen by preprocessing each header alone in GNU C. Choose the
  headers per mode by compiling each alone, or leave the POSIX headers
  out of the modes without a POSIX feature macro; both backends on
  macOS refuse the unit in the three modes with a feature macro, so
  check that the change keeps what macOS reads.
- [High] glibc declares binary128 types that the parser does not read
  as type names: under Clang `bits/floatn.h:97` is
  `typedef __float128 _Float128;`, and under GCC `math.h` declares
  functions of GCC's `_Float128` (`bits/mathcalls-helper-functions.h:20`).
  On Debian no `.tc` input that includes `stdio.h` compiles with Clang,
  and `test/run/pipeline.t`, `headers.t` and `tools/corpus/runner.t`
  fail. Reproducer:
  `/Volumes/Optaine/typec-hosts/repro/debian-glibc/run.sh REPO`.
- [Medium] `test/run/declarations.t` fails with Debian 13's Clang 19:
  in an enumeration whose values do not all fit `int` (`enum mixed`,
  `after_max`, `unsigned_after` of `declarations.c`), typec gives every
  enumerator the enumeration's type, as GCC, Apple Clang 21 and Clang
  22 do, and Clang 19 gives an enumerator that fits `int` the type
  `int`.
  `Cc_option` names Clang 18 to 21 as supported: decide the oldest
  Clang, or make the rule depend on the backend's version. Reproducer:
  `enum.c` in `/Volumes/Optaine/typec-hosts/repro/debian-glibc`.
- [Low] `typec.opam` asks for OCaml 5.0, but `tools/fuzz` uses
  `Char.Ascii` of 5.4, so Debian 13's OCaml 5.3 does not build the
  tree and the Debian host takes OCaml from opam. Raise the bound to
  5.4, or do without `Char.Ascii` if a distribution's OCaml should do.
- [Medium] `test/run/target.t`, `types.t` and `declarations.t` run on
  x86-64 hosts only: `target.t` expects the x86-64 model and the other
  two compile with `-m32` as well. Give them the expected model and a
  second target of arm64 once an arm64 host runs the suite, so that
  `types.t` confirms the provisional enumeration rule
  (`Arithmetic.enum_compatible_type`) there too.
- [Low] `tools/corpus/runner.t` runs `/usr/bin/clang`, not the Clang
  that `TYPEC_TEST_CLANG` names (`test/run/backends.sh`).

## Corpus

The front end accepts the 246 units of the corpus with Clang and with
GCC 16 (macOS x86-64), and each gives the object that the backend builds
alone; block pointers and `_Float16` in the SDK's headers have unknown
types (design 13.3).

- [High] Pin the rest of the corpus of plan 0.11 in the corpus
  repository, each with its licence recorded there: musl (MIT, without
  `src/string/aarch64`, which has its own terms), programs generated by
  Csmith (BSD-2-Clause; its runtime headers keep the University of Utah
  notice), GCC's `c-torture/execute` (GPL-3.0 or later: the repository
  names the archive and holds no file of it), and the translation unit
  that includes every standard and POSIX header of a host.
- [Medium] SQLite's recipe declares a substitute test (a smoke test of
  ours), so gate 1 is not met for it: the amalgamation has no test
  suite. Its own suite needs the full source tree and Tcl.
- [Medium] chibicc's recipe declares a substitute test (its tests
  compiled to assembly) on every host. Its own suite runs only on Linux
  x86-64, which has not run yet; the recipe format limits only `cflags`
  and `libs` to a system, so a `test own` for Linux x86-64 needs the
  format to limit `test` to a system and to name a machine.
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
