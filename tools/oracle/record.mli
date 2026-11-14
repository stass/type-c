(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** One expression node of Clang's AST, as the oracle writes it. *)

type t = {
  first : int;
      (** the byte offset in the preprocessed file of the expression's
          first byte *)
  limit : int;  (** the byte offset just past its last byte *)
  kind : string;  (** Clang's node kind, such as [ImplicitCastExpr] *)
  cast : string option;
      (** the cast kind of a cast node, such as [LValueToRValue] *)
  category : string;  (** [lvalue], [prvalue] or [xvalue] *)
  qual_type : string;  (** the type as Clang prints it *)
  desugared : string option;
      (** the type with its outermost sugar removed, when that spells it
          differently *)
}

val to_line : t -> string
(** The record as a line without its newline: the fields
    [FIRST LIMIT KIND CAST CATEGORY TYPE DESUGARED] separated by tabs,
    an absent optional field spelled [-]. In the string fields, a
    backslash and every control byte is written as [\xHH], so a field
    holds no tab or newline, and a field that is [-] alone as [\x2d]. *)

val needs_escape : char -> bool
(** Whether {!to_line} escapes a byte: a backslash or a control byte. *)

val escaped : string -> string
(** A field as {!to_line} writes it. *)

val of_line : string -> (t, string) result
(** The record of a line that {!to_line} writes, or why the line is not
    one. Lines come from a file, so nothing about them is trusted. *)
