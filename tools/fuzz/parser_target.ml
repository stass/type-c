(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The parser as a fuzz target: a text that the reader accepts is parsed
   with the keywords of an LP64 target in GNU C. Each stage either
   accepts its input or refuses it with a printable message. An accepted
   unit must keep the promises of Tree: every node's span holds its parts
   in token order, and parsing the same tokens again gives the same tree.
   The parser, whose recursion Parser.max_nesting bounds, runs on a small
   stack (Small_stack); the checks keep the default one.

   The target stops at the parser so that its linear bounds on heap and
   time check that parsing stays linear in the input. The declaration
   reader's work is bounded by the instance budget of design 3.5 rule 7
   instead, which a short input can fill, so it runs in the lowering
   target, whose bounds are those of the budgets. *)

open Typec_cpp
open Typec_syntax
open Typec_test_support

let violated = Property.violated
let lp64 = Canned_targets.(target gcc_probes lp64_macros)

(* The only call of the parser, so that a change to its interface is one
   edit here. *)
let parse reader =
  Parser.parse ~keywords:(Typec_sema.Target.keywords lp64 Gnu) reader

let check_spans reader unit =
  let dump = Tree_dump.translation_unit reader unit in
  match Tree_dump.span_violation (Tree_dump.group dump) with
  | Some violation -> violated ("spans nest in token order: " ^ violation)
  | None -> ()

(* The parser keeps its typedef scope in its own state; parsing again in
   the same process shows whether any of it outlives a parse. *)
let check_deterministic reader unit =
  if parse reader <> Ok unit then violated "parsing is deterministic"

let check_parsed reader unit =
  check_spans reader unit;
  check_deterministic reader unit

let check text =
  match Reader.read ~name:"fuzz.i" text with
  | Error error -> Property.check_refusal error
  | Ok reader -> (
      match Small_stack.run (fun () -> parse reader) with
      | Ok parsed -> check_parsed reader parsed
      | Error error -> Property.check_refusal error)
