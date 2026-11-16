(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The parser and the declaration reader as one fuzz target: a text that
   the reader accepts is parsed, and a unit that parses has its file-scope
   declarations read for an LP64 target. Each stage either accepts its
   input or refuses it with a printable message. An accepted unit must
   keep the promises of Tree: every node's span holds its parts in token
   order, and parsing the same tokens again gives the same tree. The
   parser, whose recursion Parser.max_nesting bounds, runs on a small
   stack (Small_stack); the rest keeps the default one.

   The declaration reader takes only a parsed unit, so a target of its
   own would run the same front half on the same inputs; here one
   campaign drives both, and the backtrace of a crash names the stage. *)

open Typec_cpp
open Typec_syntax
open Typec_test_support

let violated = Property.violated
let lp64 = Canned_targets.target Canned_targets.lp64_macros

(* The only call of the parser, so that a change to its interface is one
   edit here. *)
let parse reader =
  Parser.parse_with_scopes
    ~keywords:(Typec_sema.Target.keywords lp64 Gnu)
    reader

let check_spans reader unit =
  let dump = Tree_dump.translation_unit reader unit in
  match Tree_dump.span_violation (Tree_dump.group dump) with
  | Some violation -> violated ("spans nest in token order: " ^ violation)
  | None -> ()

(* The parser keeps its typedef scope in its own state; parsing again in
   the same process shows whether any of it outlives a parse. *)
let check_deterministic reader unit =
  if Result.map fst (parse reader) <> Ok unit then
    violated "parsing is deterministic"

let read_declarations reader scopes =
  match Typec_sema.Declarations.read lp64 reader scopes with
  | Ok _ -> ()
  | Error error -> Property.check_refusal error

let check_parsed reader (unit, scopes) =
  check_spans reader unit;
  check_deterministic reader unit;
  read_declarations reader scopes

let check text =
  match Reader.read ~name:"fuzz.i" text with
  | Error error -> Property.check_refusal error
  | Ok reader -> (
      match Small_stack.run (fun () -> parse reader) with
      | Ok parsed -> check_parsed reader parsed
      | Error error -> Property.check_refusal error)
