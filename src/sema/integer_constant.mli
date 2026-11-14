(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The values of integer constant expressions (C11 6.6p6) and the
    operations of C on them, on the target's widths. Each operation is
    computed exactly and its result then takes the rule of its type:
    reduced modulo 2{^N} when unsigned (6.2.5p9), an error when signed and
    out of range (6.6p4). Conversions wrap, as GCC and Clang define the
    implementation-defined conversion to a signed type (6.3.1.3p3), and so
    does a left shift of a signed value, whose overflow GCC defines and
    both accept.

    An enumerated type takes part as its compatible integer type, so a
    value has an integer type of {!Integer.t}. *)

open Typec_cpp

(** {e Provisional (design P16).} [Opaque] is the value of an integer
    constant expression that the backend evaluates and [typec] does not:
    the size or alignment of a structure, union or array type, the size
    of [_Bool] or of an atomic type and the alignment of any type, none of
    which the target model holds; a floating constant converted to an
    integer type; the size of an expression, whose type the declarations
    do not compute; and any operation with an opaque operand. The
    expression is still an integer constant expression: an array whose
    length is one is not a variable length array. *)
type value =
  | Known of Exact_integer.t  (** in the range of the type *)
  | Opaque

type t = private { integer_type : Integer.t; value : value }

type error =
  | Overflow  (** 6.6p4: a signed result outside its type, 6.5.5p6 *)
  | Division_by_zero  (** 6.5.5p5 *)
  | Shift_out_of_range  (** 6.5.7p3: a negative count or one too wide *)
  | Too_large
      (** 6.4.4.1p6: no type of the constant's list holds it. Beyond the
          lists, GCC gives a decimal constant [__int128] and Clang
          [unsigned long long]. *)
  | Imaginary  (** A GNU imaginary constant is not of an integer type. *)
  | Invalid_character of Escape.error
  | Character_too_large
      (** A character with no single code unit of its type, or one that
          Clang refuses in a plain character constant: one outside the
          basic character set (6.4.4.4p10). *)
  | Multiple_characters
      (** More than one character in a prefixed character constant, which
          Clang refuses and GCC takes as its last (6.4.4.4p11). *)
  | Empty_character

val error_message : error -> string

val known : Target.t -> Integer.t -> Exact_integer.t -> t
(** A value converted to the type, as {!convert} converts. *)

val opaque : Integer.t -> t

val fits : Target.t -> Integer.t -> Exact_integer.t -> bool
(** Whether the type holds the value. *)

val convert : Target.t -> Integer.t -> t -> t
(** The conversion to an integer type (6.3.1.2, 6.3.1.3). *)

val truth : t -> bool option
(** Whether the value compares unequal to 0; [None] when opaque. *)

val of_integer_constant :
  Target.t ->
  Number.base ->
  string ->
  Number.integer_suffix ->
  (t, error) result
(** [of_integer_constant target base digits suffix] is the constant with
    those digits, without the prefix of their base: the first type of its
    list that holds the value (6.4.4.1p5). *)

val of_character_constant :
  Target.t -> Token.encoding -> string -> (t, error) result
(** [of_character_constant target encoding spelling] is the value of the
    character constant spelled [spelling], prefix and quotes included
    (6.4.4.4p10, p11). A plain constant has type [int]: of one character,
    the value of that [char]; of more, its bytes in order, the first most
    significant and the excess first ones dropped, as both GCC and Clang
    evaluate them. *)

val unary :
  Target.t ->
  evaluated:bool ->
  Typec_syntax.Tree.unary_operator ->
  t ->
  (t, error) result
(** [+], [-], [~] and [!] (6.5.3.3); the other unary operators are not
    allowed in a constant expression and raise [Invalid_argument]. An
    operation that is not [evaluated], being in an operand that is not
    evaluated (6.6p3), gives an opaque value where it would fail. *)

val binary :
  Target.t ->
  evaluated:bool ->
  Typec_syntax.Tree.binary_operator ->
  t ->
  t ->
  (t, error) result
(** The binary operators of 6.5.5 to 6.5.14, as {!unary}. A false left
    operand of [&&] or a true one of [||] decides the value whatever the
    right one is. *)

val conditional : Target.t -> t -> t -> t -> t
(** [conditional target condition if_true if_false] (6.5.15). *)
