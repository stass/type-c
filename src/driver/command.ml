(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A usage error follows the getopt convention; 127 is the status a shell
   gives for a command it cannot run. *)
let exit_usage = 2
let exit_cannot_run = 127

(* The status still reports the failure when stderr is closed. *)
let fail status message =
  (try prerr_endline ("typec: " ^ message) with Sys_error _ -> ());
  exit status

(* The argument vector reaches the backend as it is: no shell sees it. *)
let exec { Invocation.program; arguments } =
  try Unix.execvp program (Array.of_list (program :: arguments))
  with Unix.Unix_error (error, _, _) ->
    fail exit_cannot_run
      (Printf.sprintf "cannot run the C compiler %S: %s" program
         (Unix.error_message error))

let run ~env_cc arguments =
  match Invocation.of_command_line ~env_cc arguments with
  | Error error -> fail exit_usage (Invocation.error_message error)
  | Ok invocation -> exec invocation
