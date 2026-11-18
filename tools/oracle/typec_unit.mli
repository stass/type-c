(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The typec half of the typing oracle: a preprocessed file as typec
    reads it, and the type it gives each expression, keyed as the
    records of {!Record} are, by the byte range of the expression in the
    file. *)

open Typec_sema

val model :
  cc:string -> string list -> Typec_syntax.Keyword_set.dialect * Target.t
(** [model ~cc options] is the keyword dialect and the target model of
    [cc options -fsyntax-only], as [typec] would take them for a [.tc]
    input. It raises [Failure] with a message when [cc] gives no model or
    the options are refused. *)

type t = private {
  target : Target.t;
  text : Typec_cpp.Reader.t;
  unit : Typec_syntax.Tree.translation_unit;
  declarations : Declarations.unit_text Declarations.t;
}

val read :
  Typec_syntax.Keyword_set.dialect ->
  Target.t ->
  name:string ->
  string ->
  (t, Typec_cpp.Reader.error) result
(** [read dialect target ~name text] parses [text], named [name], and
    reads its declarations, which types its expressions, as typec does. *)

(** An expression that typec has typed: the bytes [first] up to, not
    including, [limit] of the text. *)
type expression = { first : int; limit : int; typed : Expressions.typed }

val expressions : t -> below:int -> expression list
(** The typed expressions that end at or before byte [below], by their
    first byte and then their last. *)

val location : t -> int -> Typec_cpp.Location.t
(** The presumed location of the token that starts at or around a byte
    offset: the last token that starts at or before it, else the first. *)

val category : Expressions.typed -> string
(** [lvalue] or [rvalue]. *)
