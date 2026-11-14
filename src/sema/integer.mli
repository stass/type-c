(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The integer types of C other than the enumerated types (C11 6.2.5p4-6):
    [_Bool], the standard signed and unsigned integer types and the GNU
    extended types [__int128] and [unsigned __int128]. Plain [char] is
    distinct from [signed char] and [unsigned char]. Sizes and the
    signedness of [char] are facts of the target; see {!Target}. *)
type t =
  | Bool
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
  | Int128
  | Unsigned_int128

val rank : t -> int
(** The integer conversion rank (C11 6.3.1.1p1), as a number of which only
    the order is meaningful. [__int128] ranks above [long long], as in GCC
    and Clang. *)

val to_unsigned : t -> t
(** The corresponding unsigned type (C11 6.2.5p6): [Unsigned_char] for
    plain [char]; an unsigned type is its own. *)

val of_specifiers : Typec_syntax.Tree.basic_type_specifier list -> t option
(** The integer type that a multiset of type specifiers names (C11
    6.7.2p2), such as [long unsigned int]; [None] for any other. *)

val name : t -> string
(** The type spelled as in C, such as [unsigned long]. *)
