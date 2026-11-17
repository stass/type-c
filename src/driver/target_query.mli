(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Ask the backend for the target model it compiles for. *)

(** Why the backend gave no target model. *)
type error =
  | Exited of int  (** The backend exited with this non-zero status. *)
  | Ended_by_signal of int  (** The signal that ended the backend. *)
  | Output_too_long  (** More output than any macro dump has. *)
  | Invalid_macros of Typec_sema.Target.error
  | Neither_enumeration_probe of string list
      (** Neither probe of the enumeration representation compiled under
          these options. *)
  | Both_enumeration_probes of string list
      (** Both probes compiled under these options. *)
  | Probe_ended_by_signal of string list
      (** A signal ended the backend compiling a probe under these
          options. *)
  | No_temporary_directory of string
      (** Why the directory of the probes' files could not be made. *)

val query :
  program:string -> string list -> (Typec_sema.Target.t, error) result
(** [query ~program options] runs [program options -dM -E -x c /dev/null]
    with an argument vector, reads the predefined macros it prints on
    stdout and builds the target model from them. It then learns the
    enumeration representation by two probe compiles,
    [program options -fsyntax-only -w -dumpdir DIR/ -x c -], each reading
    its text from a pipe and writing to [/dev/null], with the files that
    an option makes it write in a temporary [DIR]; exactly one must exit
    with status 0, and it names the representation. The macro dump inherits stdin and
    stderr, every run the environment, and [program] is found through
    [PATH] when it has no slash. It raises [Unix.Unix_error] when a
    system call fails, as when the backend cannot be started; every pipe
    is closed and the backend reaped on every path. The read ends when every
    process holding the backend's stdout has closed it, so a backend that
    leaves a daemon with that stdout makes the query wait for the daemon.

    The options are passed as they are, so the caller chooses them: those
    of the compilation that select the target or the dialect, such as
    [-m32], [-funsigned-char] or [-std=gnu17]. Inputs, [-o] and
    dependency options such as [-M] change what the backend prints or
    where, so they must not be among them. *)

val error_message : program:string -> error -> string
