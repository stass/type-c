(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp

type edit = { range : Reader.range; location : Location.t; text : string }

(* The newline in front starts the marker on a line of its own wherever
   the edit stands in a line. In a system header the marker carries flag
   3 and no enter or return flag, so the backend keeps exempting the
   header from warnings (design 13.4). *)
let marker (owner : File.t) (location : Location.t) =
  let system_flag = if owner.system_header then " 3" else "" in
  Printf.sprintf "\n# %d \"%s\"%s\n" location.line location.file system_flag

(* The presumed location of the line where the replaced bytes end: no
   token of cc -E output spans lines, so it is the line of the last token
   replaced, or of the token an insertion precedes. *)
let end_location (tokens : Token.t array) range =
  tokens.(Reader.end_token range).location

(* The line markers between tokens of one file enter and leave other
   files in pairs, so a range in one file drops whole pairs. *)
let in_one_file (tokens : Token.t array) (range : Reader.range) =
  let owner = tokens.(range.first).owner in
  let rec from index =
    index = range.first + range.count
    || (tokens.(index).owner == owner && from (index + 1))
  in
  from range.first

let check_one_file tokens edit =
  if not (in_one_file tokens edit.range) then
    invalid_arg "Emitter.emit: an edit spans files"

(* The edit as the backend reads it: between markers that give its
   location and then the location where the replaced tokens end. *)
let replacement (tokens : Token.t array) edit : Reader.replacement =
  let owner = tokens.(edit.range.first).owner in
  let text =
    marker owner edit.location ^ edit.text
    ^ marker owner (end_location tokens edit.range)
  in
  { range = edit.range; text }

(* Reader.rewrite checks the order of the ranges. *)
let emit (unit : Reader.t) edits =
  List.iter (check_one_file unit.tokens) edits;
  Reader.rewrite unit (List.map (replacement unit.tokens) edits)
