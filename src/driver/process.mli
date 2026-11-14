(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Running one backend command of the pipeline. *)

val run :
  stdin:Unix.file_descr ->
  stdout:Unix.file_descr ->
  string list ->
  Unix.process_status
(** [run ~stdin ~stdout command] starts the program [List.hd command]
    with the argument vector [command], never through a shell, with
    [stdin] and [stdout] and the stderr and environment of [typec], and
    waits for it to end. The program is found through [PATH] when its
    name has no slash. A signal that {!Signals} records while the program
    runs is passed on to it, so it ends as it would have without
    [typec]. It raises [Unix.Unix_error] when the program cannot be
    started. *)
