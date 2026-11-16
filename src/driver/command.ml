(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

(* The status still reports the failure when stderr is closed. *)
let report message =
  try prerr_endline ("typec: " ^ message) with Sys_error _ -> ()

let fail failure message =
  report message;
  exit (Exit_status.code failure)

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
  | Error error ->
      fail Exit_status.Environment (Target_query.error_message ~program error)
  | Ok target ->
      (try
         print_string (Target.to_string target);
         flush stdout
       with Sys_error message ->
         fail Exit_status.Environment
           ("cannot write the target model: " ^ message));
      exit 0

(* How the pipeline ends: with an exit status, or by a signal. *)
type outcome = Exit of int | Signal of int

(* Raised at the first step of the pipeline that fails, after its
   message, and caught once in run_pipeline. *)
exception Stopped of outcome

let stop failure message =
  report message;
  raise (Stopped (Exit (Exit_status.code failure)))

let stop_if_caught () =
  match Signals.caught () with
  | Some signal -> raise (Stopped (Signal signal))
  | None -> ()

(* A step that fails ends the pipeline as the backend ended. waitpid
   reports a stopped child only when asked to, which Process.run does not. *)
let run_step ~stdin ~stdout command =
  stop_if_caught ();
  (match Process.run ~stdin ~stdout command with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED status -> raise (Stopped (Exit status))
  | Unix.WSIGNALED signal -> raise (Stopped (Signal signal))
  | Unix.WSTOPPED _ ->
      stop Exit_status.Internal
        "internal error, a bug in typec: the backend was reported stopped"
  | exception Unix.Unix_error (error, _, _) ->
      stop Exit_status.Environment (cannot_run (List.hd command) error));
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
      stop Exit_status.Environment
        ("cannot read the preprocessed text: " ^ message)
  in
  match Typec_cpp.Reader.read ~name:translation.source text with
  | Ok unit -> unit
  | Error error ->
      stop Exit_status.Refused (Typec_cpp.Reader.error_message error)

(* A signal that interrupts the query ends the pipeline by that signal.
   The query is the first step, and a backend that fails it, as one
   that rejects an option of the command line does, ends the pipeline
   as a failed step does, after the backend's own message. *)
let query_target ~program options =
  let model =
    try Target_query.query ~program options
    with Unix.Unix_error (error, _, _) ->
      stop_if_caught ();
      stop Exit_status.Environment (cannot_run program error)
  in
  stop_if_caught ();
  match model with
  | Ok target -> target
  | Error (Exited status) -> raise (Stopped (Exit status))
  | Error (Ended_by_signal signal) -> raise (Stopped (Signal signal))
  | Error ((Output_too_long | Invalid_macros _) as error) ->
      stop Exit_status.Environment (Target_query.error_message ~program error)

let lower dialect target text =
  match Front_end.lower dialect target text with
  | Ok lowered -> lowered
  | Error error ->
      stop Exit_status.Refused (Typec_cpp.Reader.error_message error)

let write_emitted (destination : Pipeline.destination) text =
  try
    match destination with
    | Pipeline.Standard_output ->
        print_string text;
        flush stdout
    | Pipeline.File path ->
        Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel text)
  with Sys_error message ->
    stop Exit_status.Environment ("cannot write the C: " ^ message)

let make_directory path =
  try Temp_dir.make_subdirectory path
  with Sys_error message ->
    stop Exit_status.Environment
      ("cannot create a temporary directory: " ^ message)

let translate ~null (target : Target.t) (translation : Pipeline.translation)
    =
  make_directory translation.directory;
  preprocess ~null translation;
  let text = read_preprocessed translation in
  let lowered = lower translation.dialect target text in
  write_emitted translation.emitted (Typec_emit.Emitter.emit text lowered);
  Option.iter
    (fun compile ->
      run_step ~stdin:null ~stdout:Unix.stdout
        (compile target.backend.compiler))
    translation.compile

(* One target model serves every translation, as they share the options
   of the compile step, and names the compiler that the commands are for.
   The final command reads typec's stdin, which an input "-" names. *)
let run_plan ~program (plan : Pipeline.t) =
  let target = query_target ~program plan.target_options in
  with_file "/dev/null" [ Unix.O_RDONLY ] (fun null ->
      List.iter (translate ~null target) plan.translations);
  Option.iter
    (fun final ->
      run_step ~stdin:Unix.stdin ~stdout:Unix.stdout
        (final target.backend.compiler))
    plan.final

let run_pipeline (invocation : Invocation.t) temp_dir =
  let emit_c = invocation.action = Invocation.Emit_c in
  match
    Pipeline.plan ~program:invocation.program ~emit_c ~temp_dir
      invocation.arguments
  with
  | Error error ->
      report (Pipeline.error_message error);
      Exit (Exit_status.code Exit_status.Environment)
  | Ok plan -> (
      try
        run_plan ~program:invocation.program plan;
        Exit 0
      with
      | Stopped outcome -> outcome
      | Unix.Unix_error (error, call, path) ->
          report
            (Printf.sprintf "%s %s: %s" call path (Unix.error_message error));
          Exit (Exit_status.code Exit_status.Environment))

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
      fail Exit_status.Environment
        ("cannot create a temporary directory: " ^ message)
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

(* Every process below a backend inherits the mark, so typec refuses to
   run anywhere there: a backend that is typec itself, or runs it, would
   otherwise start typec again forever. Refusing a nested typec that
   would end is the price of not telling the two apart. *)
let outer_cc_variable = "TYPEC_OUTER_CC"

let refuse_as_backend outer_cc =
  fail Exit_status.Environment
    (Printf.sprintf
       "the C compiler %S runs typec again (%S, marked by %s): name the \
        real C compiler with --cc=PATH or TYPEC_CC"
       outer_cc Sys.executable_name outer_cc_variable)

let run_command_line ~env_cc ~outer_cc arguments =
  Option.iter refuse_as_backend outer_cc;
  match Invocation.of_command_line ~env_cc arguments with
  | Error error -> fail Exit_status.Environment (Invocation.error_message error)
  | Ok invocation -> (
      Unix.putenv outer_cc_variable invocation.program;
      try perform invocation
      with Unix.Unix_error (error, _, _) ->
        fail Exit_status.Environment (cannot_run invocation.program error))

let hold_standard_descriptors () =
  try Process.hold_standard_descriptors ()
  with Unix.Unix_error (error, _, _) ->
    fail Exit_status.Environment
      ("cannot open /dev/null: " ^ Unix.error_message error)

(* Every failure of typec's own is handled where it happens, so an
   exception that reaches this handler is a bug. The backtrace, recorded
   under OCAMLRUNPARAM=b, comes first so that the message ends stderr. *)
let run ~env_cc ~outer_cc arguments =
  try
    hold_standard_descriptors ();
    run_command_line ~env_cc ~outer_cc arguments
  with exn ->
    (try prerr_string (Printexc.get_backtrace ()) with Sys_error _ -> ());
    fail Exit_status.Internal
      ("internal error, a bug in typec: " ^ Printexc.to_string exn)
