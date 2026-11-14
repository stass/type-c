(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The backend command that a [typec] command line asks for.

    [typec] owns one option, [--cc=PATH]; every other argument belongs to
    the backend and keeps its position. *)

(** A backend command: the program to run and the arguments after its
    name. The program is never empty. *)
type t = private { program : string; arguments : string list }

(** Why a command line names no backend. *)
type error = Empty_cc_option  (** [--cc=] was given without a path. *)

val of_command_line :
  env_cc:string option -> string list -> (t, error) result
(** [of_command_line ~env_cc arguments] takes the backend from the last
    [--cc=PATH] in [arguments], else from [env_cc] (the value of
    [TYPEC_CC]) when it is set and not empty, else ["cc"]. The [--cc=]
    options are removed and every other argument is kept in order; [--cc]
    without [=] is not a [typec] option and is forwarded like any other. *)

val error_message : error -> string
