(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The exit statuses of [typec]'s own failures (design 13.2). A backend
    step that fails passes on the backend's own status instead, so these
    are chosen apart from the statuses a C compiler driver exits with. *)

type t =
  | Refused  (** a diagnostic about the source: the program is refused *)
  | Environment
      (** the command line, the backend or the system: the backend cannot
          be started or gives no target model, a file cannot be read or
          written *)
  | Internal
      (** an uncaught exception or a state that cannot happen: a bug in
          [typec] *)

val code : t -> int
(** The exit status of a failure. *)

val of_code : int -> t option
(** The failure whose status is the argument, if any. Any other status
    of [typec] is 0, the backend's, or 128 when a signal that ended a
    step does not end [typec] ({!Signals.end_by}). *)
