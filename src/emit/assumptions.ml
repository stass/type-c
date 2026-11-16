(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_sema

(* [holds] is a constant expression that is 1 where the assumption holds;
   a [_Generic] of an operand of the assumed type keeps it constant
   whatever the operand, which is not evaluated (C11 6.5.1.1p3). *)
let assertion ~holds ~assumes ~option =
  Printf.sprintf "_Static_assert(%s, \"typec assumes %s (%s?)\");" holds
    assumes option

(* A bit-field as wide as int promotes to int where it is signed and to
   unsigned int where it is not (C11 6.3.1.1p2), so the type of its
   promotion shows its signedness. typec types a plain int bit-field as
   int. The member's name is reserved to typec, so no pragma of the unit
   poisons it. *)
let signed_bit_field target =
  let width = Target.integer_width target Integer.Int in
  let promoted =
    Arithmetic.promote target ~bit_field_width:width (Integer Integer.Int)
  in
  assertion
    ~holds:
      (Printf.sprintf
         "_Generic(+(struct { int __tc_bits : %d; }){ 0 }.__tc_bits, %s: 1, \
          default: 0)"
         width
         (Arithmetic.name (promoted :> Arithmetic.t)))
    ~assumes:"plain int bit-fields are signed" ~option:"-funsigned-bitfields"

let double_constant =
  assertion ~holds:"_Generic(1.5, double: 1, default: 0)"
    ~assumes:"unsuffixed floating constants are double"
    ~option:"-fsingle-precision-constant"

(* The range of the value 0 alone, the only value of the probe: every
   integer type holds it, so the rule always gives a type. *)
let zero_range : Arithmetic.enumerator_range = { negative = false; width = 0 }

let enumeration target =
  let compatible =
    Integer.name
      (Option.get (Arithmetic.enum_compatible_type target zero_range))
  in
  assertion
    ~holds:
      (Printf.sprintf
         "_Generic((enum { __tc_enum_probe })0, %s: 1, default: 0)"
         compatible)
    ~assumes:
      ("an enumeration of small nonnegative values is compatible with "
     ^ compatible)
    ~option:"-fshort-enums"

let assertions target =
  [ signed_bit_field target; double_constant; enumeration target ]
