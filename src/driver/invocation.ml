(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type action = Compile | Emit_c | Print_target

type t = {
  program : string;
  arguments : Command_line.argument list;
  action : action;
  stats : bool;
}

type error = Empty_cc_option

(* The backend when neither the command line nor TYPEC_CC names one. *)
let default_program = "cc"

(* The option of typec that [argument] is, with its value. *)
let typec_option = function
  | Command_line.Option { role = Typec option; value; _ } ->
      Some (option, value)
  | _ -> None

(* The last --cc= wins, as a later option overrides an earlier one in cc. *)
let choose_program ~env_cc cc_paths =
  match (List.rev cc_paths, env_cc) with
  | last :: _, _ -> last
  | [], Some program when program <> "" -> program
  | [], _ -> default_program

let choose_action typec_options =
  let given option = List.mem_assoc option typec_options in
  if given Cc_option.Print_target then Print_target
  else if given Cc_option.Emit_c then Emit_c
  else Compile

let of_command_line ~env_cc words =
  let arguments = Command_line.read words in
  let typec_options = List.filter_map typec_option arguments in
  let backend_arguments =
    List.filter (fun argument -> typec_option argument = None) arguments
  in
  let cc_paths =
    List.filter_map
      (fun (option, value) ->
        if option = Cc_option.Cc then Some value else None)
      typec_options
  in
  if List.mem "" cc_paths then Error Empty_cc_option
  else
    Ok
      {
        program = choose_program ~env_cc cc_paths;
        arguments = backend_arguments;
        action = choose_action typec_options;
        stats = List.mem_assoc Cc_option.Stats typec_options;
      }

let error_message = function
  | Empty_cc_option -> "--cc= needs the path of a C compiler"
