<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# TODO

Work that is worth doing and is not a work package of
[type-c-implementation-plan.md](type-c-implementation-plan.md). "Design"
is [type-c-language-design.md](type-c-language-design.md).

## Before Stage 0 starts

- [Medium] Decide where the corpus repository is hosted: it exists
  locally at `/Volumes/Optaine/type-c-corpus`, with no remote, and its
  README says what it holds. (`tools/hosts` runs the Linux hosts in
  containers, the arm64 ones under emulation, and the FreeBSD one over
  ssh, on a machine of the owner's.)

## Driver

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
- [Medium] A command that links a `.tc` input with another input
  (`typec -g a.tc b.c -o a`, or with `b.o`) compiles each `.tc` input
  to a temporary object first and loses the side outputs of that step
  with the object: with `-g` on macOS the `.dSYM` bundle (the backend
  runs `dsymutil` only for a link that compiles a source), the `.dwo`
  files of `-gsplit-dwarf` and the `-fstack-usage` and
  `-fcallgraph-info` files. A link of `.tc` inputs alone compiles the
  emitted C in its final command and keeps them. Doing that always
  would give the other inputs the `-std=gnu11` (when the command line
  has no `-std=`) and `-Wno-gnu-line-marker` that the emitted C needs.
  Decide whether that is acceptable, and then delete the object path,
  or keep the path for those command lines.
- [Low] The steps of the pipeline get `-Wno-unused-command-line-argument`
  so that Clang does not warn about the options of the whole command
  line that a step does not use; GCC ignores it, but adds a note that
  names it to any diagnostic of that step. Pass it to Clang only once
  the driver knows the backend's family.
- [Low] With Clang the debug information names the compilation unit
  after the emitted file, an absolute path in the random temporary
  directory (GCC names it after the `.tc` input), so a Clang build with
  `-g` is not reproducible and names a file that no longer exists. Name
  it after the input, for example with `-fdebug-prefix-map` or by the
  line markers that Clang reads.
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
- [Low] The static assertions that end a lowered unit
  (`src/emit/assumptions.ml`) see the options in effect where the unit
  ends. GCC's `#pragma GCC optimize ("short-enums")` and
  `("single-precision-constant")` change the types of the declarations
  and constants after them (measured with GCC 16), so a region between
  `#pragma GCC push_options` and `pop_options` passes unseen; so may
  `__attribute__((optimize))` (unmeasured). Refuse those pragmas in a
  unit with Type-C constructs, or assert the type of each enumeration
  at file scope where the unit ends.
- [Low] The target query gives the backend typec's stdin, which it never
  needs; a stray `-` among the options makes it read the terminal. Give
  it `/dev/null`.
- [Low] An empty macro dump, as from `--print-target -o FILE`, reports
  one missing macro chosen by record field evaluation order. Report an
  empty dump as such.

## Reader of preprocessed text

- [Low] `Spans.spell_text` checks only that the tokens are in order and
  within the text: the text the reader keeps is its input by
  construction. Check instead that each identifier's written bytes,
  read alone, give one identifier of the name its token carries.

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
- [Low] Diagnostics of later stages print names and spellings from the
  text, and file names from line markers (`Expressions.needing`), where
  a crafted name can hold control bytes or a fake `[TC0018]`; route them
  through the escaping of `Reader.error_message`, and
  cut a quoted spelling, such as a number that is no constant, to a
  bounded length so that a huge token cannot make a huge message.
- [Medium] `Rule.c_text` takes free text, so a site can still write a
  Type-C refusal without its code as a refusal of C text, and whether
  each of its sites cites C11 or the GCC manual rests on review. Give it
  a structured citation (C11 clause, GCC manual section, translation
  limit) that renders the parenthesised clause, so that no design
  citation can be written there; about 15 sites cite nothing yet.
- [Low] `Rule.diagnostic`, `message`, `c_text` and `text` are OCaml in a
  string of `rule_codegen.ml`, sealed by an `include (struct ... end :
  sig ... end)`; move them to a hand-written `diagnostic.ml` and `.mli`
  over the generated `Rule.code` and `Rule.clause`, so the generator
  emits only what the table derives.
- [Low] The rule `Profile` has no clause, so each of its ten sites
  writes "(design 13.3)" or "(design P16)" by hand, and only two tests
  assert its code. Give it the clause (the P16 sites keep P16 in their
  prose) and assert `[TC0031]` at each site.
- [Low] A diagnostic gives the file and the line but not the source line
  that design 13.6 says it carries; print the line of text under it.
- [Low] A carriage return that no newline follows is a blank to the
  reader, but Clang 21 and GCC 16 end a line of `-x cpp-output` input
  there: the backend counts one more line, and a pragma line that holds
  `\r#pragma pack(1)` is two directives to it but one to typec. `cc -E`
  writes one only in a line marker of GCC's for a file name that holds
  it, and GCC then refuses its own output. Refuse such a carriage
  return, so that the lines of the reader are always the backend's.
- [Low] `#ident` and `#sccs`, which `cc -E` passes through, are refused
  as unsupported directives. Pass them through like a pragma if a corpus
  uses them.

## Parser

- [Low] Design 2.3 refuses an identifier that begins with `__tc_`
  anywhere in the text, C text included; the parser checks the grammar
  tokens only, not the identifiers of a `#pragma` line
  (`Token.Identifiers`). Decide whether a pragma's identifiers count,
  and refuse them there if they do.
- [Low] Where a declaration hides `try` or `defer` (design 2.3), Type-C
  text that writes the construct gets a plain syntax error at the token
  after the word (`expected ; after return, found f`), which does not
  say that a declaration hides the word or where it is. A hidden
  universe name gets no such note either. Add a note naming the
  declaration if the pilot shows the error confusing. Until work
  packages 2.4 and 2.5, a bare unhidden word in operand position
  (`x + defer`, `sizeof try`) says the construct is not implemented
  rather than that it is a syntax error.
- [Low] A type name as the controlling operand of `_Generic` (C2y,
  `_Generic(const int, const int: 1, int: 2)`), which GCC 16 and Clang
  accept in gnu11, is a syntax error. Read it, with its type unconverted,
  if the corpus has one.
- [Low] `&&a` of a label that is not defined is left to the backend,
  which refuses it: the parser keeps the arguments of an attribute as
  tokens, and both backends compile `&&b` where `b` is defined in a
  statement expression in `__attribute__ ((aligned (sizeof ({ b: 0;
  }))))` once optimization drops the address. Refuse it where the
  parser resolves labels once it reads attribute arguments as
  expressions, if a consumer needs that.
- [Low] Two GNU rules that both backends enforce are left to them: a
  case or default label inside a statement expression for a switch
  outside it (GCC manual, "Statement Exprs"), and `&&a` in the
  parameters of a block literal, which typing does not read. Check the
  first with the case labels in `Expressions`.
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
- [Low] `Reachability.label_refusal` checks the jumps into a statement
  expression and into a guarded statement (design 4.3 rule 3) in a
  second walk, which must visit every node where the parser reads a
  labelled statement: a goto whose label that walk misses passes
  unchecked. Make both checks where the parser resolves labels, which
  knows the statement expressions and the arm around each label and
  jump, and delete the walk's queues of definitions and jumps.
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
- [Medium] `[[gnu::x]]` is read as the GNU attribute `x` even where
  Clang has no `gnu::` spelling of it: Apple Clang 21 gives
  `__has_c_attribute(gnu::x)` 0 for `overloadable`, `availability`,
  `unavailable`, `cpu_dispatch`, `cpu_specific`, `diagnose_if`,
  `noescape`, `flag_enum` and others, so `[[gnu::overloadable]]` is
  ignored by Clang and read as an overload by `typec`. Record the
  `gnu::` spelling per entry of `attribute_effects`, as the `clang::`
  spelling is, after measuring GCC's spellings too.
- [Low] An attribute's vendor prefix travels as a string that the
  parser joins and `declarations.ml` splits, and `attribute_name`
  strips `__` from any prefix, so `[[__clang__::x]]` reads as
  `clang::x` where Clang normalises only `__gnu__` and `_Clang`. Give
  `Tree.attribute_node` a structured vendor field with one scope rule.
- [Low] The `clang::` spellings of `attribute_effects` apply whatever
  the backend, so under GCC `[[clang::overloadable]]` makes an overload
  GCC ignores, as `__attribute__((overloadable))` already does. Ask the
  backend (`__has_c_attribute`) once, in `Target`, if this matters.
- [Medium] Design section 6 rule 1 refuses `_Defer` among the tokens
  that typing does not read, through one scan over every such token.
  No such scan exists: `skip_balanced` (`src/syntax/parser.ml`) passes
  over attribute arguments and skipped function bodies without looking,
  so `_Defer` there reaches the backend as written, and the body of a
  block literal refuses it only because the parser refuses every
  `defer` statement (`fail_defer`). When package 2.5 builds `defer`,
  build the one scan over the tokens that typing does not read (it
  also refuses the word `defer` in an attribute argument of Type-C
  text, design section 6 rule 1), with
  no check of its own for any kind of such text. The scan also takes
  over the text rules of a block literal (`refuse_type_c_text_in_block`)
  and of a skipped function body (`skipped_body`), which run as checks of
  their own (design 13.3).

## Expression typing

- [Medium] Design 13.5: the type name of an association of an answered
  `_Generic`, or an operand of an answered
  `__builtin_types_compatible_p`, is dropped with what it declares and
  uses. A structure, union or enumeration it declares is gone, though C
  declares it in the enclosing scope (6.7.2.3): a later use then fails
  in the backend, or silently means an outer declaration of the name
  (`_Generic(x, d: 1, enum { K = 5 }: 2)` before a use of a global
  `K`). A name used only there, through `__typeof__`, fires
  `-Wunused-variable` or `-Wunused-function`, which fails a `-Werror`
  build. Refuse an answered construct whose dropped type names declare
  a tag or an enumeration constant. Untried: a type name kept as
  `__typeof__((void)(__typeof__(T) *)0, (char (*)[i])0)` might keep
  both, at the cost of a stranger lowering.
- [Low] `Expressions.answered` copies the answers that `selections` and
  `compatibilities` hold; recording only the spans answered would leave
  one copy.
- [Low] `Expressions.selected`, `statement_value`, `case_value` and the
  first argument of a moving builtin read a node through
  `operand_typed`, correct because an earlier step typed it; a wrong
  caller raises `Invalid_argument`. Storing the typed chosen operand
  with its selection, and having `block_items` give the typed last
  expression statement, would hand these readers the type by data flow.
- [Medium] Design 3.3's target under elided braces is the first
  variant, because only a variant target changes a meaning today. `str`
  string literals (section 8, P13) and generic deduction (7.2) also take
  meaning from the target: before they land, state the rule as the first
  subobject on the elision chain whose type gives the target a meaning.
- [Low] `Ctype.first_variant` follows the elision chain that
  `Initialiser.first_level` encodes too. Split a pure first-subobject
  step that both use, keeping the rule 6 refusal at the callers that open
  a record.
- [Low] Under `{0}` rule 7, a constant that is no valid 0 (`{0i}`, an
  integer too large) is refused as reaching into the variant rather
  than with the constant's own error.
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
- [Low] `Integer_constant.binary` raises on a comparison and
  `Integer_constant.comparison` on any other operator; only the order of
  the arms of `Expressions.classify_node` routes each operator to its
  function. Give the comparisons a type of their own in
  `Tree.binary_operator` (for example `Comparison of comparison`), so
  that a misrouted operator does not compile.
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
- [Medium] With GCC, a member found through a qualified anonymous member
  has an unknown type, which hides a variant from design 3.2 rule 6:
  `struct t { const struct { e v; }; };` lets Type-C text read `x.v.tag`
  of a `struct t x`. The `Anonymous_member` difference should leave only
  the qualifiers unknown, or the member funnel that `.`, `->` and the
  member path of `offsetof` share should refuse a variant on the declared
  member type; `offsetof` reads the declared type already, so the two
  disagree until then.
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

- [Low] `check_distinct` compares the associations of a generic
  selection in pairs: 20000 of them take 26 s, where GCC and Clang, as
  quadratic, take 4 s.

- [Low] `Initialiser.reach_of` converts the raw type of an initialiser
  itself, which drops the `_Atomic` of a call or cast
  (`Expressions.value_type` keeps it), so with
  `_Atomic struct s as(void);` typec reads `struct w { struct s a; } v =
  { as() };` as initialising `a` whole, where Clang elides its braces
  and refuses the initialiser. Clang lets an `_Atomic` subobject take
  `T` and `_Atomic T` whole, and a plain one only `T`; the typing
  callback could give the value type beside the raw one.
- [Low] An integer constant expression of an `_Atomic` type, as
  `(_Atomic int)1`, is decided from its type in an enumerator, an array
  length and `_Static_assert` and through `operand` in a case label, so
  with Clang typec accepts the first three, which Clang refuses, and
  refuses the last; with GCC, which accepts all four, the unknown type of
  the cast makes typec refuse an enumerator and a file-scope array
  length. One path for whether a constant expression has integer type
  would settle both.
- [Low] Clang refuses `aip += 1` with `int *_Atomic aip` and GCC accepts
  it; typec accepts it with both.
- [Low] The diagnostics of a qualified constructor `T.C` quote only the
  first token of `T`, so `list(int).None` reports that "the variant
  'list'" has no constructor `None`. Quote the whole type name.
- [Low] Names in diagnostics are cut in two ways: `Expressions.quote`
  at 64 bytes, which may split a UTF-8 sequence, and
  `Declarations.shown_instance` at 200 bytes on a character boundary;
  the variant message of `Initialiser.refuse_opening` cuts none, and an
  instance name may be thousands of bytes long. Use one cut, on a
  character boundary, everywhere a name is quoted.
- [Medium] Two guarantees of the names derived from an instance rest on
  callers, not on types: `Spelling.instance` takes the encodings of the
  arguments as plain strings, and `Ctype.instance` is a public record,
  so a name that no encoding made can become a `Spelling.c_name`; and
  `Ctype.define_variant` and `define_variant_instance` refuse the other
  kind of tag only at run time. Give encodings a private type that only
  the encoder makes, and hand the `define` of
  `Ctype.declare_variant_instance` a definer bound to its tag.

## Declarations

- [High] A type argument holds no attribute (design 3.5 rule 2), and
  typing does not check it yet: an attribute or a nullability qualifier
  written in the argument, or one with which a typedef name that the
  argument uses, at any depth, is declared (`vector(wide)` where `wide`
  is `int` with `aligned(16)`). An attribute that makes a type unknown
  is refused already, as the type has no row in design 10.3; one that
  `attribute_effects` reads as neutral, `aligned` among them, and
  nullability, which `qualifiers_of` drops, are not. Record on each
  typedef name whether its declaration holds one, and walk the
  argument's type name. Also refuse a type parameter in the arguments of
  an attribute in a generic's definition (`aligned(sizeof(T))`), which
  the parser keeps as an unread token span: the parser, which resolves
  the parameter, is the place.
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
- [Medium] The return-form marks of design 13.3 are not in
  `attribute_effects`: mark `overloadable`, `unavailable`,
  `availability`, `diagnose_if`, `cpu_dispatch`, `cpu_specific`,
  `target_clones` and `target_version` when package 2.5 builds the
  return form.
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
- [Low] `enum e;` before `enum e : int;`, which GCC and Clang refuse,
  is accepted, as is `enum e : int x;`, a fixed type outside
  `enum e : int;` alone, which C23 and Clang refuse; the backend reports
  each.
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
  declarator, and Ctype keeps no typedef to tell them apart. A distinct
  referenced type gives itself unqualified instead, as design 3.4 needs,
  so `__typeof__` of the result may lose such a qualifier under Clang.
- [Medium] Distinct types: an implicit conversion between a distinct
  type and an unknown one is accepted, since `refuse_distinct_conversion`
  refuses only where `Ctype.compatible` answers false: `u = d` where `u`
  is declared through a `__typeof__` that typec leaves unknown, and so a
  move-only atomic builtin (design 3.4 rule 5) on such an object. Refuse
  it in Type-C text, as design 13.5 refuses an unknown that may hide a
  distinct type.
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
- [High] Pragma lines in a generic's definition. Design 10.3 makes a
  generic whose definition holds a pragma an error (P25), and nothing
  reports it: `Emitter.token` makes no piece of a pragma line or of a
  `#` punctuator, so lowering could only drop the token. Part 9 of
  package 2.1 refuses such a generic with a rule code of its own, a
  generic type and a generic function alike. Tests: a generic with a
  `#pragma` line and one with a `_Pragma` operator are refused with
  that code, and the same definitions without the pragma give
  instances. The design does not say what becomes of a `#` punctuator
  in a definition, which `Emitter.token` drops as well: in an attribute
  argument, which the parser skips, dropping it would change the
  argument. Refuse it in part 9 too unless the design gives it a piece.
- [Medium] The order of edits that `Emitter.emit` takes is made by the
  sort at the end of `Lowering.edits`, and a test that adds a bracket
  (`test_lowering.ml`, `bracketed_after_forward`) repeats it. A bracket
  at the anchor after a variant's forward declaration is valid only as
  an insertion that sorts before the head replacing the name, so part 9
  of package 2.1, which merges brackets with the edits of lowering,
  would repeat it again. Keep the order in one place: one function that
  merges edits, or the sort in `Emitter.emit`.
- [Medium] The record of what a generic's definition uses and declares,
  which `Resolution.check` reads, is complete only while every lookup of
  a use in `state.entities` and `state.tag_types` goes through
  `entity_used` or `prior_tag`, and every declaration through
  `bind_entity` or `bind_tag`. Make the two tables an abstract module in
  `declarations.ml` whose only lookup of a use and only binding record
  them, with separate, named accessors for the comparison at a place,
  the type parameters of an instance, the final types of enumerators
  and the builtins, so that a new lookup cannot skip the record.
- [Medium] `note_own` takes the scope of a declaration in a generic's
  definition from the reader's `state.place`, which a block read for a
  statement expression leaves at file scope: `type g(T) = struct { T v;
  int a[sizeof(({ int k = 1; k; }))]; };` is refused as declaring `k`
  around the text (TC0039), where the backend would refuse the
  statement expression at file scope anyway. Let the parser, which
  knows every scope, record in `Tree.declared` and `Declares` whether
  the declaration's scope is file scope, and read that instead; generic
  functions (package 2.2), which have bodies, need it right.
- [Medium] Design 13.5 refuses an identifier of unread text that
  denotes a constructor where C declares its spelling, and refuses the
  identifiers of the second unread-text rule in all Type-C text.
  `Resolution` checks only moved text, and cannot tell a constructor:
  the parser's views hold none, as a target type selects one (3.3).
  Decide with package 2.3 how unread text names a constructor, and check
  the rule for Type-C text that does not move at its own place.
- [Low] Design 3.5's example `type named(T) = struct { str name; T
  value; }; int str; named(int) n;` is valid, but the parser reads
  `str` as an ordinary identifier until package 3.4 gives it its
  meaning. Add it to `generic_resolution` in `test_declarations.ml`
  then.

- [Medium] The needs of a type complete (design 10.3) are calls of
  `Declarations.needs_complete` at each construct of the list, so a
  construct that typing reads and the list misses leaves an instance
  declared and not defined, which the backend refuses. The lvalue
  conversion (C11 6.3.2.1p2) is the open end: it is met where each
  operation takes its operand (`read_operand`, a targeted position,
  the branches of `?:`, a comma, a cast, an expression statement), not
  in one place. Make the conversion one function of `Expressions`,
  whose result an operand can only be read through, and give it the
  need; `Ctype.define_instance` is likewise reachable from any module
  that its comment does not bind.
- [Low] A function definition needs its parameter types complete as
  its declarator is read and its return type after, the reverse of the
  text, while design 3.5 rule 7 fixes the order in which the needs of
  a definition are visited; which application a nesting error cites,
  and the order of `Declarations.definitions`, can differ from the
  rule's.
- [Medium] A constant expression may depend on a type parameter
  through an untagged structure body in it (`char k[2 - sizeof(struct
  { T q; })]` in a generic's definition is accepted), as
  `Ctype.mentions_opaque` does not look into members. The parser,
  which allows a body there, is the place: no structure or union body
  in an expression of a generic's definition (design 3.5 rule 4).
- [Low] A generic name longer than `Encoding.max_length` refuses each
  application with a message that blames its first argument; refuse
  such a name at its declaration.
- [Low] Typing refuses every type in an expression of a generic's
  definition that mentions a type parameter (`sizeof(T *)` among them),
  where design 3.5 rule 4 and 7.1 rule 4 refuse an expression whose
  value depends on one. Say the simpler rule in the design, or relax
  the check.
- [Medium] The opaque value type of a definition check is a structure
  without members (`Ctype.declare_opaque`), which is exact for generic
  types but not for the bodies of generic functions (design 7.1 rule
  3): such a structure may be passed through `...` and is refused the
  initialiser `{0}`. Give it a shape of its own when generic functions
  are typed.
- [Medium] `Ctype.instance` holds the encodings of its arguments as
  plain strings, so a caller can build one from a string that
  `Encoding.encode` did not make, which need not be self-delimiting.
  Make the encoding a type that only `Encoding` makes when instances are
  built.

- [Medium] `Declarations` reads only a C typedef by the rule of design
  3.5 rule 2 that names an untagged type: a Type-C alias of an untagged
  enum or of a qualified untagged struct or union names nothing, so
  `type e = enum { A };` and `type s = const struct { int x; };` have
  no row where the design gives `1e` and `K1s`. Read an alias by the
  same rule as a typedef.
- [Low] The enumeration of a variant's tags is declared with the tag
  `N_tag`, so it is encoded `T5N_tag`, a row of a tag of its own
  specifier that design 10.3 does not give a derived enumeration. Give
  the design a row for it, or `Ctype.enum_tag` a derived name.
- [Low] Whether a tag is declared at file scope is read from the
  reader's place (`Declarations.at_file_scope`), a second model of the
  scope that the parser chooses for it. A generic definition that opens
  a scope without a place of its own would mark a tag in its body as at
  file scope. Have the parser record the kind of scope in the tag's
  binding.

## Matching

- [Medium] typec does not check that `&` takes no `register` object
  (C11 6.5.3.2p1): `register struct s r; (&r)->m` is a backend error.
  Record in `typed` that an lvalue designates a register object, or a
  member or element of one, as `bit_field` is recorded; then `address`
  refuses it, and `access_of` in `src/sema/expressions.ml` reads that
  fact and `lvalue` instead of walking the syntax in `addressable`.
- [Medium] `--trap-function=name` (design 10.5) is not implemented: a
  trap is `__builtin_trap()` alone. Add the option to the driver and
  pass the name to lowering, with a run test on both backends. The name
  is the program's, so a block may hide it where a trap is written,
  against design 13.5 (every name lowering writes is claimed or
  reserved): say in 10.5 how the call reaches it, for example through
  one `__tc_` function defined at file scope.
- [Low] `case A: L: case B:` in a match is refused under design 4.3
  rule 3; the rule it breaks is 4.1 rule 2 (a label of the match stands
  directly in its body). Give the label under a named label its own
  message.
- [Low] Every match names its pointer `__tc_match`, which is safe only
  because each reference sits inside the block that declares it. A name
  unique per match (by the token index of `match`) would make that hold
  by construction.
- [Low] Design 13.5 names the invented names that are one of a kind
  (`__tc_ret`, `__tc_r`, `__tc_t0`, the probes) but not `__tc_match`,
  `__tc_copy` and `__tc_tag`, which lowering writes. Its rule (no `__`
  after the prefix) holds for them, as `test/unit/test_naming.ml`
  checks on the emitted C; add them to that paragraph, or state the
  rule alone without the list.
- [Low] Invented names are string literals in lowering, the emitter
  and the assertions, and `test/unit/test_naming.ml` finds them by
  scanning the C of one sample unit, with a count of the names it
  expects: a name of a construct the sample lacks goes unchecked. Make
  one module mint every invented name, with a constructor for a name of
  one of a kind that refuses `__` and one for a kind word and its rest,
  so design 13.5's rule holds by type. The kind words (`slice_index`,
  `arg`, `module`, `header`, `pack_probe_1`, `pack_probe_2`) are not in
  the code yet; with that module the test can check that no universe
  function name is another kind's word.
- [Low] `Ctype.same_type` holds `Unspecified`, `Old_style []` and
  `Old_style [int]` to be three types, while design 10.3 encodes all
  three `N` and Clang takes `typedef int (*t)();` and
  `typedef __typeof__(&f) t;` for an old-style `f` as one type. typec
  accepts that pair too, so the old-style list may never reach
  `same_type`; find whether it can, and if so compare lists without a
  prototype as one, so that `test/unit/test_naming.ml` can draw them.
- [Low] Where `match` is a typedef name, `match (f(void)) { ... }` in a
  block, a GNU nested function, now reports an expression error rather
  than the GNU profile's refusal of nested functions.
- [Low] An arm is a block (design 4.1 rule 5), but the parser refuses
  GNU `__label__` at the start of its items ("expected an expression,
  found `__label__`"), which a compound statement accepts. Either read
  local labels at the start of an arm, which lowering already places at
  the start of a block, or say in 4.1 that an arm declares none.

## Fuzzing

- [Medium] Offer the OCaml AFL patch upstream
  (`tools/fuzz/patches/ocaml-5.5.2-afl.patch`). AFL++ on macOS hands the
  coverage map over only as a POSIX shared memory descriptor
  (`__AFL_SHM_FD`), and the runtime of OCaml (`runtime/afl.c`, 5.5.2 and
  trunk) attaches only a SysV segment and speaks only the old fork-server
  handshake, so the fuzz build needs a patched compiler (README,
  "Fuzzing"). Raise there too that the map size is defined twice, as
  `INITIAL_AFL_AREA_SIZE` in `afl.c` and `afl_map_size` in
  `asmcomp/afl_instrument.ml`, and the runtime reports the former. Once
  OCaml takes both changes, drop the patch and pin the release that has
  them.

## Test hosts

`tools/hosts` runs the suite on Debian 13 (glibc) and Alpine 3.24
(musl) in containers, each on x86-64 and on arm64 (the latter under
emulation), and on FreeBSD 16.0-CURRENT over ssh, x86-64.

- [Low] Two runs of `tools/hosts/freebsd.sh` on one `DIR` at once are
  not guarded: each empties the other's source and corpus.
- [Medium] `tools/hosts/run.sh` (`take_results`, `changed_records`) and
  `tools/hosts/freebsd.sh` (`check_records`, `copy_records`) each check
  and copy the records a host sends back, in different ways, and
  `run.sh` accepts any one host directory and any record names. Give
  both one funnel that takes only the records of the host, programs and
  compilers of the run, with `runs/` removed before the run instead of
  comparing against what was sent.
- [Low] Neither host script bounds the size of the results a host sends
  back, so a host that runs hostile corpus code can fill the local disk.
- [Medium] In `test/run/abi.t` the C side declares the Type-C functions
  with the hand-written tags `struct c_scalar` and the like, while the
  lowering uses `struct scalar`: across translation units the types are
  not compatible (C11 6.2.7), which works at the ABI but would trip
  `-fsanitize=cfi-icall`. Let `hand.h` spell its names through one
  prefix macro that `layout.tc` sets to `c_` and `side.c` leaves empty.
- [High] Stage 1 exit gate 4 does not hold for size as stated, and
  its speed is not yet settled. `tools/measure/gate4.sh` (results in
  `/Volumes/Optaine/typec-gate4/results.md`), with twins that carry the
  guarantees of the `match`, finds `shapes` and `ids` equal in code size
  on both backends and `shapes` within noise in time. What remains:
  1. one union member per constructor (design 10.1): GCC 16 makes
     `tree` 51 bytes larger, where `main` keeps three arms storing
     constructors of the same layout separate (17 jumps against 14);
     giving the twin's union one member per constructor accounts for 49
     of the 51 bytes, and the other 2 are unexplained; clang gives equal
     code;
  2. clang runs the Type-C `tree` 4.6% faster than its twin with a
     noise of 10%, so whether the speed-up is real, and which construct
     gives it, is not settled;
  3. the `ids` walk, bound by memory, and the clang `tree` timing were
     inconclusive on a host at load 8 to 11 (interquartile ranges up to
     a third of the run time): rerun on an idle host before the gate is
     signed off.
- [Medium] On GCC 16 the trapping `default` of a `match` in a hot loop
  costs about 18% in `shapes`: its loop over the array keeps an index
  counter beside the pointer, while a twin without the `default` (and
  so without the guarantee of design 4.5) does not. Reproduce by
  dropping the `default` from `tools/measure/gate4/shapes.c` and
  running `gate4.sh`. The twins carry the same `default`, so the gate
  does not see it. Is the lowering of the default (design 13.5) worth
  changing, for example to one trap block shared by the `match` sites
  of a function, without weakening design 4.5?
- [Low] No host sets `TYPEC_TEST_REQUIRE_M32`, which makes `dune test`
  fail when the backends cannot compile `<limits.h>` with `-m32`. The
  Dockerfiles install no 32-bit headers; `tools/hosts/freebsd.sh` probably
  has them but passes only `TYPEC_TEST_CLANG` and `TYPEC_TEST_GCC` to the
  remote `dune test`. Once a p620 run prints no `-m32` note, pass the
  variable there.
- [Low] `test/run/abi.t` does not carry `compound` from Type-C to C or
  through a callback, nor a distinct type as a variant field.
- [Low] `tools/oracle/oracle.t` has its own default of
  `TYPEC_TEST_CLANG` instead of sourcing `test/run/backends.sh`.
- [Medium] The arm64 hosts run under qemu-user 10.2.3 (registered with
  `tonistiigi/binfmt --install arm64` after uninstalling the VM's 7.0.0
  handler; a `colima restart` may bring 7.0.0 back, which kills about 1
  in 100 GCC compilations). Both hosts build and run the suite; their
  remaining failures are the items of this section. A native arm64
  machine would settle the provisional causes and remove the emulator
  from the results.
- [Medium] `Target.architecture` is the first of a list of predefined
  macros that the backend defines, while Clang decides where it has
  `__builtin_setjmp` by the TargetInfo of the triple; the two agree on
  every triple tried with `--target` (arm64ec needed `__arm64ec__` before
  `__x86_64__`), but nothing makes them agree on another. The calls of
  `expressions.t` for AArch64 and ARMv7 cover two of the architectures;
  PowerPC, SystemZ and VE are untested.
- [Medium] `test/unit/test_small_stack.ml` fails on both arm64 hosts
  with `FAIL: the backtrace names the stage`. In OCaml 5.4.1 native code
  on arm64, when a stack reaches its limit the `Stack_overflow` carries
  an empty backtrace: 0 frames on the main fiber and 2 after the
  re-raise of `Small_stack.run`, where amd64, and bytecode on arm64,
  give 1024. `caml_call_realloc_stack` in `runtime/arm64.S` pops the
  argument pair that holds the caller's `x30` and raises with `x30`
  pointing into the stack-check stub of `asmcomp/arm64/emit.mlp`, which
  has no frame descriptor, so `caml_stash_backtrace` stops at once;
  amd64 raises with the real return address. Report it to OCaml with
  the fix `ldr x30, [sp, 8]` before the `add sp, sp, 16` (unbuilt,
  untested). Provisional: the cause is read from the source and seen
  under qemu-user only; the path makes no system call, so native arm64
  should fail too, which one run there would settle. Reproducer: a
  native program that sets `Gc.stack_limit` to 32K words, catches the
  `Stack_overflow` of a non-tail recursion 64K deep and prints
  `Printexc.raw_backtrace_length` (0 on arm64, 1024 on amd64).

## Corpus

- [Low] The corpus reference compile takes its commands from
  `Pipeline.plan`, so it shares typec's option routing: if
  `Pipeline` dropped a code-generation option from the compile step,
  both objects would lose it and the unit would still report
  identical. If that class of bug matters, give the reference one
  independent check: compare the compile step's options against the
  user's command line.
The front end accepts the 246 units of the corpus with Clang and with
GCC 16 (macOS x86-64), and each gives the object that the backend builds
alone; block pointers and `_Float16` in the SDK's headers have unknown
types (design 13.3).

- [High] Record the whole corpus on one revision of typec and of the
  corpus repository, on every gating host, and commit the records: the
  macOS records of c-testsuite, chibicc, lua and zlib are rewritten but
  uncommitted, and the Linux records of musl and zlib name a corpus
  revision that was `-dirty`. A Linux record comes from
  `tools/hosts/run.sh --corpus` (README, "Linux test hosts").
- [Low] The runner's command line and the meaning of its status 3 are
  written out in `tools/hosts/corpus-in-container.sh`,
  `tools/hosts/freebsd.sh` and the README's example; `run.sh` and
  `freebsd.sh` could share one script that runs it.
- [Low] `debian-amd64` and `alpine-amd64` write their corpus records to
  the same `runs/linux-x86_64/` and their logs to the same
  `CACHE/build/linux-x86_64/`, since the runner names a host by
  `uname -s` and `uname -m`, so a run of one replaces the other's.
  The name needs the C library if both hosts are to gate.
- [Medium] musl's recipe declares a substitute test (19 checks of
  ours), so gate 1 is not met for it: libc-test needs a system running
  musl. Its recipe links each directory relocatably (`ld -r`), which
  checks less than a shared link would; revisit if a musl host exists.
- [Medium] SQLite's recipe declares a substitute test (a smoke test of
  ours), so gate 1 is not met for it: the amalgamation has no test
  suite. Its own suite needs the full source tree and Tcl.
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
  labels the revision its caller names for the checkout as that at run
  time, because `typec` cannot report the revision it was built from. A
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

## Design questions with a gate

- [High] Package 4.1 decides whether a Type-C translation unit may
  include an emitted header (design 9.3). The include guards are macros
  and do not survive `-E`, so what reaches a Type-C unit is the header's
  text without them: the typedefs of arguments under `__tc_` names, and
  the declarations and definitions of instances. Design 2.3 makes a
  `__tc_` name an error in a Type-C unit, C text included, and an
  instance that the unit also uses would be defined twice, by the
  header's text and by lowering. Either keep the refusal and say in 9.3
  that a Type-C unit includes the `.tci`, or have lowering take an
  instance that an emitted header's text defines as defined. Until then
  a C header that includes an emitted header cannot be shared with
  Type-C units.
- [Medium] Pilot B (plan, Stage 2) counts the label addresses that
  design 4.4's reading of `&&L` refuses though no `goto *` is ever
  given them, such as the kernel's `_THIS_IP_` (`({ __label__ __here;
  __here: (unsigned long)&&__here; })`) in a match arm or in the scope
  of a `defer` statement. If they occur, change the reading as design
  4.4 says.

## Design questions without a gate yet

- [Medium] When package 3.4 makes universe names typedef names to the
  parser, it implements design 2.3's exception to C11 6.7.6.3p11 (a
  universe name in a parenthesised parameter declarator is the parameter)
  and 2.2's old-style case (an error), each with a test; until then
  `Universe` leaves every universe name an ordinary identifier to the
  grammar.
- [Medium] Distinct types, owner decision taken by default (design
  3.4): Type-C or C text is decided by the first token of the
  operation, for an implicit conversion by that of the converted
  expression, and for a value that no operator reads (an array length,
  a designator, `goto *`) by its own. Confirm and say so in 3.4.
- [Low] The builtin table lacks `__atomic_always_lock_free` (GCC and
  Clang; libstdc++ and some C code call it, and both fold it to a
  constant) and Clang's `__scoped_atomic_*`, which LLVM's libc calls;
  typec refuses valid calls of them as undeclared.
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
- [Medium] A selection that depends on what typec does not know hides a
  variant from design 3.2 rule 6: Type-C text may write
  `__builtin_choose_expr(__builtin_constant_p(n), v, v).tag` and the
  same through `_Generic`, as the result has an unknown type. Where
  every candidate is a variant, refuse the operation in Type-C text. The
  check of rule 6 could also move to where `Expressions` opens a
  record's members, as `Initialiser` checks it, deciding the text by the
  member's token rather than the first token of the operation (a line
  marker inside an expression makes them differ).
- [Medium] The instance names of design 10.3 claim nothing yet: when
  generic types and functions are built (Stage 2), claim each instance
  name through the claim functions of the parser, the one funnel that
  refuses a derived name claimed twice, and check a generic function's
  name as a file-scope type name (design 7.1 rule 1). A constructor of
  an instance is in scope everywhere (`Ctype.define_variant_instance`)
  only once its derived names are claimed: until then C text in a block
  may declare `int list__i_Nil;`, which the lowered `list(int) l = Nil;`
  would name. Typing does not declare those names either, so C text
  that names `struct list__i_tag` gets a tag of its own.
- [Low] A type argument that carries a nullability qualifier of Clang
  or a keyword of an address space is refused (design 3.5 rule 2),
  because the encodings of design 10.3 have no row for either. If a
  consumer needs such an argument, as code that instantiates over the
  `_Nonnull` pointer typedefs of an SDK would, give each an encoding
  and a place in the type model, which drops nullability where it reads
  a qualifier (`qualifiers_of` in `src/sema/declarations.ml`).
- [Medium] C text may write the Type-C constructs (design 2.1), and one
  in a body that typing does not read reaches the backend unlowered: a
  header that writes `^{ type x = | a; }` or a match in a Clang block
  literal, or in the body of a function that C text of a system header
  defines (design 13.3). A generic function that C text of a system
  header defines has such a body itself, so no instance can be lowered
  from it, and the design has no rule for it. The refusal of P24 covers
  Type-C text only. Either make the constructs Type-C text only (amend
  2.1, which leaves no such construct in either body) or type block
  bodies with Clang's capture rules (P24) and give the body of a system
  header a rule of its own.
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

- [Medium] Design 9.2 rule 4 leaves to checked mode the operations that
  reinterpret storage as a private value (`*(symbol *)p`, a union member,
  `va_arg`, copying bytes), but section 11 does not name them. Say in
  11.2 which of them checked mode refuses or checks.
- [Medium] In a `.tc` file, `e.A` is refused ("found the type name `e`")
  when a header declares `e`; likely the C-text owner rule near
  `src/syntax/parser.ml:590`. Decide whether that is intended and test
  it either way.
- [Low] With `-g`, the debug information of a typec object differs from
  `cc -x c` on the same file: the backend compiles the preprocessed text,
  so GCC's DWARF columns come from that text and Clang's line table lists
  the line-marker files. Design 13.6 promises debuggers the original
  lines; decide whether columns must match too, and test the -g output
  against the source.
- [Low] Only test/run/pedantic.t and matches.t compile their programs
  with `-std=c11 -pedantic-errors`, so a form that a new lowering adds
  is checked against design 2.4 only if pedantic.t gains it. Give the
  ISO flags from backends.sh to every run-test compile that needs no
  GNU form, so each new run test checks its lowering by default.
- [Low] `Process.start` runs a file without `#!` through `/bin/sh`
  (execvp's ENOEXEC fallback), where glibc's posix_spawnp refused it;
  `tools/oracle/oracle.ml` still starts clang with `Unix.create_process`,
  so on glibc under qemu a missing clang there reads as status 127.
- [Low] Pilot A's Makefile builds chibicc at -O0 -g, where each arm's
  bindings take their own frame slots (design 13.5, after the table);
  build its debug configuration at -Og when package 1.12 rewrites it,
  and record the frame of `gen_expr` and the recursion depth there.
- [Low] Measure whether GCC 15 copies a constructor passed by value
  through a stack temporary, as GCC 13 and 14 do and GCC 16 does not
  (design 13.5, after the table): build `tools/measure/gate4/nodes.c` at
  -O2 with GCC 14, 15 and 16 and compare the text sizes.
- [Low] The trapping `default` of a match adds about 1.3 KB of .rodata in
  Pilot A on both backends (likely jump tables widened by the default's
  target); GCC also splits each trap into a `.cold` partition with its
  own unwind entry (about 2 KB of .eh_frame and code). Find the .rodata
  mechanism before changing the lowering; see the item on the trapping
  default in a hot loop.
- [Low] Two diagnostics from Pilot A's injections: TC0013 gives no
  column and names the owner by the path the backend found it through
  (`./type.tci`); and a binding of another arm used in an arm reads
  "'addr' is not declared (C11 6.5.1p2)" with no code, where a message
  naming the arm that binds it would point at the mistake.
- [Medium] The Linux host images have no csmith, so the csmith recipe
  fails to set up there (`prepare.sh: csmith is not installed`). Add a
  pinned csmith to tools/hosts/debian.Dockerfile and alpine.Dockerfile,
  or limit the recipe's lines to the hosts that have it.
- [High] Write the formal model for checked-mode lifetimes before any
  implementation of tier 2 (design 11.3). Nothing about lifetimes may be
  claimed until it exists.
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
