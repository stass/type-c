(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The target model: the facts about scalar types that the backend fixes.

    It is read from the backend's predefined macros, as printed by
    [cc -dM -E -x c /dev/null] with the options of the compilation, so the
    model and the compiler that compiles the output cannot disagree.
    [typec] keeps no table of targets. *)

type byte_order = Little_endian | Big_endian

(** Sizes are in bytes, that is in units of [char]. The widths of the
    typedefs such as [size_t] follow from the integer type behind each;
    see {!integer_width}. *)
type t = {
  char_bit : int;  (** [__CHAR_BIT__]: the width of a byte. *)
  char_signed : bool;  (** Plain [char] is signed: no [__CHAR_UNSIGNED__]. *)
  sizeof_short : int;
  sizeof_int : int;
  sizeof_long : int;
  sizeof_long_long : int;
  sizeof_pointer : int;
  sizeof_float : int;
  sizeof_double : int;
  sizeof_long_double : int;
  sizeof_int128 : int option;
      (** [__SIZEOF_INT128__], present when [__int128] exists. *)
  size_type : Integer.t;  (** [size_t] *)
  ptrdiff_type : Integer.t;  (** [ptrdiff_t] *)
  wchar_type : Integer.t;  (** [wchar_t] *)
  intmax_type : Integer.t;  (** [intmax_t] *)
  uintmax_type : Integer.t;  (** [uintmax_t] *)
  intptr_type : Integer.t;  (** [intptr_t] *)
  char16_type : Integer.t;  (** [char16_t] *)
  char32_type : Integer.t;  (** [char32_t] *)
  byte_order : byte_order;  (** [__BYTE_ORDER__] *)
  stdc_version : int;  (** [__STDC_VERSION__] without its suffix. *)
}

(** Why a macro dump gives no target model. *)
type error =
  | Malformed_line of string  (** A line that is not [#define NAME ...]. *)
  | Duplicate_macro of string  (** A name defined on two lines. *)
  | Missing_macro of string  (** A macro the model needs is not defined. *)
  | Malformed_macro of { name : string; value : string }
      (** A macro the model needs has a value it cannot read. *)

val of_predefined_macros : string -> (t, error) result
(** [of_predefined_macros dump] reads the output of [cc -dM -E]: one
    [#define NAME VALUE] per line, empty lines allowed. Macros the model
    does not use are ignored, but every line must have that form. *)

val integer_width : t -> Integer.t -> int
(** The width of an integer type in bits: its value bits and its sign bit
    (C11 6.2.6.2). The width of [_Bool] is 1, as its values are 0 and 1.
    Raises [Invalid_argument] for the [__int128] types on a target that
    has none, which no type of a program on that target can name. *)

val is_signed : t -> Integer.t -> bool
(** Whether an integer type is signed; for plain [char], {!char_signed}. *)

val to_string : t -> string
(** One [field: value] line per field of {!t}, in declaration order, with
    integer types spelled as in C, such as [unsigned long]. *)

val error_message : error -> string
