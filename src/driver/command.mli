(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The [typec] command: choose the backend and hand it the command line. *)

val run : env_cc:string option -> string list -> 'a
(** [run ~env_cc arguments] performs the action that
    {!Invocation.of_command_line} reads from [arguments].

    Without a [.tc] input it forwards: it replaces this process with the
    backend, so the backend's exit status, or the signal that ended it,
    is the status of [typec]. With one, or with [--emit-c], it runs the
    commands of {!Pipeline.plan} one after the other in a directory made
    by {!Temp_dir.create}, which it removes on every way out, and stops
    at the first that fails. Between the preprocessing and the compile
    step of each translation it runs {!Front_end.lower} on the text, for
    the model from {!Target_query.query} with the translation's
    [target_options], and emits the text with the edits it gives. When a
    command fails, [typec] exits with its status, or ends by the signal
    that ended it, or by a signal that {!Signals} caught. To print the
    target model, it prints {!Typec_sema.Target.to_string} of the model
    from {!Target_query.query} on stdout and exits with status 0.

    It never returns. When [typec] fails itself it prints one message
    on stderr and exits with the {!Exit_status.code} of the failure:
    [Refused] when the reader or the front end refuses the preprocessed
    text; [Environment] when the command line is wrong, the backend
    cannot be started or gives no model, or a file cannot be read or
    written; [Internal] when an exception escapes, which is a bug. *)
