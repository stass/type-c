(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The signals that end [typec] while it runs the pipeline: SIGHUP,
    SIGINT, SIGPIPE, SIGQUIT and SIGTERM.

    Once {!catch} is called, such a signal is only recorded, and the
    pipeline acts on it between its steps, so that it removes its
    temporary directory before it ends by the same signal. Any other
    signal that ends [typec], such as SIGKILL, leaves the directory
    behind. *)

val catch : unit -> unit
(** [catch ()] records each of the signals from now on, except one that
    was ignored when [typec] started: it stays ignored, as it is for the
    backend, which inherits it. The backend gets the default action for
    the others, as it would without [typec]. *)

val caught : unit -> int option
(** The first signal recorded, if any. *)

val end_by : int -> 'a
(** [end_by signal] ends [typec] by [signal], as its default action
    does, so that the caller sees the same status as from the backend
    that [signal] ended. *)
