(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Where Clang's records differ from C's types other than by spelling
    them as Clang does (README, "Typing oracle"): the rewrites that make
    Clang's spelling a type name typec reads, the spellings that name a
    type no type name can, and the records whose type is not C's. *)

val variable_length : string
(** The name that a rewritten spelling gives the length of a variable
    length array; whoever reads the spelling declares it as an [int]
    object that is not a constant. *)

val apply : string -> (string, string) result
(** [apply spelling] is Clang's [spelling] rewritten as a type name, or
    why it has none. *)

val retyped : Record.t -> string option
(** Why Clang's type of the record is not the type C gives the
    expression, when it is not. *)
