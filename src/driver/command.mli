(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The [typec] command: choose the backend and hand it the command line. *)

val outer_cc_variable : string
(** [outer_cc_variable] is ["TYPEC_OUTER_CC"], the environment variable
    that {!run} sets to the name of the backend before it runs one. *)

val run : env_cc:string option -> outer_cc:string option -> string list -> 'a
(** [run ~env_cc ~outer_cc arguments] performs the action that
    {!Invocation.of_command_line} reads from [arguments]. [outer_cc] is
    the value of {!outer_cc_variable} in the environment of [typec].

    Without a [.tc] input it forwards: it replaces this process with the
    backend, so the backend's exit status, or the signal that ended it,
    is the status of [typec]. With one, or with [--emit-c], it runs the
    commands of {!Pipeline.plan} one after the other in a directory made
    by {!Temp_dir.create}, which it removes on every way out, and stops
    at the first that fails. Before them it reads the model from
    {!Target_query.query} with the plan's [target_options], and runs
    each command for the compiler that the model names. Between the
    preprocessing and the compile step of each translation it runs
    {!Front_end.lower} on the text for that model, and emits the text
    with the edits and assertions it gives. When a
    command fails, [typec] exits with its status, or ends by the signal
    that ended it, or by a signal that {!Signals} caught. To print the
    target model, it prints {!Typec_sema.Target.to_string} of the model
    from {!Target_query.query} on stdout and exits with status 0. To
    print the version, it runs the backend with [--version] alone, then
    prints ["typec "] and {!Version.release} on a last line whatever the
    backend did, and exits with the backend's status or ends by its
    signal; a backend that cannot be started is an [Environment]
    failure.

    It never returns. When [typec] fails itself it prints one message
    on stderr and exits with the {!Exit_status.code} of the failure:
    [Refused] when the reader or the front end refuses the preprocessed
    text; [Environment] when the command line is wrong, the backend
    cannot be started or gives no model, [outer_cc] is given, or a file
    cannot be read or written; [Internal] when an exception escapes,
    which is a bug.

    It sets {!outer_cc_variable} before it runs a backend, so every
    process below the backend inherits it, and a [typec] started there
    is given [outer_cc] and fails before reading [arguments]: a backend
    that is [typec] itself, or runs it, would otherwise start [typec]
    again forever.

    A standard descriptor that [typec] is started without is [/dev/null]
    for [typec] and for the backend, as
    {!Process.hold_standard_descriptors} says. *)
