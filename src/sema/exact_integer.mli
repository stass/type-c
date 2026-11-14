(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Integers of any size. Constant expressions compute each operation
    exactly and then apply the rule of the result type, as C states them:
    an unsigned result is reduced modulo 2{^N} (C11 6.2.5p9) and a signed
    one out of range is an error (6.6p4). The operands are values of C
    integer types of at most 128 bits, so every result has at most 256 and
    each operation takes a bounded time. *)

type t

val zero : t
val one : t
val of_int : int -> t

val to_int : t -> int option
(** [None] outside the range of [int]. *)

val compare : t -> t -> int
val equal : t -> t -> bool
val is_negative : t -> bool
val neg : t -> t
val add : t -> t -> t
val sub : t -> t -> t
val mul : t -> t -> t

val div : t -> t -> t
(** The quotient truncated toward zero (6.5.5p6). Raises
    [Division_by_zero]. *)

val rem : t -> t -> t
(** The remainder of {!div}, which has the sign of the dividend. *)

val power_of_two : int -> t
(** [power_of_two n] is 2{^n}, for [n >= 0]. *)

val floor_shift_right : t -> int -> t
(** [floor_shift_right x n] is the floor of [x / 2{^n}], for [n >= 0]:
    the arithmetic right shift. *)

val modulo_power_of_two : t -> int -> t
(** [modulo_power_of_two x n] is [x] modulo 2{^n}, from 0 to 2{^n} - 1:
    the value of the low [n] bits of [x] in two's complement. *)

val logand : t -> t -> t
val logor : t -> t -> t

val logxor : t -> t -> t
(** The bitwise operations take non-negative operands. *)

val bit_length : t -> int
(** The bits that the magnitude needs: 0 for zero, [n] for a magnitude
    from 2{^n-1} to 2{^n} - 1. *)

val of_digits : base:int -> string -> t
(** The value of digits in [base] from 2 to 16, in either case. It takes
    time quadratic in their number, so the caller bounds it. *)

val to_string : t -> string
(** In decimal, with a leading [-] when negative. *)
