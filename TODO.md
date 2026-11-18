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
  README says what it holds. Pilot B's repository,
  `/Volumes/Optaine/type-c-pilot-b`, is local in the same way, and
  design 15 cites its record by commit. The review of diagnostics,
  `/Volumes/Optaine/diag-review`, is no repository yet, so TODO.md
  cites it by path alone; make it one. (`tools/hosts` runs the Linux
  hosts in containers, the arm64 ones under emulation, and the FreeBSD
  one over ssh, on a machine of the owner's.)

## Diagnostic quality (plan package 4.2)

The records: Pilot A's `RECORD.md` and `WRITEUP.md`
(`/Volumes/Optaine/type-c-pilot-a`, 323777ec9bca) count the sites of
each friction by cause and list the diagnostics of the gate-6
injections; Pilot B's `RECORD.md` (`/Volumes/Optaine/type-c-pilot-b`,
06d4eb86245a, "What section 15 asks Pilot B to count") lists every
refusal met while porting; Pilot C's `README.md`
(`/Volumes/Optaine/type-c-pilot-c`, 83abeeab038f, "Features, and what
`typec` made hard") met no diagnostic that was hard to act on. Missing:
Pilot A kept no text or count of the diagnostics its port met, only the
counts of the sites that friction shaped, so its frequencies below are
those of the sites. The first part of the review, 45 mutations of
Pilot B and the container library, is `/Volumes/Optaine/diag-review/
review.md`; the probes of the items marked "probe", one common mistake
of a C programmer each, are in `/Volumes/Optaine/diag-review/probes`
(`probe.sh`, `probe2.sh` and `probe3.sh`, run with `TYPEC` naming the
`typec` under review; their output is in `out2.txt`, `out-probe2.txt`
and `out-probe3.txt`). Read
well already, saying what, where and what to write: a missed
constructor, a dropped result, a result assigned to a C type, `try`
outside a result function or on an option, `try` of a void result, a
`switch` or `==` on a variant, a `break` that leaves an arm early, a
jump into or out of a deferred statement. No message cites a design
section.
The items are ordered by how often real code meets them.

- [Medium] Conversion hints for a variant. The hint of a refused
  conversion (`Expressions.record_conversion_hint`) looks only at which
  side is a structure: `option(point) o = p;` gets no "make one with a
  constructor", a `result(void, E)` towards `int` is told to use `try`,
  which has no value there, a pointer to an option is told to make one
  where `*p` was meant, and `return (NULL);` for an `option(int)` is
  told to "make one with a constructor of 'option(int)'" where `None`
  is meant. The full conversion check of Type-C text gives C's own
  message where a refusal used to carry a hint: `return c ? Some(1) :
  0;` gets C11 6.5.15p3's operands message, and `return (Ok("x"));` for
  a `result(int, err)` gets "a value of type 'char *' does not convert
  to 'int' without a cast (C11 6.5.16.1p1)", naming neither `Ok` nor
  its field. Proposed: decide the hint by what the variant holds (a
  constructor whose field the source converts to, an Ok whose type
  converts to the target, `None` for a null pointer constant), and name
  the constructor's field as the `[constructor-expression]` messages
  do: "the argument for the field 'value' of 'Ok' is of type 'char *',
  not 'int'". Source: review cases 18, 22, 25 and 28; probe.
- [Medium] A distinct object refused by an atomic builtin
  (`__atomic_fetch_add(&x, 1, 5)` with `id x`) is told "cast to
  'unsigned int'", where the fix casts the pointer, `(unsigned int
  *)&x`; name the pointer type there. The uses typed through the plain
  entry (a switch, a case or enum constant, a designator index, an
  array length, a scrutinee) say "this operation"; each could name its
  role, as an index does.
- [Medium] `Expressions.listed` names every entry it is given, so the
  bound on a message's list (`Selection.max_named`, through
  `Selection.named_first`) holds only where each caller cuts the list
  first. Make an uncut list impossible to pass (an abstract pair that
  only `named_first` builds), and move the cap, whose comment speaks of
  coverage alone, next to `Shown.cut` as a bound on message text. The
  shared-arm refusal may leave out the label that binds when it is past
  the eighth; name that one first.
- [Low] The refusal of a constructor where no variant with it is
  expected names the variant by its declaration's name, and its fix
  qualifies the constructor with that name, though an ordinary
  identifier may hide it at the use: `int e = 0; (void)A;` is told to
  write 'e.A', and `int result = 0; (void)Err(1);` 'result(T, E).Err'.
  Ask the parser's scopes whether the name still denotes the variant
  there, and leave the qualified fix out where it does not.
- [Low] `Ctype.result_ok` and `result_err` spell two constructor names
  that the universe text declares; derive them from result's
  declaration (its constructors through `Ctype.constructors`), so the
  universe text is their one source.
- [Low] A binding written with a C type, `Circle(double r)`, is refused
  by the parser, which does not know the field's type, so its fix names
  both forms ("write `r` ... (at a field of a variant type, a typedef
  name may stand before the name)"), and a typed binding of a typedef
  name at a field of no variant is refused by typing under
  [match-pattern]: one rule, two refusals. Recording a typed binding
  with a full type name and letting typing refuse it would give the one
  fix that the field takes. `Ok(int (*f)(void))` gets "expected `)`
  after a declarator, found `f`". Source: review.
- [Low] The test that a refusal of a variant suggests is always 'if
  (case P = e)': for `while (next())` the drop-in form is `while (case
  Ok(value) = next())`, and a `for` or `do` condition can hold no test,
  so the fix there is a loop around a test; `require_condition` could
  take the statement. The scrutinee of `->` is parenthesised after `*`
  unless it is a name, so `(p)->j` reads `*((p))`.
- [Low] A binding that its arm never uses fails a `-Werror` build with
  the backend's `-Wunused-variable`, which quotes the lowered text,
  `const __typeof__(__tc_match0->u.Circle.r) r = ...`. Proposed: the
  lowered declaration carries the source line and spelling only, so the
  backend quotes the pattern, or `typec` reports "the binding 'r' of
  'Circle(r)' is not used; write '_'" and lowering marks bindings
  unused; see the item on backend diagnostics of lowered constructs
  under "Driver". Source: probe; Pilot B's record, friction 3.
- [Low] `private-creation`: `(port)80` outside the owner gives "the
  distinct type 'port' is private to './priv.tci', so only the text of
  its owner creates its values", naming the owner by the path the
  backend found it through, and not the cast. Proposed: "the cast makes
  a value of 'port', which is private to 'priv.tci'; only that
  interface's functions make one". Source: Pilot A (Step 10, gate-6
  injections); probe.
- [Low] A match of a pointer: "the scrutinee of a match is of type
  'shape *', not a variant type; a pointer is not dereferenced
  implicitly [match-scrutinee]". Proposed: add "; write 'match (*s)'".
  Source: probe.
- [Low] Messages print types without their typedef names: `try` of a
  `word_length(...)` gives "the operand of try is of type 'unsigned
  long', not a result type", and a slice of strings prints as
  'slice(slice(const char))'. Proposed: print the type as the source
  spelled it, 'size_t' and 'slice(str)'. Source: review cases 01, 04
  and 22; probe.
- [Low] `typec`'s own diagnostics give the file and the line, no
  column, where the backend's give one: `p05.tc:2: error: ...` beside
  Clang's `p19.tc:2:48: warning: ...`. The first part of the review
  ("Columns") measured what recovering them costs and recommends
  printing the source line instead; P15 is decided on that ground (the
  backend preprocesses), so print the source line (the item on design
  13.6 under "Reader of preprocessed text"). Source: Pilot A
  (`private-creation`); probe.
- [Low] The parser quotes names with backticks, the typing stages with
  single quotes as GCC and Clang do, and some typing messages use
  backticks too (`[early-break]`, `[deferred-exit]`); pick one, in
  `Parser.quoted` and the literal backticks (about 260 golden lines).
  `Parser.quoted` also cuts at 40 bytes, which may split a UTF-8
  sequence, where the typing stages cut with `Shown.cut`; one cut goes
  with the one quoting. Source: review; probe.
- [Low] A misspelt constructor, `Circel(1.0)`, gives "'Circel' is not
  declared (C11 6.5.1p2)". Proposed: add "; did you mean the
  constructor 'Circle' of 'shape'?" when one constructor of a visible
  variant is within an edit distance of one or two. Source: review case
  03; probe.
- [Low] A constructor given too few arguments: "the constructor
  'Triangle' takes one argument for each of its 3 fields
  [constructor-expression]". Proposed: "...; it is given 2". Source:
  the smtp example's README; probe.
- [Low] A mismatched argument of a generic call, `put(&b, "x")` with
  `generic(T) void put(box(T) *b, T v)`, gives "a value of type 'char
  *' does not convert to 'double' without a cast", naming neither the
  argument nor the callee. Proposed: "the argument 'v' of 'put' is of
  type 'char *', not 'double'". Source: probe.
- [Low] The fix that a refusal of an array or a pointer where a generic
  function's slice parameter is expected proposes is checked only for
  matching that parameter, not for a valid type argument: `char a[2][3]`,
  a `void *` and a pointer to a function get `slice_from_array(a)` or
  `slice_unchecked(p, n)`, which the refusal of the type argument then
  meets. Fix the class: a funnel in `Declarations` that answers whether
  the slice instance of an element type is made, without refusing, so
  the fix asks the rule itself rather than a copy of it.

## Driver

- [Low] `typec --cc=clang` fails with a backend error on the valid C
  `#undef __APPLE__` followed by `int __APPLE__;`: Clang expands its
  predefined macros in `-x cpp-output` input, so the backend reads
  `int 1;` where the `-E` step left the identifier (design 13.2). A
  backend error on lowered code is a `typec` bug; the backend's reading
  of a unit should equal the step's for every name the unit undefines.
- [Medium] The driver refuses `-specs`/`--specs` with a `.tc` input
  (`src/driver/cc_option.ml:180-184`), and Arm GNU firmware builds
  commonly link with `--specs=nano.specs` or `--specs=nosys.specs`.
  Before Pilot C (plan 4.7) is built as its firmware is, decide whether
  a spec file may reach the link step alone, or the pilot links in a
  separate command.
- [Low] `--trap-function=` takes a C keyword (`int`, `_Bool`), which
  then fails as a backend error at `<typec>` rather than as a refusal of
  the option. Refusing it needs the keyword sets of the dialect in one
  place the driver reads. A name of the implementation's own space is
  taken too: `--trap-function=__builtin_unreachable` makes every trap
  undefined behaviour, since the backend may drop the `__builtin_trap()`
  after it.
