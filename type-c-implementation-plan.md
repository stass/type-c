<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Type-C implementation plan

This plan stages the work of building the language specified in
[type-c-language-design.md](type-c-language-design.md) ("the design"). Each
stage lists what it builds, its work packages, the gate that ends it, and
the provisional decisions (design section 15) that the gate settles.
Estimates are omitted on purpose: each gate is measured, not predicted.

## Ground rules

- **A work package is one narrow change that ends in one reviewed commit**,
  with its tests. Packages are listed in dependency order. A package that
  turns out larger than that is split before it is started.
- **Tests in proportion.** A package runs the tests it can affect while it
  is developed and the full suite once before its commit.
- **Corpora and run data stay out of this repository.** A separate
  repository pins each corpus by URL and hash; documents here cite it by
  path and commit.
- **Security is a requirement from Stage 0.** The compiler reads untrusted
  source: no shell, no execution of input, bounded recursion, fuzzing as a
  gate.
- **Supported backends and hosts.** Clang and GCC, from the releases that
  `Target.minimum_major_version` names (design 13.3). macOS on arm64, Linux on
  x86-64 and arm64 with glibc and musl, and FreeBSD.
- **A gate is passed or the stage continues.** A gate may also end with the
  decision to stop or change course; Stage 0 and Stage 6 say how.

## Implementation language

`typec` is written in OCaml 5 and built with dune.

- Why: the compiler is tree definitions and transformations, which variants
  and exhaustive matching serve directly; every change to the tree is
  flagged by the compiler while the design is still moving; and a tool that
  parses untrusted input is memory-safe by construction.
- Cost: the compiler cannot be its own pilot, so the pilots below are other
  programs; contributors need OCaml; building from source needs opam.
- Dependencies are kept to the OCaml standard library and the Unix
  library. Test-only tools may use more (a JSON reader for the typing
  oracle).
- Rewriting the compiler in Type-C is a separate decision, taken after the
  core is released (Stage 7).

Target layout of the repository:

```text
bin/            the typec executable
src/driver/     command line, backend invocation, temporary files
src/cpp/        reader for preprocessed text: tokens, line markers, pragmas
src/syntax/     tokens, tree, scopes, parser
src/sema/       types, target model, constant evaluation, typing
src/check/      Type-C rules
src/emit/       span emission and lowering
test/unit/      library tests
test/golden/    source in, C or diagnostics out
test/run/       programs compiled, run and compared with expected output
test/abi/       C callers against generated code, layout assertions
tools/          corpus runner, typing oracle, fuzz harness
```

## Stage 0: the C front end and pass-through

**Purpose.** Prove the premise on which everything else rests: `typec` can
read real C, including system headers, and cannot change it. No Type-C
feature is built here.

**Work packages**

| | Package |
| --- | --- |
| 0.1 | Skeleton: dune project, license headers, a README with the build and test commands, and a driver that forwards every argument to the backend. |
| 0.2 | Reader for preprocessed text: tokens, literals, line markers, pragmas, and the file each token belongs to. |
| 0.3 | Span emitter and the round trip: read, emit, compile with `-x cpp-output`. First object-identity test. |
| 0.4 | Target model from the backend's predefined macros. |
| 0.5 | Tree and parser for declarations and expressions: specifiers, declarators, typedef scopes, struct, union, enum, initialisers and designators, all C11 expressions including `_Generic` and compound literals; function bodies brace-matched. |
| 0.6 | Parser for statements and function bodies, including old-style definitions, with block-scope typedef names. |
| 0.7a | GNU profile syntax: attributes, `__extension__`, alternate keywords, assembler labels and statements, `typeof`, statement expressions, case ranges, the GNU forms of empty structures and initialisers, the syntax of `__builtin_va_arg` and `__builtin_offsetof`, and the macOS SDK's block pointers, nullability qualifiers and fixed enumeration types; the all-headers translation unit parses. |
| 0.7b | GNU profile types: the table of builtin functions, `__int128` and `_Float` types, vector types, block pointers, fixed enumeration types, `typeof`, the attributes that typing reads, the types of `__builtin_offsetof` and `__builtin_va_arg`, `__auto_type`. Done after 0.9b, on its expression typing. |
| 0.8 | Types: representation, compatibility, composite types, promotions, usual arithmetic conversions. |
| 0.9a | Declarations to types: specifiers and declarators, tags, typedefs, scopes and linkage at file scope; integer constant expressions. |
| 0.9b-1 | Expression typing in function bodies: lvalues and their conversions, operators with promotions and the usual arithmetic conversions, identifiers through the parser's resolutions, members, calls with prototypes and default argument promotions, casts, `sizeof` and `_Alignof` of expressions, `typeof` of expressions, statement expressions; block-scope declarations bound and typed; statement constraints the typer needs. |
| 0.9b-2 | Initialisers and compound literals, completing array types; address and arithmetic constant expressions. |
| 0.9b-3 | `_Generic` selection; the expression type a Type-C rule queries. |
| 0.10 | Typing oracle: compare the type `typec` gives each expression with Clang's AST dump. |
| 0.11 | Corpus runner and platform sweep; fix the tail it finds. Several commits, one per class of construct. |
| 0.12 | Fuzz harness for the reader and the parser; resource limits. |

