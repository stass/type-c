(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The arithmetic types of C other than the enumerated types, and the
    conversions between them (C11 6.3.1). An enumerated type takes part
    through its compatible integer type; see {!Ctype.as_arithmetic}. *)

(** A real floating type (C11 6.2.5p10). The GNU [_FloatN] and [_FloatNx]
    types join here; they need a conversion rule of their own in
    {!usual_arithmetic_conversions}, because their ranks follow from their
    ranges rather than from their order (C23 H.4.2). *)
type floating = Float | Double | Long_double

type t =
  | Integer of Integer.t
  | Real of floating
  | Complex of floating  (** [_Complex] of the floating type. *)

(** An arithmetic type that the integer promotions have produced, or a
    floating type, which they leave alone. *)
type promoted = private t

val promote : Target.t -> ?bit_field_width:int -> t -> promoted
(** The integer promotions (C11 6.3.1.1p2). [bit_field_width] is the width
    of a bit-field operand of an integer type: a bit-field whose values all
    fit [int] promotes to [int], else one whose values fit [unsigned int]
    to [unsigned int]. A wider bit-field keeps its declared type. This is
    the rule of Clang and of C11 for the bit-field types it defines; GCC
    promotes some bit-fields of types ranked above [int] otherwise
    ({!Backend_difference.Bit_field_promotion}). *)

val usual_arithmetic_conversions : Target.t -> promoted -> promoted -> t
(** The common real type and type domain of two operands (C11 6.3.1.8). *)

val default_argument_promotion : Target.t -> ?bit_field_width:int -> t -> t
(** The integer promotions, then [float] to [double] (C11 6.5.2.2p6). *)

(** The values of the enumerators of one enumeration: those of a
    [width]-bit integer, in two's complement when [negative], the narrowest
    that holds them all. *)
type enumerator_range = { negative : bool; width : int }

val enum_compatible_type :
  Target.t -> packed:bool -> enumerator_range -> Integer.t option
(** The integer type compatible with an enumerated type without a fixed
    type (C11 6.7.2.2p4), or [None] when no standard integer type holds
    the values: the first of a list that holds them (design 13.4). Under
    the int-sized representation of [target] the list is [unsigned int],
    [unsigned long] and [unsigned long long] when no value is negative,
    else [int], [long] and [long long]. Under the short representation,
    or when the specifier that holds the list is [packed], it begins with
    [unsigned char] and [unsigned short], or [signed char] and [short].
    The rule goes by rank, not size, as where [int] has 16 bits.
    {e Provisional} for the compilers that are not measured. Wider values
    are outside the profile: GCC gives the enumeration an [__int128]
    type, Clang truncates them. [test/run/types.t] checks the rule
    against the backends on its host. *)

val promote_enumeration : Target.t -> Integer.t -> promoted
(** The integer promotion of an object of an enumerated type compatible
    with the integer type: [int] where its rank is below that of [int],
    even where [int] does not hold its values, as Clang for [msp430-elf]
    promotes [unsigned short] (design 13.4); else as {!promote}. *)

val name : t -> string
(** The type spelled as in C, such as [_Complex double]. *)
