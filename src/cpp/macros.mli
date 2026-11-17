(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The macros of a unit, from the [#define] and [#undef] lines that
    [cc -E -dD] writes at their places (design 13.3): for each name, the
    token positions at which a definition or an [#undef] of it takes
    effect. The reader builds one per unit, beside the tokens. *)

(** Where a definition is, as a token's place: the file that owns its
    line and the presumed location of the line. *)
type definition = { owner : File.t; location : Location.t }

(** What a definition line does to its name. *)
type change = Defined of definition | Undefined

(** A definition line: the macro it names, the position at which it
    takes effect (the index of the first token after the line) and what
    it does. *)
type line = { name : string; position : int; change : change }

type t

val of_lines : line list -> t
(** [of_lines lines] is the table of the definition lines [lines], in
    the order of the text. *)

val at : t -> string -> int -> definition option
(** [at table name position] is the definition of [name] in force at
    the token [position]: that of the last change at or before it, or
    [None] where that change is an [#undef] or there is none. *)
