(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Starting backend programs and running one command of the pipeline. *)

val hold_standard_descriptors : unit -> unit
(** [hold_standard_descriptors ()] opens [/dev/null], read-write, on
    each of the standard descriptors that [typec] was started without, so
    that no descriptor that [typec] opens later takes its number: what
    [typec] or a backend writes there is discarded, and a read finds the
    end of the input. [typec] calls it before it opens any descriptor, and
    {!start} calls it too, so that its pipe is never a standard
    descriptor. It raises [Unix.Unix_error] when [/dev/null] cannot be
    opened. *)

val start :
  stdin:Unix.file_descr -> stdout:Unix.file_descr -> string list -> int
(** [start ~stdin ~stdout command] starts the program [List.hd command]
    with the argument vector [command], never through a shell, with
    [stdin] and [stdout] and the stderr, environment and working
    directory of [typec], and returns its process id without waiting for
    it. The program is found through [PATH] when its name has no slash.
    It raises [Unix.Unix_error] when the program cannot be started, after
    reaping the child that tried, so a program that starts and exits with
    any status, 127 included, is told apart from one that never ran.

    It forks, which the OCaml runtime refuses with [Failure] once a
    second domain has been spawned, so [typec] stays on one domain. *)

val run :
  stdin:Unix.file_descr ->
  stdout:Unix.file_descr ->
  string list ->
  Unix.process_status
(** [run ~stdin ~stdout command] starts [command] as {!start} does and
    waits for it to end. A signal that {!Signals} records while the
    program runs is passed on to it, so it ends as it would have without
    [typec]. It raises [Unix.Unix_error] when the program cannot be
    started. *)
