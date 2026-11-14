(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The typec half of the typing oracle (README, "Typing oracle"): the
   type typec gives each expression of a preprocessed file, keyed by its
   byte range as the oracle's records are.

     typec_dump CC INPUT [OPTION...]

   CC and the options give the target model and the dialect, as for
   typec. Each line is FIRST LIMIT CATEGORY TYPE, separated by tabs:
   the range [FIRST, LIMIT) in INPUT, lvalue or rvalue, and the type
   before the conversions of its context as Type_name.of_ctype spells
   it. Exit status: 0 on success, 1 when typec refuses INPUT or the
   model cannot be had, 2 for a wrong command line. *)

open Typec_sema

let dump ~cc ~input ~options =
  let dialect, target = Typec_unit.model ~cc options in
  let contents = In_channel.with_open_bin input In_channel.input_all in
  match Typec_unit.read dialect target ~name:input contents with
  | Error error -> failwith (Typec_cpp.Reader.error_message error)
  | Ok unit ->
      let print (expression : Typec_unit.expression) =
        Printf.printf "%d\t%d\t%s\t%s\n" expression.first expression.limit
          (Typec_unit.category expression.typed)
          (Type_name.of_ctype expression.typed.expression_type)
      in
      List.iter print
        (Typec_unit.expressions unit ~below:(String.length contents))

let () =
  match Array.to_list Sys.argv with
  | _ :: cc :: input :: options -> (
      try dump ~cc ~input ~options with
      | Failure message | Sys_error message ->
          Printf.eprintf "typec_dump: %s: %s\n" input message;
          exit 1
      | Unix.Unix_error (error, call, argument) ->
          Printf.eprintf "typec_dump: %s %s: %s\n" call argument
            (Unix.error_message error);
          exit 1)
  | _ ->
      prerr_endline "usage: typec_dump CC INPUT [OPTION...]";
      exit 2
