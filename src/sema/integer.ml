(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

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

let rank = function
  | Bool -> 0
  | Char | Signed_char | Unsigned_char -> 1
  | Short | Unsigned_short -> 2
  | Int | Unsigned_int -> 3
  | Long | Unsigned_long -> 4
  | Long_long | Unsigned_long_long -> 5
  | Int128 | Unsigned_int128 -> 6

let to_unsigned = function
  | Char | Signed_char | Unsigned_char -> Unsigned_char
  | Short | Unsigned_short -> Unsigned_short
  | Int | Unsigned_int -> Unsigned_int
  | Long | Unsigned_long -> Unsigned_long
  | Long_long | Unsigned_long_long -> Unsigned_long_long
  | Int128 | Unsigned_int128 -> Unsigned_int128
  | Bool -> Bool

let name = function
  | Bool -> "_Bool"
  | Char -> "char"
  | Signed_char -> "signed char"
  | Unsigned_char -> "unsigned char"
  | Short -> "short"
  | Unsigned_short -> "unsigned short"
  | Int -> "int"
  | Unsigned_int -> "unsigned int"
  | Long -> "long"
  | Unsigned_long -> "unsigned long"
  | Long_long -> "long long"
  | Unsigned_long_long -> "unsigned long long"
  | Int128 -> "__int128"
  | Unsigned_int128 -> "unsigned __int128"

(* The integer rows of the multisets of 6.7.2p2 and those of GNU
   [__int128], each sorted in the order of [Tree.basic_type_specifier]. *)
let of_specifiers (specifiers : Typec_syntax.Tree.basic_type_specifier list) =
  match List.sort compare specifiers with
  | [ Char ] -> Some Char
  | [ Char; Signed ] -> Some Signed_char
  | [ Char; Unsigned ] -> Some Unsigned_char
  | [ Short ] | [ Short; Int ] | [ Short; Signed ] | [ Short; Int; Signed ] ->
      Some Short
  | [ Short; Unsigned ] | [ Short; Int; Unsigned ] -> Some Unsigned_short
  | [ Int ] | [ Signed ] | [ Int; Signed ] -> Some Int
  | [ Unsigned ] | [ Int; Unsigned ] -> Some Unsigned_int
  | [ Long ] | [ Int; Long ] | [ Long; Signed ] | [ Int; Long; Signed ] ->
      Some Long
  | [ Long; Unsigned ] | [ Int; Long; Unsigned ] -> Some Unsigned_long
  | [ Long; Long ]
  | [ Int; Long; Long ]
  | [ Long; Long; Signed ]
  | [ Int; Long; Long; Signed ] ->
      Some Long_long
  | [ Long; Long; Unsigned ] | [ Int; Long; Long; Unsigned ] ->
      Some Unsigned_long_long
  | [ Bool ] -> Some Bool
  | [ Int128 ] | [ Signed; Int128 ] -> Some Int128
  | [ Unsigned; Int128 ] -> Some Unsigned_int128
  | _ -> None
