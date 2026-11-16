# Type-C working agreement

Type-C is a programming language in the design stage. The current design is
[type-c-language-design.md](type-c-language-design.md) and the order of work
is in [type-c-implementation-plan.md](type-c-implementation-plan.md); read
the sections relevant to a task before proposing changes to the language.

## Collaboration

* Ask, don't assume. If something is unclear, ask before writing a single line.
  Never make silent assumptions about intent, architecture, or requirements.
* **Open questions park only their slice.** A question waiting on me
  blocks only the work whose outcome depends on its answer. Keep building
  everything else meanwhile, and state the blocked slice when you ask.
* Flag uncertainty explicitly. Confidence without certainty causes more damage
  than admitting a gap.
* Suggest better approaches, especially ones with lasting impact over a
  tactical change.
* **Fix the tool, don't work around it.** When a tool, language, library,
  format or rule in this file is inadequate for the job, stop and propose
  the change: extend the tool, switch to a better one, or relax the rule.
  Never absorb the gap with layers of workaround code; bloat that exists
  only to compensate for a weak tool is a design failure. State what the
  gap costs (lines, duplication, special cases) so the trade-off is visible.
* Security is on equal footing with correctness.
* If you discover a bug, discrepancy, or something unexpected, fix it when it
  is straightforward or blocks progress; otherwise record it in `TODO.md`.
* Read this file again after each context compaction.

## Licensing

* Project-owned files use `SPDX-License-Identifier: BSD-2-Clause` and
  `Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>` in their comment
  syntax. Check provenance and license terms before importing code.
* If a development tool is missing, install it via homebrew or ask me to
  install it. Do not work around a missing tool.

## Design

* Keep designs simple and clean; never over-complicate things.
* **Simplicity over speed in the compiler.** In `typec` and its build and
  test tooling the simplest correct design wins, and no time budget gates a
  design. Optimize only when a slow step is a reported problem. Generated
  code is exempt: its size and speed are measured against hand-written C.
* **Weigh mechanism against what it buys.** Before adding a concept, rule,
  feature or option, name the concrete problem it solves and how likely it is.
  If the gain is small, choose the smallest answer: document the limitation,
  skip the case, or defer it.
* **Question every requirement before building for it.** Before a design
  adds a mechanism (a borrowed algorithm, a dependency, a format feature, a
  test harness, a process), it names the consumer that needs the property
  and what breaks without it. A requirement inherited from a previous
  implementation, a tool that provided it for free, or "matching" something
  is suspect: re-derive it from a real consumer or drop it. When a port or
  rewrite makes a property expensive, ask first whether to keep the
  property, then how. Ask of every costly mechanism: "what if we did not
  need this?"
* **Judge complexity by the model a reader must understand**: the concepts,
  rules, and interactions a change adds versus removes across the whole
  language, not its length.
* A pile of special cases usually means the design is wrong. Step back and ask
  what change would make the cases disappear, rather than handling them one by
  one.
* **No enumeration; correct by construction.** If correctness rests on a list
  (callers that must participate, states a value can take, cases a check must
  cover), the list is never complete; each review adds an entry. Ask what the
  list protects and what would make it empty, then make the property hold by
  construction:
  * make the illegal state unrepresentable;
  * make the invariant a derived fact nothing can break;
  * make one funnel the only way to reach the operation.

  Prefer fixes that delete mechanism. Wide and shallow (many mechanical edits
  that fail loudly) beats narrow and deep (a clever interlock that fails
  intermittently). Principle 8 of the design lists the properties Type-C
  gets this way.
* **Fix the class, not the instance:** in the type, module, format or
  interface that allowed the bug, not at the call site that hit it.
* **Make misuse impossible to write, not checked for.** A lint or grep only
  catches the cases it was written for; a type or visibility boundary makes
  wrong code fail to compile. OCaml: abstract types in `.mli`. C: opaque
  types, single-member structs that don't convert, `static` functions,
  module-private headers. Before claiming something can't be written,
  compile it: if it compiles, change the design; if not, keep it as a
  negative compile test.
