(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type entry = { pattern : string; reason : string }
type t = entry list

exception Malformed of string

let read_entry number line =
  match String.index_opt line '\t' with
  | None -> raise (Malformed (Printf.sprintf "line %d: no tab" number))
  | Some tab ->
      let pattern = String.sub line 0 tab
      and reason = String.sub line (tab + 1) (String.length line - tab - 1) in
      if pattern = "" || String.trim reason = "" then
        raise
          (Malformed
             (Printf.sprintf "line %d: no pattern or no reason" number));
      { pattern; reason }

let is_entry line = String.trim line <> "" && line.[0] <> '#'

let read contents =
  let lines = String.split_on_char '\n' contents in
  let read_line (number, entries) line =
    let entries =
      if is_entry line then read_entry number line :: entries else entries
    in
    (number + 1, entries)
  in
  match List.fold_left read_line (1, []) lines with
  | _, entries -> Ok (List.rev entries)
  | exception Malformed message -> Error message

let rest_is_stars pattern p =
  let rest = String.sub pattern p (String.length pattern - p) in
  String.for_all (fun c -> c = '*') rest

(* Whether [pattern] matches all of [text]. On a mismatch the last [*]
   takes one more byte and matching resumes after it: taking more at an
   earlier [*] matches nothing the last could not, so the time is at
   most the product of the lengths. [resume] is the position in the
   pattern after the last [*] and the byte of [text] it took up to. *)
let matches pattern text =
  let pattern_length = String.length pattern
  and text_length = String.length text in
  let rec scan p t resume =
    if t = text_length then rest_is_stars pattern p
    else if p < pattern_length && pattern.[p] = '*' then
      scan (p + 1) t (Some (p + 1, t))
    else if p < pattern_length && pattern.[p] = text.[t] then
      scan (p + 1) (t + 1) resume
    else
      match resume with
      | Some (after_star, taken) ->
          scan after_star (taken + 1) (Some (after_star, taken + 1))
      | None -> false
  in
  scan 0 0 None

let reason entries line =
  List.find_map
    (fun entry ->
      if matches entry.pattern line then Some entry.reason else None)
    entries
