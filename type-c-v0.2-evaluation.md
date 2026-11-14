<!--
SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
-->

# Evaluation of the Type-C v0.2 proposal

Subject: `type-c-language-design-v0.2.md` at commit `9d5c0c7`. Section
numbers such as "v0.2 1.3" refer to that file, and "v0.2 3 item 5" is the
fifth numbered item of its section 3. "Design" refers to
[type-c-language-design.md](type-c-language-design.md), which supersedes
it, and "plan" to
[type-c-implementation-plan.md](type-c-implementation-plan.md).

## Verdict

The proposal's direction is sound and its restraint is its best feature:
C-shaped `match`, no expression forms, visible costs, honest security
claims. Its weaknesses are in three places.

- **The implementation strategy cannot deliver the language.** The Clang
  probe fails on the first features, and the plan postpones the real front
  end to an undefined "transition gate".
- **Two headline features have no mechanism.** `requires(...)` constraints
  have nothing that resolves them, and the module system is a list of
  artefacts without semantics.
- **The surface language is under-specified where C makes it hard.** The
  new words collide with common C identifiers, "expected type" is not
  defined, arm termination has no rule, and zeroed storage has no meaning.

None of this sinks the idea. The design resolves each finding below, mostly
by removing mechanism rather than adding it.

## What holds up

- The principles, especially "preserve C" with its syntax-preservation
  test, and the refusal to adopt ML syntax for its own sake.
- Statement `match` with `case`, `default` and explicit `break`; no
  expression `match` until code demands one.
- Variants by value with no allocation, exact error types in `try`, and
  `defer` aligned with the WG14 TS.
- The stance on safety: opt-in checking, no claim about arbitrary C, and
  v0.2 section 6, which names the hard problems instead of hiding them.
- The test strategy of v0.2 section 8 and the insistence on a real pilot.
- "Do not start with a general ownership checker."

## Findings

Severity: **Critical** invalidates the plan or a core feature as written;
**High** is a gap that would surface in the first release; **Medium** is a
defect with a contained fix; **Low** is a note.

### Critical

**E1. The Clang probe cannot implement the language** (v0.2 5.1, 5.3, M0
to M2). The prototype lowers extensions to skeleton C and asks Clang for
types. That is circular or impossible for the features it must serve:

- Resolving `Number(42)` by expected type needs the types before valid C
  exists to probe.
- Clang has no distinct scalars. A typedef erases the distinction; a
  wrapper struct breaks casts and comparisons in the probe. Reading typedef
  sugar from Clang's tree works only where Clang happens to preserve it.
- A generic body cannot be "checked once under abstract type variables" by
  a compiler with no type variables.
- The arm-termination rule needs a parsed statement tree of every arm, and
  finding the end of an arm already needs C's declaration-versus-expression
  disambiguation. By M2 the "island parser" is a C parser without a type
  checker.

v0.2 also calls a full C parser "not a sensible MVP commitment" while
principle 7 asks that the language not be shaped by a temporary technique.
*Resolution:* a front end that parses and types all of C from the first
stage, with preprocessing left to the backend and untouched C emitted
verbatim (design 13). The plan's Stage 0 measures the real risk, the long
tail of system-header extensions.

**E2. `requires(...)` has no resolution mechanism** (v0.2 1.5). The text
says constraints are "resolved statically" and imply no dictionaries,
overloads or traits, and section 9 excludes "Rust traits/impl" and
overloading. Nothing remains that could find the `hash` for a given `K`.
The only systems that do this, in Cforall, Rust and Haskell, are the
machinery v0.2 rules out, and v0.2 itself calls the solver "the principal
engineering cost". *Resolution:* type parameters are unconstrained and
operations are passed as function pointers (design 7.1); constraints move
outside the core with stated evidence (design 12).

**E3. The module system is unspecified and outsized** (v0.2 2, 3 item 5,
5.5).
`.tci` is "not a raw textual C header" yet is pulled in by `#include`;
`.tcmeta` carries "typed IR or a specialization recipe"; the driver builds
an interface graph and deduplicates instantiation requests across the
program. No format, identity rule or build protocol is given, and the
result is a compiler that must own the build, in conflict with the "any
build system" expectation of a C extension. *Resolution:* a `.tci` is a
textual header, types follow C's cross-unit rules, and generic instances
are per translation unit (design 7.3, 9.1). `.tcmeta`, export lists and
owner-context specialisation are gone.

### High

**E4. The new words are common C identifiers** (v0.2 1.1). `type`, `match`,
`result`, `str`, `option`, `region`, `ok` and `err` are everywhere in C:
`p->type`, a parser's `match()`, `int result`. v0.2 says they are
"contextual or reserved ... depending on the grammar" and does not decide.
Reserving them breaks field access and every header macro that mentions
them. *Resolution:* only `try` and `defer` are reserved; the rest are
recognised by position, or are shadowable universe names (design 2.3).
Type-C becomes a true superset of C11 (design 2.2).

