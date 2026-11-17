(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The manual page lists the options of typec and its own exit statuses
   in prose that no table generates, so this test reads the two lists
   from the page and compares them with the driver's tables. *)

open Typec_driver

let read_lines path =
  In_channel.with_open_text path In_channel.input_all
  |> String.split_on_char '\n'

(* Each line with the name of the .Sh section that holds it. *)
let with_sections lines =
  let tag (section, tagged) line =
    match String.split_on_char ' ' line with
    | ".Sh" :: words ->
        let name = String.concat " " words in
        (name, tagged)
    | _ -> (section, (section, line) :: tagged)
  in
  List.fold_left tag ("", []) lines |> snd |> List.rev

(* An item ".It Fl -cc Ns = Ns Ar path" documents "--cc=": Fl adds the
   leading '-', and a joined value follows "Ns =". *)
let option_of_item line =
  match String.split_on_char ' ' line with
  | ".It" :: "Fl" :: name :: "Ns" :: "=" :: _ -> Some ("-" ^ name ^ "=")
  | ".It" :: "Fl" :: name :: _ -> Some ("-" ^ name)
  | _ -> None

(* An item ".It 81" documents the status 81. *)
let status_of_item line =
  match String.split_on_char ' ' line with
  | [ ".It"; status ] -> int_of_string_opt status
  | _ -> None

let items_in section read lines =
  List.filter_map
    (fun (name, line) -> if name = section then read line else None)
    lines
  |> List.sort compare

(* Every status that a process can exit with, kept when it is one of
   typec's own failures. *)
let own_statuses =
  List.init 256 Fun.id
  |> List.filter (fun status -> Exit_status.of_code status <> None)

let report what ~page ~driver =
  if page = driver then true
  else begin
    Printf.eprintf "FAIL: the %s of the manual page are %s, the driver's %s\n"
      what (String.concat " " page) (String.concat " " driver);
    false
  end

let () =
  let lines = with_sections (read_lines Sys.argv.(1)) in
  let options_agree =
    report "options"
      ~page:(items_in "DESCRIPTION" option_of_item lines)
      ~driver:(List.sort compare Cc_option.typec_spellings)
  in
  let statuses_agree =
    report "exit statuses"
      ~page:
        (items_in "EXIT STATUS" status_of_item lines
        |> List.map string_of_int)
      ~driver:(List.map string_of_int own_statuses)
  in
  if not (options_agree && statuses_agree) then exit 1
