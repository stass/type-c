(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Emits the preprocessed file named on the command line with a bracketed
   structure, struct instance, inserted before its first token, as the
   instance of a generic would be, so that the unit ends with the packing
   probe of design 10.3, for a backend to compile. *)

open Typec_cpp
open Typec_emit

let () =
  let name = Sys.argv.(1) in
  let text = In_channel.with_open_bin name In_channel.input_all in
  let unit =
    match Reader.read ~name text with
    | Ok unit -> unit
    | Error error -> failwith (Reader.error_message error)
  in
  let instance : Emitter.edit =
    { range = Reader.range unit.tokens ~first:0 ~count:0;
      location = unit.tokens.(0).location;
      text = Bracketed "struct instance { char c; int i; };" }
  in
  print_string (Emitter.emit unit { edits = [ instance ]; assertions = [] })
