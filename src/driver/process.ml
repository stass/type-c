(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The program gets the first caught signal once, and a program that has
   already ended is not an error. *)
let pass_on pid =
  match Signals.caught () with
  | Some signal ->
      (try Unix.kill pid signal with Unix.Unix_error _ -> ());
      true
  | None -> false

(* A signal interrupts the wait once its handler has recorded it; one
   caught after the program started and before the wait began interrupts
   nothing, so it is passed on first. *)
let wait pid =
  let rec wait_passing_on passed_on =
    match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        wait_passing_on (passed_on || pass_on pid)
  in
  wait_passing_on (pass_on pid)

let run ~stdin ~stdout command =
  let program = List.hd command in
  let pid =
    Unix.create_process program (Array.of_list command) stdin stdout
      Unix.stderr
  in
  wait pid
