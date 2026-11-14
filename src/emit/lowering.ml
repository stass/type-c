(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

(* Whether [indexes] are a run of adjacent tokens of one file, which an
   edit may replace whole without dropping a pragma or a line marker
   that enters or leaves a file between them. *)
let is_run (tokens : Token.t array) = function
  | [] -> true
  | first :: _ as indexes ->
      let owner = tokens.(first).owner in
      let rec from expected = function
        | [] -> true
        | index :: rest ->
            index = expected
            && tokens.(index).owner == owner
            && from (expected + 1) rest
      in
      from first indexes

(* The edits that replace the tokens at [indexes], in source order, by
   [text]. Where the tokens are a run, one edit replaces them all. Where a
   pragma or a file boundary stands between them, [text] replaces the
   first and the others are deleted, so what stands between them stays. *)
let replace (tokens : Token.t array) ~location text indexes :
    Emitter.edit list =
  match indexes with
  | [] -> []
  | first :: _ when is_run tokens indexes ->
      [ { first; count = List.length indexes; location; text } ]
  | first :: rest ->
      let delete index : Emitter.edit =
        { first = index; count = 1; location; text = "" }
      in
      { first; count = 1; location; text } :: List.map delete rest

let insert (tokens : Token.t array) ~before text : Emitter.edit =
  { first = before; count = 0; location = tokens.(before).location; text }

(* The token before [index] that is not a pragma: the grammar gives
   pragmas no place, so before a definition it is the [=]. *)
let rec grammar_token_before (tokens : Token.t array) index =
  let before = index - 1 in
  match tokens.(before).kind with
  | Token.Pragma | Token.Typec_pragma -> grammar_token_before tokens before
  | Token.Identifier | Token.Number | Token.Character _ | Token.String _
  | Token.Punctuator _ ->
      before

(* The token that the declared name goes before in an abstract
   declarator: where the identifier would be that the type name omits
   (C11 6.7.7p2). It is innermost, past a pointer that has no inner
   declarator and before a suffix that has none. *)
let rec name_position (declarator : Tree.declarator) =
  match declarator.node with
  | Pointer { inner = None; _ } | Block_pointer { inner = None; _ } ->
      declarator.span.last + 1
  | Array { inner = None; _ } | Function { inner = None; _ } ->
      declarator.span.first
  | Parenthesized_declarator { inner; _ }
  | Pointer { inner = Some inner; _ }
  | Block_pointer { inner = Some inner; _ }
  | Array { inner = Some inner; _ }
  | Function { inner = Some inner; _ } ->
      name_position inner
  | Name _ -> invalid_arg "Lowering.name_position: a named declarator"

let keyword : Tree.struct_or_union -> string = function
  | Struct -> "struct"
  | Union -> "union"

(* What [type N] lowers to where [N] is the structure or union [kind]
   with the tag [tag]. *)
let record_declarations kind ~tag name =
  let record = keyword kind ^ " " ^ tag in
  Printf.sprintf "%s; typedef %s %s;" record record name

(* [type N = T;]: the typedef, with [N] where the declarator of [T]
   would name it. [head] is the tokens [type N]. *)
let alias tokens ~location ~head name (type_name : Tree.type_name) =
  let equals = grammar_token_before tokens type_name.span.first in
  let name_before =
    match type_name.node.abstract with
    | Some abstract -> name_position abstract
    | None -> type_name.span.last + 1
  in
  replace tokens ~location "typedef" (head @ [ equals ])
  @ [ insert tokens ~before:name_before name ]

(* A specifier without a tag of its own takes [name], before its body. *)
let record_alias tokens ~location ~head name
    (specifier : Tree.record_specifier Tree.spanned) =
  let equals = grammar_token_before tokens specifier.span.first in
  let { Tree.kind; tag; members; _ } = specifier.node in
  let replace_head ~tag =
    replace tokens ~location
      (record_declarations kind ~tag name)
      (head @ [ equals ])
  in
  let insert_tag (body : _ Tree.spanned) =
    insert tokens ~before:body.span.first name
  in
  match tag with
  | Some own -> replace_head ~tag:own.name.node
  | None ->
      replace_head ~tag:name @ Option.to_list (Option.map insert_tag members)

let type_declaration (tokens : Token.t array)
    (declaration : Tree.type_declaration) =
  let { Tree.name; definition; _ } = declaration.node in
  let location = tokens.(declaration.span.first).location in
  let head = [ declaration.span.first; name.span.first ] in
  match definition with
  | Incomplete_variant ->
      replace tokens ~location
        (record_declarations Struct ~tag:name.node name.node)
        (head @ [ declaration.span.last ])
  | Alias type_name -> alias tokens ~location ~head name.node type_name
  | Record_alias record -> record_alias tokens ~location ~head name.node record

(* A type declaration may hold another, in a statement expression of
   its definition, so the edits of all are sorted; an insertion before a
   token comes before an edit that replaces it. *)
let edits (text : Reader.t) declarations =
  List.concat_map (type_declaration text.tokens) declarations
  |> List.stable_sort (fun (a : Emitter.edit) (b : Emitter.edit) ->
         compare (a.first, a.count) (b.first, b.count))
