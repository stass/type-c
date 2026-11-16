(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_sema

type resolution = Resolved of Ctype.t | Unresolved of string

(* The presumed file of the appended text, which no line marker of a
   preprocessed file names, so that an error in it is told from one in
   the text. *)
let appended_file = "<typec-oracle>"

(* The candidate whose typedef is on a presumed line of the appended
   text: the function starts on line 1, and candidate [index] is on line
   [index + 2]. *)
let index_of line = line - 2

(* The function holding one typedef of each candidate still present, in
   a block of its own on its own line, so that an error names the line
   of the spelling it is in; a dropped candidate leaves its line empty.
   Its parameter is the length of the variable length arrays. *)
let appended (candidates : string option array) =
  let buffer = Buffer.create 4096 in
  Printf.bprintf buffer "\n# 1 \"%s\"\nvoid __typec_oracle_types(int %s) {\n"
    appended_file Normalisation.variable_length;
  let add = function
    | Some spelling ->
        Printf.bprintf buffer
          "{ typedef __typeof__(%s) __typec_oracle_type; }\n" spelling
    | None -> Buffer.add_char buffer '\n'
  in
  Array.iter add candidates;
  Buffer.add_string buffer "}\n";
  Buffer.contents buffer

(* Reads the text with the candidates appended, dropping each that typec
   refuses, with typec's message as the reason, until it reads. The text
   reads alone, so an error outside the candidates' lines is typec's
   failure to read the appended function. *)
let rec read_with dialect target ~name text candidates refused =
  let contents = text ^ appended candidates in
  match Typec_unit.read dialect target ~name contents with
  | Ok unit -> unit
  | Error error ->
      let index = index_of error.location.line in
      if
        error.location.file <> appended_file
        || index < 0
        || index >= Array.length candidates
        || candidates.(index) = None
      then failwith ("the appended function: " ^ Reader.error_message error);
      candidates.(index) <- None;
      Hashtbl.replace refused index
        ("typec refuses it at file scope: " ^ error.message);
      read_with dialect target ~name text candidates refused

let appended_function (unit : Typec_unit.t) =
  match List.rev unit.unit with
  | Tree.Function_definition { node = { body = Parsed body; _ }; _ } :: _ ->
      body
  | _ -> failwith "the appended function is not the last declaration"

let line_of_span (unit : Typec_unit.t) (span : Tree.span) =
  unit.text.tokens.(span.first).location.line

(* The block of an appended typedef and its declarator. *)
let typedef_block = function
  | Tree.Block_statement { node = Compound block; _ } -> (
      match block.node.items with
      | [
          Block_declaration
            { node = Declaration { declarators = [ d ]; _ }; _ };
        ] ->
          (block, d)
      | _ -> failwith "an appended block is not one typedef")
  | _ -> failwith "an appended statement is not a block"

(* The type each typedef of the appended function gives, by the index of
   its candidate. *)
let typedef_types (unit : Typec_unit.t) =
  let types = Hashtbl.create 1024 in
  let add item =
    let block, (d : Tree.init_declarator) = typedef_block item in
    let index = index_of (line_of_span unit block.span) in
    let declared = Tree.In_tree d.node.declared.id in
    match Declarations.entity unit.declarations declared with
    | Some { declared = Typedef t; _ } -> Hashtbl.replace types index t
    | _ -> failwith "an appended typedef declares no type"
  in
  List.iter add (appended_function unit).node.items;
  types

let is_tag_keyword spelling =
  spelling = "struct" || spelling = "union" || spelling = "enum"

let is_identifier (token : Token.t) =
  match token.kind with
  | Identifier _ -> true
  | Number | Character _ | String _ | Punctuator _ | Pragma _ | Typec_pragma
    ->
      false

(* The candidates with a tag that their typedef declares, at file scope or
   in the prototype scope of a parameter, rather than names: no
   declaration at file scope declares a tag of its name, so the
   expression's is one of its own block or none. *)
let candidates_declaring_tags (unit : Typec_unit.t) ~first_token =
  let tokens = unit.text.tokens in
  let found = Hashtbl.create 16 in
  for index = first_token to Array.length tokens - 2 do
    if
      is_tag_keyword (Reader.spelling unit.text tokens.(index))
      && is_identifier tokens.(index + 1)
      && Declarations.tag unit.declarations (Tag_at (index + 1)) <> None
    then Hashtbl.replace found (index_of tokens.(index).location.line) ()
  done;
  found

(* The index of the first token at or after byte [offset]. *)
let first_token_from (tokens : Token.t array) offset =
  let rec search index =
    if index < Array.length tokens && tokens.(index).start < offset then
      search (index + 1)
    else index
  in
  search 0

let resolve_all dialect target ~name text (candidates : string array) =
  let present = Array.map Option.some candidates in
  let refused = Hashtbl.create 16 in
  let unit = read_with dialect target ~name text present refused in
  let types = typedef_types unit in
  let first_token = first_token_from unit.text.tokens (String.length text) in
  let declaring = candidates_declaring_tags unit ~first_token in
  let resolution index =
    match (Hashtbl.find_opt refused index, Hashtbl.find_opt types index) with
    | Some why, _ -> Unresolved why
    | None, _ when Hashtbl.mem declaring index ->
        Unresolved "it names a tag that no file-scope declaration declares"
    | None, Some t -> Resolved t
    | None, None -> failwith "a candidate has neither a type nor a reason"
  in
  Array.init (Array.length candidates) resolution

let resolve dialect target ~name text spellings =
  let normalised = Hashtbl.create 1024 and candidates = Hashtbl.create 1024 in
  let add spelling =
    let rewritten = Normalisation.apply spelling in
    Hashtbl.replace normalised spelling rewritten;
    match rewritten with
    | Ok type_name when not (Hashtbl.mem candidates type_name) ->
        Hashtbl.replace candidates type_name (Hashtbl.length candidates)
    | Ok _ | Error _ -> ()
  in
  List.iter add spellings;
  let ordered = Array.make (Hashtbl.length candidates) "" in
  Hashtbl.iter (fun type_name index -> ordered.(index) <- type_name) candidates;
  let resolutions = resolve_all dialect target ~name text ordered in
  fun spelling ->
    match Hashtbl.find normalised spelling with
    | Error why -> Unresolved why
    | Ok type_name -> resolutions.(Hashtbl.find candidates type_name)
