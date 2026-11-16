(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The stages after the parser recurse over the tree, which
   Parser.max_depth bounds, and need no bound of their own (design 13.7).
   Every chain that the parser reads in a loop, as deep as the bound
   lets it, goes through typing, reachability, lowering and emission on
   a stack limited near what the bound promises, so that a stage whose
   frames grow fails here rather than on a deep program. *)

open Typec_cpp
open Typec_test_support

(* The comment of Parser.max_depth measures the stages after the parser
   at under 140K words of stack on a tree at the bound; the power of two
   above it leaves room for frames a change adds. *)
let limit_words = 256 * 1024

let lp64 = Canned_targets.target Canned_targets.lp64_macros

(* The C that [text] lowers to, or the error that refuses it. *)
let lowered file text =
  let preprocessed = Preprocessed.text ~name:file text in
  Result.bind (Reader.read ~name:file preprocessed) (fun reader ->
      Result.map
        (fun edits -> Typec_emit.Emitter.emit reader edits)
        (Typec_driver.Front_end.lower Gnu lp64 reader))

(* The failure of [chain], if it has one. *)
let failure ({ name; file; text; lowers } : Chains.chain) =
  match Small_stack.run_within limit_words (fun () -> lowered file text) with
  | Ok _ when lowers -> None
  | Error _ when not lowers -> None
  | Ok _ -> Some (name, "lowered, though no stage should take it")
  | Error error -> Some (name, Reader.error_message error)
  | exception Stack_overflow -> Some (name, "overflowed the stack")

let () =
  let chains = Chains.nesting_chains Chains.links_within_bound in
  match List.filter_map failure chains with
  | [] -> ()
  | failures ->
      List.iter
        (fun (name, message) -> Printf.eprintf "FAIL: %s: %s\n" name message)
        failures;
      exit 1
