(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** What the table of rules in [rule_table.ml] is checked and turned into:
    the module Rule of typec_syntax and the catalogue of diagnostics. *)

type rule = {
  name : string;  (** the constructor of [Rule.t] *)
  code : int;  (** the number of the stable code *)
  clause : string option;
      (** the clause of the design that states the rule, which the
          diagnostic cites; [None] for a refusal whose text cites its own *)
  meaning : string;  (** what the rule refuses, in odoc markup *)
}

(** A row of the table. A rule that is removed stays as a [Retired] row,
    so that its number is never given to another rule; a retired row is
    no constructor of [Rule.t], so no diagnostic can carry its code. *)
type row =
  | Live of rule
  | Retired of {
      name : string;  (** the constructor that the rule had *)
      code : int;
      meaning : string;  (** what the rule refused *)
    }

exception Invalid_table of string

(** [check rows] raises [Invalid_table] unless row [i] of the table, live
    or retired, has code [i + 1] and the codes fit four digits. A removed
    row leaves a hole, so only a retired row can take a rule's place. *)
val check : row list -> unit

(** [ocaml rows] is the source of the module Rule, from the live rows.
    Raises [Invalid_table] as [check] does. *)
val ocaml : row list -> string

(** [catalogue rows] is the Markdown catalogue: a table of the live rows,
    then the retired codes. Raises [Invalid_table] as [check] does. *)
val catalogue : row list -> string
