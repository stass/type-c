(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

(* A usage error follows the getopt convention; 127 is the status a shell
   gives for a command it cannot run; any other failure is 1. *)
let exit_failure = 1
let exit_usage = 2
let exit_cannot_run = 127

(* The status still reports the failure when stderr is closed. *)
let report message =
  try prerr_endline ("typec: " ^ message) with Sys_error _ -> ()

let fail status message =
  report message;
  exit status

let cannot_run program error =
  Printf.sprintf "cannot run the C compiler %S: %s" program
    (Unix.error_message error)

(* The argument vector reaches the backend as it is: no shell sees it. *)
let exec { Invocation.program; arguments; _ } =
  let words = Command_line.words arguments in
  Unix.execvp program (Array.of_list (program :: words))

(* The flush is explicit so that a failed write fails the command. *)
let print_target { Invocation.program; arguments; _ } =
  let options = Command_line.words arguments in
  match Target_query.query ~program options with
  | Error error -> fail exit_failure (Target_query.error_message ~program error)
  | Ok target ->
      (try
         print_string (Target.to_string target);
         flush stdout
       with Sys_error message ->
         fail exit_failure ("cannot write the target model: " ^ message));
      exit 0

(* How the pipeline ends: with an exit status, or by a signal. *)
type outcome = Exit of int | Signal of int

(* Raised at the first step of the pipeline that fails, after its
   message, and caught once in run_pipeline. *)
exception Stopped of outcome

let stop status message =
  report message;
  raise (Stopped (Exit status))

let stop_if_caught () =
  match Signals.caught () with
  | Some signal -> raise (Stopped (Signal signal))
  | None -> ()

(* A step that fails ends the pipeline as the backend ended. *)
let run_step ~stdin ~stdout command =
  stop_if_caught ();
  (match Process.run ~stdin ~stdout command with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED status -> raise (Stopped (Exit status))
  | Unix.WSIGNALED signal -> raise (Stopped (Signal signal))
  | Unix.WSTOPPED _ -> raise (Stopped (Exit exit_failure))
  | exception Unix.Unix_error (error, _, _) ->
      stop exit_cannot_run (cannot_run (List.hd command) error));
  stop_if_caught ()

let with_file path flags f =
  let file = Unix.openfile path (Unix.O_CLOEXEC :: flags) 0o666 in
  Fun.protect ~finally:(fun () -> Unix.close file) (fun () -> f file)

let new_file_flags = Unix.[ O_WRONLY; O_CREAT; O_TRUNC ]

let preprocess ~null (translation : Pipeline.translation) =
  with_file translation.preprocessed new_file_flags (fun stdout ->
      run_step ~stdin:null ~stdout translation.preprocess)

let read_preprocessed (translation : Pipeline.translation) =
  let text =
    try In_channel.with_open_bin translation.preprocessed In_channel.input_all
    with Sys_error message ->
      stop exit_failure ("cannot read the preprocessed text: " ^ message)
  in
  match Typec_cpp.Reader.read ~name:translation.source text with
  | Ok unit -> unit
  | Error error -> stop exit_failure (Typec_cpp.Reader.error_message error)

(* A signal that interrupts the query ends the pipeline by that signal. *)
let query_target ~program (translation : Pipeline.translation) =
  let model =
    try Target_query.query ~program translation.target_options
    with Unix.Unix_error (error, _, _) ->
      stop_if_caught ();
      stop exit_cannot_run (cannot_run program error)
  in
  stop_if_caught ();
  match model with
  | Ok target -> target
  | Error error ->
      stop exit_failure (Target_query.error_message ~program error)

let check_front_end dialect target text =
  match Front_end.check dialect target text with
  | Ok () -> ()
  | Error error -> stop exit_failure (Typec_cpp.Reader.error_message error)

let write_emitted (destination : Pipeline.destination) text =
  try
    match destination with
    | Pipeline.Standard_output ->
        print_string text;
        flush stdout
    | Pipeline.File path ->
        Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel text)
  with Sys_error message -> stop exit_failure ("cannot write the C: " ^ message)

(* Each translation queries its own target model, which is simpler than
   sharing one between translations whose options are the same. *)
let translate ~program ~null (translation : Pipeline.translation) =
  preprocess ~null translation;
  let text = read_preprocessed translation in
  let target = query_target ~program translation in
  check_front_end translation.dialect target text;
  write_emitted translation.emitted (Typec_emit.Emitter.emit text []);
  Option.iter (run_step ~stdin:null ~stdout:Unix.stdout) translation.compile

(* The final command reads typec's stdin, which an input "-" names. *)
let run_plan ~program (plan : Pipeline.t) =
  with_file "/dev/null" [ Unix.O_RDONLY ] (fun null ->
      List.iter (translate ~program ~null) plan.translations);
  Option.iter (run_step ~stdin:Unix.stdin ~stdout:Unix.stdout) plan.final

let run_pipeline (invocation : Invocation.t) temp_dir =
  let emit_c = invocation.action = Invocation.Emit_c in
  match
    Pipeline.plan ~program:invocation.program ~emit_c ~temp_dir
      invocation.arguments
  with
  | Error error ->
      report (Pipeline.error_message error);
      Exit exit_usage
  | Ok plan -> (
      try
        run_plan ~program:invocation.program plan;
        Exit 0
      with
      | Stopped outcome -> outcome
      | Unix.Unix_error (error, call, path) ->
          report
            (Printf.sprintf "%s %s: %s" call path (Unix.error_message error));
          Exit exit_failure)

(* A signal caught at any point, the removal included, ends typec by it
   once the directory is gone. *)
let finish outcome =
  match (Signals.caught (), outcome) with
  | Some signal, _ | None, Signal signal -> Signals.end_by signal
  | None, Exit status -> exit status

let compile_through_pipeline invocation =
  Signals.catch ();
  let temp_dir =
    try Temp_dir.create ()
    with Sys_error message ->
      fail exit_failure ("cannot create a temporary directory: " ^ message)
  in
  let outcome =
    Fun.protect
      ~finally:(fun () -> Temp_dir.remove temp_dir)
      (fun () -> run_pipeline invocation temp_dir)
  in
  finish outcome

let perform (invocation : Invocation.t) =
  match invocation.action with
  | Invocation.Print_target -> print_target invocation
  | Invocation.Emit_c -> compile_through_pipeline invocation
  | Invocation.Compile when Pipeline.has_type_c_input invocation.arguments ->
      compile_through_pipeline invocation
  | Invocation.Compile -> exec invocation

let run ~env_cc arguments =
  match Invocation.of_command_line ~env_cc arguments with
  | Error error -> fail exit_usage (Invocation.error_message error)
  | Ok invocation -> (
      try perform invocation
      with Unix.Unix_error (error, _, _) ->
        fail exit_cannot_run (cannot_run invocation.program error))