* **Fix what produced a wrong result, not the result.** When a compiler stage,
  generator or build step gives wrong output, fix the step or constrain its
  input (types, build flags, a source check); never add a pass that scans or
  patches output. Output checks are OK only for properties no single input
  determines or tools we don't control (the C compiler), and they state
  their assumption about the tool and how a failure gets fixed. A backend
  error in lowered code is a `typec` bug: fix the lowering.
* **Decisions are pure; effects at the edge.** The stages of the compiler
  (reading tokens, parsing, typing, checking, lowering, emission) have no
  ambient effects: no files, processes, clock or globals. The driver does
  the I/O, hands each stage its input and runs the backend, so every stage
  runs deterministically in tests. A decision is a function of its inputs
  returning a value the caller applies.
* **One source for every fact.** Every decision, table and format has exactly
  one implementation. Never keep parallel copies that must change together:
  the list of places to update is an enumeration. Code in two languages
  shares a table only by generation from one source. A comment or test that
  keeps two implementations in step means a generator is missing. Generated
  files are build outputs, never committed.
* **Port by redesign, not translation.** When code moves to another language
  (the compiler, if it is ever rewritten in Type-C), identical observable
  output is the acceptance test, but the structure is designed afresh for
  the target language: idiomatic, simple and elegant there, never a
  line-by-line translation of the old code.
* **Readability is a requirement**, for specs and code alike: another
  developer can follow purpose, data flow, invariants and failure paths
  without reconstructing the code or reading the conversation. Code is
  extremely simple and readable; a review blocks code that is not. In the
  OCaml and C we write (the C that `typec` emits follows the design
  instead):
  * one job per function; a long function is split into named steps;
  * plain control flow: `if` statements and early returns in C, a flat
    `match` in OCaml; no chained ternaries or nested conditionals that
    compute a value;
  * names say what a value is; a constant is named for its concept;
  * every limit, invariant and non-obvious formula has a name or a comment
    saying why it exists;
  * one type per concept: no parallel models of the same data and no copied
    type declarations; a record is built as its final type, not through a
    separate builder type;
  * one failure path per module: in OCaml, a multi-step reader or generator
    raises a module-private exception at its first failure and catches it
    once, at its public entry, instead of returning an `option` from every
    step for each caller to re-check;
  * a sequence is read through a cursor, or destructured after one length
    check, never by scattered positional indexing;
  * defend once, at a trust boundary (for `typec`: everything it reads
    from a file or from the backend, its command line and its
    environment); never re-validate our own generated code or outputs,
    re-check at run time what a type already guarantees, or guard against
    an attacker outside the threat model;
  * no cleverness where a plain loop does; lines at most 80 columns;
  * comments say why, not what, in one plain sentence per contract; the
    argument for a decision belongs in the design doc or commit message.

## Documents

* **Specs describe the target design, in the present tense.** Edit them when
  the design changes, not to record what is built or deferred - that belongs
  in `TODO.md`. When a decision changes, edit it in place; git holds history.
* **Mark what is unproven.** A choice no experiment or prototype has confirmed
  is labelled provisional and names what would settle it, plus the default if
  it cannot be settled.
* Record a decision with its rationale in the section it shapes.
* `TODO.md` holds only work worth doing, each item tagged `[Critical]`,
  `[High]`, `[Medium]` or `[Low]`. Delete closed items.
* No temporal or campaign marks in code or docs ("now fixed", "as of <date>",
  "addressing review item 12"). The why-and-when belongs in commit messages.

## Code and tests

* Source and build files are ASCII-only; Markdown prose is exempt.
* Write tests alongside features. For a non-trivial bug, write a regression
  test first, confirm it fails, then fix and confirm it passes.
* Run tests in proportion to the change: only affected tests while developing,
  the full suite once before committing. Document the actual build and test
  commands alongside the build system as it appears.

## Committing

* Commit each solid piece of progress. History is linear: rebase and
  fast-forward, no merge commits.
* The full suite to run once before a commit is `tools/gate.sh`
  (README, "Building and testing"); `dune test` alone skips the typing
  oracle's tests.
* Before committing, launch a code-review subagent **first**, asking it to
  enumerate bugs, design issues, and security concerns (state the security
  pass explicitly) and to check readability with specific evidence. Address
  every CRITICAL and HIGH finding; note MEDIUM ones in `TODO.md` or the commit
  message.
