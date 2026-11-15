(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** How to build and test one corpus program, read from its [recipe]
    file (README, "Running the corpus").

    A recipe is a list of lines, each a keyword and its words, separated
    by blanks; [#] starts a comment line. A recipe has at least one
    [tree], [program] and [test] line; every keyword but [prepare] may
    repeat, the words of a repeated [cflags], [libs] or [library]
    accumulate, and each [test] line is a test of its own:

    {v
    tree ARCHIVE [DIR]        copy the fetched ARCHIVE into DIR
    cflags WORD...            backend options of every step
    cflags@HOST WORD...       the same, only on HOST
    libs WORD...              options after the objects of a link
    libs@HOST WORD...
    prepare SCRIPT            run in the build tree before compiling
    library UNIT...           units linked into every program
    program NAME UNIT...      a program linked from its units
    test own SCRIPT           run in the build tree after linking;
                              exit status 0 means the program's own
                              test suite passes
    test substitute SCRIPT DESCRIPTION...
                              the same, for a script that is not the
                              program's own suite (a smoke test, or
                              tests that are only compiled); the
                              DESCRIPTION says what it checks
    test@HOST own SCRIPT      either test line, only on HOST
    test@HOST substitute SCRIPT DESCRIPTION...
    v}

    A [HOST] is [SYSTEM], a host whose [uname -s] is [SYSTEM], or
    [SYSTEM/MACHINE], one whose [uname -s] is [SYSTEM] and [uname -m] is
    [MACHINE]. Each test line runs on the hosts it applies to, in the
    order of the recipe; on any other host the record shows it skipped.
    A line without a host applies everywhere, so a substitute beside an
    own suite limited to one host also runs there: that keeps the
    substitute checked on every host, and the format needs no way to
    name the hosts a line excludes.

    A [test] line has no default: it states whether its script is the
    program's own suite, because the exit gate counts only that as the
    program's tests passing, and only when every own line applies to the
    host.

    A [DIR], [UNIT] or [NAME] is a path relative to the build tree, a
    [SCRIPT] a file in the directory of the recipe. The runner adds
    [-O2]; a recipe gives no optimisation or debug option.

    The [prepare] and [test] scripts run with [sh], in the build tree,
    with these environment variables:

    {v
    CC         the backend, as given to the runner
    TYPEC_CC   the same, which typec reads as its default backend
    TYPEC      the typec under test, as an absolute path
    v}

    A test script runs once the units are built, on the programs that
    linked, even when others did not: a program that did not link has no
    file [NAME] in the build tree, and the script skips it. The record
    never calls such a run a pass of the program's tests, whatever the
    script's status. A script may print one line per test for the
    runner to count into the record, in the format of {!Test_lines}. *)

type tree = { archive : string; dir : string  (** ["."] for the root *) }
type program = { name : string; units : string list }

type suite =
  | Own  (** the program's own test suite *)
  | Substitute of string  (** what a script that is not the suite checks *)

(** Whether a test line applies to the host the recipe is read for. *)
type place =
  | Here
  | Not_here of string  (** the [HOST] the line is limited to *)

type test = { script : string; suite : suite; place : place }

type t = {
  trees : tree list;
  cflags : string list;
  libs : string list;
  prepare : string option;
  library : string list;
  programs : program list;
  tests : test list;  (** in the order of the recipe *)
}

val units : t -> string list
(** Every unit of the recipe, the library's first, each once. *)

val read : system:string -> machine:string -> string -> (t, string) result
(** [read ~system ~machine path] reads the recipe at [path] for the host
    whose [uname -s] is [system] and [uname -m] is [machine]. The error
    names the file and the line. *)
