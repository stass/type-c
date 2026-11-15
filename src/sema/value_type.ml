(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type problem =
  | Array
  | Va_list
  | Variably_modified
  | Atomic
  | Qualified
  | Incomplete
  | Const_member
  | Flexible_array_member

let describe = function
  | Array -> "is an array, which a struct can wrap"
  | Va_list -> "is a va_list, which is an array on some targets"
  | Variably_modified -> "is variably modified"
  | Atomic -> "is atomic"
  | Qualified -> "is qualified"
  | Incomplete -> "is not a complete object type"
  | Const_member -> "has a const-qualified member"
  | Flexible_array_member -> "has a flexible array member"

(* The first of [items] for which [check] finds a problem. *)
let rec first_problem check = function
  | [] -> Unknown.Answer None
  | item :: rest -> (
      match check item with
      | Unknown.Answer None -> first_problem check rest
      | found -> found)

let rec innermost_element (t : Ctype.t) =
  match t.shape with
  | Array { element; _ } -> innermost_element element
  | _ -> t

(* What a structure or union holds: a member, or an element of an array
   member, is const-qualified (an array's qualifiers are its element's),
   or holds such a member in turn. Pointed-to types are not held. *)
let rec contents_problem tags (t : Ctype.t) =
  match t.shape with
  | Record record ->
      let members = Ctype.record_members tags record in
      first_problem (member_problem tags) (Option.value members ~default:[])
  | Unknown_type unknown -> Unknown.Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ ->
      Unknown.Answer None

and member_problem tags (member : Ctype.member) =
  let element = innermost_element member.member_type in
  match member.member_type.shape with
  | Array { length = Unknown; _ } -> Unknown.Answer (Some Flexible_array_member)
  | _ when element.qualifiers.const -> Unknown.Answer (Some Const_member)
  | _ -> contents_problem tags element

(* The representation of [va_list] is the target's (design P20); on
   x86-64 it is an array, which assignment cannot copy. *)
let is_va_list (t : Ctype.t) =
  match t.shape with
  | Va_list -> true
  | _ -> false

let is_qualified (t : Ctype.t) =
  t.qualifiers.const || t.qualifiers.volatile || t.qualifiers.restrict

let negate : bool Unknown.answer -> bool Unknown.answer = function
  | Answer value -> Answer (not value)
  | Depends_on unknown -> Depends_on unknown

(* The problems of the type itself, in order, each with whether [t] has
   it; [contents_problem] finds the others. *)
let own_problems tags (t : Ctype.t) =
  [
    (Array, fun () -> Ctype.is_array t);
    (Va_list, fun () -> Unknown.Answer (is_va_list t));
    (Variably_modified, fun () -> Ctype.is_variably_modified t);
    (Atomic, fun () -> Unknown.Answer t.qualifiers.atomic);
    (Qualified, fun () -> Unknown.Answer (is_qualified t));
    (Incomplete, fun () -> negate (Ctype.is_complete tags t));
  ]

let problem tags t =
  let own (problem, has) : problem option Unknown.answer =
    match has () with
    | Unknown.Answer true -> Answer (Some problem)
    | Answer false -> Answer None
    | Depends_on unknown -> Depends_on unknown
  in
  match first_problem own (own_problems tags t) with
  | Answer None -> contents_problem tags t
  | found -> found
