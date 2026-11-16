(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t =
  | Narrow_bit_field of { integer : Integer.t Unknown.answer; width : int }
  | Bit_field_promotion of { integer : Integer.t; width : int }
  | Bit_field_real_part
  | Anonymous_member of {
      member_qualifiers : Qualifiers.t;
      anonymous : Qualifiers.t;
    }
  | Atomic_comparison of Qualifiers.t * Qualifiers.t
  | Enum_integer_composite
  | Old_style_function of {
      clang_prototype : bool;
      composite_prototype : bool;
    }
  | Return_qualifiers of Qualifiers.t * Qualifiers.t
  | Value_qualifiers of Qualifiers.t

let construct = function
  | Narrow_bit_field _ -> "the value of a bit-field narrower than its type"
  | Bit_field_promotion _ -> "the promotion of a bit-field ranked above int"
  | Bit_field_real_part -> "the real part of a bit-field"
  | Anonymous_member _ -> "a member of a qualified anonymous member"
  | Atomic_comparison _ -> "__builtin_types_compatible_p of one _Atomic type"
  | Old_style_function _ -> "a function of an old-style definition"
  | Enum_integer_composite ->
      "the composite of an enumerated type and its integer type"
  | Return_qualifiers _ -> "the qualifiers of a function's return type"
  | Value_qualifiers _ -> "the _Atomic type of a call or cast"

(* GCC leaves a bit-field of a type ranked above int and at least as wide
   as int unpromoted, where Clang promotes:
   - one wider than int and narrower than its type has a type of its own
     width in GCC and its declared type in Clang;
   - one of a declared type as wide as int keeps that type in GCC and
     becomes int or unsigned int in Clang.
   One as wide as int and narrower than its type is int or unsigned int
   in both. *)
let promotes_differently target integer width =
  let int_width = Target.integer_width target Int in
  let type_width = Target.integer_width target integer in
  let own_width = width > int_width && width < type_width in
  let declared_as_wide_as_int = width = int_width && type_width = int_width in
  Integer.rank integer > Integer.rank Int
  && (own_width || declared_as_wide_as_int)

let differs_in_gcc target = function
  | Narrow_bit_field { integer = Answer integer; width } ->
      width < Target.integer_width target integer
  | Narrow_bit_field { integer = Depends_on _; _ } -> true
  | Bit_field_promotion { integer; width } ->
      promotes_differently target integer width
  | Bit_field_real_part -> true
  | Anonymous_member { member_qualifiers; anonymous } ->
      Qualifiers.union member_qualifiers anonymous <> member_qualifiers
  | Atomic_comparison (first, second) -> first.atomic <> second.atomic
  | Enum_integer_composite -> true
  (* GCC gives a use the composite type, of which only a prototype that
     some declaration writes is a prototype. *)
  | Old_style_function { clang_prototype; composite_prototype } ->
      clang_prototype <> composite_prototype
  (* GCC drops all but _Atomic, so it agrees with Clang exactly where
     _Atomic differs. *)
  | Return_qualifiers (first, second) ->
      first <> second && first.atomic = second.atomic
  | Value_qualifiers qualifiers -> qualifiers.atomic

let answer (target : Target.t) difference location clang : _ Unknown.answer =
  let differs =
    match target.backend.compiler with
    | Clang -> false
    | Gcc -> differs_in_gcc target difference
  in
  if differs then
    Depends_on
      { construct = construct difference;
        location;
        kind = Unknown_object;
        cause = Typed_differently }
  else Answer clang
