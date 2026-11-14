(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** How to build and test one corpus program, read from its [recipe]
    file (README, "Running the corpus").

    A recipe is a list of lines, each a keyword and its words, separated
    by blanks; [#] starts a comment line. A recipe has at least one
    [tree] and [program] and one [test]; every keyword but [prepare] and
    [test] may repeat, and its words accumulate:

    {v
    tree ARCHIVE [DIR]        copy the fetched ARCHIVE into DIR
    cflags WORD...            backend options of every step
    cflags@SYSTEM WORD...     the same, only where uname -s is SYSTEM
    libs WORD...              options after the objects of a link
    libs@SYSTEM WORD...
    prepare SCRIPT            run in the build tree before compiling
    library UNIT...           units linked into every program
    program NAME UNIT...      a program linked from its units
    test SCRIPT               run in the build tree after linking;
                              exit status 0 means the tests pass
    v}

    A [DIR], [UNIT] or [NAME] is a path relative to the build tree, a
    [SCRIPT] a file in the directory of the recipe. The runner adds
    [-O2]; a recipe gives no optimisation or debug option. *)

type tree = { archive : string; dir : string  (** ["."] for the root *) }
type program = { name : string; units : string list }

type t = {
  trees : tree list;
  cflags : string list;
  libs : string list;
  prepare : string option;
  library : string list;
  programs : program list;
  test : string;
}

val units : t -> string list
(** Every unit of the recipe, the library's first, each once. *)

val read : system:string -> string -> (t, string) result
(** [read ~system path] reads the recipe at [path] for the host whose
    [uname -s] is [system]. The error names the file and the line. *)
