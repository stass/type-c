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

(* What the declarator to the right of a type's specifier starts with,
   which decides the spaces around it: a specifier is followed by a space
   unless nothing or an array suffix follows it, as in Clang's
   diagnostics, and a pointer's qualifiers by one unless nothing does. *)
type start = Nothing | Bracket | Other

(* The start of a declarator that starts with [start] once a suffix that
   starts with [suffix] is written after it. *)
let with_suffix start ~suffix =
  match start with Nothing -> suffix | Bracket | Other -> start

let words add qualifiers ~separator =
  List.iteri
    (fun index word ->
      if index > 0 then add separator;
      add word)
    (qualifier_words qualifiers)

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

(* A declaration is written from left to right: what the derivations of
   its type write before the name ([left], whose innermost part is the
   specifier), the name, then what they write after it ([right]).
   [named] writes a structure, union, enumeration or distinct type. *)
let rec declared ~named add t name =
  let start = if name = "" then Nothing else Other in
  left ~named add t start;
  add name;
  right ~named add t

(* [start] is that of the declarator that the derivations above [t] and
   the name write between [left] and [right] of [t]. *)
and left ~named add t start =
  match t.shape with
  | Pointer referenced ->
      left ~named add referenced Other;
      if parenthesized_under_pointer referenced then add "(";
      add "*";
      words add t.qualifiers ~separator:" ";
      if qualifier_words t.qualifiers <> [] && start <> Nothing then add " "
  | Array { element; _ } ->
      left ~named add element (with_suffix start ~suffix:Bracket)
  | Function { return; _ } ->
      left ~named add return (with_suffix start ~suffix:Other)
  | Void -> specifier add t.qualifiers start (fun () -> add "void")
  | Arithmetic arithmetic ->
      specifier add t.qualifiers start (fun () ->
          add (Arithmetic.name arithmetic))
  | Enum _ | Record _ | Distinct _ ->
      specifier add t.qualifiers start (fun () -> named add t)
  | Va_list ->
      specifier add t.qualifiers start (fun () ->
          add Typec_syntax.Builtin_typedef.va_list_name)
  | Unknown_type unknown ->
      specifier add t.qualifiers start (fun () ->
          add ("<" ^ unknown.construct ^ ">"))

and right ~named add t =
  match t.shape with
  | Pointer referenced ->
      if parenthesized_under_pointer referenced then add ")";
      right ~named add referenced
  | Array { element; length } ->
      add ("[" ^ length_text length ^ "]");
      right ~named add element
  | Function { return; parameters } ->
      add "(";
      parameter_list ~named add parameters;
      add ")";
      right ~named add return
  | Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list
  | Unknown_type _ ->
      ()

and parameter_list ~named add = function
  | Prototype { types = []; variadic = false } -> add "void"
  | Prototype { types; variadic } ->
      let parameter t () = declared ~named add t "" in
      let ellipsis = if variadic then [ (fun () -> add "...") ] else [] in
      separated add (List.map parameter types @ ellipsis)
  | Unspecified | Old_style _ -> ()

(* A type that is not derived: its qualifiers, its name, then the space
   before the declarator. *)
and specifier add qualifiers start write_name =
  words add qualifiers ~separator:" ";
  if qualifier_words qualifiers <> [] then add " ";
  write_name ();
  if start = Other then add " "

and separated add writes =
  List.iteri
    (fun index write ->
      if index > 0 then add ", ";
      write ())
    writes

(* How a diagnostic names a structure, union, enumeration or distinct
   type: by its tag, or by the name of its declaration. An instance is
   named by its application, with typedef names expanded, not by the C
   name that it lowers to (design 10.3). *)
let rec shown_name add t =
  match t.shape with
  | Enum tag -> add (tag_name "enum" tag.enum_name)
  (* A type parameter is named as the generic names it. *)
  | Record { record_name = Opaque_name name; _ } -> add name
  (* A type declaration's structure is named as the declaration names it. *)
  | Record { record_name = Alias_name name; _ } -> add name
  | Record { record_name = Variant_name name; _ } -> variant_text add name
  | Record { record_name = Instance_name instance; _ }
  | Distinct { distinct_instance = Some instance; _ } ->
      application_text add instance
  | Record tag ->
      add (tag_name (record_keyword tag.kind) (record_tag_name tag.record_name))
  | Distinct distinct -> add distinct.distinct_name
  | Void | Arithmetic _ | Pointer _ | Va_list | Array _ | Function _
  | Unknown_type _ ->
      invalid_arg "Type_name.shown_name"

and application_text add (instance : Ctype.instance) =
  let argument t () = declared ~named:shown_name add t "" in
  add (instance.generic :> string);
  add "(";
  separated add (List.map argument instance.argument_types);
  add ")"

and variant_text add (name : Ctype.variant_name) =
  match name with
  | Declared declared -> add (declared :> string)
  | Applied instance -> application_text add instance

(* Every name that a diagnostic shows is written through [Shown.bounded],
   so that a type of any size costs a bounded text to name. *)
let of_instance instance =
  Shown.bounded (fun add -> application_text add instance)

let of_variant name = Shown.bounded (fun add -> variant_text add name)

let declaration t name =
  Shown.bounded (fun add -> declared ~named:shown_name add t name)

let of_ctype t = declaration t ""

type lowered = { text : string; spelled : Ctype.typedef_name list }

let lowered_declaration tags t name =
  let buffer = Buffer.create 64 in
  let spelled = ref [] in
  let named add t =
    let text, typedef = lowered_name tags t in
    Option.iter (fun typedef -> spelled := typedef :: !spelled) typedef;
    add text
  in
  declared ~named (Buffer.add_string buffer) t name;
  { text = Buffer.contents buffer; spelled = List.rev !spelled }
