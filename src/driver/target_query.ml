(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Target = Typec_sema.Target

type error =
  | Exited of int
  | Ended_by_signal of int
  | Output_too_long
  | Invalid_macros of Target.error

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
    Process.start ~stdin:Unix.stdin ~stdout:input (program :: arguments)
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

let query ~program options =
  try
    let dump = run_backend program (options @ macro_dump_arguments) in
    Target.of_predefined_macros dump
    |> Result.map_error (fun error -> Invalid_macros error)
  with Failed error -> Error error

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
