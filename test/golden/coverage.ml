(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* coverage FILE...: every rule of Typec_syntax.Rule has a negative golden
   case, which is a cram test among FILE whose expected output holds the
   rule's name; and no expected output holds a name that is no rule's.
   Cram fails a case whose output differs, so the expected outputs are
   what golden.exe prints. *)

module Names = Set.Make (String)

(* Reader.error_message marks a diagnostic as an error, and Rule.message
   ends one about a rule with the rule's name in brackets. *)
let error_mark = ": error: "

let contains line part =
  let length = String.length part in
  let rec from index =
    index + length <= String.length line
    && (String.sub line index length = part || from (index + 1))
  in
  from 0

let name_of_line line =
  let closing = String.length line - 1 in
  match String.rindex_opt line '[' with
  | Some opening
    when contains line error_mark && String.ends_with ~suffix:"]" line ->
      Some (String.sub line (opening + 1) (closing - opening - 1))
  | Some _ | None -> None

let names_of_line names line =
  match name_of_line line with
  | Some name -> Names.add name names
  | None -> names

let names_of_file names path =
  Typec_test_support.Cram.output_lines path
  |> List.fold_left names_of_line names

let report heading names =
  if not (Names.is_empty names) then
    Printf.printf "%s: %s\n" heading
      (String.concat " " (Names.elements names))

let () =
  let files = List.tl (Array.to_list Sys.argv) in
  let tested = List.fold_left names_of_file Names.empty files in
  let rules =
    Names.of_list (List.map Typec_syntax.Rule.name Typec_syntax.Rule.all)
  in
  let untested = Names.diff rules tested in
  let unknown = Names.diff tested rules in
  report "rules without a golden case" untested;
  report "names of no rule" unknown;
  if not (Names.is_empty untested && Names.is_empty unknown) then exit 1
