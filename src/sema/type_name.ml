(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Ctype

let qualifier_words (qualifiers : Qualifiers.t) =
  List.filter_map
    (fun (present, word) -> if present then Some word else None)
    [
      (qualifiers.const, "const");
      (qualifiers.volatile, "volatile");
      (qualifiers.restrict, "restrict");
      (qualifiers.atomic, "_Atomic");
    ]

let tag_name keyword name =
  keyword ^ " " ^ Option.value name ~default:"<anonymous>"

let record_keyword = function Struct -> "struct" | Union -> "union"

let length_text = function
  | Constant count -> string_of_int count
  | Opaque -> "<constant>"
  | Unknown -> ""
  | Variable -> "*"

(* A type that is not derived: its qualifiers, its name, then whatever
   declarator the derivations above it have built. An array suffix follows
   the name directly, as in Clang's diagnostics. *)
let specified qualifiers name declarator =
  let specifier = String.concat " " (qualifier_words qualifiers @ [ name ]) in
  if declarator = "" || String.starts_with ~prefix:"[" declarator then
    specifier ^ declarator
  else specifier ^ " " ^ declarator

let pointer_declarator qualifiers declarator =
  match (qualifier_words qualifiers, declarator) with
  | [], _ -> "*" ^ declarator
  | words, "" -> "*" ^ String.concat " " words
  | words, _ -> "*" ^ String.concat " " words ^ " " ^ declarator

(* The array and function suffixes bind tighter than the pointer prefix
   (6.7.6), so a pointer to either is parenthesized. *)
let parenthesized_under_pointer t =
  match t.shape with
  | Array _ | Function _ -> true
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Unknown_type _ ->
      false

(* The declarator grows outward from the name as the type is unwrapped
   from the outermost derivation to the specifier. *)
let rec declaration t declarator =
  match t.shape with
  | Pointer referenced ->
      let declarator = pointer_declarator t.qualifiers declarator in
      let declarator =
        if parenthesized_under_pointer referenced then "(" ^ declarator ^ ")"
        else declarator
      in
      declaration referenced declarator
  | Array { element; length } ->
      declaration element (declarator ^ "[" ^ length_text length ^ "]")
  | Function { return; parameters } ->
      declaration return (declarator ^ "(" ^ parameter_list parameters ^ ")")
  | Void -> specified t.qualifiers "void" declarator
  | Arithmetic arithmetic ->
      specified t.qualifiers (Arithmetic.name arithmetic) declarator
  | Enum tag ->
      specified t.qualifiers (tag_name "enum" tag.enum_name) declarator
  | Record tag ->
      let name = tag_name (record_keyword tag.kind) tag.record_name in
      specified t.qualifiers name declarator
  | Distinct distinct ->
      specified t.qualifiers distinct.distinct_name declarator
  | Va_list ->
      specified t.qualifiers Typec_syntax.Builtin_typedef.va_list_name
        declarator
  | Unknown_type unknown ->
      specified t.qualifiers ("<" ^ unknown.construct ^ ">") declarator

and parameter_list = function
  | Prototype { types = []; variadic = false } -> "void"
  | Prototype { types; variadic } ->
      let ellipsis = if variadic then [ "..." ] else [] in
      String.concat ", " (List.map of_ctype types @ ellipsis)
  | Unspecified | Old_style _ -> ""

and of_ctype t = declaration t ""
