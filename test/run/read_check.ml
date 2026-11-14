(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* read_check FILE NAME...: reads the cc -E output FILE, checks that its
   tokens and gaps spell it and that the gaps hold only white space and
   line markers, and then prints, for each NAME, the owners of the tokens
   whose presumed file has the base name NAME, and the number of
   #pragma typec lines. *)

open Typec_cpp
open Typec_test_support

let fail message =
  prerr_endline ("read_check: " ^ message);
  exit 1

let read_file path = In_channel.with_open_bin path In_channel.input_all

let describe_owner (owner : File.t) =
  Filename.basename owner.name
  ^ if owner.system_header then " (system header)" else ""

(* The owners of the tokens presumed to come from [name], in the order
   they first appear. *)
let owners_of (result : Reader.t) name =
  Array.fold_left
    (fun owners (token : Token.t) ->
      let owner = describe_owner token.owner in
      if Filename.basename token.location.file = name
         && not (List.mem owner owners)
      then owner :: owners
      else owners)
    [] result.tokens
  |> List.rev

let show_owners result name =
  match owners_of result name with
  | [] -> Printf.printf "%s: no tokens\n" name
  | owners -> Printf.printf "%s: %s\n" name (String.concat ", " owners)

let count_typec_pragmas (result : Reader.t) =
  Array.fold_left
    (fun count (token : Token.t) ->
      if token.kind = Token.Typec_pragma then count + 1 else count)
    0 result.tokens

let () =
  match Array.to_list Sys.argv with
  | _ :: path :: names -> (
      match Reader.read ~name:path (read_file path) with
      | Error error -> fail (Reader.error_message error)
      | Ok result ->
          if not (Spans.spell_text result) then
            fail "the tokens and gaps do not spell the text";
          if not (Spans.gaps_are_layout result) then
            fail "a gap holds more than white space and line markers";
          List.iter (show_owners result) names;
          let typec_pragmas = count_typec_pragmas result in
          Printf.printf "#pragma typec lines: %d\n" typec_pragmas)
  | _ -> fail "usage: read_check FILE NAME..."
