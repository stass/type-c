(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The characters between the quotes of a character constant or a string
    literal (C11 6.4.4.4, 6.4.5): source characters, which are UTF-8, and
    escape sequences. *)

type element =
  | Code_point of int
      (** A source character, a simple escape sequence or a universal
          character name (6.4.3), which the encoding of the literal
          encodes. *)
  | Code_unit of int
      (** An octal or hexadecimal escape sequence: the value of one code
          unit (6.4.4.4p9). *)

type error =
  | Unknown_escape  (** 6.4.4.4p1 *)
  | Escape_out_of_range  (** 6.4.4.4p9 *)
  | Invalid_universal_character  (** 6.4.3p2, or beyond U+10FFFF *)
  | Invalid_utf8

val decode : max_code_unit:int -> string -> (element list, error) result
(** [decode ~max_code_unit text] reads [text], whose escape sequences the
    reader has delimited. An escape sequence above [max_code_unit], the
    largest value of the code unit of the literal, is out of range. GNU
    [\e] is the escape character, 27. *)

val error_message : error -> string