- [Medium] `Parser.generated_prefix` is the source of `__tc_` only for
  the two refusals that read it (the parser's and `Trap.calling`); every
  site that writes a generated name spells `"__tc_..."` itself
  (`lowering.ml`, `emitter.ml`, `assumptions.ml`, `encoding.ml`,
  `target_query.ml`). One small module owning the prefix and a
  constructor of generated names, through which every site and both
  refusals go, makes a name the user may declare unable to clash.
- [Low] `Front_end.lower` hands the same trap to `Lowering.edits` and to
  the `lowered` record that `Emitter.emit` writes its definition from;
  another builder of `lowered` could pair edits with another trap. Have
  `Emitter.limited` give the output's trap back with the edits.
- [Low] The tests of the build rules (`make_rule.t`, `ninja_rule.t`,
  `cmake_rule.t`) run only where the host has the tool: the Alpine image
  has no make, ninja or CMake, and the FreeBSD host has no ninja or
  CMake. Add them to the Alpine image, and have `freebsd.sh` require
  them as it does gmake once the owner has installed the ports there, so
  that every host runs the rules.
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
  would give the other inputs the `-std=gnu17` (when the command line
  has no `-std=`) and, on Clang, the `-fno-trigraphs` that the emitted C
  needs. Decide whether that is acceptable, and then delete the object
  path, or keep the path for those command lines.
- [Low] The target query gets `-Wno-unused-command-line-argument`
  whatever the backend, as it runs before the backend's family is
  known, so GCC adds a note that names the option to any diagnostic of
  the query, such as for `-mtune=bogus` or `-Wformat-security`, and the
  note points at the wrong option. Clang needs the option there: it
  fails the query under `-Werror` for `-stdlib=`, `-rtlib=` or
  `-unwindlib=`. A first query without options can name the family, as
  `tools/corpus/corpus.ml` does, at the cost of one more backend run;
  then `Pipeline.t.target_options` becomes a `Pipeline.command`.
- [Low] A backend's diagnostic on a line that holds a lowered construct
  quotes a fragment of the emitted text, not the source line: for
  `return (Some(d));` with a `double d` where an `option(int *)` is
  returned, Clang quotes `d` alone: the emitted C puts the constructor's
  argument and the text around it on physical lines of their own, each
  after a line marker of the source line, and Clang quotes the physical
  line. GCC 16 quotes the source line, which it
  reads from the `.tc` file. Clang also quotes text that lowering adds
  and the source does not hold: under `-Wunreachable-code`, Pilot B's
  `toml.tc:563:1` shows `__builtin_trap();`, where line 563 is the `}`
  that ends a function. Design 15 (P15) decides who preprocesses, and
  with it what a backend can quote.
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
- [Low] `typec` refuses `-std=c99` for a `.tc` input (design 2.4), so a
  build that sets `-std=c99` in one `CFLAGS` for every file cannot
  switch one file to Type-C by `CC=typec` alone: Pilot B's Makefile
  gives `toml.tc` flags of its own. Decide whether a `.tc` input takes
  the option, and what the backend is then given, or the refusal stays
  and the README says how such a build switches a file.
- [Medium] The measure scripts `containers.sh`, `unit_stats.sh`,
  `resume.sh`, `nested.sh`, `selection_stats.sh`, `try_expr.sh` and
  `try_stats.sh` each repeat the
  check that OUT lies outside the
  repository, the revision lookup, the build of typec, the CSV `row`
  function and (all but `resume.sh`) the parser of the `--stats` line, and
  the checks have drifted apart; only `zero_record.sh` writes its CSV
  to a scratch file and moves it over OUT when every run has passed.
  Move the shared set-up into one sourced `tools/measure/common.sh`.
- [Low] `slice_late_calls` of `--stats` reads the operands as written
  (`Tree.holds_call`): it counts a call in an operand that C does not
  evaluate (`sizeof`, the unselected arm of `_Generic`) and misses one
  in a bound of a variable length array or in a subscript of
  `__builtin_offsetof`. Recording call sites in the typed view, where
  `leave_untested` already clears what C does not evaluate, would make
  the count exact and delete the walker.

## C headers (plan package 4.1)

`typec --emit-c-header` writes the redirect, the guard, the macro probe
and the runs of the interface's own lowered text in macro brackets
between its include lines, the definition of each instance under its
guard where a point needs it complete, and at its end that of each
other instance that its own applications name where the definition
reads there, the layout typedef of each instance that its step
applies whose generic the step reads defined, the packing probe named
for the header, under `--trap-function` the trap's prototype and its
definition under the guard of the trap function, and under the
dependency options the rule of the header (design 9.3). The rest of
the package, in the order of its commits:

- [Low] The digested tokens are the `-E` step's, so one generic that two
  headers reach through different backends or macro environments
  (`INT_MAX` spelt `2147483647` by Clang and `0x7fffffff` by GCC,
  `__FILE__` through another include path) gets two digests, and a
  client that includes both is refused. Design 9.3 states the
  assumption; a normal form of constants would lift part of it.
- [Low] The edges of the layout digests' application graph come from
  `Declarations.applied_generics`, which `note_application` fills with
  `Hashtbl.replace`; unchecked is whether a trial or a forgotten
  reading leaves an edge behind, which would give two headers that
  read one set of definitions different digests and refuse a valid
  client. Check the rollback and add a test either way.
- [Low] `Reader.read_interface` passes over, unchecked, a token or an
  include line at the bottom of the main file before the text of the
  interface begins (before the marker of its line 1). No supported
  compiler writes one there, but a `--cc` wrapper could, and the token
  would reach the typed unit and not the header; refuse it as a token
  before the first marker is refused.
- [Low] `Header_file`: the check of the path and the rename are not
  atomic (a `link` would close the window for a new header), and no
  `fsync` precedes the rename. A message echoes the `-o` path and a
  refused interface path unescaped; an unreadable header of typec's is
  reported as one typec did not write. A replaced header or rule keeps
  the mode of the old file but takes the group of its directory (BSD,
  macOS) or of the process (Linux), which may widen who reads it; keep
  the group with `fchown` while the new file is still `0600`.
- [Low] `--emit-c-header -MD -MF M.h` or `-M -MF M.tci` replaces the
  header or the interface with the rule, as `cc -MD -MF x.c` does; `-o`
  guards the header from this and `-MF` does not. Refuse an `-MF` file
  that is the header or the interface (by device and inode at write
  time, as names alias).
- [Low] `-Wp,-MD,FILE` and `-Xpreprocessor -MF` reach the backend as
  preprocessing options, so under `--emit-c-header` the backend writes
  that rule itself, at the user's path, with the `.tci`'s default target
  and not the header. Classify them as dependency options or refuse them
  with `--emit-c-header`.
- [Low] `Pipeline.plan_header` fills a `shape` with
  values of a translation to reuse its helpers, and `Invocation` defines
  `given` twice: factor them.
- [Medium] The writer reads the lowered text of the interface again
  (`Reader.read_interface` of `Emitter.applied`) to meet each token
  that it writes as a token, since the text of an edit is a string.
  Edits that carried their tokens would let the writer take them
  directly; weigh that against the second read once instances land.

## Target model

- [Medium] Package 4.6's freestanding check must allow the compiler's
  runtime helpers. As its row reads, a helper is a symbol the program
  did not introduce, yet at -O0 on the Cortex-M3 of Pilot C a Type-C
  object calls the soft-float `__aeabi_dcmpgt`, which the compiler
  chose. A `-nostdlib` link there needs `-lgcc` to resolve the
  helpers. Plan package 4.7, criterion 1, lists them.
- [Medium] The message of the enumeration assertion of design 13.4
  points at a line of `<typec>`, text that `typec` generates, which a
  user cannot open. Name the option or the target default that
  changed the enumeration's size, and the target, instead. Feeds plan
  package 4.2.

- [Low] Every target now declares both Arm vector families or neither
  (`Target.vector_families`), so `Keyword_set.vector_families` and the
  family of `Builtin_typedef.Arm_vector` carry no information and can
  hold states nothing produces (`[Neon]`). Make it one flag, unless a
  release that declares the families apart is found.
- [Low] `Target.t` is a public record, so code can build a model that
  skips the checks of `Target.of_predefined_macros`. Make it private,
  preferably with separate signed and unsigned types for the typedef
  fields, once the tests build their models from dumps only.
- [Low] The static assertions that end a lowered unit
  (`src/emit/assumptions.ml`) see the options in effect where the unit
  ends. GCC's `#pragma GCC optimize ("short-enums")` and
  `("single-precision-constant")` change the types of the declarations
  and constants after them (measured with GCC 16), so a region between
  `#pragma GCC push_options` and `pop_options` passes unseen; so does
  `__attribute__((optimize ("short-enums")))` on a function
  (`arm-none-eabi-gcc` 14.2). Inside such a region the front end types
  an enumeration by the model's representation, and the temporary that
  13.5 writes in the enumeration's integer type narrows a value of an
  `enum` that the region makes 4 bytes to `unsigned char` (design 13.5).
  Refuse those pragmas and attributes in a unit with Type-C constructs,
  or assert the type of each enumeration at file scope where the unit
  ends.
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
  a crafted name can hold control bytes or a fake `[match-coverage]`; route them
  through the escaping of `Reader.error_message`, and
  cut a quoted spelling, such as a number that is no constant, to a
  bounded length so that a huge token cannot make a huge message.
- [Medium] `Rule.c_text` takes free text, so a site can still write a
  Type-C refusal without its name as a refusal of C text, and whether
  each of its sites cites C11 or the GCC manual rests on review. Give it
  a structured citation (C11 clause, GCC manual section, translation
  limit) that renders the parenthesised clause, so that no design
  citation can be written there; about 15 sites cite nothing yet.
  `test/golden/citations.ml` sees a citation of the design only in a
  message that a cram test prints, and only by the word "design";
  `Rule.message` takes free text as well.
- [Low] A rule's name is stable by review alone: `Rule_codegen.check`
  refuses a name used twice, but no check sees a row renamed or deleted.
  Add a step to `tools/gate.sh` that fails unless every name of
  `rule_table.ml` at the merge base with master is still in the table.
- [Low] `Temp_dir` writes the `typec:` prefix and its guard against a
  closed stderr by hand, beside `Command.report`; give both one function.
- [Low] `Rule.diagnostic`, `message`, `c_text` and `text` are OCaml in a
  string of `rule_codegen.ml`, sealed by an `include (struct ... end :
  sig ... end)`; move them to a hand-written `diagnostic.ml` and `.mli`
  over the generated `Rule.name`, so the generator
  emits only what the table derives.
- [Low] Few tests assert the name of the rule `Profile` at its sites;
  assert `[unsupported]` at each.
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
  declaration if the pilot shows the error confusing.
- [Low] A disputed break or continue in C text that GCC refuses, as
  having no statement around the loop to leave (design 4.4), is kept
  in the tree as a jump to the loop alone (`Tree.Only`), so design 6
  rule 10 does not refuse one in the scope of a defer
  (`_Defer g(); while (({ break; 1; })) ;` at the top of a body). No
  backend disagrees on what it runs, as GCC refuses it; refuse it if
  the tree comes to mark every disputed jump.
- [Low] The parser keeps the arguments of an attribute as tokens, so a
  `goto *` or `asm goto` in a statement expression there
  (`defer g(); __attribute__((assume(({ goto *p; 1; }))));`) passes
  design 6 rule 10, as a jump there passes rule 5. No backend is known
  to evaluate an attribute argument at run time; say so in the design,
  or read the arguments, if one does.
- [Low] Two places decide what the form of a `return e;` in the scope
  of a defer needs (design 13.5): `Return_form` refuses for every value
  return of the sites, `Lowering.function_edits` writes `__tc_ret` for
  those that lowering keeps, so a return in text that lowering drops (an
  answered `__builtin_types_compatible_p` type name) is refused though
  it needs nothing; and `(void)` is told from the type in
  `Return_form.takes_no_parameters` but from the tree in
  `Lowering.parameter_names`. Let the front end hand lowering the value
  returns and the parameter names that the form writes.
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
  `cleanup`) through the parser's scope. Two more consumers: a
  constructor qualified through a typedef name (`aligned(sizeof(v.A))`)
  is left to the backend, which refuses it as a syntax error, where
  typec could refuse it with its own message (design 13.5); and an instance named
  through a typedef name (`typedef o(int) oi;` then
  `aligned(sizeof(oi))`) is not completed (design 10.3), so the backend
  refuses `sizeof` of an incomplete type.
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
- [Medium] Design 11.1 rule 1 makes a `#pragma typec` line an error
  inside an external declaration of Type-C text and ignores it in C
  text. The parser passes over `Token.Typec_pragma` like any other
  pragma, wherever it stands (`lexeme_of` in `src/syntax/parser.ml`).
  Refuse the line inside an external declaration of Type-C text, with
  a rule name of its own.
