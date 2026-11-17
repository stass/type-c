(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

type error =
  | Exited of int
  | Ended_by_signal of int
  | Output_too_long
  | Invalid_macros of Target.error
  | Neither_enumeration_probe of string list
  | Both_enumeration_probes of string list
  | Probe_ended_by_signal of string list
  | No_temporary_directory of string

(* Raised at the first failure of the backend and caught in query. *)
exception Failed of error

(* Print every predefined macro of C, and nothing else, on stdout. *)
let macro_dump_arguments = [ "-dM"; "-E"; "-x"; "c"; "/dev/null" ]

(* A real dump is about 20 KB; the cap stops a wrong backend, such as
   --cc=yes, from filling memory. *)
let max_output_bytes = 1 lsl 20

let read_chunk_bytes = 65536

(* The whole output, or None once it passes the cap. *)
let read_bounded fd =
  let buffer = Buffer.create read_chunk_bytes in
  let chunk = Bytes.create read_chunk_bytes in
  let rec read_rest () =
    let count = Unix.read fd chunk 0 read_chunk_bytes in
    Buffer.add_subbytes buffer chunk 0 count;
    if Buffer.length buffer > max_output_bytes then None
    else if count = 0 then Some (Buffer.contents buffer)
    else read_rest ()
  in
  read_rest ()

(* The read end of the pipe is close-on-exec, so the backend holds only
   the write end, as its stdout. *)
let start program arguments =
  let output, input = Unix.pipe ~cloexec:true () in
  match
    Process.start ~stdin:Unix.stdin ~stdout:input ~stderr:Unix.stderr
      (program :: arguments)
  with
  | pid ->
      Unix.close input;
      (pid, output)
  | exception error ->
      Unix.close input;
      Unix.close output;
      raise error

let check_status = function
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED status -> raise (Failed (Exited status))
  | Unix.WSIGNALED signal -> raise (Failed (Ended_by_signal signal))
  | Unix.WSTOPPED _ ->
      failwith "Target_query: waitpid reported the backend stopped"

(* The backend's stderr is not a pipe, so its stdout is the only channel
   to drain and the read cannot deadlock. Every path closes the pipe and
   reaps the backend, so a failed query leaves no descriptor or zombie;
   at the cap the backend is killed, so the wait returns even when it
   ignores SIGPIPE. *)
let run_backend program arguments =
  let pid, output = start program arguments in
  let finish () =
    Unix.close output;
    snd (Unix.waitpid [] pid)
  in
  match read_bounded output with
  | Some dump ->
      check_status (finish ());
      dump
  | None ->
      Unix.kill pid Sys.sigkill;
      ignore (finish ());
      raise (Failed Output_too_long)
  | exception error ->
      ignore (finish ());
      raise error

(* Each probe compiles under its own representation alone: under the
   other the array has a negative size. The text is C89, so no -std or
   -pedantic-errors fails it, and -w keeps a -Werror from failing it on a
   warning of its reserved names. *)
let enumeration_probe enumeration_size =
  "typedef char __tc_enum_size[sizeof(enum { __tc_enum_probe }) == "
  ^ enumeration_size ^ " ? 1 : -1];\n"

let short_probe = enumeration_probe "1"
let int_sized_probe = enumeration_probe "sizeof(int)"

(* Read the text from stdin and compile nothing. An option such as
   -fstack-usage still makes GCC write a file named for the input, so
   -dumpdir puts such files in [aux_directory], which typec removes. *)
let probe_arguments aux_directory =
  [ "-fsyntax-only"; "-w"; "-dumpdir"; aux_directory ^ "/"; "-x"; "c"; "-" ]

let with_descriptor descriptor use =
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      use descriptor)

(* The pipe holds the whole text, far below a pipe's capacity, and its
   write end is closed before the backend starts, so no write can meet a
   backend that has already exited. *)
let text_on_pipe text =
  let output, input = Unix.pipe ~cloexec:true () in
  match
    with_descriptor input (fun input ->
        ignore (Unix.write_substring input text 0 (String.length text)))
  with
  | () -> output
  | exception error ->
      Unix.close output;
      raise error

(* A probe fails by design, so the backend's stdout and stderr go to
   /dev/null and its message is not shown. *)
let probe_compiles ~program ~aux_directory options text =
  let command = program :: (options @ probe_arguments aux_directory) in
  with_descriptor (text_on_pipe text) (fun stdin ->
      with_descriptor
        (Unix.openfile "/dev/null" [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0)
        (fun null ->
          match Process.run ~stdin ~stdout:null ~stderr:null command with
          | Unix.WEXITED 0 -> true
          | Unix.WEXITED _ -> false
          | Unix.WSIGNALED _ -> raise (Failed (Probe_ended_by_signal options))
          | Unix.WSTOPPED _ ->
              failwith "Target_query: waitpid reported the backend stopped"))

(* Two probes and not one, whose failure would read as the other
   representation, so that no setup error of the backend passes for an
   answer: such an error fails both. *)
let enumeration_representation ~program options =
  let aux_directory =
    try Temp_dir.create ()
    with Sys_error message -> raise (Failed (No_temporary_directory message))
  in
  Fun.protect
    ~finally:(fun () -> Temp_dir.remove aux_directory)
    (fun () ->
      let compiles = probe_compiles ~program ~aux_directory options in
      let short = compiles short_probe in
      let int_sized = compiles int_sized_probe in
      match (short, int_sized) with
      | true, false -> Target.Short
      | false, true -> Target.Int_sized
      | false, false -> raise (Failed (Neither_enumeration_probe options))
      | true, true -> raise (Failed (Both_enumeration_probes options)))

(* The macro dump runs first and shows the backend's messages, and the
   model is checked before the probes run, so the errors of setup that
   they would hide are reported. The representation changes no check of
   the model, so the first check takes either. *)
let query ~program options =
  try
    let dump = run_backend program (options @ macro_dump_arguments) in
    let model enum_representation =
      Target.of_predefined_macros ~enum_representation dump
      |> Result.map_error (fun error -> Invalid_macros error)
    in
    Result.bind (model Target.Int_sized) (fun _ ->
        model (enumeration_representation ~program options))
  with Failed error -> Error error

(* Options come from the command line, so %S escapes any control
   character. *)
let options_text = function
  | [] -> "no options"
  | options ->
      let quoted = List.map (Printf.sprintf "%S") options in
      "the options " ^ String.concat " " quoted

let error_message ~program = function
  | Exited status ->
      Printf.sprintf
        "the C compiler %S exited with status %d listing its \
         predefined macros"
        program status
  | Ended_by_signal _ ->
      Printf.sprintf
        "the C compiler %S was ended by a signal listing its \
         predefined macros"
        program
  | Output_too_long ->
      Printf.sprintf
        "the C compiler %S printed more than %d bytes listing its \
         predefined macros"
        program max_output_bytes
  | Invalid_macros error -> Target.error_message error
  | Neither_enumeration_probe options ->
      Printf.sprintf
        "the C compiler %S compiled neither probe of the enumeration \
         representation, for short and for int-sized enumerations, with %s"
        program (options_text options)
  | Both_enumeration_probes options ->
      Printf.sprintf
        "the C compiler %S compiled both probes of the enumeration \
         representation, for short and for int-sized enumerations, with %s"
        program (options_text options)
  | Probe_ended_by_signal options ->
      Printf.sprintf
        "the C compiler %S was ended by a signal compiling a probe of the \
         enumeration representation with %s"
        program (options_text options)
  | No_temporary_directory message ->
      "cannot create a temporary directory: " ^ message
