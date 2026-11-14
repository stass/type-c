(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The [typec] command: choose the backend and hand it the command line. *)

val run : env_cc:string option -> string list -> 'a
(** [run ~env_cc arguments] performs the action that
    {!Invocation.of_command_line} reads from [arguments]. To forward, it
    replaces this process with the backend, so the backend's exit status,
    or the signal that ended it, is the status of [typec]. To print the
    target model, it prints {!Typec_sema.Target.to_string} of the model
    from {!Target_query.query} on stdout and exits with status 0. It never
    returns: when the command line is wrong, the backend cannot be started
    or gives no model, it prints one message on stderr and exits with a
    non-zero status. *)
