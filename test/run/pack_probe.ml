(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Emits the preprocessed file named on the command line with a bracketed
   structure, struct instance, inserted before its first declaration, as the
   instance of a generic would be, so that the unit ends with the packing
   probe of design 10.3, for a backend to compile. *)

open Typec_cpp
open Typec_syntax
open Typec_emit

let () =
  let name = Sys.argv.(1) in
  let text = In_channel.with_open_bin name In_channel.input_all in
  let unit =
    match Reader.read ~name text with
    | Ok unit -> unit
    | Error error -> failwith (Reader.error_message error)
  in
  let at =
    match Typec_test_support.External_declarations.of_unit unit with
    | first :: _ -> Tree.anchor first
    | [] -> failwith "pack_probe: no external declaration"
  in
  let location = unit.tokens.(0).location in
  let instance output =
    Emitter.bracketed output ~at ~location
      [ Unguarded
          [ Emitter.generated output location
              "struct instance { char c; int i; };" ] ]
  in
  let instance, _ =
    Result.get_ok (Emitter.limited unit ~trap:Trap.builtin instance)
  in
  print_string
    (Emitter.emit unit
       { trap = Trap.builtin; edits = [ instance ]; assertions = [] })
