(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Lowering as a fuzz target: every text that the reader accepts goes
   through the stages of Front_end.lower, for an LP64 target in gnu11
   with the builtin trap, and is emitted as Command.translate emits it.
   Each stage either accepts its input or refuses it with a printable
   message; lowering charges at most the output limit of the unit
   (design 3.5 rule 7), and emission applies its edits without raising.
   The parser runs on the small stack, as in the parser target; the
   stages after it keep the default one.

   The parser target checks the promises of the tree; this one is the
   only target that reads declarations, and it checks the promises of
   lowering and emission. Its seeds include every seed of the parser
   target, so that the declaration reader starts from the same texts. A
   crash of an earlier stage shows here too, and its backtrace names the
   stage. *)

open Typec_cpp
open Typec_test_support
module Front_end = Typec_driver.Front_end

let lp64 = Parser_target.lp64

let check_charge (counts : Front_end.counts) =
  if counts.output_bytes > counts.output_limit then
    Property.violated "lowering charges at most the output limit"

let emit reader (lowered, counts) =
  check_charge counts;
  ignore (Typec_emit.Emitter.emit reader lowered)

let check_parsed reader (_unit, scopes) =
  match
    Front_end.lower_parsed lp64 ~trap:Typec_emit.Trap.builtin reader scopes
  with
  | Ok lowered_with_counts -> emit reader lowered_with_counts
  | Error error -> Property.check_refusal error

let check text =
  match Reader.read ~name:"fuzz.i" text with
  | Error error -> Property.check_refusal error
  | Ok reader -> (
      match Small_stack.run (fun () -> Front_end.parse Gnu lp64 reader) with
      | Ok parsed -> check_parsed reader parsed
      | Error error -> Property.check_refusal error)