**Corpus**, to be confirmed with a license check before anything is
fetched: a C conformance test suite, the SQLite amalgamation, Lua, zlib,
musl, QBE, chibicc, and randomly generated programs from Csmith. Plus one
translation unit per host that includes every standard and POSIX header.

**Exit gate**

1. Every corpus program compiles as Type-C, with the suffix forced, under
   Clang and GCC on every host, and its own tests pass.
2. For each of them the object file equals, byte for byte, the one built
   from the same preprocessed text without `typec`, at `-O2` without debug
   information.
3. The all-headers translation unit parses on every host.
4. The typing oracle reports no disagreement on the corpus outside a
   reviewed allow-list.
5. A fuzzing run of agreed length ends without a crash or a hang.

**Recorded at the gate:** the time the front end takes against the
backend's `-fsyntax-only` pass on the same input. It is a measurement and
gates nothing.

**Decided at the gate:** P16 (does any construct need an aggregate layout
value) and P19 (the front end of its own stands).

**Change of course.** The long tail of extensions is the main risk of the
whole project. If, after the sweep, three new corpus programs in a row
each still need front-end changes, stop and choose between narrowing the
supported hosts, reading header declarations from Clang's AST dump while
keeping the parser for Type-C text, and an implementation inside Clang.

## Stage 1: variants, distinct types and `match`

**Purpose.** The first useful release: design sections 2, 3.1 to 3.4, 4,
9.1 and 9.2, with the representation of 10.1, 10.2 and 10.5.

**Work packages**

| | Package |
| --- | --- |
| 1.1 | Words, the universe scope, and `type` declarations: parsing, scope, forward declarations, the alias form. |
| 1.2 | Variant declarations: checks, lowering, reservation of derived names. |
| 1.3 | Target types and constructor expressions, qualified and unqualified; lowering as compound literal and as initialiser; `{0}`. |
| 1.4 | Distinct types: the operation table; `_Generic` resolution. |
| 1.5 | `match`: patterns, bindings, exhaustiveness, lowering with the trap. |
| 1.6 | Reachability, arm termination and the jump rules. |
| 1.7 | `.tci` files, the owner rule and `private`. |
| 1.8 | Diagnostic catalogue with stable names; a negative golden test for every rule of the design. |
| 1.9 | ABI tests: C callers in both directions, layout assertions, both backends. |
| 1.10 | Pilot A. |
| 1.11 | The single-pattern test (design 4.6): parsing, typing, the jump rules, lowering. The rule on a `break` that does not end its arm (design 4.3 rule 5). A negative golden test for each rule. |
| 1.12 | Pilot A written with the single-pattern test. |

**Pilot A.** Port the tree of an existing C compiler, its AST or IR with
the passes that walk it, to variants and `match`. chibicc and QBE are the
candidates; the choice and its license check open the package. The port
lives in its own repository and records:

- lines changed, and the casts and tag tests removed;
- identifiers renamed and header macros broken (design 2.3);
- constructor resolutions that surprised the author (design 3.3);
- the size of the data against the original (design 10.1);
- matches with one `case` and a `default`, as a share of all matches;
- sites that update a payload in place (design 4.1);
- how a module of several files used `private` (design 9.2);
- friction that fits none of the above;
- the bugs the port would have caught: each bug-fix commit in the
  original's history whose bug falls in a class of the C comparison
  catalogue (exit gate 6), with the reasoning that puts it in that class
  and whether the port refuses the bug when it is reintroduced.

**Exit gate**

1. Adding a constructor makes every affected `match` fail with a diagnostic
   that names it.
2. Tests show: a missing `break` is an error; `return` and `continue` end
   an arm; a `break` in an inner loop does not; stacked labels share a
   body; a `default` receives no invalid tag.
