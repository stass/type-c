(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The command line and TYPEC_CC are read here; the backend inherits the
   environment and is found through PATH. *)
let () =
  let arguments =
    match Array.to_list Sys.argv with
    | _program_name :: arguments -> arguments
    | [] -> []
  in
  Typec_driver.Command.run ~env_cc:(Sys.getenv_opt "TYPEC_CC") arguments
