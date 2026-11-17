(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* open takes the lowest free descriptor and the lower standard ones are
   open by then, so /dev/null lands on the closed one. It is read-write,
   as LLVM opens it for itself, since a backend may abort when a write to
   its stderr fails. *)
let hold_standard_descriptors () =
  List.iter
    (fun standard ->
      match Unix.fstat standard with
      | _ -> ()
      | exception Unix.Unix_error (Unix.EBADF, _, _) ->
          ignore (Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0))
    [ Unix.stdin; Unix.stdout; Unix.stderr ]

(* Why a child did not reach the program: a system call that failed,
   with its name, or another exception, which is a bug in typec. *)
type failure = System_call of Unix.error * string | Bug of string

(* The status of a child that did not reach the program. The parent
   reads why from the pipe instead, unless the child died before it could
   write, and then reports this status as the program's. *)
let not_started_status = 127

(* start holds the standard descriptors open, so each copy is a new
   descriptor above them and no dup2 overwrites a copy that a later one
   reads. *)
let redirect ~stdin ~stdout ~stderr =
  let sources = List.map (Unix.dup ~cloexec:true) [ stdin; stdout; stderr ]
  in
  List.iter2
    (fun source standard -> Unix.dup2 ~cloexec:false source standard)
    sources
    [ Unix.stdin; Unix.stdout; Unix.stderr ]

let attempt_exec ~stdin ~stdout ~stderr program argv =
  try
    redirect ~stdin ~stdout ~stderr;
    Unix.execvp program argv
  with
  | Unix.Unix_error (error, call, _) -> System_call (error, call)
  | exn -> Bug (Printexc.to_string exn)

(* One catch-all around the whole child, which leaves only by exec or by
   _exit, so no at_exit handler or Fun.protect of typec runs in it and no
   output that typec buffered is written twice. A System_call message is
   far below PIPE_BUF, so its one write to the empty pipe is whole; a Bug
   message cut short fails to unmarshal, which is a bug report too. *)
let run_child ~stdin ~stdout ~stderr ~failure_output program argv =
  (try
     let failure = attempt_exec ~stdin ~stdout ~stderr program argv in
     let message = Marshal.to_bytes failure [] in
     ignore (Unix.write failure_output message 0 (Bytes.length message))
   with _ -> ());
  Unix._exit not_started_status

(* A signal that Signals records interrupts the read, which goes on. *)
let read_all fd =
  let buffer = Buffer.create 256 in
  let chunk = Bytes.create 256 in
  let rec read_rest () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | count ->
        Buffer.add_subbytes buffer chunk 0 count;
        read_rest ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_rest ()
  in
  read_rest ()

let rec reap pid =
  match Unix.waitpid [] pid with
  | _ -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap pid

let raise_failure program = function
  | System_call (error, call) -> raise (Unix.Unix_error (error, call, program))
  | Bug description ->
      failwith
        (Printf.sprintf "the child that was to start %S failed: %s" program
           description)

(* The write end of the pipe closes at the child's exec, so an empty read
   means the program started. Only the child ever holds the write end: the
   pipe is above the standard descriptors and close-on-exec, so no program
   inherits it. The message thus comes from a fork of this very process,
   with the same types, and Marshal reads it back safely. *)
let wait_for_exec ~failure_input pid program =
  let message =
    Fun.protect
      ~finally:(fun () -> Unix.close failure_input)
      (fun () -> read_all failure_input)
  in
  match message with
  | "" -> pid
  | _ ->
      reap pid;
      raise_failure program (Marshal.from_string message 0 : failure)

let start ~stdin ~stdout ~stderr command =
  hold_standard_descriptors ();
  let program = List.hd command in
  let argv = Array.of_list command in
  let failure_input, failure_output = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 -> run_child ~stdin ~stdout ~stderr ~failure_output program argv
  | pid ->
      Unix.close failure_output;
      wait_for_exec ~failure_input pid program
  | exception error ->
      Unix.close failure_input;
      Unix.close failure_output;
      raise error

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

let run ~stdin ~stdout ~stderr command =
  wait (start ~stdin ~stdout ~stderr command)