- [Low] A `#pragma typec` line stays inside the spans of the nodes
  around it, so emission copies it to the backend. Stage 5, which gives
  the line a meaning, decides what emission does with it.
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
- [Medium] The scan of unread text (design 6 rule 13) refuses the
  words `defer` and `try` in an attribute argument of Type-C text, a
  list of Type-C constructs that misses the others: `match` or `type`
  in a statement expression there (`aligned(sizeof(({ match (y) {
  default: break; } 1; })))`) reaches the backend as written, which
  refuses it as C. The words are also refused as a member or tag name
  (`sizeof(((struct s *)0)->defer)`), where they begin nothing.
  Refusing the one thing that lets an attribute argument hold a
  statement, a `({` in Type-C text, would cover every construct and
  free the names; decide it in the design.
- [Low] The parser parses the body of a block literal and scans it as
  unread text because typing (`src/sema/expressions.ml`) does not read
  it, a decision two modules keep apart; and a block literal inside an
  attribute argument is not parsed, so design 13.3's text rule (`block-literal`)
  does not reach it. Passing the body through `skip_balanced` would make
  "unread" mean "not parsed", if the jump and label checks the parser
  applies to the body can go.
- [Low] The claim of a generic (design 10.3) refuses a name of its
  space that the scope declares before it only where typec reads the
  declaration: `int x __attribute__((aligned(sizeof(enum { max__i =
  1 }))));` at file scope before a generic `max` is not refused, as the
  scan of unread text finds no generic yet. The backend refuses the
  redeclaration that an instance `max(int)` makes of a file-scope
  name, but nothing says so in Type-C's terms. Keep the spellings of
  the claimed form that unread text holds, and refuse them where a
  generic is declared, if a pilot meets one.

- [Low] `Statement_pragma` matches the first identifiers among all the
  tokens of a pragma line (`Token.Identifiers` drops the others), so
  `#pragma GCC 4 unroll` passes as `GCC unroll`. Safe while both
  backends pick a pragma by its first tokens, which makes that line an
  unknown pragma; have the reader keep the leading run of identifiers
  and match the list against it, so that such a line is refused.
- [Medium] The rule `pragma-macro` (design 13.5) misses a macro that
  `#pragma pop_macro` restores: GCC 16 and Apple Clang 21 write no
  `#define` after it in `-E -dD` output, so `#pragma pack(push, M)`
  after `push_macro("M")`, `#undef M` and `pop_macro("M")` passes and
  lays the structure out in two ways. Have the reader track
  `push_macro` and `pop_macro` lines if a header is found to use them
  around a pragma.
- [Low] The rule `pragma-macro` refuses a predefined macro such as
  `__APPLE__` in a pragma line, though Apple Clang 21 expands a
  built-in macro in `-x cpp-output` input too, so both readings agree
  there; the message's "keeps it as written" is untrue for those.
  Measure which macros the backends expand after `-E` and exempt them
  by rule, or say so in 13.5.
- [Low] A `#pragma` line of C text that is no sequence of tokens is
  not looked at for macros (design 13.5, provisional); if a backend is
  found to apply such a line, have the reader keep the identifiers
  before its first part that is no token.
- [Low] `Scope_pragma.placement_refusals` tests every place of a site
  against every annotated statement, quadratic in one scope with many
  of each. If it is reported slow, sort the places' tokens once and
  search for the first at or after the statement.
- [Low] Whether a token is a pragma line is matched in `Parser`,
  `Lowering`, `Resolution`, `Expressions` and `Scope_pragma`, and
  "a pragma line directly before token i" in four places; add
  `Token.is_pragma` beside `Token.is_movable` and one helper.
- [Low] `Scope_pragma` refuses a `#pragma typec` line in the scope of
  a `_Defer` of C text, where design 11.1 says the line is ignored;
  exempt it there or say so in 11.1.
- [Low] A pragma of C11 7.12.2 in the deferred statement of a defer in
  a block literal that stands in the scope of an outer function's defer
  is refused by the outer scope's rule: the outer function does not
  know the block literal's defer sites.
- [Low] The golden tests of the pragma rule of design 6 rule 9 in a
  scope have no case of a defer in a match arm, of a loop pragma before
  the `}` of a block that cannot complete, before a labelled statement
  that holds an exit, or between `S` and the first item.
- [Low] The `deferred-pragma` message names neither the pragma it refuses nor the
  ones allowed; add the line's first identifiers and point to the
  list of design 13.5.
- [Low] The walk field `operands` in `Reachability` holds the operands
  of the returns in a defer scope; name it for that
  (`return_operands`), since `operands` reads as those of any
  expression beside the expression walk's own `operands` helper.
- [Low] `Declarations` builds the moved text of a deferred statement
  and then patches its `span` to `Tree.deferred_text`, so that the
  pragma lines before `S` move with it. Build the record with the span
  it ends with: hand `moved_text` the span of the text.
- [Low] `Lowering.moved_text` drops a `#pragma typec` line of moved text
  by matching the token kind; `Emitter.moved_token`, which says how
  each token moves, is the place for that decision.

## Expression typing

- [Low] `str s = { "abc" };` elides the braces of the slice and gives
  `len` 0, which C accepts. Decide whether a braced list may initialise
  a slice member by member (design section 8), or refuse it as a
  variant's is refused.
- [Medium] The `Unknown_type` arm of `Expressions.generic_call` types
  no callee at all and may be unreachable, as `generic-function-form`
  refuses the function types that could reach it: show it reachable
  with a test or make it unrepresentable.
- [Low] `Tree.Instance` holds its generic as an expression that is
  always an identifier (`invalid_arg` in `explicit_instance`); a
  `{ name; reference }` field would make that unrepresentable. The
  `Call ... when generic_callee ... <> None` arm of `expression_node`
  evaluates the lookup twice; dispatching inside one `Call` arm needs a
  check that it keeps the frames of test_deep_trees within bound.
- [Low] `deducing_argument` repeats the `Targeted` step of `positioned`
  (`needs_complete`, `refuse_conversion`); one helper would keep them
  together. `function_instance.type_arguments` repeats
  `instance.argument_types`.
- [Low] Deduction diagnostics: `Twice` does not name the type parameter,
  and `(max)(int)` gives a bare "expected an expression".

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
  to its braced list so that static initialisers stay constant, and
  that the list replaces the initialiser with its parentheses. `typec`
  keeps the compound literal for one in parentheses
  (`static e x = (B(1));`, and `Some((B(1)))` in an initialiser), for
  one reached through elided braces (`static struct w q = { e.A };`)
  and for an atomic object (`static _Atomic e g = A;`), which
  `gcc -pedantic` calls not constant. Drop the parentheses in the
  lowering, and add the elided braces or narrow the 13.5 row for them.
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
- [Low] In C text a constructor argument converts to its field type as
  the backend decides, except where a field or an argument is a
  structure or union, which `Expressions.constructor_argument` checks,
  so a wrong scalar or pointer argument is the backend's warning or
  error on lowered code. Type-C text checks it in full (design 5); a
  constructor is a Type-C construct, so checking its arguments in full
  in any text would leave the C-text record check needless.
- [Medium] A `transparent_union` attribute on a union specifier
  (`union __attribute__((transparent_union)) u { ... };`) makes only
  that specifier's type unknown, so a later `union u` parameter is a
  plain union, and Type-C text refuses a pointer argument for it that
  GNU C takes (C11 6.5.16.1p1 checked in full, design 5). The typedef
  form that glibc uses is unknown and converts. Make an attribute
  outside the table on a record specifier obscure the tag wherever it
  is named, as for an enumeration, or record `transparent_union`.
- [Low] An integer bit-field read converts to a pointer unrefused in
  Type-C text (`int *p = s->b;`): `Expressions.null_pointer_constant`
  answers that it may be a null pointer constant. The backend refuses
  it, or warns under an older GCC.
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
- [Medium] Two guarantees of the names derived from an instance rest on
  callers, not on types: `Spelling.instance` takes the encodings of the
  arguments as plain strings, and `Ctype.instance` is a public record,
  so a name that no encoding made can become a `Spelling.c_name`; and
  `Ctype.define_variant` and `define_variant_instance` refuse the other
  kind of tag only at run time. Give encodings a private type that only
  the encoder makes, and hand the `define` of
  `Ctype.declare_variant_instance` a definer bound to its tag.
