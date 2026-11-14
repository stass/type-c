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

(* The token after [index] that is not a pragma. *)
let rec grammar_token_after (tokens : Token.t array) index =
  let after = index + 1 in
  match tokens.(after).kind with
  | Token.Pragma | Token.Typec_pragma -> grammar_token_after tokens after
  | Token.Identifier | Token.Number | Token.Character _ | Token.String _
  | Token.Punctuator _ ->
      after

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

(* Variants (design 10.1). The tokens of each field are kept, so the
   struct of a constructor's fields keeps their lines. *)

let has_payload constructors =
  List.exists
    (fun (constructor : Tree.constructor) -> constructor.node.fields <> [])
    constructors

(* What comes before the constructors: the structure and typedef, which
   the incomplete variant declares already where the variant [completes]
   one; the enumeration of the tags, numbered from 0 in order (rule 1);
   and the structure up to its union where it has one (rule 3). *)
let variant_head ~completes name constructors =
  let enumerator (constructor : Tree.constructor) =
    Tree.enumerator_name ~variant:name constructor.node.name.node
  in
  let tag_enum = "enum " ^ Tree.enum_tag_name name in
  let forward =
    if completes then "" else record_declarations Struct ~tag:name name ^ " "
  in
  let union = if has_payload constructors then " union {" else "" in
  Printf.sprintf "%s%s { %s }; struct %s { %s %s;%s" forward tag_enum
    (String.concat ", " (List.map enumerator constructors))
    name tag_enum Tree.tag_member union

let variant_tail constructors =
  if has_payload constructors then Printf.sprintf "} %s; };" Tree.union_member
  else "};"

(* The tokens at [indexes], the first of which is [first], replaced by
   [text] at the location of [first]. *)
let replace_at (tokens : Token.t array) ~first text indexes =
  replace tokens ~location:tokens.(first).location text (first :: indexes)

(* A constructor with fields becomes the struct of them that the union
   holds, named after it; [| C (] opens it, the [,] after each field
   ends that field, and the [)] closes the struct. One without fields
   becomes nothing (rule 3). *)
let constructor_edits tokens (constructor : Tree.constructor) =
  let { Tree.name; fields } = constructor.node in
  let bar = constructor.span.first and close = constructor.span.last in
  let field_end (field : Tree.field) =
    let after = grammar_token_after tokens field.span.last in
    if after = close then
      replace_at tokens ~first:after (Printf.sprintf "; } %s;" name.node) []
    else replace_at tokens ~first:after ";" []
  in
  match fields with
  | [] -> replace_at tokens ~first:bar "" [ name.span.first ]
  | _ :: _ ->
      let open_paren = grammar_token_after tokens name.span.first in
      replace_at tokens ~first:bar "struct {" [ name.span.first; open_paren ]
      @ List.concat_map field_end fields

(* [type N = ... ;]: the head replaces [type N =] and the tail the [;]. *)
let variant tokens ~location ~head (declaration : Tree.type_declaration)
    constructors =
  let { Tree.name; declared; _ } = declaration.node in
  let completes = declared.earlier <> None in
  let equals = grammar_token_after tokens name.span.first in
  replace tokens ~location
    (variant_head ~completes name.node constructors)
    (head @ [ equals ])
  @ List.concat_map (constructor_edits tokens) constructors
  @ replace_at tokens ~first:declaration.span.last (variant_tail constructors)
      []

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
  | Variant constructors ->
      variant tokens ~location ~head declaration constructors

(* The grammar tokens from [first] to [last], without the pragmas
   between them, which stay. *)
let grammar_tokens (tokens : Token.t array) first last =
  List.init (last - first + 1) (fun offset -> first + offset)
  |> List.filter (fun index ->
         match tokens.(index).kind with
         | Token.Pragma | Token.Typec_pragma -> false
         | Token.Identifier | Token.Number | Token.Character _
         | Token.String _ | Token.Punctuator _ ->
             true)

(* Design 13.5: a constructor expression becomes the compound literal
   [((struct N){ .tag = N_C, .u.C = { a, b } })], or inside an
   initialiser the braced list alone. It names the structure tag, which
   no declaration in the variant's scope may hide (design 10.1 rule 6),
   rather than the typedef name, which a block may hide. The arguments
   keep their tokens; only the name of the constructor, the [(] and the
   [)] are replaced. *)
let construction (tokens : Token.t array)
    (construction : Typec_sema.Expressions.construction) =
  let { Typec_sema.Expressions.span; variant; constructor; callee; braced; _ } =
    construction
  in
  let location = tokens.(span.first).location in
  let enumerator = Tree.enumerator_name ~variant constructor in
  let opening =
    if braced then "{ " else Printf.sprintf "((struct %s){ " variant
  in
  let closing = if braced then "}" else "})" in
  let tag = Printf.sprintf ".%s = %s" Tree.tag_member enumerator in
  match callee with
  | None ->
      replace tokens ~location
        (opening ^ tag ^ " " ^ closing)
        (grammar_tokens tokens span.first span.last)
  | Some callee ->
      let fields =
        Printf.sprintf "%s, .%s.%s = { " tag Tree.union_member constructor
      in
      let left_paren = grammar_token_after tokens callee.last in
      replace tokens ~location (opening ^ fields)
        (grammar_tokens tokens span.first left_paren)
      @ replace tokens
          ~location:tokens.(span.last).location
          (" } " ^ closing) [ span.last ]

(* A type declaration may hold another, in a statement expression of
   its definition, and a constructor's arguments other constructors, so
   the edits of all are sorted; an insertion before a token comes before
   an edit that replaces it. *)
let edits (text : Reader.t) declarations constructions =
  List.concat_map (type_declaration text.tokens) declarations
  @ List.concat_map (construction text.tokens) constructions
  |> List.stable_sort (fun (a : Emitter.edit) (b : Emitter.edit) ->
         compare (a.first, a.count) (b.first, b.count))
