(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

(* The status still reports the failure when stderr is closed. *)
let print_error line = try prerr_endline line with Sys_error _ -> ()

(* A message that names no place in the source names the program, as a
   C compiler's does. *)
let report message = print_error ("typec: " ^ message)

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

(* A refusal names its place in the source, which says where it comes
   from, so it is printed without the program's name. *)
let refuse error =
  print_error (Typec_cpp.Reader.error_message error);
  raise (Stopped (Exit (Exit_status.code Exit_status.Refused)))

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

let preprocess ~null compiler (translation : Pipeline.translation) =
  with_file translation.preprocessed new_file_flags (fun stdout ->
      run_step ~stdin:null ~stdout (translation.preprocess compiler))

let read_preprocessed (translation : Pipeline.translation) =
  let text =
    try In_channel.with_open_bin translation.preprocessed In_channel.input_all
    with Sys_error message ->
      stop Exit_status.Environment
        ("cannot read the preprocessed text: " ^ message)
  in
  match Typec_cpp.Reader.read ~name:translation.source text with
  | Ok unit -> unit
  | Error error -> refuse error

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

let lower dialect target ~trap text =
  match Front_end.lower dialect target ~trap text with
  | Ok lowered -> lowered
  | Error error -> refuse error

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

(* The counts go to stderr, as stdout may carry the emitted C. *)
let report_counts (translation : Pipeline.translation) counts =
  print_error
    (Printf.sprintf "typec: stats: %s: %s" translation.source
       (Front_end.counts_line counts))

let translate ~null ~stats ~trap (target : Target.t)
    (translation : Pipeline.translation) =
  make_directory translation.directory;
  preprocess ~null target.backend.compiler translation;
  let text = read_preprocessed translation in
  let lowered, counts = lower translation.dialect target ~trap text in
  if stats then report_counts translation counts;
  write_emitted translation.emitted (Typec_emit.Emitter.emit text lowered);
  Option.iter
    (fun compile ->
      run_step ~stdin:null ~stdout:Unix.stdout
        (compile target.backend.compiler))
    translation.compile

(* The header of an interface (design 9.3). *)

let read_interface (translation : Pipeline.translation) =
  let text =
    try In_channel.with_open_bin translation.preprocessed In_channel.input_all
    with Sys_error message ->
      stop Exit_status.Environment
        ("cannot read the preprocessed text: " ^ message)
  in
  match Typec_cpp.Reader.read_interface ~name:translation.source text with
  | Ok read -> read
  | Error error -> refuse error

let refuse_on_error = function Ok value -> value | Error error -> refuse error

(* The lowered text is emission's own output, so a failure to read it
   again is a bug of typec's. *)
let read_lowered (translation : Pipeline.translation) text =
  match Typec_cpp.Reader.read_interface ~name:translation.source text with
  | Ok read -> read
  | Error error ->
      stop Exit_status.Internal
        ("internal error, a bug in typec: the lowered text of the \
          interface does not read: "
        ^ Typec_cpp.Reader.error_message error)

let write_header (destination : Pipeline.destination) text =
  match destination with
  | Pipeline.Standard_output -> write_emitted destination text
  | Pipeline.File path -> (
      match
        Header_file.write ~first_line:Typec_emit.Header.first_line ~path text
      with
      | Ok () -> ()
      | Error message -> stop Exit_status.Environment message)

(* The header is written from the lowered text of the interface, read
   again so that the writer meets each token it writes as a token. *)
let emit_header ~null ~stats ~trap (target : Target.t)
    (plan : Pipeline.header) =
  let translation = plan.interface in
  make_directory translation.directory;
  preprocess ~null target.backend.compiler translation;
  let read = read_interface translation in
  let tree, scopes =
    refuse_on_error (Front_end.parse translation.dialect target read.unit)
  in
  refuse_on_error
    (Typec_emit.Header.check_interface ~source:translation.source read tree);
  let lowered, counts =
    refuse_on_error (Front_end.lower_parsed target ~trap read.unit scopes)
  in
  if stats then report_counts translation counts;
  let lowered_read =
    read_lowered translation
      (Typec_emit.Emitter.applied read.unit lowered.edits)
  in
  write_header translation.emitted
    (refuse_on_error (Typec_emit.Header.write plan.name lowered_read))

(* One target model serves every translation, as they share the options
   of the compile step, and names the compiler that the commands are for.
   The final command reads typec's stdin, which an input "-" names. *)
let run_plan ~program ~stats ~trap (plan : Pipeline.t) =
  let target = query_target ~program plan.target_options in
  with_file "/dev/null" [ Unix.O_RDONLY ] (fun null ->
      List.iter (translate ~null ~stats ~trap target) plan.translations);
  List.iter
    (fun final ->
      run_step ~stdin:Unix.stdin ~stdout:Unix.stdout
        (final target.backend.compiler))
    plan.finals

let run_header ~program ~stats ~trap (plan : Pipeline.header) =
  let target = query_target ~program plan.header_target_options in
  with_file "/dev/null" [ Unix.O_RDONLY ] (fun null ->
      emit_header ~null ~stats ~trap target plan)

(* [run] performs a plan that [planned] gives, or reports why there is
   none. *)
let run_planned planned run =
  match planned with
  | Error error ->
      report (Pipeline.error_message error);
      Exit (Exit_status.code Exit_status.Environment)
  | Ok plan -> (
      try
        run plan;
        Exit 0
      with
      | Stopped outcome -> outcome
      | Unix.Unix_error (error, call, path) ->
          report
            (Printf.sprintf "%s %s: %s" call path (Unix.error_message error));
          Exit (Exit_status.code Exit_status.Environment))

let run_pipeline (invocation : Invocation.t) temp_dir =
  let { Invocation.program; arguments; stats; trap; _ } = invocation in
  match invocation.action with
  | Invocation.Emit_c_header ->
      run_planned
        (Pipeline.plan_header ~program ~temp_dir arguments)
        (run_header ~program ~stats ~trap)
  | Invocation.Compile | Invocation.Emit_c | Invocation.Print_target ->
      let emit_c = invocation.action = Invocation.Emit_c in
      run_planned
        (Pipeline.plan ~program ~emit_c ~temp_dir arguments)
        (run_plan ~program ~stats ~trap)

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
  | Invocation.Emit_c | Invocation.Emit_c_header ->
      compile_through_pipeline invocation
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