- [Medium] A definition check of a generic passes a definition that
  discards a value of a type parameter, which an instance at `result`
  then fails, against design 3.5 rule 4: `type pair(T) = struct { int
  n[sizeof(({ T x = {0}; x; }), 1)]; };` is accepted and `pair(result(int,
  int))` refused at the instance (`discarded-result`). The way in is a declaration
  of `T` inside a statement expression, which rule 4 does not refuse.
  Refuse a discarded value of an opaque type parameter in a definition
  check, or close the gap in rule 4; section 7.1 rule 3 meets the same
  question for generic functions.
- [Low] `Ctype.as_result` knows the universe's `result` by the literal
  name `"result"`, a second spelling of the name that
  `File.universe_text` declares: renaming it there would turn the rule
  of design 5.2 off with only the tests to notice. Identify the
  universe's declaration itself, or take the name from `Universe`.
- [Low] An assignment is exempt from the rule against dropped results
  only bare or parenthesized, so `c ? (r = f()) : (r = g());`,
  `_Generic(0, int: (r = f()));` and `({ r = f(); });` are refused
  although they only store. If a real program meets one, see through
  `?:`, a selection and the value of a statement expression as well.
- [Low] A discarded value of a type that typec does not know (design
  13.3) is not checked against design 5.2, though an attribute that
  typec does not model may hide a `result` there, as in `f();` after
  `result(int, int) __attribute__((x)) f(void);`. Nor is the value of a
  `return` in a function whose return type typec does not know, which
  may be void. Refusing them through `needing` would refuse every
  discarded call of a function of unknown type; decide by what P21
  measures.
- [Medium] A discarded selection that typec cannot decide refuses every
  association of a result type (design 5.2), also one it can never
  select: `_Generic(x, long: f(), V: 0, default: 0);` and
  `_Generic(x, int: 0, V: 1, default: f());` where `x` is an int and `V`
  a vector type, as `select` answers `Depends_on` when any association's
  compatibility is unknown. Let `select` and `choice` give the operands
  that may be chosen (known compatible, unknown, and the default only
  where none is known compatible), decide the selection where one is
  left, and have `selected` judge exactly those; then where each of them
  is a result, report `discarded-result` rather than a dependence on typec.
- [Medium] Which operand gives the value of the expression around it
  is decided in several places that must agree: `as_enclosing` and
  `value_position` (positions), `is_assignment` (parentheses only, so
  an assignment in a selection is refused, as noted above) and
  `source_through` (parentheses and selections) in
  `src/sema/expressions.ml`, and design 3.3 and 5.2. Give one function
  that names that operand and derive the rest from it; whether design
  3.3 then gives a selected association and the value of a statement
  expression a target type (so `x = _Generic(0, int: None)` names a
  constructor) is a language decision.
- [Low] Type-C text accepts a string literal longer than the character
  array it initialises, `char s[2] = "abcd";`, which C11 6.7.9p2 makes
  a constraint violation and GCC and Clang only warn about. It drops no
  result, so design 5.2 does not need it refused; decide whether the
  rule against excess initialisers covers it.
- [Low] A cast to a slice type, `(slice(const int))s` for a
  `slice(int) s`, passes the check and the backend refuses it as a cast
  to a structure, Clang quoting the lowered compound literal. The
  conversion to const elements takes no cast, but a C programmer
  writes one. Decide whether typec refuses a cast to a slice type with
  a rule of its own, as it refuses a cast to a variant
  (`variant-operation`), or leaves it to C. Reproducer: pass
  `(slice(const int))slice_from_array(a)` for an `int a[3]` to a
  function that takes a `slice(const int)`.

- [Medium] `place_declared_try` checks the declared object at the first
  `initialiser` call in the holder, so a compound literal in a
  variably modified declarator (`int (*p)[n++ + 0*sizeof((int[]){1})]
  = try f();`) takes the check and the object goes unchecked. Key the
  check to the holder's own initialiser, and keep the holder's state
  per holder rather than in mutable fields of the view.
- [Low] The cast to void of a discarded value (design 13.5) covers the
  whole value, so it silences a pure operation under `&&`, `||`, `?:` or
  a cast that the source with a call in place of the try would draw a
  report for: `c && (x == try f());` and `(long)(x == try f());` compile
  under -Werror, as does `(long)try f();`, which Clang reports with a
  call. Decide whether such a case is worth a rule that follows the
  path to each try.
- [Low] A chain of 3000 `a ? try f() :` exceeds Clang's bracket depth
  of 2048; refuse past a named bound or document it.
- [Low] Per-holder quadratic costs: `Try_plan.expression` appends with
  `@` on left-nested chains, `site_of` and `text_of` search lists,
  `refuse_short_lived` filters every hoisted operand, and the prelude
  measures the open conditions per operand.
- [Low] Readability in try lowering: `prelude` is long and reads
  `opened` by position in four places; `hoisted_operands` returns unit
  and forces a `ref` and an `invalid_arg`; `refuse_not_held` takes a
  `try_place` and rejects `Held`.
- [Medium] A copy of source text forces the whole lowered text from
  inside the pieces of a moved edit (`Lowering.text_edits`), so a copy
  made eagerly while the text is lowered compiles and fails only at
  run time, with `Lazy.Undefined`, on the inputs that reach it; and
  copying ends only because no copy holds the edit it is copied for,
  which rests on front-end rules (design 6 rule 4, 5.1, `try-position`).
  Make a copy a value, its span and the moves it applies, among the
  pieces of an edit, and resolve every copy in one pass over the final
  edits, which can also refuse a cycle.
- [Medium] Typing a holder whose expression hoists N operands costs
  O(uses x N): `Declarations.holding` filters every moved text being
  read for each use of a name. A `?:` chain of tries at the parser's
  depth bound takes 20 s, and `test_deep_trees` pays it. Index the moved
  texts, which nest, by token, so a use finds those that hold it along
  one chain.
- [Low] A `slice_from_array` nested in the operand of another is copied
  into the outer one's length as well as its data, so N nested makings
  write 2^N copies of the innermost operand.
- [Low] `(void)(c ? try e() : try e2())` is refused as `try-void`,
  though the branches of a void conditional are discarded (5.2), and
  `__real__ (try f()) = 1.0` is accepted, as `Try_plan` drops the
  lvalue under `__real__` and `__imag__`.

## Declarations

- [Low] Every point that needs a type complete must call
  `needs_complete` (`src/sema/declarations.ml`) to define a generic
  type's instance that only a pointer has met; the type argument of a
  generic function was a point that did not, and refused
  `box(option(int)) a; clear(&a);` for `type box(T) = struct { T *items; };`.
  The list of callers holds by review. Make the question itself define
  the instance: one query of completeness, used by `Value_type` and
  every other check, that goes through `Ctype.define_instance`, so no
  check can ask whether a type is complete without defining it.
- [Medium] A `#pragma pack` line in force at the definition of a
  generic (function or type) is not carried to its instances: every
  instance stands in the bracket of design 10.3 and has the packing of
  the command line, so `#pragma pack(1)` before a generic function whose
  body declares a structure changes the layout that the check saw
  (`_Static_assert(sizeof s == 5)` passes the check and fails in
  `sz__i`). Refuse a generic defined under a `pack` line other than the
  command line's, or write the line into the bracket.
- [Medium] Definition checks re-read the closure of the generic
  functions that each body calls, and charge the instance budget for
  each reading (design 3.5 rule 7), so a library of many generic
  functions over shared helpers may use up the budget with no use of
  any of them. Package 3.6 measures it; if a real header passes the
  budget, charge a check once per callee, or not at all.
- [Low] A function instance that a unit names only in the operand of
  `sizeof` is defined and never called, which Clang reports under
  `-Wunneeded-internal-declaration`. Mark instances
  `__attribute__((unused))` if the profile admits the attribute on
  both backends, or define only instances whose names are evaluated.
- [Medium] Whether the text of a type holds an attribute, an alignment
  specifier or a `__typeof__` of an expression at the depth of design
  3.5 rule 2 is computed by a walk of the tree of its own
  (`Declarations.specifiers_are_inexact` and the functions after it),
  which must agree with the reader on what it visits. Have the reader
  return the fact with the type that it reads. `for_declarator` runs the
  walk for every declarator, members and nested parameters included,
  which nothing reads there and which costs depth times size.
- [Low] Moved text can hold C text through a line marker, as an
  `#include` of a C header inside the operand of a `try`, and the
  parser passes a block literal there unread, so `^{ extern int o
  __attribute__((aligned(16))); }` declares an entity with linkage that
  design 13.5 refuses in moved text, unseen. No backend is known to
  carry such an attribute out of a block literal (Clang does not; GCC
  has none). Refuse C text inside moved text, or hold the rule of
  `Resolution.check_unread_declarations` in the parser's one scan of
  unread text (`scan_unread`) for every unread kind in a moved span.
- [Medium] A declaration without `overloadable` that follows an
  overload of its name, with no function before the overloads, is taken
  as the name's first declaration (`Declarations.earlier_entity`, the
  `beside` table), so `int f(int) __attribute__((overloadable));
  typedef int f;` and `...; int f;` are accepted, which Clang rejects
  (C11 6.7p3); so is `int f(int); int f(int)
  __attribute__((overloadable)); int f(int);`. Refuse a declaration of
  another kind after an overload set.
- [Medium] `Resolution.add_typedef` infers the token of a typedef
  name's first declaration, the key of the check of moved text (design
  13.5), as the least `Tree.declared.earlier` of its redeclarations, so
  `Declarations.record_again` passes it every redeclaration, exact ones
  included, and the key is right only because one scope is read in
  token order and an overload stands beside a function alone. Have
  `Entity.t` carry the token of its first declaration, set where
  `fresh_entity` makes it, and key the event by that.
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
- [Low] The size of an array that an initialiser completes (`sizeof a`
  of `int a[] = { 1, 2 }`, `sizeof "abc"`) is opaque, as every array's
  is under P16, though its element type and length are known, so an
  enumerator or bit-field width of it is refused. Computing an array's
  size from its element's where the element is a scalar would accept
  it without computing any aggregate layout.
- [Low] `external_facts.anchor` is an option only for the state before
  the first external declaration, and `note_text` takes it with
  `Option.get`. Build the facts at the first external declaration, or
  make the facts themselves optional.
