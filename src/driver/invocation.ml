(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type action = Compile | Emit_c | Print_target

type t = {
  program : string;
  arguments : Command_line.argument list;
  action : action;
  stats : bool;
  trap : Typec_emit.Trap.t;
}

type error = Empty_cc_option | Invalid_trap_function of string

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

(* The last --trap-function= wins, as the last --cc= does, and an invalid
   one is an error wherever it stands, as an empty --cc= is. *)
let choose_trap typec_options =
  let choose chosen (option, value) =
    match (chosen, option) with
    | Error _, _ -> chosen
    | Ok _, Cc_option.Trap_function -> (
        match Typec_emit.Trap.calling value with
        | Some trap -> Ok trap
        | None -> Error (Invalid_trap_function value))
    | Ok _, _ -> chosen
  in
  List.fold_left choose (Ok Typec_emit.Trap.builtin) typec_options

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
    match choose_trap typec_options with
    | Error error -> Error error
    | Ok trap ->
        Ok
          {
            program = choose_program ~env_cc cc_paths;
            arguments = backend_arguments;
            action = choose_action typec_options;
            stats = List.mem_assoc Cc_option.Stats typec_options;
            trap;
          }

(* %S escapes every byte outside printable ASCII, so the name cannot
   reach the terminal as a control sequence. *)
let error_message = function
  | Empty_cc_option -> "--cc= needs the path of a C compiler"
  | Invalid_trap_function name ->
      Printf.sprintf "--trap-function= needs an ASCII C identifier, not %S"
        name
