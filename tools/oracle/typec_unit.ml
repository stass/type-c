(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_driver

(* The pipeline decides the dialect and the target options of a [.tc]
   input, so a plan for one stands for the compilation of INPUT.i: the
   input itself is never read. *)
let model ~cc options =
  let arguments = Command_line.read (options @ [ "--emit-c"; "input.tc" ]) in
  match Pipeline.plan ~program:cc ~emit_c:true ~temp_dir:"." arguments with
  | Error error -> failwith (Pipeline.error_message error)
  | Ok { translations = []; _ } | Ok { translations = _ :: _ :: _; _ } ->
      failwith "the options name inputs"
  | Ok { translations = [ translation ]; _ } -> (
      match Target_query.query ~program:cc translation.target_options with
      | Ok target -> (translation.dialect, target)
      | Error error -> failwith (Target_query.error_message ~program:cc error))

type t = {
  target : Target.t;
  text : Reader.t;
  unit : Tree.translation_unit;
  declarations : Declarations.t;
}

let ( let* ) = Result.bind

let read dialect target ~name contents =
  let* text = Reader.read ~name contents in
  let keywords = Target.keywords target dialect in
  let* unit = Parser.parse ~keywords text in
  let* declarations = Declarations.read target text unit in
  Ok { target; text; unit; declarations }

type expression = { first : int; limit : int; typed : Expressions.typed }

let range unit (expression : Tree.expression) =
  let first = unit.text.tokens.(expression.span.first)
  and last = unit.text.tokens.(expression.span.last) in
  (first.start, last.start + last.length)

let expressions unit ~below =
  let found = ref [] in
  let visit expression =
    match Declarations.expression unit.declarations expression with
    | None -> ()
    | Some typed ->
        let first, limit = range unit expression in
        if limit <= below then found := { first; limit; typed } :: !found
  in
  Tree_expressions.iter visit unit.unit;
  List.sort (fun a b -> compare (a.first, a.limit) (b.first, b.limit)) !found

(* The index of the last token that starts at or before [offset], or 0;
   the tokens are in the order of the text. *)
let token_at (tokens : Token.t array) offset =
  let rec search low high =
    if high - low <= 1 then low
    else
      let middle = (low + high) / 2 in
      if tokens.(middle).start <= offset then search middle high
      else search low middle
  in
  search 0 (Array.length tokens)

let location unit offset =
  let tokens = unit.text.tokens in
  if Array.length tokens = 0 then
    { Location.file = ""; line = 0; flags = No_flags }
  else tokens.(token_at tokens offset).location

let category (typed : Expressions.typed) =
  if typed.category = Lvalue then "lvalue" else "rvalue"
