(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The names that the external declarations of a unit declare with their
   own declarators and with the tags and enumerator lists of their own
   specifiers, each with its last declaration there, and the builtin
   typedef names. All of them have file scope (C11 6.2.1p4), which is
   enough for a test that names what it declares at file scope. A
   declaration nested deeper, as in a member or an array length, is not
   looked for, though some have file scope (TODO.md). *)

open Typec_syntax
open Tree

type t = {
  ordinary : (string, reference) Hashtbl.t;
  tags : (string, tag_id) Hashtbl.t;
}

let add_tag names (tag : tag) =
  match tag.binding with
  | Declares { id; earlier = _ } | Names id ->
      Hashtbl.replace names.tags tag.name.node id

let add_enumerator names (enumerator : enumerator) =
  let { name; declared; attributes = _; value = _ } = enumerator.node in
  Hashtbl.replace names.ordinary name.node (In_tree declared.id)

let add_specifier names (specifier : declaration_specifier spanned) =
  match specifier.node with
  | Type_specifier (Struct_or_union { tag; _ }) ->
      Option.iter (add_tag names) tag
  | Type_specifier (Enum { tag; enumerators; _ }) ->
      Option.iter (add_tag names) tag;
      Option.iter (List.iter (add_enumerator names)) enumerators
  | Storage_class _ | Type_specifier _ | Type_qualifier _
  | Function_specifier _ | Alignment_specifier _ | Attributes _ ->
      ()

let add_declarator names declarator (declared : declared) =
  Option.iter
    (fun name -> Hashtbl.replace names.ordinary name (In_tree declared.id))
    (declared_name declarator)

let add_external names = function
  | External_declaration
      { node = Declaration { specifiers; declarators }; span = _ } ->
      List.iter (add_specifier names) specifiers;
      List.iter
        (fun (init_declarator : init_declarator) ->
          let ({ declarator; declared; _ } : init_declarator_node) =
            init_declarator.node
          in
          add_declarator names declarator declared)
        declarators
  | Function_definition { node = { specifiers; declarator; declared; _ }; _ }
    ->
      List.iter (add_specifier names) specifiers;
      add_declarator names declarator declared
  | External_declaration { node = Static_assert _; _ }
  | Top_level_asm _ | Empty_declaration _ ->
      ()

let of_unit (unit : translation_unit) =
  let names = { ordinary = Hashtbl.create 64; tags = Hashtbl.create 16 } in
  List.iter
    (fun (name, _) -> Hashtbl.replace names.ordinary name (Builtin name))
    Builtin_typedef.table;
  List.iter (add_external names) unit;
  names

let ordinary names name = Hashtbl.find_opt names.ordinary name
let tag names name = Hashtbl.find_opt names.tags name

(* Every ordinary name with its declaration, in the order of the names. *)
let all_ordinary names =
  List.sort compare (List.of_seq (Hashtbl.to_seq names.ordinary))
