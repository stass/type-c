(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type outcome = { status : Unix.process_status; cpu_seconds : float }

(* The status of a child whose exec fails, as a shell reports it. *)
let cannot_start = 127

let with_dev_null f =
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close null) (fun () -> f null)

(* The child only redirects and execs, so that nothing of the parent,
   such as its buffered output, runs twice. *)
let spawn ~cwd ~stdout ~stderr command =
  let argv = Array.of_list command in
  with_dev_null (fun null ->
      flush_all ();
      match Unix.fork () with
      | 0 -> (
          try
            Unix.chdir cwd;
            Unix.dup2 ~cloexec:false null Unix.stdin;
            Unix.dup2 ~cloexec:false stdout Unix.stdout;
            Unix.dup2 ~cloexec:false stderr Unix.stderr;
            Unix.execvp argv.(0) argv
          with _ -> Unix._exit cannot_start)
      | pid -> pid)

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let children_cpu_seconds () =
  let times = Unix.times () in
  times.Unix.tms_cutime +. times.Unix.tms_cstime

let run ~cwd ~stdout ~stderr command =
  let before = children_cpu_seconds () in
  let status = wait (spawn ~cwd ~stdout ~stderr command) in
  { status; cpu_seconds = children_cpu_seconds () -. before }

let first_line ~cwd command =
  let output, input = Unix.pipe ~cloexec:true () in
  let channel = Unix.in_channel_of_descr output in
  let text, status =
    Fun.protect
      ~finally:(fun () -> In_channel.close channel)
      (fun () ->
        let pid =
          Fun.protect
            ~finally:(fun () -> Unix.close input)
            (fun () ->
              with_dev_null (fun null ->
                  spawn ~cwd ~stdout:input ~stderr:null command))
        in
        let text = In_channel.input_all channel in
        (text, wait pid))
  in
  match (status, String.split_on_char '\n' text) with
  | Unix.WEXITED 0, line :: _ when line <> "" -> Some line
  | _ -> None

let describe = function
  | Unix.WEXITED code -> Printf.sprintf "exited with %d" code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      Printf.sprintf "ended by signal %d" signal
