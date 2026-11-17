(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The backend command that a [typec] command line asks for.

    [typec] owns six options, [--cc=PATH], [--print-target], [--emit-c],
    [--emit-c-header],
    [--stats] and [--trap-function=NAME]; every other argument belongs to
    the backend and keeps its position. The command line is read with
    {!Command_line.read}, so an option of [typec] is one only where an
    option can stand: the value of [-o] is never one. *)

(** What [typec] does with the backend. *)
type action =
  | Compile
      (** Run the backend with the arguments, through the pipeline of
          {!Pipeline} when an input is a [.tc] file. *)
  | Emit_c  (** Write the C of the one [.tc] input ([--emit-c]). *)
  | Emit_c_header
      (** Write the C header of the one [.tci] input ([--emit-c-header],
          design 9.3). *)
  | Print_target
      (** Print the target model that the backend reports when it is run
          with the arguments as options ([--print-target]). *)
  | Print_version
      (** Print the release of [typec] and run nothing ([--version]). *)

(** A backend command: the program to run, the arguments after its name,
    the action, whether to report the counts of each [.tc] input
    ([--stats]), and how the C of a [.tc] input traps (design 10.5). The
    program is never empty, and the arguments hold no option of
    [typec]. *)
type t = private {
  program : string;
  arguments : Command_line.argument list;
  action : action;
  stats : bool;
  trap : Typec_emit.Trap.t;
}

(** Why a command line names no backend. *)
type error =
  | Empty_cc_option  (** [--cc=] was given without a path. *)
  | Invalid_trap_function of string
      (** A [--trap-function=], the first such, names no C identifier
          ({!Typec_emit.Trap.calling}); an empty [--cc=] goes first. *)
  | Emit_c_with_header
      (** [--emit-c] and [--emit-c-header] are both given; an empty
          [--cc=] goes first. *)

val of_command_line :
  env_cc:string option -> string list -> (t, error) result
(** [of_command_line ~env_cc arguments] takes the backend from the last
    [--cc=PATH] in [arguments], else from [env_cc] (the value of
    [TYPEC_CC]) when it is set and not empty, else ["cc"]. The action is
    [Print_version] when [--version] appears anywhere, else
    [Print_target] when [--print-target] does, else
    [Emit_c_header] when [--emit-c-header] does, else [Emit_c] when
    [--emit-c] does, else [Compile]; [--emit-c] with [--emit-c-header] is
    an error; [stats] is whether [--stats]
    appears; [trap] calls the function that the last
    [--trap-function=NAME] names, else is {!Typec_emit.Trap.builtin}.
    The [typec] options are removed and every other argument is kept in
    order; a look-alike such as [--cc] without [=] is not a [typec]
    option and is forwarded like any other. *)

val error_message : error -> string
