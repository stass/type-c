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

let record_tag_name = function
  | Anonymous -> None
  | Named name -> Some name
  | Variant_name name -> Some (Encoding.variant_name name :> string)
  | Alias_name name -> Some name
  | Instance_name instance -> Some (Encoding.instance_name instance)
  | Opaque_name name -> Some name

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

type tag_line = { tag : string; line : string }

let tag_lines t =
  let tag_line = function
    | Ctype.Named_record { kind; record_name; _ } ->
        Option.map
          (fun tag -> { tag; line = record_keyword kind ^ " " ^ tag ^ ";" })
          (record_tag_name record_name)
    | Named_enum _ -> None
  in
  List.filter_map tag_line (Ctype.named_tags t)

(* How lowered C names one without its qualifiers, which the caller
   writes (design 10.3): a type with a tag in the lowered C, a variant or
   an alias of 10.2 included, by that tag; an untagged one by the one
   typedef name that its encoding takes; a distinct type by its typedef
   name, which is its instance name where it is an instance. A typedef
   name denotes the qualifiers of its declaration too, which no qualifier
   written beside it takes away, so a qualified one is spelled through
   [__typeof_unqual__]. Gives the typedef name that it spells, if any. *)
let lowered_name tags t =
  let typedef_name () =
    match Ctype.typedef_names tags t with
    | [ typedef ] when Ctype.typedef_qualifiers tags t = Qualifiers.none ->
        (typedef.name, Some typedef)
    | [ typedef ] ->
        ("__typeof_unqual__(" ^ typedef.name ^ ")", Some typedef)
    | [] | _ :: _ :: _ -> invalid_arg "Type_name.lowered_name: no one name"
  in
  match t.shape with
  | Enum { enum_name = Some name; _ } -> ("enum " ^ name, None)
  | Record { kind; record_name; _ } -> (
      match record_tag_name record_name with
      | Some name -> (record_keyword kind ^ " " ^ name, None)
      | None -> typedef_name ())
  | Enum { enum_name = None; _ } -> typedef_name ()
  | Distinct { distinct_instance = Some instance; _ } ->
      (Encoding.instance_name instance, None)
  | Distinct { distinct_instance = None; distinct_name; _ } ->
      (distinct_name, None)
  | Void | Arithmetic _ | Pointer _ | Va_list | Array _ | Function _
  | Unknown_type _ ->
      invalid_arg "Type_name.lowered_name"

(* The declarator grows outward from the name as the type is unwrapped
   from the outermost derivation to the specifier; [named] spells a
   structure, union, enumeration or distinct type. *)
let rec declared ~named t declarator =
  let declaration = declared ~named in
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
      declaration return
        (declarator ^ "(" ^ parameter_list ~named parameters ^ ")")
  | Void -> specified t.qualifiers "void" declarator
  | Arithmetic arithmetic ->
      specified t.qualifiers (Arithmetic.name arithmetic) declarator
  | Enum _ | Record _ | Distinct _ ->
      specified t.qualifiers (named t) declarator
  | Va_list ->
      specified t.qualifiers Typec_syntax.Builtin_typedef.va_list_name
        declarator
  | Unknown_type unknown ->
      specified t.qualifiers ("<" ^ unknown.construct ^ ">") declarator

and parameter_list ~named = function
  | Prototype { types = []; variadic = false } -> "void"
  | Prototype { types; variadic } ->
      let ellipsis = if variadic then [ "..." ] else [] in
      let parameter t = declared ~named t "" in
      String.concat ", " (List.map parameter types @ ellipsis)
  | Unspecified | Old_style _ -> ""

(* How a diagnostic names a structure, union, enumeration or distinct
   type: by its tag, or by the name of its declaration. An instance is
   named by its application, with typedef names expanded, not by the C
   name that it lowers to (design 10.3). *)
let rec shown_name t =
  match t.shape with
  | Enum tag -> tag_name "enum" tag.enum_name
  (* A type parameter is named as the generic names it. *)
  | Record { record_name = Opaque_name name; _ } -> name
  (* A type declaration's structure is named as the declaration names it. *)
  | Record { record_name = Alias_name name; _ } -> name
  | Record { record_name = Variant_name name; _ } -> of_variant name
  | Record { record_name = Instance_name instance; _ }
  | Distinct { distinct_instance = Some instance; _ } ->
      application_text instance
  | Record tag ->
      tag_name (record_keyword tag.kind) (record_tag_name tag.record_name)
  | Distinct distinct -> distinct.distinct_name
  | Void | Arithmetic _ | Pointer _ | Va_list | Array _ | Function _
  | Unknown_type _ ->
      invalid_arg "Type_name.shown_name"

and application_text (instance : Ctype.instance) =
  let argument t = declared ~named:shown_name t "" in
  (instance.generic :> string)
  ^ "("
  ^ String.concat ", " (List.map argument instance.argument_types)
  ^ ")"

and of_variant (name : Ctype.variant_name) =
  match name with
  | Declared declared -> (declared :> string)
  | Applied instance -> application_text instance

let of_instance = application_text
let declaration t name = declared ~named:shown_name t name
let of_ctype t = declaration t ""

type lowered = { text : string; spelled : Ctype.typedef_name list }

let lowered_declaration tags t name =
  let spelled = ref [] in
  let named t =
    let text, typedef = lowered_name tags t in
    Option.iter (fun typedef -> spelled := typedef :: !spelled) typedef;
    text
  in
  let text = declared ~named t name in
  { text; spelled = List.rev !spelled }
