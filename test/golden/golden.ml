(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* golden FILE: the C that typec emits for FILE, which holds preprocessed
   text, or the diagnostic that refuses it. It runs the stages that typec
   runs after the backend preprocesses (Front_end.lower), for the LP64
   target of the unit tests in gnu11, so that its output depends on no
   backend. *)

open Typec_cpp

let target = Typec_test_support.Canned_targets.(target lp64_macros)

let () =
  let path = Sys.argv.(1) in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let lowered =
    Result.bind (Reader.read ~name:path source) (fun text ->
        Result.map
          (fun edits -> Typec_emit.Emitter.emit text edits)
          (Typec_driver.Front_end.lower Gnu target text))
  in
  match lowered with
  | Ok c -> print_string c
  | Error error ->
      print_endline (Reader.error_message error);
      exit 1
