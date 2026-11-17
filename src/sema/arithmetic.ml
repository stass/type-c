(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type floating = Float | Double | Long_double
type t = Integer of Integer.t | Real of floating | Complex of floating
type promoted = t
type enumerator_range = { negative : bool; width : int }

(* Whether [integer] holds every value of a [width]-bit integer, in two's
   complement when [signed]. A signed type spends one bit on the sign. *)
let holds target integer ~signed ~width =
  let integer_width = Target.integer_width target integer in
  match (Target.is_signed target integer, signed) with
  | true, true -> width <= integer_width
  | true, false -> width < integer_width
  | false, true -> false
  | false, false -> width <= integer_width

(* An operand is promoted when it is a bit-field or its rank is at most
   that of int; int and unsigned int promote to themselves. A bit-field
   too wide for unsigned int has a wider declared type, which it keeps. *)
let promote_integer target ?bit_field_width integer =
  let signed = Target.is_signed target integer in
  let width =
    match bit_field_width with
    | Some width -> width
    | None -> Target.integer_width target integer
  in
  let promotable =
    Option.is_some bit_field_width
    || Integer.rank integer <= Integer.rank Int
  in
  if not promotable then integer
  else if holds target Int ~signed ~width then Int
  else if holds target Unsigned_int ~signed ~width then Unsigned_int
  else integer

(* A bit-field has an integer type (C11 6.7.2.1p5), so a floating operand
   has no width to consider. *)
let promote target ?bit_field_width = function
  | Integer integer -> Integer (promote_integer target ?bit_field_width integer)
  | (Real _ | Complex _) as floating -> floating

let floating_rank = function Float -> 0 | Double -> 1 | Long_double -> 2

let wider_floating a b = if floating_rank a >= floating_rank b then a else b

(* C11 6.3.1.8p1 for two promoted integer types. *)
let common_integer target a b =
  let signed_a = Target.is_signed target a in
  let signed_b = Target.is_signed target b in
  let higher_rank x y = if Integer.rank x >= Integer.rank y then x else y in
  if signed_a = signed_b then higher_rank a b
  else
    let signed, unsigned = if signed_a then (a, b) else (b, a) in
    if Integer.rank unsigned >= Integer.rank signed then unsigned
    else if
      holds target signed ~signed:false
        ~width:(Target.integer_width target unsigned)
    then signed
    else Integer.to_unsigned signed

(* The result is complex when either operand is (C11 6.3.1.8p1); an
   integer operand converts to the real type of the floating one. *)
let usual_arithmetic_conversions target a b =
  match (a, b) with
  | Integer a, Integer b -> Integer (common_integer target a b)
  | Real floating, Integer _ | Integer _, Real floating -> Real floating
  | Complex floating, Integer _ | Integer _, Complex floating ->
      Complex floating
  | Real a, Real b -> Real (wider_floating a b)
  | (Real a | Complex a), (Real b | Complex b) ->
      Complex (wider_floating a b)

let default_argument_promotion target ?bit_field_width arithmetic =
  match promote target ?bit_field_width arithmetic with
  | Real Float -> Real Double
  | promoted -> promoted

(* The lists of the enumeration rule (design 13.4): the short
   representation and [packed] put the two types of lower rank than int
   before the int-sized ones. *)
let int_sized_signed_candidates = [ Integer.Int; Long; Long_long ]

let int_sized_unsigned_candidates =
  [ Integer.Unsigned_int; Unsigned_long; Unsigned_long_long ]

let short_signed_candidates =
  Integer.Signed_char :: Short :: int_sized_signed_candidates

let short_unsigned_candidates =
  Integer.Unsigned_char :: Unsigned_short :: int_sized_unsigned_candidates

let enum_candidates (target : Target.t) ~packed ~negative =
  let short = packed || target.enum_representation = Short in
  match (short, negative) with
  | false, false -> int_sized_unsigned_candidates
  | false, true -> int_sized_signed_candidates
  | true, false -> short_unsigned_candidates
  | true, true -> short_signed_candidates

let enum_compatible_type target ~packed range =
  List.find_opt
    (fun integer ->
      holds target integer ~signed:range.negative ~width:range.width)
    (enum_candidates target ~packed ~negative:range.negative)

let promote_enumeration target integer =
  if Integer.rank integer < Integer.rank Int then Integer Integer.Int
  else promote target (Integer integer)

let floating_name = function
  | Float -> "float"
  | Double -> "double"
  | Long_double -> "long double"

let name = function
  | Integer integer -> Integer.name integer
  | Real floating -> floating_name floating
  | Complex floating -> "_Complex " ^ floating_name floating