- [Medium] The record of what a generic's definition uses and declares,
  which `Resolution.check` reads, is complete only while every lookup of
  a use in `state.entities` and `state.tag_types` goes through
  `entity_used` or `prior_tag`, and every declaration through
  `bind_entity` or `bind_tag`. Make the two tables an abstract module in
  `declarations.ml` whose only lookup of a use and only binding record
  them, with separate, named accessors for the comparison at a place,
  the type parameters of an instance, the final types of enumerators
  and the builtins, so that a new lookup cannot skip the record.
- [Low] The reader still keeps its own model of file scope,
  `state.place`, beside the parser's `Tree.scope_depth`: it drives
  `note_nested_mention`, the `~at_file_scope` of every record and
  enumeration declared, and the variable length array rule, and a
  block of a statement expression outside a function leaves it at file
  scope (`struct q` in `int a[sizeof(({ struct q { int z; } x; 1;
  }))];` is a record of file scope). The backend refuses such a
  statement expression anyway. Derive these from the scope that the
  parser recorded and retire `At_file_scope` as a source of the fact.
- [Low] The enumerators that a variant's constructors claim have no
  `Tree.declared` in the tree: `declare_tag_enumerators` builds one in
  the reader, with the variant's scope, and `Tree_dump` repeats the
  rule. Record each constructor's declaration in the tree where the
  parser claims it, and read it in both.

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
- [Low] Typing refuses every type name in an expression of a generic
  type's definition that mentions a type parameter
  (`Declarations.expression_type_name`), where design 7.1 rule 4
  refuses only a construct that needs the value of an expression that
  depends on one: `type g(T) = struct { __typeof__((T *)0) p; };` is
  refused (`generic-definition`) and the design allows it. Give the definition check
  the test of rule 4 when generic functions are typed, as their bodies
  need it.
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
- [Low] Which constructors have a payload and whether a variant has a
  union (design 10.1 rule 3) is decided twice: sema reads it from
  `Ctype.constructor.fields`, and lowering derives it again from the
  tree's fields less an instance's void fields (`Lowering.has_fields`).
  Have the reading record the decision once, for lowering to apply.
- [Low] `_Atomic(void)` is accepted, as in `_Atomic(void) *p;` or the
  argument of `ptr(_Atomic(void))` and `opt(_Atomic(void))`, and the
  backend refuses the typedef that typec writes for it: Clang refuses
  `_Atomic` of an incomplete type. Check what C11 6.7.2.4 and GCC
  allow, and refuse the same where the type is built.
- [Low] Names used only inside a field that void removes from an
  instance (design 3.5 rule 6) still take part in the resolution check
  (13.5) and still cause instances and argument typedefs, although
  lowering writes none of that text. This refuses or writes more than
  needed, never less.

## Matching

- [Medium] typec does not check that `&` takes no `register` object
  (C11 6.5.3.2p1): `register struct s r; (&r)->m` is a backend error.
  Record in `typed` that an lvalue designates a register object, or a
  member or element of one, as `bit_field` is recorded; then `address`
  refuses it, and `access_of` in `src/sema/expressions.ml` reads that
  fact and `lvalue` instead of walking the syntax in `addressable`.
- [Low] `case A: L: case B:` in a match is refused under design 4.3
  rule 3; the rule it breaks is 4.1 rule 2 (a label of the match stands
  directly in its body). Give the label under a named label its own
  message.
- [Low] A type declaration in the body of a generic function keeps its
  names in each instance (design 7.3 rule 7): the typedef name of the
  type and the enumerators of a variant's constructors, which lowering
  spells from the type's name (`type_declaration` and the constructions
  in `src/emit/lowering.ml`). Each instance stands after the file-scope
  declarations that follow the definition, so `type pair = ...;` in the
  body and a later `int pair;` fail under `-Wshadow -Werror` on GCC 16,
  though nothing is hidden as written. Writing them under local names
  needs the variant's name in typing (`Ctype.variant_name`) to be the
  instance's own.
- [Low] Invented names are string literals in lowering, the emitter
  and the assertions, and `test/unit/test_naming.ml` finds them by
  scanning the C of one sample unit, with a count of the names it
  expects: a name of a construct the sample lacks goes unchecked. Make
  one module mint every invented name, with a constructor for a name of
  one of a kind that refuses `__` and one for a kind word and its rest,
  so design 13.5's rule holds by type. The kind words (`arg`,
  `module`, `header`, `pack_probe_1`, `pack_probe_2`) are not in the
  code yet.
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

- [Low] A resumed instance never reads the seeds again, so new
  committed seeds reach a campaign only through a new instance. Giving
  the main instance `-F` on the seed directory would have AFL++ import
  them on every run.
- [Low] The time and heap figures of the `parser` target in
  `tools/fuzz/fuzz.ml` and the docs' fuzzing limits (8K additions in
  65 ms, 50 words per byte) were measured with the declaration reader
  in that target; measure them again in the instrumented harness and
  adjust the 300 ms limit if the parser alone is much faster.
- [Medium] The refusal of a forwarded `-d` option (design 13.2) knows
  only `-Wp,`, `-Xpreprocessor` and `-Xclang`: Apple Clang 21 also
  passes on `-Xclang=-dM`, `-Xarch_host -dM`, `-Xarch_ARCH`,
  `-Xarch_device`, `-Xopenmp-target[=]` and `-Xoffload-compiler`
  values, and expands `@FILE` inside `-Xclang` and `-Wp,`. The reader
  refuses Clang's `-dM` and `-dI` text and Clang ignores `-dU`, so no
  wrong unit is known to pass, but the rule is a list. Decide whether
  a forwarded option is read as the same option on its own for every
  refusal (which also refuses `-Wp,-P` and `@FILE` up front) and
  whether the `-X` family is marked by a prefix rule; `is_dump` also
  tells a dump by its refusal message, which an entry flag would make
  hold by construction.
- [Medium] `tools/fuzz/seeds.t` passes a seed that its target refuses,
  as the harness exits 0 for a refusal too, so a seed that never reaches
  the stage it is for goes unnoticed (four parser seeds lacked the line
  marker the reader needs). Have the test say how far each seed got, for
  instance a harness mode that fails unless the target's last stage
  accepted the input.
- [Medium] The AFL++ dictionary (`tools/fuzz/dictionary.ml`) lacks the
  words that reach lowering: the contextual keywords of Type-C (`match`,
  `generic`, `type`, `try`, `defer`), the names of the universe text
  (`slice_from_array`, `slice_sub`, `result`, `Ok`) and the `.tc"` of a
  line marker that makes a unit Type-C. The contextual words are
  constants and a `match` on strings spread over `src/syntax/parser.ml`,
  not one table; make them one, then generate the dictionary entries
  from it.
- [Medium] Offer the OCaml AFL patch upstream
  (`tools/fuzz/patches/ocaml-5.5.2-afl.patch`). AFL++ on macOS hands the
  coverage map over only as a POSIX shared memory descriptor
  (`__AFL_SHM_FD`), and the runtime of OCaml (`runtime/afl.c`, 5.5.2 and
  trunk) attaches only a SysV segment and speaks only the old
  fork-server handshake, so the fuzz build needs a patched compiler
  (docs/development.md, "Fuzzing"). Raise there too that the map size is
  defined twice, as `INITIAL_AFL_AREA_SIZE` in `afl.c` and
  `afl_map_size` in `asmcomp/afl_instrument.ml`, and the runtime reports
  the former. Once OCaml takes both changes, drop the patch and pin the
  release that has them.

## Test hosts

`tools/hosts` runs the suite on Debian 13 (glibc) and Alpine 3.24
(musl) in containers, each on x86-64 and on arm64 (the latter under
emulation), and on FreeBSD 16.0-CURRENT over ssh, x86-64.

- [High] `c_header.t` fails on `debian-amd64`: the dependency output of
  the backend lists `/usr/include/stdc-predef.h` before the other
  headers, which the expected output lacks.
- [High] `type_declarations.t` fails on `debian-amd64`: Clang 21 prints
  an "add missing switch cases" note after the `-Wswitch` error that the
  expected output lacks.
- [High] `try_expressions.t` fails on `debian-amd64`: `fenv.tc` links
  without `-lm` (undefined `feclearexcept` and `fetestexcept`) with
  Clang and with GCC.
- [High] `examples.t` fails on `debian-amd64`: `original/strnsubst.c`
  uses `uintptr_t` without `<stdint.h>`, which glibc's headers do not
  bring in.
