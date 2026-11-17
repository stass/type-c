(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* golden [--int16] FILE: the C that typec emits for FILE, or the
   diagnostic that refuses it. A FILE.i holds the whole text that cc -E writes, and any
   other FILE that text after the line marker that opens the main file
   under FILE's name, which golden writes. It runs the stages that typec
   runs after the backend preprocesses (Front_end.lower), for the LP64
   target of the unit tests in gnu11, so that its output depends on no
   backend; --int16 takes that target with an int of 16 bits instead,
   for the rules that only such an int reaches. It leaves out the
   assertions that end a lowered unit, which
   are the same for every unit and which test/run/target.t checks. *)

open Typec_cpp

let lp64 = Typec_test_support.Canned_targets.(target lp64_macros)
let int16 = Typec_test_support.Canned_targets.(target lp64_int16_macros)

let preprocessed path source =
  if Filename.check_suffix path ".i" then source
  else Typec_test_support.Preprocessed.text ~name:path source

let () =
  let target, path =
    match Array.to_list Sys.argv with
    | [ _; "--int16"; path ] -> (int16, path)
    | [ _; path ] -> (lp64, path)
    | _ -> failwith "usage: golden [--int16] FILE"
  in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let lowered =
    Result.bind
      (Reader.read ~name:path (preprocessed path source))
      (fun text ->
        Result.map
          (fun ((lowered : Typec_emit.Emitter.lowered), _) ->
            Typec_emit.Emitter.emit text { lowered with assertions = [] })
          (Typec_driver.Front_end.lower Gnu target
             ~trap:Typec_emit.Trap.builtin text))
  in
  match lowered with
  | Ok c -> print_string c
  | Error error ->
      print_endline (Reader.error_message error);
      exit 1
