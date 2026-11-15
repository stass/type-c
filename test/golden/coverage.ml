(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* coverage FILE...: every rule of Typec_syntax.Rule has a negative golden
   case, which is a cram test among FILE whose expected output holds the
   rule's code; and no expected output holds a code that is no rule's.
   Cram fails a case whose output differs, so the expected outputs are
   what golden.exe prints. *)

module Codes = Set.Make (String)

let code_length = String.length "TC0000"

let is_digit c = c >= '0' && c <= '9'

(* A code is "TC" and four digits in brackets, as Rule.message ends a
   diagnostic. *)
let code_at line index =
  if index + code_length + 2 > String.length line then None
  else
    let code = String.sub line (index + 1) code_length in
    let digits = String.sub code 2 (code_length - 2) in
    if
      line.[index] = '['
      && line.[index + code_length + 1] = ']'
      && String.starts_with ~prefix:"TC" code
      && String.for_all is_digit digits
    then Some code
    else None

let codes_of_line codes line =
  let found = ref codes in
  String.iteri
    (fun index _ ->
      match code_at line index with
      | Some code -> found := Codes.add code !found
      | None -> ())
    line;
  !found

(* In a cram test, an output line is indented by two spaces and is neither
   a command ("  $ ") nor its continuation ("  > "). *)
let is_output line =
  String.starts_with ~prefix:"  " line
  && not
       (String.starts_with ~prefix:"  $ " line
       || String.starts_with ~prefix:"  > " line)

let codes_of_file codes path =
  In_channel.with_open_bin path In_channel.input_lines
  |> List.filter is_output
  |> List.fold_left codes_of_line codes

let report heading codes =
  if not (Codes.is_empty codes) then
    Printf.printf "%s: %s\n" heading
      (String.concat " " (Codes.elements codes))

let () =
  let files = List.tl (Array.to_list Sys.argv) in
  let tested = List.fold_left codes_of_file Codes.empty files in
  let rules =
    Codes.of_list (List.map Typec_syntax.Rule.code Typec_syntax.Rule.all)
  in
  let untested = Codes.diff rules tested in
  let unknown = Codes.diff tested rules in
  report "rules without a golden case" untested;
  report "codes of no rule" unknown;
  if not (Codes.is_empty untested && Codes.is_empty unknown) then exit 1
