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
| 1.8 | Diagnostic catalogue with stable codes; a negative golden test for every rule of the design. |
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
   size and speed within measurement noise at `-O2`. The C twin carries
   the guarantees of its Type-C program: its `switch` on a tag traps on
   a tag that is none of the constructors, as every `match` does (design
   4.5), so a `default` arm of the `match` becomes cases for the
   remaining constructors before a trapping `default`; and the payload
   fields a binding reads are copied into locals when the case is
   entered (design 4.1). The gate then measures the cost
   of the lowering, not of the guarantees.
5. Pilot A builds, passes the original compiler's tests, and its record is
   written up.
6. A C comparison catalogue shows what Stage 1 catches that C does not.
   Each entry pairs a C program with its Type-C counterpart and records,
   for GCC and for Clang, whether `-Wall -Wextra` gives a diagnostic and
   which other warning would (`-Wswitch-enum`; `-Wimplicit-fallthrough`
   on Clang). The Type-C side gives the code of the rule that refuses it
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
| 2.4 | `try`: typing, the three positions, lowering; the rule against dropped results. |
| 2.5 | `defer`: the rules, the jump constraints, lowering with name hygiene; interplay with `try`, `match` and loops. |
| 2.6 | Pilot B: a binary reader or a parser with a single error path. |

Pilot B records the statements rewritten to fit the `try` positions
(P8), the uses of `void` type arguments (P7), the code size and the
refusal and diagnostic counts that the P9 row of design section 15
lists, which is the one list of them, how often rule 5 of section 6 and
design 4.3 refused a label address `&&L` that no `goto *` is given
(design 4.4), how often a block literal was refused (P24), whether
instance names read well in a debugger (P10), and the counts of type
definitions that the P23 row lists (decided at Stage 3).

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

**Purpose.** Design sections 7 and 8.

**Work packages**

| | Package |
| --- | --- |
| 3.1 | Generic function declarations: opaque type parameters and body checking. |
| 3.2 | Calls: deduction and explicit instances. |
| 3.3 | Instantiation and emission: per-unit instances, typedef substitution, recursion limit, and rule 8 of design 3.5 for function definitions (P23). |
| 3.4 | Slices and `str`: the universe declarations, `[]`, the three functions, literal typing, the const conversion. |
| 3.5 | A container library written as a test: a vector, a hash map that takes its operations as function pointers, and a region allocator, used from several translation units with several element types. |
| 3.6 | Measurements: code growth from duplicated instances, cost of bounds checks and of function-pointer operations, compile time. |

**Exit gate**

1. The library compiles in separate translation units and runs with
   several element types; there are no duplicate symbols; a clean build
   and an incremental build give identical output.
2. Every operation that is invalid on a type parameter is rejected at the
   definition, not at a use.
3. Out-of-range slice accesses trap; the negative tests for slices pass.
4. The measurements of 3.6 are written up.

**Decided at the gate:** P11 to P14, P23, and whether the measured cost of
function-pointer operations is evidence for constraints (design section
12). **Release 0.3.**

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
| Golden tests | The C and the diagnostics for a given source, including stable codes. |
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
- The repository that pins the corpora and holds the pilots.
- The choice of pilot A, and of the conformance suite for the corpus.
