(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Writes a preprocessed C file with a static assertion after each expression
   statement of its function bodies, for the target model that typec's target
   query reads from a backend: that the expression has the type typec gives
   it, qualifiers included, and, where typec calls it an lvalue, a use of its
   address, and the value of each [__builtin_types_compatible_p] that typec
   answers. A backend that compiles the result agrees with typec on every
   one. The statements of compound statements are probed, those under other
   statements not; types that are not C when spelled, unknown types, among
   them those that GCC gives otherwise than Clang, variably modified ones and
   the bit-fields that a member access designates, which typeof refuses, are
   left out. *)

open Typec_cpp
open Typec_syntax
open Typec_sema
module Target_query = Typec_driver.Target_query

let read_file path = In_channel.with_open_bin path In_channel.input_all

let or_exit message = function
  | Ok value -> value
  | Error error ->
      prerr_endline (message error);
      exit 1

(* The bytes of [span] as written in [contents], the text that [text]
   was read from. *)
let source_text contents (text : Reader.t) (span : Tree.span) =
  let first = text.tokens.(span.first) and last = text.tokens.(span.last) in
  String.sub contents first.start (last.start + last.length - first.start)

let spelled t =
  match (Ctype.pointer_to t, Ctype.is_variably_modified t) with
  | Ok pointer, Answer false ->
      let name = Type_name.of_ctype pointer in
      if String.contains name '<' then None else Some name
  | Ok _, (Answer true | Depends_on _) | Error _, _ -> None

(* The C that checks what typec gives [expression]. *)
let assertions contents text result (typed : Expressions.typed) expression =
  let written = source_text contents text expression.Tree.span in
  let type_check =
    match spelled typed.expression_type with
    | Some pointer when not (Expressions.designates_bit_field typed) ->
        [ Printf.sprintf
            "_Static_assert(__builtin_types_compatible_p(__typeof__(%s) *, \
             %s), \"typec\");"
            written pointer ]
    | Some _ | None -> []
  in
  let lvalue_check =
    if typed.category = Lvalue && not (Expressions.designates_bit_field typed)
    then
      [ Printf.sprintf "(void)sizeof &(%s);" written ]
    else []
  in
  let value_check =
    match Declarations.types_compatible result expression with
    | Some (Answer compatible) ->
        [ Printf.sprintf "_Static_assert((%s) == %d, \"typec\");" written
            (Bool.to_int compatible) ]
    | Some (Depends_on _) | None -> []
  in
  String.concat " " (type_check @ lvalue_check @ value_check)

(* The byte after each probed statement, with what to insert there. *)
let rec block_insertions contents text result (block : Tree.block) =
  List.concat_map
    (function
      | Tree.Block_statement statement ->
          statement_insertions contents text result statement
      (* Typing refuses every defer, so a probed unit holds none. *)
      | Block_declaration _ | Block_type_declaration _ | Block_defer _ -> [])
    block.node.items

and statement_insertions contents text result (statement : Tree.statement) =
  match statement.node with
  | Compound block -> block_insertions contents text result block
  | Expression_statement expression -> (
      match Declarations.expression result expression with
      | Some typed ->
          let last = text.Reader.tokens.(statement.span.last) in
          let inserted = assertions contents text result typed expression in
          [ (last.start + last.length, " " ^ inserted) ]
      | None ->
          failwith ("untyped: " ^ source_text contents text expression.span))
  | _ -> []

let insertions contents text result (unit : Tree.translation_unit) =
  List.concat_map
    (function
      | Tree.Function_definition { node = { body = Parsed block; _ }; _ } ->
          block_insertions contents text result block
      | _ -> [])
    (Tree.external_declarations unit)

let print_with text inserted =
  let at = ref 0 in
  List.iter
    (fun (offset, insertion) ->
      print_string (String.sub text !at (offset - !at));
      print_string insertion;
      at := offset)
    inserted;
  print_string (String.sub text !at (String.length text - !at))

let () =
  match Array.to_list Sys.argv with
  | _ :: source :: program :: options ->
      let target =
        or_exit
          (Target_query.error_message ~program)
          (Target_query.query ~program options)
      in
      let contents = read_file source in
      let text =
        or_exit Reader.error_message (Reader.read ~name:source contents)
      in
      let keywords = Target.keywords target Gnu in
      let unit, scopes =
        or_exit Parser.error_message (Parser.parse_with_scopes ~keywords text)
      in
      let result =
        or_exit Reader.error_message
          (Declarations.read target ~product:Unit_text text scopes)
      in
      print_with contents (insertions contents text result unit)
  | _ ->
      prerr_endline "usage: expression_probe PREPROCESSED-C CC [OPTION...]";
      exit 2
