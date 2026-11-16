(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Emits the preprocessed file named on the command line with every
   token in front of its last external declaration, pragma lines among
   them, moved as the operand of a try is (design 13.5): deleted at its
   own place and written, as moved text without a bracket, in front of
   that declaration, for a backend to compile. *)

open Typec_cpp
open Typec_emit

let read name =
  let text = In_channel.with_open_bin name In_channel.input_all in
  match Reader.read ~name text with
  | Ok unit -> unit
  | Error error -> failwith (Reader.error_message error)

(* The first token of the last external declaration, which the probe
   expects to be a C one. *)
let last_start unit =
  let declarations = Typec_test_support.External_declarations.of_unit unit in
  let last = List.nth declarations (List.length declarations - 1) in
  match last.declaration with
  | External_declaration { span; _ } -> span.first
  | _ -> failwith "moved_pragma_probe: a last declaration that is no C one"

let moved_piece unit index =
  match Emitter.moved_token unit index with
  | Some piece -> piece
  | None -> failwith "moved_pragma_probe: an unmovable token"

let () =
  let unit = read Sys.argv.(1) in
  let start = last_start unit in
  let deleted =
    Emitter.code
      (Reader.range unit.tokens ~first:0 ~count:start)
      ~location:unit.tokens.(0).location ""
  in
  let moved =
    Emitter.moved
      (Reader.range unit.tokens ~first:start ~count:0)
      (List.init start (moved_piece unit))
  in
  print_string
    (Emitter.emit unit { edits = [ deleted; moved ]; assertions = [] })
