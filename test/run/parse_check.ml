(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* parse_check MACROS FILE: reads and parses the cc -E output FILE with
   the keywords of the backend whose cc -dM -E output is MACROS, in GNU C
   whatever the dialect of FILE, checks that the spans of the tree nest
   in order and that every token outside the external declarations is a
   pragma, and prints what each external declaration declares. *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let fail message =
  prerr_endline ("parse_check: " ^ message);
  exit 1

let read_file path = In_channel.with_open_bin path In_channel.input_all

let span_of = function
  | Tree.External_declaration declaration -> declaration.span
  | Tree.Function_definition definition -> definition.span
  | Tree.Top_level_asm assembler -> assembler.span
  | Tree.Empty_declaration span -> span

let is_pragma (token : Token.t) =
  match token.kind with
  | Token.Pragma | Token.Typec_pragma -> true
  | Token.Identifier | Token.Number | Token.Character _ | Token.String _
  | Token.Punctuator _ ->
      false

(* The first token that no external declaration holds and that is not a
   pragma. *)
let first_token_outside (reader : Reader.t) unit =
  let held = Array.make (Array.length reader.tokens) false in
  List.iter
    (fun declaration ->
      let span = span_of declaration in
      Array.fill held span.first (span.last - span.first + 1) true)
    unit;
  Array.to_seqi reader.tokens
  |> Seq.find (fun (index, token) ->
         (not held.(index)) && not (is_pragma token))

let names declarators =
  List.filter_map
    (fun (d : Tree.init_declarator) -> Tree.declared_name d.node.declarator)
    declarators

let describe = function
  | Tree.External_declaration { node = Tree.Static_assert _; _ } ->
      "static assertion"
  | Tree.External_declaration { node = Tree.Declaration { declarators; _ }; _ }
    -> (
      match names declarators with
      | [] -> "declaration of a tag"
      | names -> "declaration " ^ String.concat " " names)
  | Tree.Function_definition { node = { declarator; _ }; _ } ->
      "function "
      ^ Option.value (Tree.declared_name declarator) ~default:"?"
  | Tree.Top_level_asm _ -> "assembler"
  | Tree.Empty_declaration _ -> "empty declaration"

let keywords_of_dump path =
  match Target.of_predefined_macros (read_file path) with
  | Ok target -> Target.keywords target Gnu
  | Error error -> fail (Target.error_message error)

let () =
  match Sys.argv with
  | [| _; macros; path |] -> (
      let keywords = keywords_of_dump macros in
      match Reader.read ~name:path (read_file path) with
      | Error error -> fail (Reader.error_message error)
      | Ok reader -> (
          match Parser.parse ~keywords reader with
          | Error error -> fail (Parser.error_message error)
          | Ok unit ->
              let dump = Tree_dump.translation_unit reader unit in
              let violation = Tree_dump.span_violation (Tree_dump.group dump) in
              Option.iter fail violation;
              Option.iter
                (fun (index, _) ->
                  fail (Printf.sprintf "token %d is outside the tree" index))
                (first_token_outside reader unit);
              List.iter (fun d -> print_endline (describe d)) unit))
  | _ -> fail "usage: parse_check MACROS FILE"
