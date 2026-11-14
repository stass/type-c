(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

(* A usage error follows the getopt convention; 127 is the status a shell
   gives for a command it cannot run; any other failure is 1. *)
let exit_failure = 1
let exit_usage = 2
let exit_cannot_run = 127

(* The status still reports the failure when stderr is closed. *)
let fail status message =
  (try prerr_endline ("typec: " ^ message) with Sys_error _ -> ());
  exit status

(* The argument vector reaches the backend as it is: no shell sees it. *)
let exec { Invocation.program; arguments; _ } =
  Unix.execvp program (Array.of_list (program :: arguments))

(* The flush is explicit so that a failed write fails the command. *)
let print_target { Invocation.program; arguments; _ } =
  match Target_query.query ~program arguments with
  | Error error -> fail exit_failure (Target_query.error_message ~program error)
  | Ok target ->
      (try
         print_string (Target.to_string target);
         flush stdout
       with Sys_error message ->
         fail exit_failure ("cannot write the target model: " ^ message));
      exit 0

let perform (invocation : Invocation.t) =
  match invocation.action with
  | Invocation.Forward -> exec invocation
  | Invocation.Print_target -> print_target invocation

let run ~env_cc arguments =
  match Invocation.of_command_line ~env_cc arguments with
  | Error error -> fail exit_usage (Invocation.error_message error)
  | Ok invocation -> (
      try perform invocation
      with Unix.Unix_error (error, _, _) ->
        fail exit_cannot_run
          (Printf.sprintf "cannot run the C compiler %S: %s"
             invocation.program (Unix.error_message error)))
