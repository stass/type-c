(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The reader as a fuzz target: any text is read, a rejection must come
   with a printable message, and an accepted text must keep the promises
   of Reader.t: its tokens and gaps spell it, the gaps are layout only,
   and the emitter copies it unchanged. *)

open Typec_cpp
open Typec_test_support

let violated = Property.violated

(* Number.classify takes any spelling, so every pp-number is a valid
   input to it; its result is not checked, only that it returns. *)
let classify_numbers (result : Reader.t) =
  Array.iter
    (fun (token : Token.t) ->
      if token.kind = Token.Number then
        ignore (Number.classify (Reader.spelling result token)))
    result.tokens

let check_accepted text (result : Reader.t) =
  if not (Spans.spell_text text result) then
    violated "the tokens and gaps spell the text";
  if not (Spans.gaps_are_layout text result) then
    violated "the gaps hold only white space and line markers";
  if Typec_emit.Emitter.emit result [] <> text then
    violated "a unit without edits is emitted as it was read";
  classify_numbers result

let check text =
  match Reader.read ~name:"fuzz.i" text with
  | Ok result -> check_accepted text result
  | Error error -> Property.check_refusal error
