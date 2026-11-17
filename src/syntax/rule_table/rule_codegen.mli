(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** What the table of rules in [rule_table.ml] is checked and turned into:
    the module Rule of typec_syntax and the catalogue of diagnostics. *)

type rule = {
  constructor : string;  (** the constructor of [Rule.t] *)
  name : string;
      (** the stable name that a diagnostic ends with, as GCC and Clang
          end a warning with its option *)
  clause : string;
      (** the clause of the design or the plan that states the rule, which
          the catalogue cites *)
  meaning : string;  (** what the rule refuses, in odoc markup *)
}

(** A row of the table. A rule that is removed stays as a [Retired] row,
    so that its name is never given to another rule; a retired row is no
    constructor of [Rule.t], so no diagnostic can carry its name. *)
type row =
  | Live of rule
  | Retired of {
      name : string;
      meaning : string;  (** what the rule refused *)
    }

exception Invalid_table of string

(** [check rows] raises [Invalid_table] unless every name, live or
    retired, is lowercase words of letters and digits joined by single
    hyphens, and no two rows have one name. *)
val check : row list -> unit

(** [ocaml rows] is the source of the module Rule, from the live rows.
    Raises [Invalid_table] as [check] does. *)
val ocaml : row list -> string

(** [catalogue rows] is the Markdown catalogue: a table of the live rows,
    then the retired names. Raises [Invalid_table] as [check] does. *)
val catalogue : row list -> string

(** [stale_citations rows ~file text] is a message ["file:line: ..."] for
    each citation in the Markdown [text] of [file] that names no live row
    of [rows], in the order of the text. Prose cites a rule as [\[name\]]:
    every pair of square brackets that Markdown leaves as text, being
    neither a link nor in code, is a citation. *)
val stale_citations : row list -> file:string -> string -> string list
