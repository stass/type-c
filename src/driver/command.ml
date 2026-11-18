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

let stop_if_caught () =
  match Signals.caught () with
  | Some signal -> raise (Stopped (Signal signal))
  | None -> ()

(* How a backend [command] ended, or, as an error, typec's own failure
   to run it, already reported. waitpid reports a stopped child only when
   asked to, which Process.run does not. *)
let run_backend ~stdin ~stdout command =
  match Process.run ~stdin ~stdout ~stderr:Unix.stderr command with
  | Unix.WEXITED status -> Ok (Exit status)
  | Unix.WSIGNALED signal -> Ok (Signal signal)
  | Unix.WSTOPPED _ ->
      report "internal error, a bug in typec: the backend was reported stopped";
      Error (Exit (Exit_status.code Exit_status.Internal))
  | exception Unix.Unix_error (error, _, _) ->
      report (cannot_run (List.hd command) error);
      Error (Exit (Exit_status.code Exit_status.Environment))

(* A step that fails ends the pipeline as the backend ended. *)
let run_step ~stdin ~stdout command =
  stop_if_caught ();
  (match run_backend ~stdin ~stdout command with
  | Ok (Exit 0) -> ()
  | Ok outcome | Error outcome -> raise (Stopped outcome));
  stop_if_caught ()

let with_file path flags f =
  let file = Unix.openfile path (Unix.O_CLOEXEC :: flags) 0o666 in
  Fun.protect ~finally:(fun () -> Unix.close file) (fun () -> f file)

let new_file_flags = Unix.[ O_WRONLY; O_CREAT; O_TRUNC ]

(* The first [limit] bytes of [file], or all of it if shorter. *)
let read_at_most file limit =
  let buffer = Bytes.create limit in
  let rec fill filled =
    if filled = limit then Bytes.sub_string buffer 0 filled
    else
      match Unix.read file buffer filled (limit - filled) with
      | 0 -> Bytes.sub_string buffer 0 filled
      | count -> fill (filled + count)
  in
  fill 0

(* The start of the regular file [path], or None. A device or a FIFO,
   which a line marker can name, is never opened, as opening one can
   act on it; the stat before the open decides that, and the fstat
   after it checks that the file opened is the file stated. O_NONBLOCK
   and O_NOCTTY keep an open that loses that race from waiting for a
   FIFO's writer or taking a terminal. The line is shown at best
   effort, so a failed close gives None too. *)
let read_source path =
  try
    let stated = Unix.stat path in
    if stated.st_kind <> Unix.S_REG then None
    else
      with_file path Unix.[ O_RDONLY; O_NONBLOCK; O_NOCTTY ] (fun file ->
          let opened = Unix.fstat file in
          if opened.st_dev <> stated.st_dev || opened.st_ino <> stated.st_ino
          then None
          else Some (read_at_most file Source_line.longest_read))
  with Unix.Unix_error _ | Fun.Finally_raised _ -> None

(* The line that a refusal names, as the diagnostic shows it, or None
   where no regular file holds it. *)
let source_line (location : Typec_cpp.Location.t) =
  match Source_line.path location with
  | None -> None
  | Some path ->
      Option.bind (read_source path) (Source_line.quote ~line:location.line)

(* A refusal names its place in the source, which says where it comes
   from, so it is printed without the program's name. *)
let refuse (error : Typec_cpp.Reader.error) =
  print_error (Typec_cpp.Reader.error_message error);
  Option.iter print_error (source_line error.location);
  raise (Stopped (Exit (Exit_status.code Exit_status.Refused)))

let preprocess ~null compiler (translation : Pipeline.translation) =
  with_file translation.preprocessed new_file_flags (fun stdout ->
      run_step ~stdin:null ~stdout (translation.preprocess compiler))

(* A file that a backend step wrote, [what] naming it in the message. *)
let read_step_output ~what path =
  try In_channel.with_open_bin path In_channel.input_all
  with Sys_error message ->
    stop Exit_status.Environment
      (Printf.sprintf "cannot read %s: %s" what message)

let read_preprocessed_text (translation : Pipeline.translation) =
  read_step_output ~what:"the preprocessed text" translation.preprocessed

let read_preprocessed (translation : Pipeline.translation) =
  let text = read_preprocessed_text translation in
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
  | Error
      (( Output_too_long | Invalid_macros _ | Neither_enumeration_probe _
       | Both_enumeration_probes _ | Probe_ended_by_signal _
       | No_temporary_directory _ ) as error) ->
      stop Exit_status.Environment (Target_query.error_message ~program error)

let lower dialect target ~trap text =
  match Front_end.lower dialect target ~trap text with
  | Ok lowered -> lowered
  | Error error -> refuse error

(* [what] names the text in the message. *)
let print_text ~what text =
  try
    print_string text;
    flush stdout
  with Sys_error message ->
    stop Exit_status.Environment
      (Printf.sprintf "cannot write %s: %s" what message)

let write_emitted (destination : Pipeline.destination) text =
  match destination with
  | Pipeline.Standard_output -> print_text ~what:"the C" text
  | Pipeline.File path -> (
      try
        Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel text)
      with Sys_error message ->
        stop Exit_status.Environment ("cannot write the C: " ^ message))

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
  let text = read_preprocessed_text translation in
  match Typec_cpp.Reader.read_interface ~name:translation.source text with
  | Ok read -> read
  | Error error -> refuse error

