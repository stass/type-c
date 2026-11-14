(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Telling which constant a preprocessing number is (C11 6.4.4). The
    reader does not: a preprocessing number is a constant only where the
    parser reads one. The GNU profile adds binary integers with [0b] and
    one imaginary suffix [i] or [j], in either case, among the other
    suffixes. *)

(** The base of an integer constant. [0] is octal, as in C11. *)
type base = Binary | Octal | Decimal | Hexadecimal

(** The [l] or [ll] of an integer suffix, in either case. *)
type integer_length = Not_long | Long | Long_long

type integer_suffix = {
  unsigned : bool;  (** [u] or [U] *)
  length : integer_length;
  imaginary : bool;
}

(** The type that the [f] or [l] of a floating suffix, in either case,
    gives; a constant without either is a [Double]. *)
type floating_type = Double | Float | Long_double

type floating_suffix = { floating_type : floating_type; imaginary : bool }

type t =
  | Integer of {
      base : base;
      digits : string;  (** without the prefix of the base and the suffix *)
      suffix : integer_suffix;
    }  (** C11 6.4.4.1 *)
  | Floating of { suffix : floating_suffix }  (** C11 6.4.4.2 *)
  | Not_a_constant

val classify : string -> t
(** [classify spelling] is the constant that the preprocessing number
    [spelling] spells, and [Not_a_constant] for any other text. *)
