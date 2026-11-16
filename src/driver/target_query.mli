(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Ask the backend for the target model it compiles for. *)

(** Why the backend gave no target model. *)
type error =
  | Exited of int  (** The backend exited with this non-zero status. *)
  | Ended_by_signal of int  (** The signal that ended the backend. *)
  | Output_too_long  (** More output than any macro dump has. *)
  | Invalid_macros of Typec_sema.Target.error

val query :
  program:string -> string list -> (Typec_sema.Target.t, error) result
(** [query ~program options] runs [program options -dM -E -x c /dev/null]
    with an argument vector, reads the predefined macros it prints on
    stdout and builds the target model from them. The backend inherits
    stdin, stderr and the environment, and [program] is found through
    [PATH] when it has no slash. It raises [Unix.Unix_error] when a
    system call fails, as when the backend cannot be started; the pipe is
    closed and the backend reaped on every path. The read ends when every
    process holding the backend's stdout has closed it, so a backend that
    leaves a daemon with that stdout makes the query wait for the daemon.

    The options are passed as they are, so the caller chooses them: those
    of the compilation that select the target or the dialect, such as
    [-m32], [-funsigned-char] or [-std=gnu17]. Inputs, [-o] and
    dependency options such as [-M] change what the backend prints or
    where, so they must not be among them. *)

val error_message : program:string -> error -> string
