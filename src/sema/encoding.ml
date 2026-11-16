(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type reason =
  | Int128
  | Va_list
  | Unknown_type of Unknown.t
  | Array_not_under_pointer
  | Function_not_under_pointer
  | Opaque_length
  | Variable_length
  | Unnamed
  | Several_names of string list
  | Not_at_file_scope

type no_row = { part : Ctype.t; reason : reason }

(* Raised at the first part without a row; caught in [encode]. *)
exception No_row of no_row

let refuse part reason = raise (No_row { part; reason })

(* A name is self-delimiting after its length in bytes, which counts a
   character outside ASCII as the bytes of its UTF-8 form. *)
let length_prefixed name = string_of_int (String.length name) ^ name

let integer_code part : Integer.t -> string = function
  | Bool -> "b"
  | Char -> "c"
  | Signed_char -> "a"
  | Unsigned_char -> "h"
  | Short -> "s"
  | Unsigned_short -> "t"
  | Int -> "i"
  | Unsigned_int -> "j"
  | Long -> "l"
  | Unsigned_long -> "m"
  | Long_long -> "x"
  | Unsigned_long_long -> "y"
  | Int128 | Unsigned_int128 -> refuse part Int128

let floating_code : Arithmetic.floating -> string = function
  | Float -> "f"
  | Double -> "d"
  | Long_double -> "e"

let arithmetic_code part : Arithmetic.t -> string = function
  | Integer integer -> integer_code part integer
  | Real floating -> floating_code floating
  | Complex floating -> "C" ^ floating_code floating

(* Several qualifiers are written in the order A, r, V, K. *)
let qualifier_codes (qualifiers : Qualifiers.t) =
  let code present letter = if present then letter else "" in
  code qualifiers.atomic "A"
  ^ code qualifiers.restrict "r"
  ^ code qualifiers.volatile "V"
  ^ code qualifiers.const "K"

let instance_code (instance : Ctype.instance) =
  "I"
  ^ length_prefixed (instance.generic :> string)
  ^ String.concat "" instance.arguments
  ^ "E"

let instance_name (instance : Ctype.instance) =
  (instance.generic :> string) ^ "__" ^ String.concat "" instance.arguments

(* Design 3.5 rule 2: only a declaration at file scope gives a type the
   one name that it has in every translation unit. *)
let at_file_scope part declared_at_file_scope =
  if not declared_at_file_scope then refuse part Not_at_file_scope

(* An untagged type is named by its one typedef name. *)
let typedef_code tags part =
  match Ctype.typedef_names tags part with
  | [ name ] -> length_prefixed name
  | [] -> refuse part Unnamed
  | names -> refuse part (Several_names names)

(* The declaration of a type chooses its row, however a use spells it
   (design 10.3): the tag that a variant or an alias claims is no tag of
   its own specifier. *)
let record_code tags part (tag : Ctype.record_tag) =
  at_file_scope part tag.record_at_file_scope;
  match tag.record_name with
  | Named name -> "T" ^ length_prefixed name
  | Variant_name name -> length_prefixed (name :> string)
  | Alias_name name -> length_prefixed name
  | Instance_name instance -> instance_code instance
  | Anonymous -> typedef_code tags part

let enum_code tags part (tag : Ctype.enum_tag) =
  at_file_scope part tag.enum_at_file_scope;
  match tag.enum_name with
  | Some name -> "T" ^ length_prefixed name
  | None -> typedef_code tags part

let distinct_code part (distinct : Ctype.distinct) =
  at_file_scope part distinct.distinct_at_file_scope;
  length_prefixed distinct.distinct_name

let length_code part (length : Ctype.length) =
  match length with
  | Constant count -> string_of_int count
  | Unknown -> ""
  | Opaque -> refuse part Opaque_length
  | Variable -> refuse part Variable_length

(* [t] where an array or a function type has a row: what a pointer points
   to, or the element of such an array. The qualifiers of an array are
   those of its element, which encodes them (C11 6.7.3p9). *)
let rec pointee_code tags (t : Ctype.t) =
  match t.shape with
  | Array { element; length } ->
      "Y" ^ pointee_code tags element ^ length_code t length ^ "E"
  | Function { return; parameters } ->
      "F" ^ object_code tags return ^ parameters_code tags parameters ^ "E"
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Unknown_type _ ->
      object_code tags t

(* The parameters are adjusted and unqualified ({!Ctype.parameters}), as C
   compares them (C11 6.7.6.3p15). *)
and parameters_code tags (parameters : Ctype.parameters) =
  match parameters with
  | Prototype { types = []; variadic = false } -> "v"
  | Prototype { types; variadic } ->
      let ellipsis = if variadic then "z" else "" in
      String.concat "" (List.map (object_code tags) types) ^ ellipsis
  | Unspecified | Old_style _ -> "N"

and object_code tags (t : Ctype.t) =
  qualifier_codes t.qualifiers ^ unqualified_code tags t

and unqualified_code tags (t : Ctype.t) =
  match t.shape with
  | Void -> "v"
  | Arithmetic arithmetic -> arithmetic_code t arithmetic
  | Enum tag -> enum_code tags t tag
  | Pointer referenced -> "P" ^ pointee_code tags referenced
  | Record tag -> record_code tags t tag
  | Distinct distinct -> distinct_code t distinct
  | Va_list -> refuse t Va_list
  | Array _ -> refuse t Array_not_under_pointer
  | Function _ -> refuse t Function_not_under_pointer
  | Unknown_type unknown -> refuse t (Unknown_type unknown)

let encode tags t =
  match object_code tags t with
  | code -> Ok code
  | exception No_row no_row -> Error no_row
