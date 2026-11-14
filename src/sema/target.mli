(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The target model: the facts about scalar types that the backend fixes.

    It is read from the backend's predefined macros, as printed by
    [cc -dM -E -x c /dev/null] with the options of the compilation, so the
    model and the compiler that compiles the output cannot disagree.
    [typec] keeps no table of targets. *)

(** A standard integer type of C, as named by a predefined type macro
    such as [__SIZE_TYPE__]. Plain [char] is distinct from [signed char]
    and [unsigned char]. *)
type integer_type =
  | Char
  | Signed_char
  | Unsigned_char
  | Short
  | Unsigned_short
  | Int
  | Unsigned_int
  | Long
  | Unsigned_long
  | Long_long
  | Unsigned_long_long

type byte_order = Little_endian | Big_endian

(** Sizes are in bytes, that is in units of [char]. The sizes of the
    typedefs such as [size_t] follow from the integer type behind each;
    see {!sizeof_integer}. *)
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
  has_int128 : bool;  (** [__int128] exists: [__SIZEOF_INT128__]. *)
  size_type : integer_type;  (** [size_t] *)
  ptrdiff_type : integer_type;  (** [ptrdiff_t] *)
  wchar_type : integer_type;  (** [wchar_t] *)
  intmax_type : integer_type;  (** [intmax_t] *)
  uintmax_type : integer_type;  (** [uintmax_t] *)
  intptr_type : integer_type;  (** [intptr_t] *)
  char16_type : integer_type;  (** [char16_t] *)
  char32_type : integer_type;  (** [char32_t] *)
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

val sizeof_integer : t -> integer_type -> int
(** The size of an integer type on the target. *)

val to_string : t -> string
(** One [field: value] line per field of {!t}, in declaration order, with
    integer types spelled as in C, such as [unsigned long]. *)

val error_message : error -> string
