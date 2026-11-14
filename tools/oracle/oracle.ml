(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The Clang half of the typing oracle (README, "Typing oracle"): runs
   Clang's JSON AST dump on a preprocessed file and writes a record of
   each expression in it.

     oracle CC INPUT OUTPUT [OPTION...]

   CC is Clang, found through PATH when it has no slash, and the options
   go to it, such as -std=gnu11 or a --target. The records go to OUTPUT,
   one per line in the format of Record.to_line; it is written in full
   or not at all. Exit status: 0 on success, 1 when Clang fails or its
   output is refused, 2 for a wrong command line. *)

exception Failed of string

let usage () =
  prerr_endline "usage: oracle CC INPUT OUTPUT [OPTION...]";
  exit 2

(* -w: the oracle reads types, and warnings would bury Clang's errors.
   The -- keeps an input whose name starts with a dash a file. *)
let clang_command cc input options =
  [ cc; "-Xclang"; "-ast-dump=json"; "-fsyntax-only"; "-w" ]
  @ options
  @ [ "-x"; "cpp-output"; "--"; input ]

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let describe = function
  | Unix.WEXITED code -> Printf.sprintf "exited with %d" code
  | Unix.WSIGNALED signal ->
      Printf.sprintf "was killed by %s" (Sys.signal_to_string signal)
  | Unix.WSTOPPED signal ->
      Printf.sprintf "was stopped by %s" (Sys.signal_to_string signal)

(* Starts Clang with its stdout on a pipe, its stdin /dev/null and our
   stderr, so that its diagnostics are seen. *)
let start_clang command =
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDONLY; O_CLOEXEC ] 0 in
  let program = List.hd command in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Unix.close write_end;
        Unix.close null)
      (fun () ->
        Unix.create_process program (Array.of_list command) null write_end
          Unix.stderr)
  in
  (pid, Unix.in_channel_of_descr read_end)

(* Reads the rest of Clang's output unchecked once the reader has
   refused it, so that Clang ends as it would have, not of a broken
   pipe, and its status means what it says. *)
let discard channel =
  let buffer = Bytes.create 65536 in
  while input channel buffer 0 (Bytes.length buffer) > 0 do
    ()
  done

let read_records ~input ~input_size channel output =
  let write_line record =
    output_string output (Record.to_line record);
    output_char output '\n'
  in
  let result = Clang_ast.read ~input ~input_size channel write_line in
  if Result.is_error result then discard channel;
  result

(* Clang's status is checked first: when it fails, its output is cut
   short and the reader's complaint about it says nothing new. *)
let records ~cc ~input ~options output =
  let input_size = (Unix.stat input).st_size in
  let pid, channel = start_clang (clang_command cc input options) in
  let result =
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> read_records ~input ~input_size channel output)
  in
  match (wait pid, result) with
  | Unix.WEXITED 0, Ok summary -> summary
  | Unix.WEXITED 0, Error message -> raise (Failed message)
  | status, _ -> raise (Failed (cc ^ " " ^ describe status))

(* The records go to a new temporary file beside OUTPUT, renamed into
   place once they are complete, so that a reader of OUTPUT never sees
   part of them. Its permissions are those the umask leaves, as for a
   file the oracle would create. *)
let run ~cc ~input ~output ~options =
  let partial, channel =
    Filename.open_temp_file ~mode:[ Open_binary ] ~perms:0o666
      ~temp_dir:(Filename.dirname output)
      (Filename.basename output) ".part"
  in
  match
    let summary = records ~cc ~input ~options channel in
    close_out channel;
    Sys.rename partial output;
    summary
  with
  | summary ->
      Printf.printf "%s: %d expressions, %d without a source range\n" input
        summary.Clang_ast.expressions summary.without_range
  | exception error ->
      close_out_noerr channel;
      (try Sys.remove partial with Sys_error _ -> ());
      raise error

let () =
  match Array.to_list Sys.argv with
  | _ :: cc :: input :: output :: options -> (
      try run ~cc ~input ~output ~options with
      | Failed message ->
          Printf.eprintf "oracle: %s: %s\n" input message;
          exit 1
      | Sys_error message ->
          Printf.eprintf "oracle: %s\n" message;
          exit 1
      | Unix.Unix_error (error, call, argument) ->
          Printf.eprintf "oracle: %s %s: %s\n" call argument
            (Unix.error_message error);
          exit 1)
  | _ -> usage ()