let refuse_on_error = function Ok value -> value | Error error -> refuse error

let stop_on_error = function
  | Ok () -> ()
  | Error message -> stop Exit_status.Environment message

(* A text bound for its destination, and the file that holds it there. *)
type output = {
  what : string;  (** names the text in a message *)
  destination : Pipeline.destination;
  text : string;
  file : path:string -> string -> Header_file.file;
}

(* The files are written together, so that a refusal of one leaves
   every path as it was, then the other texts are printed in order. *)
let put outputs =
  let file output =
    match output.destination with
    | Pipeline.File path -> Some (output.file ~path output.text)
    | Pipeline.Standard_output -> None
  in
  stop_on_error (Header_file.write (List.filter_map file outputs));
  List.iter
    (fun output ->
      if output.destination = Pipeline.Standard_output then
        print_text ~what:output.what output.text)
    outputs

let header_output ~stats ~trap (target : Target.t) (plan : Pipeline.header) =
  let translation = plan.interface in
  let read = read_interface translation in
  let tree, scopes =
    refuse_on_error (Front_end.parse translation.dialect target read.unit)
  in
  refuse_on_error
    (Typec_emit.Header.check_interface ~source:translation.source read tree);
  let header, counts =
    refuse_on_error
      (Front_end.lower_header target ~trap ~source:translation.source
         ~name:plan.name read.unit scopes)
  in
  if stats then report_counts translation counts;
  {
    what = "the header";
    destination = translation.emitted;
    text = header;
    file = Header_file.header ~first_line:Typec_emit.Header.first_line;
  }

let rule_output (rule : Pipeline.rule) =
  let what = "the dependency rule" in
  {
    what;
    destination = rule.destination;
    text = read_step_output ~what rule.written;
    file = Header_file.rule;
  }

let emit_header ~null ~stats ~trap (target : Target.t)
    (plan : Pipeline.header) =
  let translation = plan.interface in
  make_directory translation.directory;
  preprocess ~null target.backend.compiler translation;
  match plan.output with
  | Pipeline.Header -> put [ header_output ~stats ~trap target plan ]
  | Pipeline.Header_and_rule rule ->
      let header = header_output ~stats ~trap target plan in
      let rule = rule_output rule in
      put [ header; rule ]
  | Pipeline.Rule rule -> put [ rule_output rule ]

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
let run_planned ~input planned run =
  match planned with
  | Error error ->
      report (Pipeline.error_message ~input error);
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
      run_planned ~input:Pipeline.Interface
        (Pipeline.plan_header ~program ~temp_dir arguments)
        (run_header ~program ~stats ~trap)
  | Invocation.Compile | Invocation.Emit_c | Invocation.Print_target
  | Invocation.Print_version ->
      let emit_c = invocation.action = Invocation.Emit_c in
      run_planned ~input:Pipeline.Unit
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

(* A backend that fails to answer is named, since some, like false(1),
   fail without a word. *)
let print_backend_version program =
  let command = [ program; "--version" ] in
  match run_backend ~stdin:Unix.stdin ~stdout:Unix.stdout command with
  | Ok (Exit 0) -> Exit 0
  | Ok (Exit _ as outcome) ->
      report
        (Printf.sprintf "the C compiler %S failed to print its version"
           program);
      outcome
  | Ok (Signal _ as outcome) | Error outcome -> outcome

(* A reader that stops at the backend's first line, as head -1 does, may
   have closed the pipe before this line: that is no failure, so SIGPIPE,
   ignored only now that the backend no longer inherits it, must not end
   typec. Any other failed write fails the command. *)
let print_release () =
  let line = "typec " ^ Version.release ^ "\n" in
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  try ignore (Unix.write_substring Unix.stdout line 0 (String.length line))
  with
  | Unix.Unix_error (Unix.EPIPE, _, _) -> ()
  | Unix.Unix_error (error, _, _) ->
      fail Exit_status.Environment
        ("cannot write the version: " ^ Unix.error_message error)

(* The backend answers first, so a build tool that tells compilers apart
   by the output of --version sees the backend; typec's line follows it
   whatever the backend did. *)
let print_version { Invocation.program; _ } =
  let outcome = print_backend_version program in
  print_release ();
  finish outcome

let perform (invocation : Invocation.t) =
  match invocation.action with
  | Invocation.Print_version -> print_version invocation
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
