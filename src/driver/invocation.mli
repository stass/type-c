(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The backend command that a [typec] command line asks for.

    [typec] owns two options, [--cc=PATH] and [--print-target]; every other
    argument belongs to the backend and keeps its position. *)

(** What [typec] does with the backend. *)
type action =
  | Forward  (** Run the backend with the arguments. *)
  | Print_target
      (** Print the target model that the backend reports when it is run
          with the arguments as options ([--print-target]). *)

(** A backend command: the program to run, the arguments after its name
    and the action. The program is never empty. *)
type t = private {
  program : string;
  arguments : string list;
  action : action;
}

(** Why a command line names no backend. *)
type error = Empty_cc_option  (** [--cc=] was given without a path. *)

val of_command_line :
  env_cc:string option -> string list -> (t, error) result
(** [of_command_line ~env_cc arguments] takes the backend from the last
    [--cc=PATH] in [arguments], else from [env_cc] (the value of
    [TYPEC_CC]) when it is set and not empty, else ["cc"]. The action is
    [Print_target] when [--print-target] appears anywhere, else [Forward].
    The [typec] options are removed and every other argument is kept in
    order; a look-alike such as [--cc] without [=] is not a [typec] option
    and is forwarded like any other. *)

val error_message : error -> string
