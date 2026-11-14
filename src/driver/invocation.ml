(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type action = Forward | Print_target
type t = { program : string; arguments : string list; action : action }
type error = Empty_cc_option

let cc_option_prefix = "--cc="
let print_target_option = "--print-target"

(* The backend when neither the command line nor TYPEC_CC names one. *)
let default_program = "cc"

let is_cc_option = String.starts_with ~prefix:cc_option_prefix

let cc_option_path option =
  let prefix_length = String.length cc_option_prefix in
  String.sub option prefix_length (String.length option - prefix_length)

(* The last --cc= wins, as a later option overrides an earlier one in cc. *)
let choose_program ~env_cc cc_paths =
  match (List.rev cc_paths, env_cc) with
  | last :: _, _ -> last
  | [], Some program when program <> "" -> program
  | [], _ -> default_program

let of_command_line ~env_cc arguments =
  let cc_options, arguments = List.partition is_cc_option arguments in
  let print_target_options, forwarded =
    List.partition (String.equal print_target_option) arguments
  in
  let action = if print_target_options = [] then Forward else Print_target in
  let cc_paths = List.map cc_option_path cc_options in
  if List.mem "" cc_paths then Error Empty_cc_option
  else
    let program = choose_program ~env_cc cc_paths in
    Ok { program; arguments = forwarded; action }

let error_message = function
  | Empty_cc_option -> "--cc= needs the path of a C compiler"
