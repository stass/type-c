(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t =
  | Narrow_bit_field of { integer : Integer.t Ctype.answer; width : int }
  | Bit_field_promotion of { integer : Integer.t; width : int }
  | Bit_field_real_part
  | Anonymous_member of { member_type : Ctype.t; anonymous : Ctype.qualifiers }
  | Atomic_comparison of Ctype.t * Ctype.t

let construct = function
  | Narrow_bit_field _ -> "the value of a bit-field narrower than its type"
  | Bit_field_promotion _ -> "the promotion of a bit-field ranked above int"
  | Bit_field_real_part -> "the real part of a bit-field"
  | Anonymous_member _ -> "a member of a qualified anonymous member"
  | Atomic_comparison _ -> "__builtin_types_compatible_p of one _Atomic type"

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
  | Anonymous_member { member_type; anonymous } ->
      Ctype.qualify anonymous member_type <> Ok member_type
  | Atomic_comparison (first, second) ->
      let atomic t = (Ctype.top_qualifiers t).atomic in
      atomic first <> atomic second

let answer (target : Target.t) difference location clang : _ Ctype.answer =
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