**E5. "Expected type" is undefined** (v0.2 1.2 rule 1, 1.6). Constructor
resolution depends on it, but v0.2 does not say which positions have an
expected type or what happens when an ordinary identifier of the same name
is visible. *Resolution:* a closed table of target-typed positions and a
precedence rule (design 3.3).

**E6. The milestones are out of order** (v0.2 7). M1 delivers variants and
M2 delivers `match`, but without `match` a variant's payload cannot be
read, so M1's exit gate ("replace a handwritten tag/union") cannot be met.
M3 needs generic `option` and `result` before M4 introduces generics, and
plans "built-in fixed shapes" to bridge the gap. *Resolution:* variants and
`match` are one stage; generic types precede `try` (plan, Stages 1 and 2).

**E7. Arm termination has no rule** (v0.2 1.3). It is "a control-flow graph
property", but C defines no reachability, so two implementations would
disagree on `while (1)`, on calls to `abort`, and on dead code.
*Resolution:* a syntactic definition in the style of Java (design 4.4),
with `_Noreturn` calls counted.

**E8. Zeroed and uninitialised variants** (v0.2 1.2 rules 2 and 6). "Every
datatype value must be initialized by a valid constructor before it is
read" cannot be enforced in default mode. For zero-initialisation, the
commonest C initialisation, v0.2 says only that checked Type-C rejects
relying on it "unless the language explicitly defines a default variant";
it defines none, and default mode is left without a meaning.
*Resolution:* all-zero storage is the first constructor with zero fields,
by construction (design 3.2).

**E9. `result(void, E)`, `ok()` and `try` in `return`** (v0.2 1.6). `void`
as a type argument contradicts "T ranges over complete object types".
`ok`/`err` duplicate the constructors `Ok`/`Err`. "A whole return
expression" as a `try` position does not type-check: `try e` has type `T`
where the function returns `result(U, E)`. *Resolution:* one rule for
`void` arguments, constructors only, and three `try` positions (design 3.5,
5.1).

**E10. A `result` can be dropped silently** (v0.2 1.6). Calling a fallible
function as a statement discards the error, which defeats "one error
path". *Resolution:* an expression statement of `result` type is an error
(design 5.2).

**E11. Generics lack their operational half** (v0.2 1.5, 3 item 5). Not
specified: how a call finds its type arguments, how to name an instance
when deduction cannot, which types may be arguments (qualified, array,
incomplete, block-scope), what linkage instances have, and how instance
names are formed beyond "deterministic". *Resolution:* design 3.5, 7.2,
7.3 and 10.3.

**E12. The lifetime model is unsound as described** (v0.2 4.2 to 4.4). "A
pointer into A may be stored in an object living in B only if A outlives
B", solved as a partial order, ignores that the object's own region must
be known exactly: weaken a pointer to a long-lived mutable object and a
short-lived pointer can be stored through it. Cyclone and Rust spend most
of their type systems on this. v0.2 is right to defer the feature and
wrong to describe it as a matter of solving `outlives`. *Resolution:*
checked mode is split; lifetimes are an open problem with one candidate
and a formal-model gate (design 11.3).

**E13. No concise test for one constructor** (v0.2 1.3). Compiler code is
full of `if (n->kind == ND_NUM)`. With statement `match` alone, each
becomes a five-line `match` with a `default`, on which v0.2 also wants a
warning. This is the likeliest complaint about the first release. *Not
resolved by adding syntax:* the design records a candidate, `if (case
P = e)`, and the measurement that decides it (design 12, P4).

**E14. Bindings are modifiable copies** (v0.2 1.3 rule 7). Assigning to a
binding compiles and changes nothing visible. *Resolution:* bindings are
non-modifiable (design 4.1); binding by reference is outside the core.

**E15. `private` has no owner** (v0.2 2). "Within the defining
implementation" presumes a module identity that textual inclusion does not
give. *Resolution:* the owner is the declaring file and its paired `.tc`
(design 9.2), extended to distinct types, and stated not to be a security
boundary.

**E16. Slice checks only in checked mode** (v0.2 1.8). A slice whose index
is unchecked by default is a struct with a misleading name. *Resolution:*
`s[i]` always checks; `s.data[i]` is the unchecked spelling (design 8).

### Medium

**E17. `uint32_t` tag** (v0.2 3 item 1). Debuggers show a number. *Resolution:*
a generated enum (design 10.1, P3).

