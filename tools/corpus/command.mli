(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Running the commands of a corpus build. A command is an argument
    vector whose first element names the program, found through [PATH]
    when it has no slash; it never goes through a shell, and its stdin
    is [/dev/null]. Each function raises [Unix.Unix_error] when no
    process can be made. *)

type outcome = {
  status : Unix.process_status;
  cpu_seconds : float;
      (** the user and system time of the command and of the processes
          it waited for *)
}

val run :
  cwd:string ->
  stdout:Unix.file_descr ->
  stderr:Unix.file_descr ->
  string list ->
  outcome
(** [run ~cwd ~stdout ~stderr command] runs [command] in the directory
    [cwd] and waits for it. A program that cannot be started ends with
    status 127. *)

val first_line : cwd:string -> string list -> string option
(** [first_line ~cwd command] is the first line [command] prints on
    stdout when it succeeds; its stderr is discarded. *)

val describe : Unix.process_status -> string
(** How a command ended, as in "exited with 1". *)
