# Type-C working agreement

Type-C is a programming language in the design stage. The current design is
[type-c-language-design.md](type-c-language-design.md) and the order of work
is in [type-c-implementation-plan.md](type-c-implementation-plan.md); read
the sections relevant to a task before proposing changes to the language.

## Collaboration

* Ask, don't assume. If something is unclear, ask before writing a single line.
  Never make silent assumptions about intent, architecture, or requirements.
* Flag uncertainty explicitly. Confidence without certainty causes more damage
  than admitting a gap.
* Suggest better approaches, especially ones with lasting impact over a
  tactical change.
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
* **Weigh mechanism against what it buys.** Before adding a concept, rule,
  feature or option, name the concrete problem it solves and how likely it is.
  If the gain is small, choose the smallest answer: document the limitation,
  skip the case, or defer it.
* **Judge complexity by the model a reader must understand**: the concepts,
  rules, and interactions a change adds versus removes across the whole
  language, not its length.
* A pile of special cases usually means the design is wrong. Step back and ask
  what change would make the cases disappear, rather than handling them one by
  one. Prefer properties that hold *by construction* (illegal states
  unrepresentable, one funnel to an operation) over rules that depend on
  remembering every exception.
* Human readability is a requirement, for specs and code alike.

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
* Before committing, launch a code-review subagent **first**, asking it to
  enumerate bugs, design issues, and security concerns (state the security
  pass explicitly) and to check readability with specific evidence. Address
  every CRITICAL and HIGH finding; note MEDIUM ones in `TODO.md` or the commit
  message.