**E18. Constructors as inline functions** (v0.2 3 item 2). A function call is
not a constant expression, so `static expr x = expr.Number(1);` would not
compile. *Resolution:* compound literals and braced initialisers (design
13.5).

**E19. A source `default:` and invalid tags** (v0.2 3 item 3). If the lowered
`switch` reuses the user's `default`, a corrupted tag runs user code.
*Resolution:* the lowered `switch` names every constructor and its
`default` is always the trap (design 4.5).

**E20. Distinct types have no operation set** (v0.2 1.4). Truth tests,
`{0}`, bit-fields, variadic arguments and `_Generic` are unaddressed, and
"a declared derived operation" is not defined. *Resolution:* a closed table
(design 3.4).

**E21. `defer` lowering** (v0.2 1.7, 5.4). "Flags" are unnecessary once
jumps past a `defer` are banned, as the TS bans them. Repeating a deferred
statement inside an inner block can capture a shadowing name, so the
design forbids the shadowing. The TS keyword is `_Defer`. *Resolution:*
design 6 and 13.5.

**E22. Macro restrictions and compact emission** (v0.2 5.2). Restrictions
on extensions inside macros vanish when parsing follows preprocessing. The
proposed "compact" output that keeps `#include` lines would expand macros
twice. *Resolution:* design 2.4 and 13.2; no compact mode.

**E23. Layout knowledge** (v0.2 6). A front end that types C is tempted to
compute `sizeof`. Any disagreement with the backend is a silent ABI bug.
*Resolution:* aggregate layout is opaque to the front end (design 13.3).

**E24. Padding discloses memory.** Not addressed in v0.2. A variant has
padding and an inactive union remainder; copying it to an untrusted sink
leaks stack or heap bytes. *Resolution:* stated in design 10.1; an option
to zero them is in TODO.

**E25. Field types** (v0.2 1.2). Arrays, bit-fields and unnamed fields are
not ruled in or out. *Resolution:* design 3.2 rule 4.

**E26. Regions conflate two things** (v0.2 4.2). A bump allocator needs no
language support; only lifetime checking does. *Resolution:* a region is a
library until tier 2 exists (design 11.3).

**E27. Calls out of checked code** (v0.2 4.1, 6). "Reject or treat as
unsafe" is not a rule. *Resolution:* checked code calls checked functions
and declarations made in checked text (design 11.1).

**E28. Generated-name collisions** (v0.2 3 item 8). "Source code may not define
conflicting generated names" needs the names. *Resolution:* design 2.3,
10.1 and 10.3.

**E29. `str_from_literal`** (v0.2 1.8). Every string constant would need a
wrapper call. *Resolution:* a literal is a `str` by target type (design 8).

**E30. Specification, plan and history in one file.** v0.2 carries a date,
revision notes and milestones. *Resolution:* the design is present-tense;
the plan and this evaluation are separate files.

### Low

**E31.** The `abstract` declaration (v0.2 2) is unnecessary: `type N;`
already declares an incomplete type.

**E32.** `derive` and closures (v0.2 1.9, 1.10) are thin but correctly
deferred. They are listed in design 12.

**E33.** Staying on C11 is reasonable. The dialect must be pinned when
invoking the backend, because compiler defaults differ and move between
releases (design 2.4).

**E34.** Nothing exposes the tag as an integer, which table-driven code
wants. Listed in design 12.

**E35.** v0.2 does not say which C errors `typec` reports and which the
backend reports. Design 13.3 does.

## How v0.2's milestones map to the plan

| v0.2 | Plan |
| --- | --- |
| M0 pass-through via probe | Stage 0: the C front end and verbatim emission |
| M1 nominal types, M2 `match` and private | Stage 1, as one stage |
| M3 `result`, `try`, `defer` | Stage 2, after generic types |
| M4 generics and multi-file builds | Stage 3; multi-file needs nothing new |
| M5 slices, checked mode, regions | Slices in Stage 3; tier 1 in Stage 5; lifetimes in Stage 6, conditional |
| M6 ergonomics, M7 closures | Stage 7, each item on its own evidence |

## What was checked, and what was not

Checked with the local Clang: the lowering of design 10.1 and 13.5
compiles under `-std=c11 -pedantic-errors -Wall -Wextra`; `cc -E` passes
Type-C text and `#pragma typec` through; compiling preprocessed output
with `-x cpp-output` gives a byte-identical object.

Not checked, and flagged as such:

- GCC as backend. No GCC was installed where this was written.
- The cost of the GNU profile on real system headers. It is the main risk
  and Stage 0 exists to measure it.
- The size estimates for the compiler.
- The soundness of the homogeneous-regions candidate.
- The current state of the Checked C and Cforall projects, cited from
  memory as precedents.
- Licences of the test corpora named in the plan.
