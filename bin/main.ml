(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The command line, TYPEC_CC and the mark of an outer typec are read
   here; the backend inherits the environment, with the mark that Command
   sets, and is found through PATH. *)
let () =
  let arguments =
    match Array.to_list Sys.argv with
    | _program_name :: arguments -> arguments
    | [] -> []
  in
  let outer_cc = Sys.getenv_opt Typec_driver.Command.outer_cc_variable in
  Typec_driver.Command.run ~env_cc:(Sys.getenv_opt "TYPEC_CC") ~outer_cc
    arguments