3. A private variant is built in its owner, matched in a second Type-C
   file, and read from a C file that declares the layout of design 10.1 by
   hand.
4. Differential tests against hand-written C give the same output, and
   size and speed within measurement noise at `-O2`. The C twin declares
   each variant as design 10.1 lays it out, one union member per
   constructor, and carries the guarantees of its Type-C program: its
   `switch` on a tag traps on a tag that is none of the constructors, as
   every `match` does (design 4.5), so a `default` arm of the `match`
   becomes cases for the remaining constructors before a trapping
   `default`; and the payload fields a binding reads are copied into
   locals when the case is entered (design 4.1). The gate then measures
   the cost of the lowering, not of the representation or the
   guarantees. Speed is the count of
   instructions a program retires in user mode, read from the hardware
   counters of the FreeBSD test host (`pmcstat`), not its wall time:
   that host is never idle, and its load moves wall time by more than
   the differences the gate looks for, while the instruction count of
   a run of a billion instructions repeats to within a hundred. Within
   noise then means the same count up to its spread between runs. The count of
   unhalted core cycles is recorded beside it and gates nothing: it
   moves with the load, but it shows the stalls on memory, which a
   program bound by memory spends its time in and the instruction
   count cannot see, so a lowering that costs only in memory, as a
   wider layout, shows in the cycles alone.
5. Pilot A builds, passes the original compiler's tests, and its record is
   written up.
6. A C comparison catalogue shows what Stage 1 catches that C does not.
   Each entry pairs a C program with its Type-C counterpart and records,
   for GCC and for Clang, whether `-Wall -Wextra` gives a diagnostic and
   which other warning would (`-Wswitch-enum`; `-Wimplicit-fallthrough`
   on Clang). The Type-C side gives the name of the rule that refuses it
   (package 1.8). The entries:
   - a constructor added without updating every `match` (4.2), beside a
     C `switch` on the kind that has a `default` or an `int` kind field,
     the forms `-Wswitch` misses; a `match` with a `default` hides the new
     constructor too, and the entry says so;
   - a payload reached outside `match`, under the wrong tag or with no
     tag test (3.2 rule 6);
   - a missing `break` at the end of an arm (4.3);
   - a value of one distinct type used as another or as its
     representation, and an operator 3.4 does not allow on it;
   - a private value made outside its owner, between Type-C files and
     apart from the zero value, written `{0}`, `{}` or `(T){0}` (9.2);
   - an invalid tag, from a cast or a union, which C reads as a stray
     member and Type-C traps on at run time (4.5); this entry checks the
     trap, not a diagnostic. An uninitialised tag is outside Stage 1
     (checked mode, 11.2).

   Each entry for a feature that Pilot A's port uses is also injected into
   the port and refused there; the record names the features it uses.

**Package 1.12.** Pilot A's matches of one `case` and a `default`, and
the predicate and accessor functions that only ask for one constructor,
are rewritten with the single-pattern test. The record gives:

- matches that keep a `default`, as a share of all matches;
- tag tests that the form does not fit, by shape (negated, joined with
  `&&` or `||`, of several constructors), and the predicate functions
  that stay for them;
- code size against package 1.10's port.

**Decided at the gate:** P4, on the numbers of package 1.12: the
`default` warning stays off and the single-pattern test stays a
condition, with a field list optional in a test (design 4.2, 4.6).
**Release 0.1.**

## Stage 2: generic types, `result`, `try` and `defer`

**Purpose.** Design sections 3.5, 3.6, 5 and 6. Generic types come before
`try` because `result` is one.

**Work packages**

| | Package |
| --- | --- |
| 2.1 | Generic type declarations and applications: identity, lazy instantiation and limits. `void` is an argument here wherever the substituted definition is valid C, as in `ptr(void)` with `type ptr(T) = T *;`; a variant field whose type becomes `void` (design 3.5 rule 6) is refused as a construct of package 2.3. The one check of the resolution property (design 13.5), built here and applied to type definitions (rule 8 of design 3.5); packages 2.4 and 2.5 pass the operand of `try`, deferred statements and the operand of a `return` through the same check and add none of their own. The packing bracket with its probe (design 10.3), and the driver's refusal of `-fpack-struct` without a value (design 13.2), in `src/driver/cc_option.ml`. |
| 2.2 | Instance names and emission order; property tests that the naming is injective. |
| 2.3 | The universe types `option` and `result`; the variant field whose type becomes `void` (design 3.5 rule 6), which ends the refusal of package 2.1. |
| 2.4 | `try`: typing, lowering, and its first three holders, each with the `try` as the whole of its expression: an expression statement, the right operand of a simple assignment that is one, and the initialiser of a declaration; the rule against dropped results. |
| 2.5 | `defer`: the rules, the jump constraints, lowering with name hygiene; interplay with `try`, `match` and loops. |
| 2.6 | Pilot B: a binary reader or a parser with a single error path. |

