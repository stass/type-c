(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The target model: which compiler the backend is, and the facts about
    scalar types that it fixes.

    It is read from the backend's predefined macros, as printed by
    [cc -dM -E -x c /dev/null] with the options of the compilation, so the
    model and the compiler that compiles the output cannot disagree.
    [typec] keeps no table of targets. *)

type byte_order = Little_endian | Big_endian

(** The C compiler that is the backend. Clang also defines [__GNUC__],
    so [__clang__] tells the two apart. *)
type compiler = Gcc | Clang

type backend = {
  compiler : compiler;
  major_version : int;
      (** [__clang_major__] for Clang, [__GNUC__] for GCC. Apple numbers
          its Clang releases on its own. *)
}

(** Sizes are in bytes, that is in units of [char]. The widths of the
    typedefs such as [size_t] follow from the integer type behind each;
    see {!integer_width}. *)
type t = {
  backend : backend;
      (** A supported release, see {!minimum_major_version}. Its compiler
          decides which constructs have an unknown type, those that GCC
          types otherwise than Clang ({!Backend_difference}); its version
          is named for [--print-target] only, as typec types C alike for
          every supported release of a compiler. *)
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
  optional_floats : Typec_syntax.Optional_float.t list;
      (** The optional floating types that the backend has, in the order
          of [Optional_float.all]: those whose macro it defines,
          [__FLTN_MANT_DIG__] for [_FloatN], [__FLTNX_MANT_DIG__] for
          [_FloatNx] and [__SIZEOF_FLOAT128__] for [__float128]. *)
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
  | Unsupported_model of string
      (** The macros break a guarantee of C on the types, or describe an
          integer type wider than {!max_integer_width}. *)
  | Unsupported_backend of backend
      (** A compiler older than {!minimum_major_version}. *)

val minimum_major_version : compiler -> int
(** The oldest release of each compiler that typec supports: for Clang
    the first that follows C23 6.7.2.2 (N3029) on the type of an
    enumerator, for GCC the oldest that a test host runs (design
    13.3). *)

val max_integer_width : int
(** 128 bits: the widest integer type of a model, which bounds the work
    of constant evaluation. *)

val of_predefined_macros : string -> (t, error) result
(** [of_predefined_macros dump] reads the output of [cc -dM -E]: one
    [#define NAME VALUE] per line, empty lines allowed. Macros the model
    does not use are ignored, but every line must have that form. The
    model must keep the guarantees of C that the front end relies on:
    [CHAR_BIT] of at least 8, the minimum widths of the standard integer
    types (5.2.4.2.1) in the order of their ranks (6.2.5p8), and unsigned
    [size_t], [uintmax_t], [char16_t] and [char32_t] with signed
    [ptrdiff_t], [intmax_t] and [intptr_t]; and [wchar_t], [char16_t]
    and [char32_t] of at most 32 bits. A size above 65536 is
    malformed. A dump with neither [__clang__] nor [__GNUC__] is
    reported as missing [__GNUC__], and a backend older than
    {!minimum_major_version} is unsupported. *)

val keywords :
  t -> Typec_syntax.Keyword_set.dialect -> Typec_syntax.Keyword_set.t
(** [keywords target dialect]: the keywords that the backend reads a text
    of [dialect] with, which spell its [optional_floats] and, where it has
    [sizeof_int128], [__int128]. *)

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