- [Medium] `tools/hosts/run.sh` runs only the image's GCC, `gcc` 14 on
  Debian, whose image fixes `TYPEC_TEST_GCC`, so the suite never runs
  with the image's `gcc-16`; run by hand with `docker run --env
  TYPEC_TEST_GCC=/usr/bin/gcc-16`, it gives the same four failures as
  GCC 14. Pass the variable through `run.sh` or name a host for it.
- [Low] Two runs of `tools/hosts/freebsd.sh` on one `DIR` at once are
  not guarded: each empties the other's source and corpus.
- [Low] Two runs of `tools/hosts/run.sh` for one host from trees with
  different Dockerfiles remove each other's image after building their
  own, so the second build can remove the first's image before its
  container starts ("No such image"), and the two rebuild on every
  alternation.
- [Medium] `tools/hosts/run.sh` (`take_results`, `changed_records`) and
  `tools/hosts/freebsd.sh` (`check_records`, `copy_records`) each check
  and copy the records a host sends back, in different ways, and
  `run.sh` accepts any one host directory and any record names. Give
  both one funnel that takes only the records of the host, programs and
  compilers of the run, with `runs/` removed before the run instead of
  comparing against what was sent.
- [Low] Neither host script bounds the size of the results a host sends
  back, so a host that runs hostile corpus code can fill the local disk.
- [Low] `test/run/abi.t` checks the compatibility of `hand.h` with the
  lowering only as far as layout, so a member that keeps its size but
  changes its type (`unsigned u` to `int u`) passes while the tags stop
  being compatible across translation units. GCC 16 under `-std=c23`
  accepts an identical second definition of a tag and rejects a
  different one: a `-fsyntax-only` step on `abi.tci` followed by an
  unprefixed `hand.h` would prove it, if `typec` passes `-std=c23` on.
- [Low] Gate 4 has no instruction counts for GCC 16.
  `tools/measure/gate4.sh` needs hwpmc, which only p620 has, with GCC
  14 but not GCC 16; the macOS host has GCC 16 but no hardware
  counters, so it can only be timed by wall clock. Building
  `lang/gcc16` from ports on p620 and naming it in `TYPEC_TEST_GCC` for
  a second run would count it.
- [Medium] On GCC 16 the trapping `default` of a `match` in a hot loop
  costs about 18% in `shapes`: its loop over the array keeps an index
  counter beside the pointer, while a twin without the `default` (and
  so without the guarantee of design 4.5) does not. Reproduce by
  dropping the `default` from `tools/measure/gate4/shapes.c` and
  comparing the loops of the two builds at `-O2 -S` with GCC 16. The
  twins carry the same `default`, so the gate does not see it. Is the
  lowering of the default (design 13.5) worth changing, for example to
  one trap block shared by the `match` sites of a function, without
  weakening design 4.5?
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
- [Medium] Report to OCaml upstream (the owner decides to file) that a
  `Stack_overflow` raised at a stack that cannot grow carries no
  backtrace in native code on arm64. `test_small_stack` skips its
  assertion that the backtrace names the stage on arm64, by
  `Config.architecture`, and prints why; the other users of
  `Small_stack`, `test_parser` and `tools/fuzz/parser_target.ml`, get an
  empty backtrace there. In OCaml 5.4.1 native code
  on arm64, when a stack reaches its limit the `Stack_overflow` carries
  an empty backtrace: 0 frames on the main fiber and 2 after the
  re-raise of `Small_stack.run`, where amd64, and bytecode on arm64,
  give 1024. `caml_call_realloc_stack` in `runtime/arm64.S` pops the
  argument pair that holds the caller's `x30` and raises with `x30`
  pointing into the stack-check stub of `asmcomp/arm64/emit.mlp`, which
  has no frame descriptor, so `caml_stash_backtrace` stops at once;
  amd64 raises with the real return address. The fix to report is `ldr x30, [sp, 8]` before the `add sp, sp, 16` (unbuilt,
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

- [Low] The runner's command line and the meaning of its status 3 are
  written out in `tools/hosts/corpus-in-container.sh`,
  `tools/hosts/freebsd.sh` and the example in `docs/development.md`;
  `run.sh` and `freebsd.sh` could share one script that runs it.
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
  time, because `typec` cannot report the revision it was built from:
  `typec --version` prints the release of `dune-project` only. Printing
  the revision too would name the binary exactly, but needs git at build
  time, which a release tarball lacks.
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

## Language reference

- [Medium] Write section 12 (checked mode) of `docs/reference.md`,
  which points to the design instead.
- [Low] The README states `typec`'s exit statuses in five sections
  ("Choosing the backend", "Compiling a `.tc` input", "Printing the
  target model", "Printing the version", "What typec reports"), copies
  of typec(1)'s EXIT STATUS, which `test/unit/test_manual.ml` checks
  against the driver while nothing checks the copies. Have the README
  point to typec(1) for them, as `docs/reference.md` does.
- [Low] typec(1) (DESCRIPTION) and the README ("Compiling a `.tc`
  input") call an input a Type-C unit when it ends in `.tc` "with no
  `-x` other than `-x none` before it", but `typec -x c -x none x.tc`
  compiles `x.tc` as Type-C: the rule is that the last `-x` before it,
  if any, is `-x none`. Say so in typec(1) and have the README point
  to it.
- [Low] Neither the design nor `docs/reference.md` says that C text
  cannot write a constructor expression: in a `.h`, `Q(1)` gives
  "'Q' is not declared" and `T.C` "expected an expression, found the
  type name", for a public variant too, while reference 1.1 says the
  grammar is the same for both texts. State the restriction (design
  2.1 and reference 1.1), or make C text take constructors.
- [Low] Design 9.2 rule 4 says that a line marker in the source can
  name the owner's file and so claim its rights, but a client unit
  that begins with `# 1 "ticket.tc"` is still refused
  `[private-creation]`. Find which marker, if any, claims the rights,
  and correct the design to match.
- [Low] `docs/reference.md` does not state some rules that a user can
  meet: `[excess-initializer]` (design 5.2), the pragma rules
  `[try-pragma]`, `[deferred-pragma]` and `[instance-pragma]`, the
  `return` rules of design 6 rule 12 (`[defer-return-jump]` and the
  `defer-return-*` names), `[function-instance-place]`, the rest of
  `[generic-definition]` (`_Alignas`, `_Atomic ( )`, `typeof` and
  attribute arguments over a parameter, an enumeration with a body, a
  structure body under a declarator), provisional P26, and the
  translation limits of design 3.5 rule 7 and 4.7 rule 10.

## Design questions with a gate

- [Low] Design 3.5 rule 7 and P30 say that the encodings of the
  arguments of one instance hold at most 4096 bytes together, but
  `Encoding.instance` bounds the whole code of the instance: `I`, the
  generic's name with its length and the encodings, up to 259 bytes
  more than the arguments. `typec --stats` reports that code
  (`longest_instance_code`). Package 3.6 settles the bound; say in the
  rule which quantity it bounds, or bound only the arguments.
- [Low] `typec --stats` reports nothing for a unit that typec refuses,
  which is the unit nearest a limit. If package 3.6 or the pilot wants
  the counts of a refused unit, carry them in the error.

- [Medium] Pilot B (plan, Stage 2) counts the label addresses that
  design 4.4's reading of `&&L` refuses though no `goto *` is ever
  given them, such as the kernel's `_THIS_IP_` (`({ __label__ __here;
  __here: (unsigned long)&&__here; })`) in a match arm or in the scope
  of a `defer` statement. If they occur, change the reading as design
  4.4 says.
- [Medium] A function that hands a deferred resource to its caller, or
  links it into a structure, clears the variable first, since the
  deferred statement reads the variable at the exit (`ret = x; x = 0;
  return Ok(ret);`). 7 of the 9 `defer` statements of Pilot B need
  that hand-over, nothing checks that it is written, and forgetting it
  frees what the caller owns. Count the idiom again in the next pilot
  before any change to the language, such as a `defer` that runs on
  the error exit alone.

## Design questions without a gate yet

- [Medium] A slice argument costs code under GCC on Arm. Pilot C's
  port of `stream_buffer.c` is 5.9% larger than the original at -Os
  and 3.9% at -O2 over arm-none-eabi-gcc 14, though smaller over
  Clang: GCC builds every two-word structure argument on the stack
  and loads it back into registers, as plain C passing such a
  structure does, keeps one `slice_sub` check Clang folds, and does
  not carry a length's value range through a structure member as it
  does through a scalar (pilot repository
  /Volumes/Optaine/type-c-pilot-c at 83abeea, README "Sizes"). Weigh
  lowering a slice parameter of an internal-linkage function as two
  scalars against the mechanism it adds; measure on GCC 15 and 16
  first.
- [Medium] A member access to an `_Atomic` structure or union, which
  C11 6.5.2.3p5 leaves undefined, is typed with the atomic qualifier
  dropped (`member_of` in `src/sema/expressions.ml`) and not refused.
  A `match (p->state)` on such a structure then reads the member
  through its base several times, and GCC warns into the lowered text
  naming `__tc_base0`, where Clang refuses it (`-Watomic-access`).
  Refuse the access in typing, at the user's text.
- [Low] Design 13.5's list of lvalues whose address C aligns rests on
  `#pragma pack` being the only way a variant or an object holding one
  is packed where typec does not see it. Check two other ways on both
  backends: a variant declaration carrying `__attribute__((packed))`,
  and `-fpack-struct=n` on the command line.
- [Medium] A generic container hashes and compares an opaque `K` only
  through function pointers it is handed, so the per-type operations
  are indirect calls unless the C compiler propagates the constant
  pointer. `examples/wordfreq` measures it: Clang inlines them and the
  generic map beats `khash` by 10%; GCC 14 keeps the calls and the map
  is 18% slower, 5 points of it the index checks. Decide whether
  Type-C binds such operations at instantiation (a function parameter
  that each instance fixes, so the lowering calls it by name), or
  documents the cost.
- [Medium] What a renamed C file loses is spread over design 2.2, 2.3,
  2.4, 13.2 and 13.3, and the README's "Adopting one file" repeats it
  by hand; the refusal of a source character that is not valid UTF-8
  (`src/sema/escape.ml`) and of a builtin outside the table are in no
  section. Make design 2.2 the one list of the exceptions to the
  superset property, each pointing at the section that states it, and
  have the README link to it instead of keeping its own list.
- [Medium] C text keeps C's meaning for a universe name at three
  grammar sites (`opens_nested_declarator`, `parameters`,
  `identifier_list` in the parser), which serve `slice` and `str` as
  well, since the universe text declares them. As a bare generic is
  always an error (design 3.5 rule 1), a universe generic in C text
  could begin a type only before `(`, decided in the one predicate
  behind `starts_declaration` and `is_typedef_name`, which would cover
  every C position at once; `str`, the one universe type that is no
  generic, would keep the three sites or need a rule of its own. Owner
  decision: it changes the wording of design 2.2 and 2.3.
- [Medium] The tests rebuild where the universe tokens end, which the
  reader alone knows: `Spans.read_bytes` puts `File.universe_text` in
  front of the text, and `test_parser`'s `universe_token_count` counts
  the universe's tokens. A reader view for tests (the index of the first
  own token, the bytes the tokens index) would make them read the one
  fact instead.
- [Low] Design 13.3 calls the universe text "the two lines of 3.6",
  `option` and `result`, while `File.universe_text`
  (`src/cpp/file.ml`) holds four, adding `slice` and
  `type str = slice(const char);`, and section 8 writes `str` as
  `typedef slice(const char) str;`. Make 13.3 and section 8 state the
  four lines as the reader has them, or change the reader.

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
- [Low] Design 7.1 rule 3: the refusal of the zero initialiser of a
  variable length array passes an array whose variability
  `Depends_on` an unknown type; refuse it unless it is `Answer false`.
- [Medium] The type declarations that a text lowers come from one
  table of the unit, which `Lowering` filters for each text by span,
  while the other inputs of `text_edits` come from the reading of the
  text (`typed`, `names`). Have the reading of each text carry the
  type declarations it read, so that no kind of text can lower its
  constructs and miss its declarations.
- [Medium] `Expressions.gives_dependence` lists the constructs that
  give dependence on a type parameter, where design 7.1 rule 4 wants it
  from the one place that gives a layout; the list refuses valid
  programs (`char buf[sizeof w.b];` with a member `b` of a record that holds a `T`,
  `char b[({ 4; })];`, and a `const volatile` object, which is no
  constant). A dependent `const` object reaches an `"i"` or `"n"`
  operand of `__asm__`, which asks for a constant.
- [Low] Generic functions, readability: `dependent_objects` stores a
  span that nothing reads; the message of `parameter_dependent` and the
  meaning of `type-parameter-constant` name too few sources of
  dependence; "in a generic function" is held in
  `Declarations.state.generic_part`, in
  `Expressions.context.generic_definition`, which follows it, and in
  `Expressions.enclosing.in_generic`, which covers the body alone and
  decides `__func__` and `gives_dependence`; derive the last from the
  context.