Pilot B lives in a repository of its own, as Pilot A does, and design
section 15 cites its record by path and commit. It records the
statements rewritten to fit the `try` positions and the statements
refused for a pragma (P8), the uses of `void` type arguments (P7), the
code size and the counts of refusals and of diagnostics for P9, how
often rule 5 of section 6 and design 4.3 refused a label address `&&L`
that no `goto *` is given (design 4.4), how often a block literal was
refused (P24), whether instance names read well in a debugger (P10),
and the counts of type definitions that the P23 row lists (decided at
Stage 3). The decided rows P7 to P10 of design section 15 are the
record of what it found.

**Exit gate**

1. Pilot B has one error path, releases every resource on every exit under
   fault injection, and runs clean under the address and undefined
   behaviour sanitizers.
2. Tests cover `return`, `break`, `continue` and `goto` through deferred
   statements, a `defer` that is conditionally reached, and every rejected
   jump.
3. Code size of pilot B with the repeated-cleanup lowering is measured
   against a hand-written `goto cleanup` version.

**Decided at the gate:** P7 to P10. **Release 0.2.**

## Stage 3: generic functions and slices

**Purpose.** Design sections 7 and 8, and the nested patterns of
design 4.7. Nested patterns stand here because their rules read
the generic types of Stage 2, `option` and `result` among them,
and the opaque type parameters of package 3.1. `try` inside
expressions (design 5.1 rule 3) stands here because the container
library and the README are its first users, and because a `try` in
a generic function is lowered in an instance of package 3.3.

**Work packages**

| | Package |
| --- | --- |
| 3.1 | Generic function declarations: opaque type parameters and body checking. |
| 3.2 | Calls: deduction and explicit instances. |
| 3.3 | Instantiation and emission: per-unit instances, typedef substitution, the nesting limit, the instance budget, the output limit and the bound on encodings of design 3.5 rule 7, and rule 8 of design 3.5 for function definitions (P23). |
| 3.4 | Slices and `str`: the universe declarations, `[]`, the three functions, literal typing, the const conversion. |
| 3.5 | A container library written as a test: a vector, a hash map that takes its operations as function pointers, and a region allocator, used from several translation units with several element types. |
| 3.6 | Measurements: code growth from duplicated instances, cost of bounds checks, without optimisation as well as with it (P28), and of function-pointer operations, compile time. The bytes of text that each unit of the library and of the pilot counts for its instances in the front end, the bytes that lowering charges for it and their ratio to its source, and its longest encodings of one instance, against the instance budget, the output limit and the bound on encodings of design 3.5 rule 7 (P30). The bytes of a `long double` that the zero initialiser leaves, counted by the functions of its test on both backends at `-O0`, `-O2` and `-O3` (design 13.5): a record, and no test. The refusals, by their names, of design 7.3 rule 4 (P27) and of design section 8 rule 9 (P28), and the slice indexes and `slice_sub` expressions that stand where C does not evaluate them (P28), in the library and the pilot. The slice tests that hold a call or a statement expression in an operand after the first, and the cost of volatile temporaries for those alone (P28). What a slice index reaches, and where a call stores through the address of an element that it holds across another argument, when the full expression that holds the index is resumed after its function has begun to evaluate it again, the limit of design section 8 rule 10, on both backends at `-O0` and at `-O2`: a record, and no test. |
| 3.7 | The selection tree of design 4.7 rule 6: a function from the typed labels of a match to its tree, with the checks of design 4.2 and the bound of design 4.7 rule 10 read from the tree and from nowhere else. Matches without nested patterns keep their diagnostics. Unit tests on label sets written as data, nested ones included, and a property test: for generated label sets and every value up to a depth, the tree selects the label that a matcher which tries the labels in order selects and reads no tag that the matcher does not, and it reports as missing or never selected exactly what the values show. |
| 3.8 | Nested patterns in `match` (design 4.7): the grammar, sub-patterns typed by their position, typed bindings, `*`, bindings at any depth, and the lowering of selection (design 13.5). A negative golden test for each rule. A bare identifier that binds a field of variant type is refused from this package on (design 4.7 rule 3), so the tests that hold one take the typed form. In the README, the `case Err(error):` of the `result` section and the second `match` in its arm become the nested labels `case Err(Missing(name)):` and `case Err(NotANumber(name)):`; the first example, whose `show` writes `case Err(DivByZero):`, and Status say that nested patterns are built. |
| 3.9 | Nested patterns in the single-pattern test (design 4.6, 4.7 rule 9), in `if` and in `while`: typing, the field list left out at any depth, lowering. |
| 3.10 | Measurements of nested patterns: selection against hand-written nested `switch` statements, size and speed, on both backends at `-O0` and at `-O2` (P31); the largest selection tree in the container library, the pilot and the tests (P32). |
| 3.11 | `try` inside expressions (design 5.1 rule 3, 13.5), after packages 3.3 and 3.4: `try` as a unary operator; one function of the typed tree from a `try` to its holder and the operators between them, which gives every refusal of place, `try-list` among them; one function from a holder to its prelude and its edits, in the order of 5.1; the hoisted operands passed through the one check of the resolution property (package 2.1) and the pragma stretch, and through one walk of their own for `try-lifetime`: a compound literal in an operand under a condition, and an array that is no lvalue in any; `try-lvalue` and `try-loop`, and `try-void` by the discarded positions of design 5.2. A negative golden test for each refusal, and the tests of package 2.4 that refuse a `try` for its place take the places that stay refused. Before a `try` in a generic function is lowered so, the TODO item on `Moved` edits in the definition of a generic is closed. In the README, the first example and Status say that `try` inside an expression is built. |
| 3.12 | Measurements of `try` inside expressions, from a script under `tools/measure`: the preludes of the container library, the pilot and the README against the same code with each `try` in a declaration of its own, size and speed, on both backends at `-O0` and at `-O2`, and the holders that hold a side effect before a `try` which C leaves unsequenced with it (P33); the refusals of `try-loop` and what each loop became (P34); the refusals of `try-list` and what each refused initialiser holds beside its `try` (P35); the refusals of `try-pragma` (P8). |

