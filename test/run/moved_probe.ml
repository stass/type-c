(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Emits the preprocessed file named on the command line with its first
   external declaration moved as the definition of a generic is to an
   instance (design 13.4): deleted at its own place and written, token
   by token, in a packing bracket in front of the last external
   declaration, after a typedef that typec writes at the line of that
   declaration, for a backend to compile. *)

open Typec_cpp
open Typec_syntax
open Typec_emit

let read name =
  let text = In_channel.with_open_bin name In_channel.input_all in
  match Reader.read ~name text with
  | Ok unit -> unit
  | Error error -> failwith (Reader.error_message error)

(* The tokens of a declaration; the probe moves and anchors at no other
   kind of external declaration. *)
let span_of (item : Tree.external_declaration Tree.item) =
  match item.declaration with
  | External_declaration { span; _ } -> span
  | _ -> failwith "moved_probe: an external declaration that is no C one"

let () =
  let unit = read Sys.argv.(1) in
  let declarations =
    Typec_test_support.External_declarations.of_unit unit
  in
  let first = List.hd declarations
  and last = List.nth declarations (List.length declarations - 1) in
  let { Tree.first = start; last = finish } = span_of first in
  let count = finish - start + 1 in
  let application = unit.tokens.((span_of last).first).location in
  let edits output =
    let deleted =
      Emitter.code output
        (Reader.range unit.tokens ~first:start ~count)
        ~location:unit.tokens.(start).location ""
    in
    let token offset = Option.get (Emitter.token output (start + offset)) in
    let moved =
      Emitter.bracketed output ~at:(Tree.anchor last) ~location:application
        (Emitter.generated output application "typedef int __tc_arg__i;"
        :: List.map token (List.init count Fun.id))
    in
    [ deleted; moved ]
  in
  let edits, _ =
    Result.get_ok (Emitter.limited unit ~trap:Trap.builtin edits)
  in
  print_string
    (Emitter.emit unit { trap = Trap.builtin; edits; assertions = [] })
