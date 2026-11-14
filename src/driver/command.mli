(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The [typec] command: choose the backend and hand it the command line. *)

val run : env_cc:string option -> string list -> 'a
(** [run ~env_cc arguments] replaces this process with the backend chosen
    by {!Invocation.of_command_line}, so the backend's exit status, or the
    signal that ended it, is the status of [typec]. It never returns: when
    the command line is wrong or the backend cannot be started, it prints
    one message on stderr and exits with a non-zero status. *)