**Exit gate**

1. The library compiles in separate translation units and runs with
   several element types; there are no duplicate symbols; a clean build
   and an incremental build give identical output.
2. Every operation that is invalid on a type parameter is rejected at the
   definition, not at a use.
3. Out-of-range slice accesses trap; the negative tests for slices pass.
   Each run test of the lowered form (design 13.5, "The check of a
   slice") has a partner that fails where the test is missing, on both
   backends at `-O0` and at `-O2`:
   - an index and a `slice_sub` whose operand holds a compound literal
     read its elements after the expression; the partner indexes one
     past the literal and traps;
   - `sizeof(s[0])` and `sizeof(slice_sub(s, 0, 1))` size arrays of
     file scope and draw no diagnostic; the partner, an index out of
     range in a `sizeof` whose operand is a variable length array,
     traps;
   - `sizeof(s[c])` with `c` of type `char` draws no diagnostic under
     `-Wall`; the partner, the lowered text without the unary plus of
     its index, is reported under `-Wchar-subscripts`;
   - an index in range stores once where C evaluates the operand of a
     `sizeof` by the value of a layout constant that `typec` holds
     opaque (design 13.3),
     `sizeof(*(c ? (int (*)[s[i] = 5])p : (void *)(sizeof(struct four) - 4)))`
     with one `int` in `struct four`; the partner, the same index out
     of range, traps and stores nothing;
   - the form of an index and of a `slice_sub` that C does not
     evaluate, taken from the lowered text and compiled in an operand
     that C evaluates, traps before it evaluates an operand; the
     partner, the same text without its trap, evaluates them;
   - operands that count their evaluations are evaluated once in an
     index, a `slice_sub` and a `slice_from_array`; the partner, a
     `slice_from_array` of a variable length array, is refused;
   - `slice_from_array` initialises an object of file scope under
     `-pedantic-errors`; the partner, an index that C evaluates in the
     head of a function, is refused;
   - an initialiser of file scope in parentheses,
     `slice(int) b = (slice_from_array(a));` and `static e x = (B(1));`,
     and a `slice_from_array` as the argument of a constructor,
     `option(str) o = Some(slice_from_array(letters));`, compile under
     `-pedantic-errors` on both backends and hold their values; the
     partner, the lowered text with the compound literal inside the
     parentheses and as the payload, is refused by GCC;
   - a `slice(int)` converts to `slice(const int)` in an argument, an
     assignment, a `return` and either operand of a conditional
     operator whose other operand is a `slice(const int)`, with an
     operand that counts its evaluations evaluated once, and
     `slice(const int) c = slice_from_array(a);` initialises an object
     of file scope under `-pedantic-errors`; the partners, the lowered
     text with the compound literal of `slice(int)` in that
     initialiser and with the operands of the conditional operator as
     the source has them, are refused by both backends;
   - a string literal initialises a `str` of file scope under
     `-pedantic-errors` and holds its length without the NUL; the
     partner, `slice_from_array` of an array of arrays, is refused by
     `typec` (design section 8 rule 2, 3.5 rule 2);
   - `slice_from_array` of an array of `int` compiles without a
     diagnostic under `-pedantic-errors -Wall -Wextra` in a block, at
     file scope, in a return type, in the size of a member and in a
     parameter list, `void f(char x[sizeof(slice_from_array(a))])`;
     the partner, one of an array whose elements have size 0, a
     structure without members and `int[sizeof(struct four) - 4]`, is
     refused by both backends for the negative size of an array
     (design 13.5), in a block, at file scope and in a parameter list;
   - an index whose operand returns a second time reaches the element
     of its index again where its function has not begun to evaluate
     it in between, with `setjmp` in a statement expression and with a
     call of `getcontext` as the operand; the partner, the same run
     with an index out of range at the second return, traps.
4. The measurements of 3.6 are written up.
5. Nested patterns behave as design 4.7 says. Each test has a partner
   that fails where the rule or the lowered form is missing, and the
   run tests run on both backends at `-O0` and at `-O2`:
   - `case Err(DivByZer):` is refused with a message that names
     `DivByZer` and `eval_error`, also in the scope of an object and
     of an enumeration constant named `DivByZer`; the partner,
     `case Err(eval_error DivByZer):`, compiles and is selected for
     every `Err`;
   - `case Cons(head, Nil):` at a field that points to a variant with
     the constructor `Nil` is refused; the partner,
     `case Cons(head, *Nil):`, compiles and is selected for a tail
     that holds `Nil` and for no other;
   - a match with the labels `Ok(value)`, `Err(DivByZero)` and
     `Err(Overflow)` compiles; without its last arm it is refused with
     a message that names `Err(Overflow)`, and a constructor added to
     `eval_error` makes it fail with a message that names `Err` of
     that constructor; the partner, the match with a `default`,
     compiles, and its `default` takes the new constructor;
   - `case Add(l, r):` before `case Add(*Num(a), *Num(b)):` is refused
     at the second label; the partner, the two in the other order,
     compiles and selects the first for two numbers and the second
     for every other `Add`;
   - a `default` written before the `case` labels takes only what no
     label matches; the partner, a `default` after labels that match
     every value, is refused;
   - with `case Pair(Left, _):` before `case Pair(_, *Leaf(n)):`, a
     value that holds `Left` and a null pointer selects the first arm;
     the partner, a value that holds another constructor and a null
     pointer, is stopped by the address sanitizer at the match;
   - a field of variant type whose tag is overwritten with no
     constructor's value traps in a match that names a constructor at
     the field; the partner, the same value in a match that binds the
     field or writes `_` for it, runs its arm;
   - a scrutinee and an operand that count their evaluations are
     evaluated once in a `match`, once in an `if` test and once for
     each iteration of a `while` test; the partner, the lowered text
     with the operand written again where the tree reads its second
     tag, counts two;
   - in a generic function, `case Some(x):` on an `option(T)` binds the
     field in an instance whose argument is a variant; the partner,
     `case Some(Some(y)):` there, is refused at the definition;
   - each run test has a twin in C with nested `switch` statements
     written by hand, which gives the same output, and its lowered
     text compiles under `-pedantic-errors` with the options that the
     tests of `match` use; the partner, the twin of the test of two
     overlapping labels with its labels' tests exchanged, differs;
   - a match whose tree passes the bound of design 4.7 rule 10 is
     refused as a limit of `typec`, within the time of the unit
     tests; the partner, a match of the same shape whose tree stays
     under the bound, compiles;
   - the property test of 3.7 passes; the partner, the same test over
     a tree that is built from the labels in reverse order, fails;
   - the fuzzing of the parser and the checker (Tests) starts from a
     corpus that holds nested patterns.
6. `try` inside expressions behaves as design 5.1 rule 3 says. Each
   test has a partner that fails where the rule or the lowered form
   is missing, and the run tests run on both backends at `-O0` and
   at `-O2`:
   - `two(try a(), try b())`, where `a` and `b` both fail, returns
     the error of `a`; the partner, the lowered text with each
     `try` written where it stands as a statement expression that
     returns, gives the error of `b` under GCC;
   - `emit(out, pos++, try next(in))` with a `next` that fails
     leaves `pos` as it was; the partner, the same call after
     `int at = pos++;`, finds it one higher;
   - `p && try check(p) > 0` with a null `p` is 0 and does not call
     `check`; the partner, the lowered text without the `if` of the
     prelude, calls it;
   - `c ? try f() : (mark(), try g())` calls `f` alone where `c` is
     not 0, and `mark` and then `g`, each once, where it is; the
     partners, the lowered text without the `else` and the lowered
     text that keeps `mark()` in the holder as well, call `g` after
     `f` and `mark` twice;
   - a holder of two `try` expressions in the scope of a `defer`
     statement whose second operand fails runs the deferred
     statement once, after both operands; the partner, the lowered
     text without the copies in the second test, does not run it;
   - `s[i] + try f()` with `i` out of range and an `f` that fails
     returns the error; the partner, the same with an `f` that
     succeeds, traps;
   - the preludes of these tests, and `try f();` with a `T` of
     `int`, compile without a diagnostic in the ISO and the GNU form
     of C11 and of C17 under `-pedantic-errors -Wall -Wextra
     -Wshadow -Wconversion -Wsign-conversion`; the partner, the
     lowered text of `try f();` with the read of the `Ok` field in
     the holder, draws `-Wunused-value` from both;
   - `use((try f()).name)`, where `name` is an array of `char` and
     `use` takes a `char *`, compiles under `-pedantic-errors`; the
     partner, the lowered text with a `const` temporary, is refused
     by both backends;
   - `x = try c ? f() : g();` is refused as `try-operand`; the
     partner, `x = try (c ? f() : g());`, compiles and calls one of
     the two;
   - each of these is refused under its name, and its partner
     compiles and runs: `while (try more(r))` (`try-loop`) and
     `for (;;) { if (!try more(r)) break; }`;
     `__builtin_constant_p(try f())` (`try-position`) and
     `__builtin_expect(try f(), 0)`, which calls `f` once;
     `sizeof(try f())`, `({ try f(); })` and
     `int a = g(), b = try f();` (`try-position`) and the same
     with the `try` in a declaration of its own;
     `&try f()` (`try-lvalue`) and `&x` after `x = try f();`;
     `x = try v();` with a `T` of `void` (`try-void`) and
     `c ? try v() : try w();`;
     `sizeof(enum { K = 5 }) + try g(K)` (`try-name-capture`) and
     the same with the enumeration declared before the statement;
     `consume(c ? try wrap((int[]){7}) : NULL)` (`try-lifetime`),
     where `wrap` returns `Ok` of its argument, and
     `consume(try wrap((int[]){7}))`, where `consume` reads 7;
     `consume(try wrap(make().a))` and
     `(p = make().a, try read_value(p))` (`try-lifetime`), where
     `make` returns a structure that holds the array `a`, and the
     same two with `m.a` after `struct s m = make();`, which read
     the element, and `try g((try f()).name)`, where `name` is an
     array member of the value of a `try`;
     `int a[2] = { (try set_two(), x = 1), try read_x() };` and
     `int a[2] = { (try set_two(), x = 1), read_x() };`
     (`try-list`), where `set_two` stores 2 in `x` and `read_x`
     returns it, and `int a[2] = { try set_two(), try read_x() };`,
     which leaves 2 in `a[1]`, also where the list is that of a
     compound literal;
   - the fuzzing of the parser and the checker (Tests) starts from a
     corpus that holds `try` inside expressions.

**Decided at the gate:** P11 to P14, P23, P27, P28, P30 to P35, and whether the
measured cost of function-pointer operations is evidence for constraints
(design section 12). **Release 0.3.**

## Stage 4: interoperation and release quality

**Work packages**

| | Package |
| --- | --- |
| 4.1 | `--emit-c-header`, with three decisions (design 9.3): whether a Type-C translation unit may include an emitted header; whether an emitted header carries the type assertions of design 13.4, which it does not by default because they would assert the options of the client's compile; and whether `--emit-c-header` refuses the options that change one of those types, as the driver does for a `.tc` input (design 13.2). |
| 4.2 | Review of diagnostic quality on the pilots; columns where they can be recovered. |
| 4.3 | Build integration: documented rules for make, ninja and cmake; dependency files. |
| 4.4 | A language reference and a tutorial for users. |
| 4.5 | Packaging: opam, Homebrew, a FreeBSD port. |
| 4.6 | Freestanding check: a `-nostdlib` link with `--trap-function` leaves no undefined symbol that the program did not introduce. |
| 4.7 | Pilot C: a freestanding component. |

**Exit gate.** Every provisional decision from P1 to P16 is settled or
defaulted and the design is edited to say so; the three pilots build with
the release; the core language is frozen as **release 1.0**.

**Decided at the gate:** P15 (whether line-granular locations are good
enough, or `typec` gets a preprocessor of its own).

## Stage 5: checked mode, tier 1

**Purpose.** Design sections 11.1 and 11.2.

**Work packages**

| | Package |
| --- | --- |
| 5.1 | The pragmas, checked text, trusted contracts and `unsafe`. |
| 5.2 | Flow analysis over the typed tree: definite assignment and null facts. |
| 5.3 | The tier 1 rules and the inserted checks. |
| 5.4 | A checked interface to part of the C library, as the worked example of a trusted contract. |
| 5.5 | Negative tests for every rule; tests that sanitizers agree with the inserted checks; fuzzing of generated code. |

**Exit gate.** Pilot B is moved into checked text. The record states how
many `unsafe` blocks it needed and why, and which rules rejected correct
code.

**Decided at the gate:** P17.

## Stage 6: lifetimes (conditional)

**Purpose.** Design section 11.3. This stage starts only if tier 1 is in
use and its users ask for more.

| | Package |
| --- | --- |
| 6.1 | A formal model of homogeneous regions: syntax, typing rules and a soundness argument. |
| 6.2 | A prototype checker; pilot A's tree moved to regions. |

**Exit gate.** P18 is decided. If the model is unsound or the pilot shows
the restrictions are unworkable, checked mode stays at tier 1 and the
design says so.

## Stage 7: features on evidence

The features of design section 12 enter one at a time, each as a design
change backed by the evidence its row names. A rewrite of the compiler in
Type-C is considered here, not earlier.

## Tests

| Kind | What it shows |
| --- | --- |
| Golden tests | The C and the diagnostics for a given source, including stable names. |
| Run tests | Generated code behaves as specified, on both backends. |
| Differential tests | A Type-C program and a hand-written C program agree; plain C through `typec` yields identical objects. |
| Typing oracle | The front end types C as Clang does. |
| ABI tests | Layout assertions; C and Type-C calling each other across translation units, optimisation levels and targets. |
| Property tests | Exhaustiveness, reachability, instance naming, slice arithmetic. |
| Fuzzing | The reader, the parser and the checker neither crash nor hang; generated code is clean under sanitizers. |
| Freestanding checks | No undefined symbol beyond the program's own. |
| Benchmarks | Dispatch, construction, generic containers, `try`, bounds checks, compile time, code size. |

## Security

- The compiler is memory-safe and runs no input. Subprocesses are started
  from argument vectors; intermediate files live in a private temporary
  directory.
- Lowering introduces no undefined behaviour of its own: unions are read
  through their declared members, checks precede the pointer arithmetic
  they guard, and index arithmetic is unsigned.
- Every trap is tested to fire. No option removes one.
- Each claim in design section 14 has negative tests, and each stage's
  review pass asks explicitly for security findings.

## Risks

| Risk | Signal | Response |
| --- | --- | --- |
| The tail of C extensions does not end | Stage 0 change-of-course condition | The three options listed there |
| The front end types C differently from the backend | Typing-oracle disagreements; backend errors in lowered code | Fix; the backend still compiles every token, so a divergence is loud |
| Diagnostics without columns or macro context are too weak | Pilot records | A preprocessor of its own (P15) |
| The first release is awkward for real code | Package 1.12's numbers on tag tests the single-pattern test does not fit; Pilot A's numbers on in-place updates | A wider single-pattern test (design 4.6); binding by reference (design section 12), which waits for a lifetime tier |
| Duplicated instances bloat binaries | Stage 3 measurements | External instances (design section 12) |
| The design moves under the implementation | Rework of merged packages | Gates settle provisional decisions before the next stage builds on them |
| Too few OCaml contributors | Review latency | Keep the code plain: no advanced type-level features |

## Open logistics

- Where the continuous-integration hosts for Linux and FreeBSD run.
- Where the repository that pins the corpora and the repositories of
  the pilots are hosted.
- The choice of pilot A, and of the conformance suite for the corpus.
