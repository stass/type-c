(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Writes a preprocessed C file with a static assertion after each
   expression statement of its function bodies, for the target model read
   from a macro dump: that the expression has the type typec gives it,
   qualifiers included, and, where typec calls it an lvalue, a use of its
   address, and the value of each [__builtin_types_compatible_p] that
   typec answers. A backend that compiles the result agrees with typec on
   every one. The statements of compound statements are probed, those under
   other statements not; types that are not C when spelled, unknown
   types, among them those that GCC gives otherwise than Clang, variably
   modified ones and the bit-fields that a member access designates,
   which typeof refuses, are left out. *)

open Typec_cpp
open Typec_syntax
open Typec_sema

let read_file path = In_channel.with_open_bin path In_channel.input_all

let or_exit message = function
  | Ok value -> value
  | Error error ->
      prerr_endline (message error);
      exit 1

let source_text (text : Reader.t) (span : Tree.span) =
  let first = text.tokens.(span.first) and last = text.tokens.(span.last) in
  String.sub text.text first.start (last.start + last.length - first.start)

let spelled t =
  match (Ctype.pointer_to t, Ctype.is_variably_modified t) with
  | Ok pointer, Answer false ->
      let name = Type_name.of_ctype pointer in
      if String.contains name '<' then None else Some name
  | Ok _, (Answer true | Depends_on _) | Error _, _ -> None

(* The C that checks what typec gives [expression]. *)
let assertions text result (typed : Expressions.typed) expression =
  let written = source_text text expression.Tree.span in
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
    if typed.lvalue && not (Expressions.designates_bit_field typed) then
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
let rec block_insertions text result (block : Tree.block) =
  List.concat_map
    (function
      | Tree.Block_statement statement ->
          statement_insertions text result statement
      | Block_declaration _ -> [])
    block.node.items

and statement_insertions text result (statement : Tree.statement) =
  match statement.node with
  | Compound block -> block_insertions text result block
  | Expression_statement expression -> (
      match Declarations.expression result expression with
      | Some typed ->
          let last = text.Reader.tokens.(statement.span.last) in
          let inserted = assertions text result typed expression in
          [ (last.start + last.length, " " ^ inserted) ]
      | None -> failwith ("untyped: " ^ source_text text expression.span))
  | _ -> []

let insertions text result (unit : Tree.translation_unit) =
  List.concat_map
    (function
      | Tree.Function_definition { node = { body = Parsed block; _ }; _ } ->
          block_insertions text result block
      | _ -> [])
    unit

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
  match Sys.argv with
  | [| _; dump; source |] ->
      let target =
        or_exit Target.error_message
          (Target.of_predefined_macros (read_file dump))
      in
      let text =
        or_exit Reader.error_message
          (Reader.read ~name:source (read_file source))
      in
      let keywords = Target.keywords target Gnu in
      let unit =
        or_exit Parser.error_message (Parser.parse ~keywords text)
      in
      let result =
        or_exit Reader.error_message (Declarations.read target text unit)
      in
      print_with text.text (insertions text result unit)
  | _ ->
      prerr_endline "usage: expression_probe MACRO-DUMP PREPROCESSED-C";
      exit 2
