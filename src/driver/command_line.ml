(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type argument =
  | Input of { path : string; type_c : bool }
  | Option of { role : Cc_option.role; words : string list; value : string }
  | Truncated of string list

(* The language that cc gives an input when no -x is in effect. *)
let no_language = "none"

let is_option word =
  word <> "-"
  && (String.starts_with ~prefix:"-" word
     || String.starts_with ~prefix:"@" word)

(* The first [count] of [words] and the rest, or None when there are
   fewer. *)
let rec split_at count words =
  match (count, words) with
  | 0, rest -> Some ([], rest)
  | _, [] -> None
  | count, word :: rest ->
      Option.map
        (fun (taken, rest) -> (word :: taken, rest))
        (split_at (count - 1) rest)

let read words =
  (* [language] is the value of the last -x, which cc applies to the
     inputs after it. *)
  let rec read_from language arguments = function
    | [] -> List.rev arguments
    | word :: rest when not (is_option word) ->
        let type_c =
          language = no_language
          && Filename.check_suffix word Typec_cpp.File.source_suffix
        in
        read_from language (Input { path = word; type_c } :: arguments) rest
    | word :: rest -> (
        let option = Cc_option.classify word in
        match split_at option.separate_values rest with
        | None -> List.rev (Truncated (word :: rest) :: arguments)
        | Some (values, rest) ->
            let value =
              match values with
              | first :: _ when option.joined_value = "" -> first
              | _ -> option.joined_value
            in
            let language =
              if option.role = Cc_option.Language then value else language
            in
            let argument =
              Option { role = option.role; words = word :: values; value }
            in
            read_from language (argument :: arguments) rest)
  in
  read_from no_language [] words

let words arguments =
  List.concat_map
    (function
      | Input { path; _ } -> [ path ]
      | Option { words; _ } | Truncated words -> words)
    arguments