- [Low] typec accepts a scalar's initialiser in two pairs of braces,
  `int *q = {{0}};`, which C11 6.7.9p11 does not allow and GCC 16
  refuses ("braces around scalar initializer"); refuse the second pair
  where the initialiser is read, for all text.
- [Medium] GCC 16 warns of `unused` in a type name on a structure
  (`sizeof(struct s __attribute__((unused)))`, "ignoring attributes
  applied to 'struct s' after definition") and not on a `short`, so the
  fact that design 13.3 records of `unused` does not hold under
  `-Werror` there. Decide whether a warning breaks the fact.
- [Low] An attribute that typec does not know makes the type of a
  generic function unknown, so design 7.1 rule 6 refuses it whether or
  not the function ends in an ellipsis. No attribute changes the
  parameter types or whether a function is variadic, so an obscured
  function type could keep its prototype, as 13.3 keeps "whether it is
  a function type", and the refusal would then fall on the ellipsis
  case alone. Decide whether to keep the prototype.
- [Medium] Follow-ups of the review of the instance budget: the
  messages echo the presumed file name unbounded (`fail_instances`,
  `fail_nesting`, the output limit's refusal and every location
  prefix), so a file name of 100 KB is printed whole.
- [Low] The output limit charges each piece where it is made, so a
  piece that lowering puts into two edits is written twice and
  charged once. A `Moved` edit's pieces are read only through
  `Emitter.copied`, which charges them again, but a piece list that
  lowering holds itself could still be passed to two edits; no path
  does. Charging the edits that `limited` returns once more, exactly,
  would close it.
- [Medium] `Emitter.joined` holds a text built from a list to the
  limit only where lowering calls it (the enumerators, the case labels
  and the bindings); a text built per item by hand escapes it until
  its edit is made. Let `Emitter.code` and `closing` take the parts of
  their text and charge them part by part, so that `joined` goes.
- [Medium] The factor of the output limit counts every byte of the
  preprocessed unit, its headers included, so a short unit that
  includes 10 MB of headers may write 2.6 GB; and emission holds the
  text several times at its peak (each edit's string, the buffer that
  grows by doubling, its contents and the assertions appended). Weigh
  counting the unit's own bytes only, and write the replacements and
  the assertions into one buffer sized from the charge.
- [Low] Four copies of the substring helper in test/unit, five with
  `holds` in test_lowering.ml, should move to test/support.
- [Medium] Package 3.3: the instance budget (design 3.5 rule 7) for
  function instances. Reading the definition of a generic function for
  an instance counts on the one count, through
  `Declarations.charge_reading` with the link of the instance, as
  `in_instance` does for a type's, so that no reading goes uncounted;
  the output limit charges the texts of function instances as it does
  every text lowering makes. Regression, the shallow
  branching chain: the generic functions `g0` to `g24`, each
  `generic(T) void gN(T *p) { const T *q = p; gM(&p); gM(&q); }` and
  the last with an empty body, and one use `g0(&x)`. No chain holds
  more than 25 instances, so the nesting limit does not refuse it. It
  is refused with the message of the budget, within a time bound, and
  no lowered text is written. A definition check follows its chain and
  counts, the checks run in the order of the definitions, and one of
  them passes the budget before the use is read, so the error stands
  at a call in the definition of some `gM` and cites the call that
  began the chain, in the definition under check. The test asserts
  that both stand in definitions and not which `gM`. Partner: the
  chain of 10 functions compiles and runs, and the lowered text holds
  its 1023 instances. A second refusal has its place at a use: the
  chain of 10, used with as many argument types as pass the budget, is
  refused at a call in an instance, and the message cites the use that
  began the chain. With the count of function instances left out, the
  chain of 25 does not end within the bound.
- [Medium] Function names in a generic function (design 7.1 rule
  3): the refusal follows the array through the forms that hand it
  on as it is. Pairs for `test/golden/generic_functions.t`, each
  refused with `type-parameter-operation` in a generic body: `sizeof (__func__)`,
  `sizeof _Generic(0, int: __func__)`,
  `sizeof __builtin_choose_expr(1, __func__, 0)` and
  `sizeof __extension__ __func__`, which `typec` refuses and no test
  holds, and `sizeof(__typeof_unqual__(__func__))`, which it refuses
  for another reason: the front end does not read
  `__typeof_unqual__` in source text and reports an undeclared
  name. Decide whether the profile reads that specifier (design 13.3
  names `typeof` alone); if it does, the refusal is `type-parameter-operation`. Partners
  that stand, where C converts the array: `puts((__func__))`,
  `puts(_Generic(0, int: __func__))`, `puts(__extension__ __func__)`,
  `sizeof(({ __func__; }))`, `sizeof(0, __func__)` and
  `_Generic(__func__, const char *: 1, default: 2)`. The reason is
  tested on the backend: C text of each refused form gives 2 in `f`
  and 5 in `f__i` under both.
- [Medium] `Ctype.compatible` answers `Depends_on` for two unknown leaf
  types of one spelling (`_Float16`, `_Complex int`), so
  `pointers_differ` refuses `void (*q)(T, _Float16) = p;` where `p` has
  that very type. Let an unknown record whether it can hide a derived
  type, so that a leaf compares with its own spelling, and
  `is_variably_modified` answers for it too.
- [Low] `is_variably_modified` does not descend into function
  parameters, so the head `generic(T) void f(void (*g)(size_t n,
  T (*)[n]));` passes design 7.1 rule 6, which refuses a variably
  modified type at any depth, and `Ctype.same_length` then takes two
  variable lengths for the same in rule 7. Descend into the parameters
  of function types, and give `Variable` no "same" answer under
  `~exact:true`. Pair: that head is refused and `void (*g)(size_t n,
  T a[n])`, which C adjusts to a pointer, stands.
- [Medium] Generic functions: only `_Generic` and
  `__builtin_types_compatible_p` ask `Ctype.compatible_by_argument`;
  every other caller of `Ctype.compatible` takes "the argument decides"
  for "incompatible", so `vector(T) a = vi;` with `vi` a `vector(int)`
  passes, valid only in the `int` instance, and `vector(T) a[1] =
  { vi };` initialises `a[0]` whole in that instance and `a[0].data` in
  the others (`Initialiser.reach_of`). Give `compatible` the three
  answers, so every caller handles `Argument_decides`, as design 7.1
  rule 4 asks of one comparison.
- [Medium] Generic functions: whether the subject of an attribute
  mentions a type parameter is noted where the attribute is read
  (`Declarations.note_subjects`), so `struct __attribute__((packed)) s;`
  before `struct s { char c; T a; }` passes, and Clang carries `packed`
  onto the definition, where GCC 16 does not. Record the subject and
  ask `mentions_opaque` in `check_generic_attribute`, after the whole
  definition is read.
- [Low] The message of a generic prototype that holds `_Alignas`
  (`Parser.check_generic_prototype`) says that `_Noreturn` and
  attributes stand on the definition; C refuses the specifier there.
- [Low] Generic functions, readability and representation:
  `generic_part` is ambient state that `earlier_entity` and
  `declare_in` read; pass the fact explicitly from
  `read_generic_function`. `generic_function` could hold its function
  type, recorded after reading, removing `generic_function_type`'s
  `invalid_arg`. Split `read_generic_function` into named steps; make
  `pointers_differ` a flat match and raise the parameter gap before
  `crosses` in `refuse_conversion`; `object_of_first` and the
  untargeted-argument message want plainer wording.
- [Low] The resolution check sees a name of moved text only where
  typing passes it to `Declarations.note_use` or `note_own`, so a
  typing path that reads `state.entities` directly would let a name
  escape the check unseen. The parser resolves every name: it could
  record the uses and declarations by span for `Resolution` to read.
- [Medium] `Resolution.check` takes one place or none, so a caller with
  several places (the exits of a defer) runs the clauses that hold
  whatever the place once without one and then again at each place.
  Let it take the list of places, run those clauses once and the
  reading at each place.
- [Medium] The check of design 6 rules 8 and 12 looks up, by span, what
  typing found in each deferred statement and return operand
  (`Declarations.moved_text`) and the parser's view at each exit
  (`Parser.statement_view`), and a miss is an internal error: correct
  only while typing, the parser and `Reachability.defers` agree on the
  same nodes. Carry the view on the exit, or have typing return what it
  found keyed by the nodes that reachability reads.
- [Medium] `Emitter.moved` takes any range, so only the lowering that
  calls it keeps the text of an instance, which needs the packing
  bracket of design 10.3, from being written without one. The lowering
  of a `try` and that of the copies of a deferred statement use it;
  give it a site that only the parser makes, as
  `Emitter.bracketed` takes an anchor: the front of the statement or
  declaration that holds a `try`, or the place of a copy.

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
- [Low] P9 was decided on deferred statements that are each a single
  call (design 15). The cost of repetition grows with the size of the
  deferred statement times the exits of its scope: measure it on code
  whose deferred statements hold several statements, against the same
  code with a `goto cleanup`.
- [Low] P10 was decided on instance names read in lldb (design 15).
  Read them under gdb on a GCC build as well: an instance, its tags by
  name, and a value of it.
- [Low] Design section 8 rule 2 refuses a label of the function in the
  operand of a `slice_from_array`, as the third clause of the
  resolution property on a name in scope after the text (design 13.5,
  "Moved text"). Rule 3 of design 5.1 names a tag and an enumeration
  constant alone for the operand of a `try`, which is written once.
  Say in "Moved text" whether the clause takes a label for such a
  name where the text is written once.
- [Low] Design 10.5 gives a backend without `__builtin_trap` an
  endless loop after the trap function, which is a statement. The test
  of a slice writes its trap as an expression (design 13.5), and both
  supported backends have the builtin (design 2.4). Remove the clause
  from 10.5, or say what the expression is on such a backend.
- [Medium] Design section 8 rule 10 says what a second return of a
  call does to the values that a slice test holds. Every value that
  lowering holds across text of the program is in the same position,
  and no rule says so. A `return` in the scope of a `defer` holds its
  value in `__tc_r0` across the cleanups (design 13.5), and needs no
  GNU form and no `getcontext` to meet the case: a deferred statement
  marks a place with `setjmp` where C allows it, a `longjmp` to the
  body abandons the `return`, the `return` is evaluated again, and its
  cleanup resumes the first. Written by hand in the lowered form, the
  resumed `return` yields the later value under Apple Clang 21 at
  `-O0` and under GCC 16 at `-O0` and at `-O2` (`ret.c` beside
  `longjmp/measure.sh`, design 13.5). The temporaries of a prelude
  are held across the rest of the holder of their `try` expressions
  (design 13.5), which is unmeasured. A value of two parts can come
  apart there: under GCC 16 at `-O2` a resumed slice test had the
  pointer of one evaluation and the length of another (design 13.5),
  and a `result` in `__tc_r0` is a tag and a payload. Rule 10 states
  its limit over the full expression that holds the index. Go through
  the lowered forms for such values and state one rule of that shape
  for all of them in section 14, with rule 10 of section 8 as its case
  for slices.
- [Medium] Typing takes a compound literal that a constructor or a
  slice making writes for a constant wherever its operands are, but C
  takes it for one only as the braced initialiser of a whole object
  (design 13.5). At file scope `int *p = slice_from_array(a).data;`,
  `slice(int) g = 1 ? slice_from_array(a) : slice_from_array(b);`,
  `str s = 1 ? "a" : "bc";` and `e x = 1 ? A(1) : B(2);` pass `typec`
  and GCC 16 refuses each under `-pedantic-errors` ("initializer
  element is not constant"). Make such a value constant in one place,
  only where it initialises a whole object, and make the sentences of
  section 8 rules 5 and 6 that say these makings "stand at file scope"
  say so.
- [Medium] Constructions (`Sites.construction`, `Sites.brace`) and
  slice makings (`Expressions.slice_makings`) are two models of one
  concept, a value lowered to its braced list where it initialises a
  whole object: each has its own `braced` span, table and brace step,
  `initialises_whole` matches a pair of lookups, and a making's record
  has three writers (`made_slice`, `convert_slice`, `initialises_whole`)
  whose result rests on the conversion running before the brace step.
  Give both one record, with the instance decided once, when it is
  typed.
- [Low] Slice lowering, loose ends: `slice-check-place` names "an index
  of a slice or a `slice_sub`" for a conversion outside a function body
  (`void g(int a[take(m)]);`), and section 8 rule 9 does not name
  conversions; `slice_check` and `check` name conversions, which test
  nothing; `Lowering.by_body` groups consecutive runs only, which is
  right only while bodies never interleave (`unsupported`);
  `Expressions.slice_checks` maps an evaluated check outside a body to
  `Untested` instead of failing; the untested trap is spelled three
  times in `untested` and the temporary names `__tc_s%d`, `__tc_i%d` in
  four functions; `convert_slice` decides, re-targets a making and
  records a check in one match; `slice_of` hides a `needs_complete`;
  `read_universe_generic` also reads `str`; `state.slice_generic`
  repeats the `generics` entry of `slice`.
- [Low] `slice_sub` of an empty slice whose `data` is null, which
  section 8 rule 7 allows, lowers to `NULL + 0`, undefined in C11
  (6.5.6p8); neither backend's UBSan reports it. Decide whether the
  lowering avoids the addition at `lo == 0` or the design forbids a
  null `data`.
- [Low] `slice_from_array(a).len` is a member of a compound literal
  and no constant expression (design section 8 rule 2, 13.5). An
  array of that size, `char b[slice_from_array(a).len];`, is a
  variable length array; Apple Clang 21 in the GNU form of C, the
  default of `typec`, computes the size as a constant and warns of
  that without an option (`-Wgnu-folding-constant`), which is an error
  under `-pedantic-errors`, so this lowered text does not compile
  under that option as design 2.4 says all of it does. Decide whether
  the length of a `slice_from_array` is a constant expression of
  Type-C, lowered as the quotient alone where a constant is wanted,
  or whether 2.4 names the case; `sizeof(a) / sizeof(a[0])` is the
  constant meanwhile.
- [Low] Design 13.5 (the constructor row) gives the braced list to an
  initialiser of an object "declared with the variant's type". `typec`
  writes it for an object of a compatible type under any qualifier,
  and keeps the compound literal for an atomic object, which Clang
  gives no braced list (`initialises_whole` in
  `src/sema/expressions.ml`). State that condition in the row; the
  row of `slice_from_array` takes its condition from there.
- [Medium] Returning a `result` by value costs code. In Pilot B the
  text of `toml.tc` is 11.9% larger under GCC 16 (2192 bytes) and 2.8%
  larger under Apple Clang 21 (528 bytes) than the `goto cleanup`
  version in C. The repeated cleanups are 368 and 208 bytes of that
  (design 15, P9). The rest, 1824 and 320 bytes, is not split further:
  the record puts it down to the return of a structure of a tag and a
  union where the C returns an `int` or a pointer, and under GCC most
  of the growth is in functions that hold no `defer` (`parse_array`
  +432, `next_token` +208). `examples/ringbuf` measures the same cost
  alone: its parser returns `result(command, parse_error)`, 32 bytes on
  x86-64 and 16 on a Cortex-M3, through a hidden pointer, and rewriting
  it to return an `int` and write the command through a pointer, as the
  C does, saves 58 to 144 bytes of machine code with `-fno-inline` (76 under
  GCC 16 `-Os`, 108 under Arm GCC 14.2 `-Os`) and 0 to 192 as built
  (README there, "Where the bytes go"). Measure whether a `result`
  whose error type has no fields could be returned as a bare pointer or
  `int` (design 3.5, 13.4), which is one of the compact layouts of
  design 12.
- [Medium] Every tag of a variant is an `enum`, the size of an `int`,
  so `option(unsigned char)` is 8 bytes:
  `struct option__h { enum option__h_tag tag; union { struct {
  __tc_arg__h value ; } Some; } u; };` in the C of `examples/ringbuf`.
  On a Cortex-M3 the calling convention returns a structure over 4
  bytes through memory, so `ring_get` stores the tag and the byte to
  the caller's stack, where the C returns `-1` in a register. With
  every tag of that lowered C changed to `unsigned char`, the port's
  machine code shrinks by 112 bytes of 1288 under Arm GCC 14.2 `-Os`, 39 of
  1618 under GCC 16 `-Os`, 64 of 3140 under GCC 16 `-O2`, and 0 to 4
  under Apple Clang 21. The tag of the `option` alone gains nothing
  under Arm GCC (+28 bytes): GCC builds the two-byte return on the
  stack. This is evidence for the "Compact layouts" row of design 12,
  an ABI change, so opt-in; decide whether it comes in, and whether
  it follows the short-enum representation. Scripts and data:
  `/Volumes/Optaine/ringbuf-growth/tools/bytetag-all.sed`, results in
  `base/low/byteall.*.txt` there.
- [Medium] Alpine packages no csmith (3.24), so the csmith recipe
  fails to set up in the Alpine host images (`prepare.sh: csmith is not
  installed`). Build a pinned csmith from source in alpine.Dockerfile, or
  limit the recipe's lines to the hosts that have it.
- [High] Write the formal model for checked-mode lifetimes before any
  implementation of tier 2 (design 11.3). Nothing about lifetimes may be
  claimed until it exists.
- [Medium] Decide whether to offer an option that zeroes padding and the
  inactive part of a variant on construction, against disclosure of stale
  memory (design 10.1 rule 5).
- [Medium] Look at the lowered shape of a `try` prelude under `&&` and
  in the condition of an `if`: against the same code with the `try` in
  a declaration of its own, the single form under `&&` takes 1.135
  times as long on Clang and 1.137 on GCC 16 at `-O2`, and the one in
  an `if` condition 1.267 on Clang (plan, "Measurements of 3.12").
- [Medium] Design 5.1 (the rationale for the order) and 13.5 ("The
  statement that holds a `try`", "The objects and the order of a
  prelude", "The cost of a prelude") cite measurements of hand-written
  samples that no script in the repository reproduces: the order of
  two failing operands under a statement expression, the diagnostics
  of the prelude, its size against hand-written C, and the three
  forms that `try-lifetime` and `try-list` refuse, lowered by hand: a
  compound literal under the `if` of a prelude, a temporary object
  read after its hoisted operand (under the address sanitizer as
  well), and a braced list whose initialiser the order divides; and
  the braced list whose values are converted, with and without the
  temporaries of the converted values, under the floating-point
  environment, its `-Wconversion` warnings, and a bit-field
  initialised through a temporary of its declaring type.
  Package 3.12 adds the script under `tools/measure`; have the design
  cite it.
- [Medium] `Expressions.test` and `Expressions.arms` hold both forms
  of selection: a test keeps `constructor` and `constructors`, and an arm
  its `cases`, which lowering reads only where `nested` is `None`. Make
  each one variant, the tag of a flat selection or its tree, so that
  lowering cannot read the flat fields of a nested one.
- [Medium] Design 4.7 rule 10 bounds the selection tree at 127 nodes
  deep so that its nested `switch` statements (13.5) fit Clang's
  default bracket depth of 256, but the nesting of the statements
  around the match counts against the same 256 and nothing bounds it
  below the parser's node depth, so a match nested about 130 deep with
  a tree near the bound fails in the backend. Bound the two together in one place, or lower a path of the
  tree without nesting (a `switch` per node in sequence), which would
  remove the depth bound.
- [Medium] Design 4.7 cites counts of the bindings and fields of Pilots
  A and B that no script in either pilot's repository reproduces: add
  the script there and cite the commit that holds it.
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
- [Medium] A `defer` that is badly placed and also inside the statement of
  another `defer`, as in `defer if (c) defer g();`, is refused as
  `Defer_position`, because the position check runs while the inner
  statement is read and the walk that raises `Defer_in_deferred` runs
  after the outer one. Pilot B then undercounts the latter. Check
  "inside a deferred statement" first, at one place (design 6 rule 11).

- [Medium] Constant comparisons promote an enumeration operand by
  `Arithmetic.promote` of its compatible type
  (`Integer_constant.compared_type`, reached from `comparison_constant`
  in src/sema/expressions.ml), while typing promotes it by
  `Ctype.promoted_arithmetic`: where int has 16 bits,
  `(enum P)40000 > 0` for `enum __attribute__((packed)) P { PA = 40000 }`
  is false in Clang for msp430-elf and true in typec. The comparison
  should take the promoted types from typing, so promotion has one source.
- [Medium] A block-scope `enum __attribute__((packed)) E;` that names an
  outer `E` is a new tag in Clang, which carries `packed` to the block's
  list (`sizeof (enum E) == 1`), and the outer tag in GCC (size 4);
  typec follows GCC, records the `packed` on the outer enumeration and
  gives the block's list a known `unsigned int`, where design 13.4 wants
  an unknown type with either backend.
