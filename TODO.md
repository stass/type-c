<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# TODO

Work that is worth doing and is not a work package of
[type-c-implementation-plan.md](type-c-implementation-plan.md). "Design"
is [type-c-language-design.md](type-c-language-design.md).

## Before Stage 0 starts

- [High] Check the license and provenance of each pilot candidate named
  in the plan before fetching any of them.
- [Medium] Decide where the corpus repository is hosted: it exists
  locally at `/Volumes/Optaine/type-c-corpus`, with no remote, and its
  README says what it holds. (`tools/hosts` runs the Linux hosts in
  containers, the arm64 ones under emulation, and the FreeBSD one over
  ssh, on a machine of the owner's.)

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
- [Low] A diagnostic gives the file and the line but not the source line
  that design 13.6 says it carries; print the line of text under it.
- [Medium] Whether a refusal carries a stable code rests on its site
  calling `Rule.message`: the failure functions of the parser and the
  declarations take a plain string. Some refusals cite the design and
  carry no code: the profile limits of design 13.3 (`expressions.ml`,
  the GNU nested function in `parser.ml`) and "break outside a loop,
  switch or match" (design 4.3 rule 2). Decide whether these are rules
  with codes (a `Profile` rule, like `Not_implemented`), then make the
  failure functions take a diagnostic of two cases, a rule of Type-C
  made only by `Rule.message` and a refusal of C text, so that each
  site chooses visibly; state the boundary in design 13.6.
- [Medium] Nothing stops a retired code from being reused: the table in
  `src/syntax/rule_table/rule_table.ml` checks only that codes rise, so
  deleting the last rule and adding one with its number passes. Keep
  retired rows in the table, marked retired, left out of `Rule.t` and
  listed as retired in the catalogue.
- [Low] `#ident` and `#sccs`, which `cc -E` passes through, are refused
  as unsupported directives. Pass them through like a pragma if a corpus
  uses them.

## Parser

- [Low] A type name as the controlling operand of `_Generic` (C2y,
  `_Generic(const int, const int: 1, int: 2)`), which GCC 16 and Clang
  accept in gnu11, is a syntax error. Read it, with its type unconverted,
  if the corpus has one.
- [Medium] The parser reads chains in loops (left-associative binary
  operators, the comma operator, postfix operators, casts and the prefix
  operators, assignments, the last operands of conditionals, the
  pointer, array and function derivations of a declarator, and the
  statements that end in a substatement: `if (a) if (b) ...`, `else if`
  chains, loops and labels), so a chain is not bounded by
  `Parser.max_nesting`, and its tree is as deep as it is long. A pass
  that recurses over the tree can exhaust the stack on a long chain: the
  constant evaluator of `Declarations` counts its depth against
  `max_expression_depth` and expression typing `Expressions.max_depth`,
  and the test dump must count too or walk chains in loops.
- [Medium] Typing checks the controlling expressions of statements, the
  places of `case`, `default`, `break` and `continue`, and the values of
  `case` labels; nothing checks the other constraints of statements that
  the parser accepts: the storage classes of a `for` declaration
  (6.8.5p3), duplicate and missing labels (6.8.1p3, 6.8.6.1p1) and
  `return` with or without a value (6.8.6.4p1),
  and the GNU label rules: a label address (`&&a`) outside a function
  body, a duplicate or undefined `__label__` label, `&&a` as a use of
  `a`, and a jump into a statement expression from outside it. Check
  them where bodies are typed (`Expressions`). `Declarations` checks
  those of declarations.
- [Medium] `test/support/file_scope_names.ml` finds what a unit declares
  at file scope from its external declarations alone, so
  `declaration_probe` and `test_declarations` miss file-scope names
  declared deeper: an enumerator among members (`struct s { enum { C }
  m; };`) or in an array length (`int a[sizeof (enum { B })];`). Let
  the parser, the one implementation of the scope rules, give the
  declarations visible at the end of the unit, and drop the helper.
- [Low] A use of a name of an identifier list before the declaration
  list declares it (`int f(b, n) int b[n]; int n; {}`) is reported as
  declared where typec does not read declarations, where Clang says
  undeclared; and the ids of `Tree` are public constructors, so any
  module could mint one: make them private to the parser.
- [Medium] The arguments of an attribute are a span the parser does not
  read, so the identifiers in them resolve to nothing: `aligned(N)` with
  an enumerator `N`, `vector_size(N * sizeof (T))`, `cleanup(f)`. The
  first consumer of such an argument must not look names up itself:
  parse the arguments of the attributes whose grammar is known (an
  expression for `aligned` and `vector_size`, an identifier for
  `cleanup`) through the parser's scope.
- [Medium] Labels are names only in the tree: a label statement, `goto`,
  `&&label` and the labels of `asm goto` record no declaration or
  resolution. A label's scope is its function (6.2.1p3), so a `goto`
  before its label resolves only at the end of the body, and a GNU
  `__label__` declares a label with block scope that a label statement
  in that block defines. Resolve them per function body, and per block
  literal body, once it is parsed (a pure step of the parser), into the
  tree, for the label checks. Until then `Reachability.resolve` in
  `src/sema/reachability.ml` resolves a label by its name and the
  `__label__` declarations around it, for design 4.3 rule 3; it goes
  when the tree resolves labels.
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
  Check them with the other constraints of statements.
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
- [Medium] typec reads C23 attribute specifiers (`[[...]]`) only before
  the specifiers of a declaration, a parameter or a member and as a null
  statement, through reads at several sites and a refusal in the
  old-style declaration list (`src/syntax/parser.ml`). GCC and Clang
  also accept them after `struct`, `union` and `enum`, after a
  declarator, among the qualifiers of a pointer and after an
  enumerator, where typec's error does not name the construct. Read
  both forms through one funnel at each attribute slot that both
  backends accept, which removes the list of sites.

## Expression typing

- [High] A constructor whose target is a variant declared in a block can
  be written outside that block, where `__typeof__` carries the type of
  a statement expression (or a block literal) out of it. There the
  names it lowers to denote something else or nothing: with
  `int e_A = 7;` outside, `__typeof__(({ type e = | A; e v = A; v; })) y
  = A;` lowers to `{ .tag = e_A }`, reads the local object and compiles
  silently; a compound literal's `struct e` fails in the backend. Design
  10.1 rule 6 makes the names denote the variant only within its scope.
  Recommended: refuse a construction outside its variant's scope, which
  is a token range, so the parser records where each type declaration's
  scope ends and constructor_expression checks the use against it; the
  alternative, refusing type declarations inside expressions, also
  refuses `type t = typeof(({ type u = ...; ... }))`. Owner decision, as
  it adds a rule to 3.3.
- [Medium] Design 13.5: a `_Generic` that typec answers keeps only the
  selected expression, so the backend no longer sees the uses in its
  controlling expression and other associations: `-Wunused-variable` and
  `-Wunused-function` fire on a name used only there, which fails a
  `-Werror` build. Keeping every association and making the backend
  select typec's answer would keep them: the controlling expression as
  `((void)(e), (char (*)[k])0)` and the type name of association `i` as
  `char (*)[i]`. Owner to choose.
- [Medium] Design 13.5: a structure, union or enumeration that a type
  name or the controlling expression of an answered `_Generic` or
  `__builtin_types_compatible_p` declares is dropped with it, though C
  declares it in the enclosing scope (6.7.2.3). A later use then fails
  in the backend, or silently means an outer declaration of the name
  (`_Generic(x, d: 1, enum { K = 5 }: 2)` before a use of a global `K`).
  Refuse an answered construct whose dropped tokens declare a tag or an
  enumeration constant.
- [Low] `Expressions.answered` copies the answers that `selections` and
  `compatibilities` hold; recording only the spans answered would leave
  one copy.
- [Medium] `Expressions.positioned` refuses a second typing of a node
  in another position at run time, and some callers type a node twice in
  the same position on purpose (`selected`, `statement_expression`,
  `integer_constant` after `case_value`). Split the entry points: typing
  a child asserts it is untyped, reading a typed one goes through
  `operand_typed`; then the stored position and its check go.
- [Medium] Design 3.3's target under elided braces is the first
  variant, because only a variant target changes a meaning today. `str`
  string literals (section 8, P13) and generic deduction (7.2) also take
  meaning from the target: before they land, state the rule as the first
  subobject on the elision chain whose type gives the target a meaning.
- [Low] `Initialiser.first_variant` follows the elision chain that
  `first_level` encodes too. Split a pure first-subobject step that both
  use, keeping the rule 6 refusal at the callers that open a record.
- [Low] Under `{0}` rule 7, a constant that is no valid 0 (`{0i}`, an
  integer too large) is refused as reaching into the variant rather
  than with the constant's own error.
- [Medium] An unqualified constructor whose name is a visible typedef
  name does not parse (`type A = int; type e = | A; e x = A;`): the
  parser reads a typedef name in an expression as an error, before the
  target type is known, against design P2. Say so in 3.3 or let the
  parser read such a name as an identifier where `(`, `,`, `;`, `)` or
  `:` follows.
- [Medium] Design 13.5 says a constructor inside an initialiser lowers
  to its braced list so that static initialisers stay constant; one in
  parentheses (`static e x = (B(1));`) or reached through elided braces
  (`static struct w q = { e.A };`), and one for an atomic object
  (`static _Atomic e g = A;`), lower to a compound literal, which
  `gcc -pedantic` calls not constant. Narrow the 13.5 row or drop the
  parentheses and add the elided braces in the lowering.
- [Medium] `Expressions.constructor_argument` repeats `Initialiser`'s
  rule that a structure is initialised whole when its type is
  compatible (6.7.9p13). Check the arguments as the initialiser of the
  payload structure through `Initialiser` instead.
- [Low] A variant's constructors and its structure's members are two
  tables in `Ctype.tags` under one id; `define_record` can still
  complete a variant without constructors. Keep the constructors in the
  record's definition, or refuse a variant tag in `define_record`.
- [Low] `{0}` (design 3.2 rule 7) is read as any integer constant 0
  (`{0L}`, `{0x0}`) without a designator; say so in the design.
- [Medium] Constructor arguments are converted to their field types by
  the backend, except where a field or an argument is a structure or
  union, which `Expressions` checks. A wrong scalar or pointer argument
  is then the backend's error on lowered code; check 6.5.16.1p1 in
  typec once typing models assignment conversions.
- [Medium] The result type of each operator on integer constants is
  decided twice, by `Expressions` and by `Integer_constant.unary`,
  `binary` and `conditional`, which the classing of constants calls: the
  conversions are shared, the mapping from operator to type is not. Let
  the constant operations take the result type from typing.
- [Medium] The rule that the initialiser of an object of static or
  thread storage duration is constant (6.7.9p4) reports only what both
  GCC and Clang refuse (`Expressions.Not_constant`). Each takes other
  forms (6.6p10) that the other refuses: GCC a call of some library
  functions (`abs(-1)`), Clang a comma operator; both read a `const`
  object. Calls, commas, casts of addresses to integers and the value of
  a `const` object are left to the backend. If a Type-C rule or lowering
  needs the value of a static initialiser, class those by
  `Target.compiler`.
- [Medium] `Declarations.initialised` completes an array's type by
  recording the entity again in the tables that hold it (`record`,
  `note_at_file_scope`); a table added later, or one read between the
  declarator and the end of its initialiser, keeps the incomplete type.
  One funnel that updates a declared object, or an entity whose type is
  one binding cell, would make it hold by construction.
- [Medium] `Ctype.Variable` stands for every array length that is not
  an integer constant expression, which includes lengths that GCC and
  Clang fold to a constant (`static const int N = 4; int a[N];`, a
  `Backend_constant`). So the rule that a variable length array takes no
  initialiser (6.7.9p3) is the backend's, and `int a[N];` at file scope
  is an error here. A length that records whether the backend may fold
  it would settle both.
- [Low] Where the operands of an operation are an `Unevaluable` and a
  `Not_integer` (`Expressions.broken_by`), the first decides: in a block,
  `char b[(int)(_Float16)1 + n];` is an error and
  `char b[n + (int)(_Float16)1];` a variable length array. Let
  `Not_integer` win in either order.
- [Low] GCC finds the type of `int a[] = {}` compatible with no `int[0]`
  (`__builtin_types_compatible_p`), which Clang and typec do; its size is
  0 in all three. initialisers.t asserts only the size.
- [Low] Clang refuses a brace-elided initialiser for a member of an
  empty structure (`struct { struct {} e; int b; } y[] = { 1, 2 };`),
  where GCC skips the member with a warning; typec stops following the
  positions there, and the length it gives such an array is opaque.
- [Low] The run probes (`test/run/expression_probe.ml`,
  `declaration_probe.ml`) check a type by compatibility, through
  `_Generic` and `__builtin_types_compatible_p`, so they miss a type that
  is compatible with the backend's but not the same, such as the
  composite of an enumerated type and its integer type. A typedef
  redefinition with typec's spelling (`typedef __typeof__(e) T1;
  typedef <spelling> T1;`) would check sameness (6.7p3).
- [Medium] With GCC, the unknown types of `Backend_difference` cover more
  than the difference, so code that needs the type is refused where both
  compilers agree. A member found through a qualified anonymous member
  is unknown, though only the qualifiers of the lvalue differ and its
  value has one type in both (`_Generic(t.z + 0, int: 1, default: 0)`
  in an enumerator is refused). An operand whose promotion is unknown
  makes `p + w.l`, `a[w.l]` and `1 << w.l` unknown, though GCC gives
  them the type of the pointer, the element and `int`. And
  `__builtin_types_compatible_p(_Atomic int, long)` is unknown though
  GCC also answers 0, and the real part of a bit-field is unknown where
  only whether it is an lvalue differs (`__real__ s.f` with
  `unsigned f : 32` is `unsigned int` in both). The composite of an
  enumerated type and its integer type is unknown, though the two differ
  only where a rule asks for the same type, as a typedef redefinition
  does: after `enum e { E0 = 1 }; extern enum e x; extern unsigned x;`,
  `_Generic(&x, unsigned *: 1, default: 2)` is refused in an enumerator,
  though both compilers select 1. Keep the value type of
  such a member apart from the qualifiers of its lvalue, let an
  arithmetic operand keep its integer type with an unknown promoted
  type, let the comparison ask whether the types without `_Atomic` are
  compatible, and keep the type of a real part that both compilers
  give.
- [Low] Whether a bit-field's type is an integer type is decided twice:
  `Ctype.check_bit_field` refuses other types, and
  `Expressions.bit_field_integer` reads the integer type again, failing
  with `invalid_arg` where the two disagree. Let `Ctype.member` carry
  the width and integer type of a bit-field, filled where the record is
  defined.
- [Low] `typeof` of a bit-field that a member access designates, which
  GCC and Clang refuse, gives the bit-field's type.
- [Medium] `Ctype.find_member` passes over an anonymous member of
  unknown type, such as one whose specifier has an attribute outside the
  table, so `t.z` of `struct T { struct { int z; }
  __attribute__((ms_struct)); } t;` is reported as no member, which
  Clang accepts, and so is the designator `.z` of an initialiser of
  `struct T` (`Ctype.member_path`). Let both answer `Depends_on` where a
  record has such a member, typing give the access that unknown type and
  `Initialiser` lose the position.
- [Medium] An identifier is a spelling, so a universal character name
  and the UTF-8 character it names are two names (`linked` is keyed by
  spelling), and the length of `__func__` counts the spelling: Clang
  gives a function spelled with `\U0001F600` a name of its UTF-8 bytes.
  Normalise identifiers to UTF-8 where the reader lexes them.

- [Low] `check_distinct` compares the associations of a generic
  selection in pairs: 20000 of them take 26 s, where GCC and Clang, as
  quadratic, take 4 s.

## Declarations

- [Medium] `Declarations` knows the effects of the GNU attributes of a
  table (`attribute_effects`): `noreturn`, `gnu_inline` and Clang's
  `overloadable` mark a function, the rest change no type or constant it
  computes. Any other one, `packed`, `mode` and `vector_size` among
  them, makes the type it applies to unknown (design 13.3, P21). The
  table is the answer to the design question on attributes until 0.7b
  reads them; `aligned` is on it only while record layout is the
  backend's, and `packed` could join it on the same ground. Only the
  declaration of a function at file scope records `noreturn`,
  `gnu_inline` and `overloadable`; anywhere else, on a pointer, a
  parenthesized declarator, a typedef, an object, a structure, each
  makes the type it applies to unknown, though GCC and Clang make
  `noreturn` part of
  the type of a pointer to a function and of a function typedef, and
  ignore both on an `int`. Inside the declarator of a function, as in
  `void * __attribute__((noreturn)) f(void);`, they move to the
  function in GCC and Clang, which typec refuses rather than record.
  Whether a declaration records the effects is decided twice, by
  `read_init_declarator` for `declare_type` and by `file_scope_declared`;
  block-scope declarations should get it from one place. Each effect is
  also spelled in four places in step (a field of `attributed`, a
  constructor of `attribute_effect`, an arm of `read_attributes`, the
  empty `no_attributes`); a set of effects would leave the table and the
  one consumer. The table checks no attribute's arguments
  (`noreturn(1)` is accepted).
- [Medium] Unknown types (design 13.3, P21) for 0.7b to replace by
  types where a point needs them: block pointers, `_Float16`, the
  builtins that the table of builtin functions leaves unknown (those of
  vector and optional floating types, `__builtin_apply`,
  `__builtin_va_arg_pack`, `__builtin_tgmath`), and what an attribute
  outside the table applies to. A block literal has an unknown type, as
  its body is not typed. An attribute outside the
  table on a structure or union specifier makes the type of that
  specifier unknown, while a later `struct s` names the record as
  declared: right for its identity, members and completeness, the facts
  typec computes, but `transparent_union` changes how typing must
  convert arguments.
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
  (`access`, `alias`, `target`) belong to the declaration; the arity
  and return checks of those functions are lost. Decide in 13.3
  whether an attribute on a function declarator keeps the function type
  and marks the declaration instead.
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
- [Medium] `__real__` and `__imag__` of an integer constant are integer
  constant expressions in GCC and Clang; the constant evaluator of
  `Declarations` calls them not constant.
- [Medium] Attributes inside what the reader does not read, such as an
  initialiser or the operand of `sizeof`, are not checked against the
  table. Checking them in the parser, where every attribute is made,
  would cover every position by construction; the reader's full record
  patterns cover only the positions it reads, and not a field read by
  projection.
- [Low] The parser reads a tag alone in a declaration as GCC and C11 do
  (6.7.2.3p7, p9): `const struct s;`, `struct s;` among members and
  `enum e;` without a fixed type name the visible tag, where Clang
  declares a new one in the current scope, and attributes after the tag
  leave `struct s` alone, where Clang requires the `;` right after it.
  With Clang as the backend, typec and the backend then see different
  types where an outer tag of the name is visible. Refuse those forms
  there if the corpus has them.
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
  *);`, which i386 and arm64 Darwin accept. In a body a `va_list`
  parameter has an unknown type, since x86-64 adjusts it to `struct
  __va_list_tag *` (Clang), so `&ap` and the uses of `ap` are not typed.
  If a Type-C rule needs them, the representation must come from the
  backend (a target table is ruled out by design 13.3).
- [Medium] A use of a name with a Clang overload (`overloadable`, design
  13.3) in scope before the declaration it resolves to has an unknown
  type, as the parser resolves it to the last declaration of the name,
  overload or not, which need not be the function that Clang chooses;
  so the type and arity of a call to one are the backend's. Overload
  resolution with Clang's rules would type them.
- [Medium] Two `overloadable` declarations of a name with the same type
  in one scope are one function in Clang; typec gives each an entity of
  its own and checks none of Clang's rules on overload sets: an
  overload whose parameter types are those of the name's declaration
  without the attribute, a second such declaration, a return type that
  conflicts with an overload of the same parameter types, an overload
  without a prototype (Clang refuses each). The backend reports them.
  Merging needs the overloads of a name in scope, which the reader does
  not keep (`beside` holds only the entity before them), and a type
  comparison that counts `pass_object_size` and `enable_if`, which typec
  leaves unknown.
  Do it with overload resolution if that needs the identity.
- [Medium] A block-scope declaration with linkage takes its linkage
  from the last declaration of its name with linkage and the composite
  type of the last at file scope (6.2.2p4, 6.2.7p4), as the parser
  records no link to a visible declaration of an enclosing scope. Where
  a declaration without linkage hides those, C gives the block's
  `extern` external linkage and no composite with the hidden type:
  `static int x; void f(void) { int x; { extern int x; } }` is undefined
  there and accepted here, and `int a[3]; void f(void) { int a; {
  extern int a[]; sizeof a; } }` gives `a` the size it lacks. The
  resolution of the declared name where its declarator starts, recorded
  by the parser, would settle both. A function shows it too: in
  `int f(int); void g(void) { int f; { extern int f(); } }` Clang and
  GCC give the inner `f` the type `int ()` and typec `int (int)`, and
  after `int f(a) long a; {...}` typec gives it `int (long)`.
- [Low] `Backend_difference.answer` makes every unknown type an object
  type, so `Expressions.backend_type` gives back a function type's
  kind; `answer` could take the kind from Clang's type. In
  `Expressions.function_designator`, `checked` guards a
  `Ctype.function_returning` that cannot fail, as promoted parameters
  are no larger than those they replace; a total `Ctype` function that
  replaces the parameters of a function type would drop it.
- [Medium] An `entity` and an `item` carry no location or tree node, so
  no message can point at a previous declaration and a consumer lines
  `items` up with the tree by position. The id of each declaration is
  the token of its name; record the first in an entity when 0.9b or
  Stage 1 first needs it.
- [Medium] Integer constant expressions do not evaluate a call, so a
  builtin that GCC and Clang fold to a constant, such as
  `__builtin_constant_p` or `__builtin_classify_type`, is an error where
  an integer constant expression must be known: an enumerator, a
  `_Static_assert` (the macOS SDK's `os_log` asserts
  `__builtin_constant_p` of its format), a `case` label, a bit-field
  width, a file-scope array length. A `__builtin_choose_expr` whose
  condition is one has an unknown type. Fold them in typing where the
  corpus shows code that needs it.
- [Low] The table of builtin functions (design 13.3) gives the GCC
  constants of `_Float32`, `_Float64`, `_Float32x` and `_Float64x`
  (`__builtin_inff32` and the like) to every GCC target, as every target
  of the test hosts has the types; on a target without one the backend
  refuses the call. The run test checks the referenced types of pointer
  parameters and the qualifiers that the table adds, not a qualifier that
  the table lacks or the other parameter types, which the backends'
  documentation alone states, as a call converts its arguments without a
  warning.
- [Low] The table of builtin functions was filled from the corpus and
  from the macros of the all-headers unit in GNU C11 and ISO C11. Headers
  outside that unit reach builtins it lacks, such as the macOS SDK's
  `libunwind.h` (`__builtin_ptrauth_string_discriminator`), and so may
  C23 headers (`__builtin_stdc_*` in glibc's `stdbit.h` under GCC 14).
  Add each family where code reaches it.
- [Low] An `__atomic` or `__sync` builtin whose first argument points
  to a qualified type has an unknown type: Clang keeps a qualifier that
  a typedef gives the referenced type (`typedef const int cint; cint *p;
  __atomic_load_n(p, 0)` is `const int`) and drops one of the
  declarator, and Ctype keeps no typedef to tell them apart.
- [Medium] A `__builtin_choose_expr` whose condition depends on an
  unknown type through a cast or a selection, such as one whose own
  condition is `__builtin_constant_p(x)`, is an error rather than of
  unknown type: the constant `Unevaluable` holds both an invalid
  expression and one that depends on an unknown type. Give the second a
  constant of its own, which `choice` maps to an unknown selection.
- [Low] A call of a builtin that a rule types does not check its number
  of arguments (`__builtin_isnan()` is `int`), which the backend
  refuses; nor is a callee chosen by `_Generic` or
  `__builtin_choose_expr` typed by the rule (it is unknown).
- [Low] `specified.storage` holds a `Tree.storage_class`, which can say
  `_Thread_local` although `storage_class` never puts it there. Give it a
  type without that case.
- [Low] `Declarations` refuses some code that both backends accept with
  a warning: unknown escape sequences such as `'\q'`, `_Complex` alone
  and `_Complex int` (the last two for the GNU profile, 0.7).
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
  `offsetof`, which GCC and Clang expand to `__builtin_offsetof` (0.7);
  the length that an initialiser gives an array of unknown size where an
  array designator is a size (`[sizeof (struct s)] = 1`) or braces are
  elided into an array of opaque length, which is opaque, and the size of
  an array that an initialiser completes (`sizeof a` of
  `int a[] = { 1, 2 }`, `sizeof "abc"`), opaque as every array's is,
  though its element type and length are known. The target model has no
  alignments and no size of `_Bool` or of an atomic type, so `_Alignof`
  of any type and those sizes are opaque too, although they are not
  aggregates. How often real code needs each is for the corpus to show.

## Matching

- [Low] A break or continue in a statement expression in the condition
  or step of a loop counts, in typing and in reachability alike, for the
  statements around the loop. Whether GCC and Clang bind it to the loop
  itself is not checked; a disagreement makes the analysis call an arm
  end unreachable that is not, which the arm-end trap stops. Check both
  backends and make typing and `Reachability` follow them.
- [Low] Reachability does not walk type names: a break, continue or
  goto in a statement expression in an array length or a `typeof` is not
  seen by the arms and loops around it, nor a label there by the jump
  rule. (A match there is checked, since typing asks rule 1 of each arm
  it reads.)
- [Medium] Typing (`enclosing` in `src/sema/expressions.ml`) and
  `Reachability` (`loop`, `switch_flow`, `match_flow`) each decide which
  construct a break or continue leaves, two copies that must agree.
  Resolve each break and continue to its target once, in the parser as
  for labels, and have both read it.

- [High] Owner decision: a binding of a match lowers to
  `const __typeof__(__tc_match->u.C.f) x = __tc_match->u.C.f;`, which
  GCC and Clang accept in every dialect but which is not ISO C11, against
  design 2.4 ("Everything Type-C lowers to is ISO C11"). C11 cannot
  declare the copy without a name for the field's type, and no such name
  is sure to be visible at the match: a typedef name or tag used by the
  field may be hidden there. The alternatives are to relax 2.4 for
  `__typeof__` (C23 `typeof`), or to have each variant declare a
  generated typedef per field (a change to 10.1). Recommended: relax 2.4;
  the choice is one function, `binding_declaration` in
  `src/emit/lowering.ml`.
- [Medium] Design 13.5 reaches every lvalue scrutinee through a pointer
  except a volatile, atomic or `register` one. typec keeps no fact that
  an object is declared `register`, so it reaches only an lvalue reached
  through a pointer (`*p`, `p->m`, and members of those) in place and
  copies a named object. Record `register` in `Entity.Object` and widen
  `access_of` in `src/sema/expressions.ml`, with a run test that a
  `register` scrutinee compiles.
- [Medium] `--trap-function=name` (design 10.5) is not implemented: a
  trap is `__builtin_trap()` alone. Add the option to the driver and
  pass the name to lowering, with a run test on both backends.
- [Low] A variant declared in a statement expression that is the
  scrutinee of a match lowers to C that names its tag and enumerators
  outside their scope, a backend error; constructor expressions likely
  have the same class. Refuse a match (and a constructor) whose variant
  is not in scope where its lowering names it.
- [Low] `case A: L: case B:` in a match is refused under design 4.3
  rule 3; the rule it breaks is 4.1 rule 2 (a label of the match stands
  directly in its body). Give the label under a named label its own
  message.
- [Low] Every match names its pointer `__tc_match`, which is safe only
  because each reference sits inside the block that declares it. A name
  unique per match (by the token index of `match`) would make that hold
  by construction.
- [Low] Where `match` is a typedef name, `match (f(void)) { ... }` in a
  block, a GNU nested function, now reports an expression error rather
  than the GNU profile's refusal of nested functions.

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
(musl) in containers, each on x86-64 and on arm64 (the latter under
emulation), and on FreeBSD 16.0-CURRENT over ssh, x86-64.

- [Medium] `tools/hosts/freebsd.sh` runs `corpus/fetch.sh` for the whole
  manifest, GCC's archive included, whichever programs it runs, so an
  archive that does not download fails a run that does not need it.
  Let the runner or `fetch.sh` resolve a program to its archives.
- [Medium] The records of a corpus run on the FreeBSD host exist only in
  the log: `tools/hosts/freebsd.sh` deletes `DIR/corpus` on the next run
  and does not copy `runs/` back into the corpus repository.
- [Low] `tools/hosts/freebsd.sh` copies the source with a pipeline of
  `git ls-files` and `tar` without `pipefail`, so a failure of either
  that leaves a partial tree shows up as a failure of dune. Two runs on
  one `DIR` at once are not guarded.
- [Medium] In `test/run/abi.t` the C side declares the Type-C functions
  with the hand-written tags `struct c_scalar` and the like, while the
  lowering uses `struct scalar`: across translation units the types are
  not compatible (C11 6.2.7), which works at the ABI but would trip
  `-fsanitize=cfi-icall`. Let `hand.h` spell its names through one
  prefix macro that `layout.tc` sets to `c_` and `side.c` leaves empty.
- [Medium] Stage 1 exit gate 4 also asks for size and speed within
  noise at `-O2`; `test/run/abi.t` checks only the output of its
  differential program. Measure at the gate: `size` of the objects of
  each pair, and the run time of a loop-heavy pair over repeated runs
  with the spread reported, on each backend.
- [Medium] `test/run/backends.sh` drops `-m32` from
  `hosted_second_target` when the host lacks the C headers of i386,
  and nothing reports it: a host that loses its 32-bit headers runs
  `test/run/abi.t` on one target with every test passing. Let a host
  declare the targets it must have, for example through a
  `TYPEC_TEST_*` variable, and fail when one is missing.
- [Low] `test/run/abi.t` does not carry `compound` from Type-C to C or
  through a callback, nor a distinct type as a variant field.
- [Low] `tools/oracle/oracle.t` has its own default of
  `TYPEC_TEST_CLANG` instead of sourcing `test/run/backends.sh`.
- [High] The arm64 hosts do not run reliably on the x86-64 colima VM:
  its qemu-user (v7.0.0, `/usr/bin/qemu-aarch64` in the VM) kills about
  1 in 100 GCC compilations with a segmentation fault of `cc1`,
  whatever the load. `debian-arm64` therefore does not build (opam
  compiles OCaml 5.4.1 with GCC; the build fails with `gcc: internal
  compiler error: Segmentation fault`), and `headers.t` fails on
  `alpine-arm64` in a different place each run (`present` and `unit`
  lose a header when `gcc` crashes). Reproducer: in
  `typec-host-alpine-arm64`, run `gcc -std=gnu11 -fsyntax-only -x c -`
  on `#include <H>` for each header of `headers.t` a few hundred
  times. Needs a newer qemu-user in the VM (not installed:
  `tonistiigi/binfmt --install arm64` keeps the VM's handler) or a
  native arm64 machine.
- [Medium] `Target.architecture` is the first of a list of predefined
  macros that the backend defines, while Clang decides where it has
  `__builtin_setjmp` by the TargetInfo of the triple; the two agree on
  every triple tried with `--target` (arm64ec needed `__arm64ec__` before
  `__x86_64__`), but nothing makes them agree on another. The calls of
  `expressions.t` for AArch64 and ARMv7 cover two of the architectures;
  PowerPC, SystemZ and VE are untested.
- [Medium] `test/unit/test_small_stack.ml` fails on `alpine-arm64`
  with `FAIL: the backtrace names the stage`: the backtrace of a
  `Stack_overflow` in `Small_stack.run` has at most
  `frames_of_the_stage` frames there. Reproducer: `tools/hosts/run.sh
  alpine-arm64` (or `dune test test/unit` in that image). Not known
  whether OCaml 5.4 on arm64, or the emulation, shortens the
  backtrace.

## Corpus

The front end accepts the 246 units of the corpus with Clang and with
GCC 16 (macOS x86-64), and each gives the object that the backend builds
alone; block pointers and `_Float16` in the SDK's headers have unknown
types (design 13.3).

- [High] Pin the rest of the corpus of plan 0.11 in the corpus
  repository, each with its license recorded there: musl (MIT, without
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
- [Medium] 23 units of GCC's `c-torture/execute` define nested
  functions (`nestfunc-*.c`, `20000822-1.c` and others), which are
  outside the GNU profile (design 13.3) and which Clang refuses as a
  backend without typec.
  Skip them in the corpus as the `-std=gnu89` units are, so that a run
  counts only the units typec should accept.
- [Low] A `typec` option that compiles a `.c` input as Type-C would let
  a program's own build replace `cc` with `typec` without renaming its
  sources. The corpus runner copies each unit to a `.tc` file next to
  it instead, which also makes `__FILE__` name the copy.
- [Low] The corpus runner waits for every command without a time
  limit, so a test or a compile that hangs stops the run.
- [Low] The corpus runner reports a command ended by a signal with
  OCaml's number for it (`Command.describe`), which is negative and not
  the system's: "ended by signal -10" for SIGSEGV. `Sys.signal_to_string`
  names it.
- [Low] A run record names `typec` by the digest of its binary and
  labels the revision of the checkout beside it as that at run time,
  because `typec` cannot report the revision it was built from. A
  `typec --version` printing it would name the binary exactly; today
  `--version` goes to the backend like any unknown option.
- [Medium] The corpus runner trusts a test script to test every program
  that linked: gcc-torture and Csmith re-read the recipe and skip a
  program whose file is missing, c-testsuite globs its own list. The
  runner could pass the names of the linked programs and check that each
  gets one `TEST` line. It also ends the whole run (exit 2) when a file
  of one unit cannot be read or written, as when a unit the prepare
  script should have generated is missing, instead of recording the
  unit.
- [Low] The corpus test scripts: c-testsuite's has no CPU limit like the
  others, Csmith's stops at a failed reference link, and a Csmith program
  that times out in both builds with the same output counts as agreeing.
- [Low] The corpus runner's reference recipe repeats what
  `src/driver/pipeline.ml` passes to the backend (`-D__TYPEC__=1`, the
  default `-std=gnu11`), as `test/run/pipeline.t` does.

## Typing oracle

- [Medium] (0.10) The comparison leaves 2748 records of the corpus
  unresolved for naming an anonymous structure, union or member by its
  location (`union (unnamed union at src/lstate.h:181:3)`), which no
  type name names. Resolving them needs the tag that `typec` declares at
  the presumed location of each tag keyword, which `Declarations` does
  not give. Reproducer: `/Volumes/Optaine/type-c-corpus-cache/build/darwin-x86_64/lua/clang/src/lvm.tc.ref.i`.
- [Medium] (0.10) The comparison reads Clang's spellings at file scope,
  so a tag or typedef name of a block is unresolved: 153 records of
  SQLite, such as `struct Sublist *` and `void_function`. Worse, a name
  that a block declares again reads as the file-scope one, so a scoping
  bug of `typec` that gives the file-scope type there agrees. Reading
  spellings in the scope of their expression needs the parser to give
  its scope at a point of the unit; short of that, a spelling with a
  name that some block or prototype declares could be unresolved.
  Reproducer: a SQLite amalgamation preprocessed by Clang,
  `/Volumes/Optaine/typec-oracle-0.10b/corpus/sqlite3.tc.ref.i`, lines
  68820 and 192761 of `sqlite3.tc`; the corpus cache has SQLite
  preprocessed only by GCC.
- [Medium] (0.10) `Tree_expressions` lists every place of the tree that
  holds an expression, which a new place in the tree must join, or its
  expressions show as Clang-only. `Declarations` gives each typed
  expression by its node but not all of them; an accessor over the
  typed view (`Expressions.t`) would make the walk unnecessary. Until
  then, the walk reads some records of the tree by field (`type_name`,
  `parameter`, `function_definition`) where destructuring them with
  every field named would make the compiler report a new one.
- [Low] (0.10) A record's value category is a string checked against
  the three Clang gives, and the `Retyped` rule compares it as one; a
  variant would make a misspelt category impossible to write.
- [Medium] (0.10) Each spelling that `typec` refuses costs a read of
  the whole unit again: the spellings refused in SQLite make its
  comparison take 27 seconds, most of them in re-reads. Marking a
  spelling unresolved before the read when it has an identifier that no
  file-scope declaration declares would leave one read in most units.
- [Low] (0.10) An allow-list entry that matches no disagreement is not
  reported, so a stale or broad pattern goes unnoticed; the comparison
  could count the disagreements each entry allows.
- [Medium] (0.10) Nothing runs the comparison over the corpus: a run of
  the four programs takes a script around `oracle.exe` and
  `compare.exe`. The corpus runner (0.11) could run both on each unit
  it preprocesses with Clang and keep the counts in its run record.
- [Medium] (0.7b) Types that `typec` does not compute, which the
  comparison counts as unknown on the corpus: `va_list` parameters and
  functions with the attribute `no_sanitize_thread`. Reproducer:
  `/Volumes/Optaine/type-c-corpus-cache/build/darwin-x86_64/lua/clang/src/lapi.tc.ref.i`.
- [Low] The order of the oracle's records is what shows which of the
  nodes that share a range is outermost, and it holds only because
  Clang writes a node's range before its children. A field with each
  record's depth among the expressions would state it.
- [Low] test/run/target.t keys the expected plain-char signedness,
  wchar_t and __float128 on `uname -m` (x86_64, amd64, aarch64), a hand
  list that each new host spelling extends; take the expectations from
  the backend's own macros (__CHAR_UNSIGNED__, __WCHAR_TYPE__,
  __SIZEOF_FLOAT128__) instead.

## Design questions without a gate yet

- [Medium] When package 3.4 makes universe names typedef names to the
  parser, it implements design 2.3's exception to C11 6.7.6.3p11 (a
  universe name in a parenthesised parameter declarator is the parameter)
  and 2.2's old-style case (an error), each with a test; until then
  `Universe` leaves every universe name an ordinary identifier to the
  grammar.
- [Medium] `private`, owner decisions taken by default (design 9.2),
  each in one place: `File.owns` compares `M.tci` and `M.tc` without
  their directories, as the backend names an interface by the `-I` path
  it found it through; the primary source file is the bottom of the
  stack of files that the line markers describe (`File.main`), so an
  `M.tc` that another file includes owns nothing of `M.tci`; only Type-C
  text is bound (`Expressions.refuse_private_creation`), so C text may
  cast to a private distinct type; a variant declared `type N;` in one
  file and defined `private` in another belongs to the file of the
  definition. The check is syntactic: `sizeof((symbol)1)`, `(void)` of
  such a cast and the identity cast `(symbol)s` are refused too.
  Confirm each and say so in 9.2 rules 1 and 2. The names compare after
  `Filename.basename`, which splits on `/` only.
- [Medium] Design 9.2 rule 4 excuses "C code or unchecked Type-C", but
  Type-C text makes a private value without a cast or a constructor
  through a pointer or a union: `symbol *q = (void *)&n; return *q;`,
  `*(instruction *)p`, `union { unsigned u; symbol s; }`. Name these in
  rule 4 as outside the rule (refusing pointer conversions would break
  `malloc` code), or tie them to the checked mode of section 11.
- [Medium] Distinct types, owner decisions taken by default (design
  3.4): a qualified representation (`distinct const int`) is refused;
  an argument of a distinct type to a function without a prototype is
  refused as `...` is, since both promote it; Type-C or C text is
  decided by the first token of the operation, for an implicit
  conversion by that of the converted expression, and for a value that
  no operator reads (an array length, a designator, `goto *`) by its
  own; a builtin that operates on the object its first argument points
  to (`__atomic_*`, `__sync_*`) refuses one of a distinct type, loads
  and stores too; an `asm` operand refuses a distinct value.
- [Medium] Distinct types: C text sees the representation at every
  level, so a C-text operation on a Type-C value gives U where the
  object is D: with a header macro `M(p)` that is `*(p)` on `id *p`,
  Type-C `v == M(p)` is refused and `M(p) == v` accepted (the text of
  the operation's first token decides). Decide whether a C-text result
  that designates a Type-C object keeps its distinct type.
- [Medium] Distinct types: a `Targeted` position is both the target type
  of design 3.3 and the type an implicit conversion goes to, which
  differ where an initialiser elides braces; so the conversion check
  skips structure and array targets and `Initialiser.reach_of` checks
  the scalar again through `converts`. Give the initialiser's `value`
  both types and let `positioned` check the scalar alone.
- [Low] Distinct types in C text: GNU `typeof` of an expression keeps
  the distinct type, so `__builtin_types_compatible_p(typeof(p),
  unsigned *)` in C text still compares a distinct type.
- [Low] Distinct types: `Distinct_operand` carries a `Ctype.t`, so
  `refuse_mixed` has an unreachable case; carry the `Ctype.distinct`.
  The bit-field narrowing that GCC applies is skipped for a distinct
  member in C text too.
- [Low] Type-C text cannot name a tag that a type declaration claims
  (design 10.1 rule 6); C text in the same unit can, and names the
  lowered structure. Say so in the design or refuse it there too.
- [High] Owner decisions taken by default, each in one place: `{0}`
  zeroes a structure whose first member is a variant, reaching its tag
  through elided braces (`Initialiser.zeroes_variant_members`); `(void)v`
  discards a variant (`Expressions.discards`); `_Generic` on a variant is
  a type query, as `sizeof` is (its controlling expression is a whole
  use). Confirm each and say so in design 3.2 rules 6 and 7.
- [Medium] A selection that depends on what typec does not know hides a
  variant from design 3.2 rule 6: Type-C text may write
  `__builtin_choose_expr(__builtin_constant_p(n), v, v).tag` and the
  same through `_Generic`, as the result has an unknown type; and the
  body of a Clang block literal is not typed at all. Where every
  candidate is a variant, refuse the operation in Type-C text. The
  check of rule 6 could also move to where `Expressions` opens a
  record's members, as `Initialiser` checks it, deciding the text by the
  member's token rather than the first token of the operation (a line
  marker inside an expression makes them differ).
- [Medium] `offsetof(struct s, v.tag)` in Type-C text reaches the tag of
  the variant member `v`: `Expressions` refuses `offsetof` of a variant
  but does not resolve the member path of `offsetof`, so it cannot see
  one that passes through a variant. Resolve the path through
  `Ctype.find_member` and refuse a variant on it.
- [Medium] A name that a variant derives (design 10.1 rule 6) may be a
  keyword of the backend: `type _Static = | assert;` lowers to the
  enumerator `_Static_assert`, which the backend refuses. The claim
  functions of the parser are the one funnel for derived names (they
  refuse `__tc_` there); give the parser's state the keyword set and
  refuse a derived keyword there too, and the instance names of 10.3
  (`type vector_ = | i;` derives `vector__i`) when 2.1 defines them.
- [Medium] Whether a variant completes `type N;` is read from
  `declared.earlier` by Lowering, Declarations and the tree dump, which
  holds only while no other type declaration has an `earlier`; and
  Declarations keeps the incomplete variant's structure in a table of
  its own beside `tag_types`. Carry it in the tree
  (`Variant of { completes; constructors }`).
- [Medium] The names a variant claims are listed in the parser, in
  Declarations and in two test helpers, and the layout of 10.1 is built
  both as text (Lowering) and as a `Ctype` (Declarations). Let `Tree`
  give the derived names of a declaration once, for all of them.
- [Low] Type-C text names a derived enumerator or tag inside the
  arguments of a GNU attribute (`aligned(e_A)`), which the parser does
  not read; see the attribute-argument item above.
- [Low] A pragma between a field and its `,` or `)` lands before the
  `;` that lowering puts there, which the backend refuses, as it
  refuses the pragma in a parameter list. Insert the `;` after the
  field instead.
- [Low] A `va_list` field is a value type to `Value_type`, which models
  `va_list` as neither an array nor a structure (design P20), though on
  x86-64 it is an array and cannot be assigned. Decide in design 3.2
  rule 4 whether a field may have it.
- [Low] A type declaration in a span that the parser does not read, the
  arguments of a GNU attribute or the body of a function that a system
  header defines, is emitted unlowered and fails in the backend. Refuse
  it there, or say in design 13.3 that those spans hold C only.
- [Low] Lowering takes the type declarations that `Declarations` reads,
  so one in a node that the reader does not visit would go unlowered.
  Every node probed is visited; the parser, which meets each one, could
  hand them over instead.
- [Low] Each edit of the emitter is wrapped in two line markers, so
  `--emit-c` shows a lowered alias over eight lines. An edit whose text
  and replaced tokens hold no newline could go without them.

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
  conflicting types, and which `Declarations` records on a function;
  and `gnu_inline`, which changes what an inline definition defines
  (`sys/cdefs.h` uses it under GCC, not Clang) and which `Declarations`
  records on a function.
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
