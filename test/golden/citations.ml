(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* citations FILE...: no expected output of a cram test among FILE says
   the word "design". A diagnostic says what is wrong and how to fix it
   in the terms of the user's text; the rule name in its brackets is the
   reference, and the catalogue maps that name to the clause of the
   design. The check reads every output line, so a test names nothing in
   its source "design". It sees only the messages that the tests print. *)

let word = "design"

let is_letter c =
  match c with 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false

(* Whether [line] has [word] at [index], not inside a longer word such as
   "designator". *)
let word_at line index =
  let after = index + String.length word in
  let letter_at i = i >= 0 && i < String.length line && is_letter line.[i] in
  after <= String.length line
  && String.lowercase_ascii (String.sub line index (String.length word))
     = word
  && (not (letter_at (index - 1)))
  && not (letter_at after)

let says_word line =
  let rec from index =
    index < String.length line && (word_at line index || from (index + 1))
  in
  from 0

let citing_lines path =
  Typec_test_support.Cram.output_lines path
  |> List.filter says_word
  |> List.map (fun line -> path ^ ":" ^ line)

let () =
  let files = List.tl (Array.to_list Sys.argv) in
  let citing = List.concat_map citing_lines files in
  List.iter print_endline citing;
  if citing <> [] then exit 1
