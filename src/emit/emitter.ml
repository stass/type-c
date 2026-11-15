(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp

type edit = { first : int; count : int; location : Location.t; text : string }

(* The newline in front starts the marker on a line of its own wherever
   the edit stands in a line. In a system header the marker carries flag
   3 and no enter or return flag, so the backend keeps exempting the
   header from warnings (design 13.4). *)
let marker (owner : File.t) (location : Location.t) =
  let system_flag = if owner.system_header then " 3" else "" in
  Printf.sprintf "\n# %d \"%s\"%s\n" location.line location.file system_flag

(* The bytes of the text that an edit replaces, as (start, stop). *)
let replaced_bytes (tokens : Token.t array) edit =
  let start = tokens.(edit.first).start in
  if edit.count = 0 then (start, start)
  else
    let last = tokens.(edit.first + edit.count - 1) in
    (start, last.start + last.length)

(* The presumed location of the line where the replaced bytes end: no
   token of cc -E output spans lines, so it is the line of the last token
   replaced, or of the token an insertion precedes. *)
let end_location (tokens : Token.t array) edit =
  if edit.count = 0 then tokens.(edit.first).location
  else tokens.(edit.first + edit.count - 1).location

(* The line markers between tokens of one file enter and leave other
   files in pairs, so a range in one file drops whole pairs. *)
let in_one_file (tokens : Token.t array) edit =
  let owner = tokens.(edit.first).owner in
  let rec from index =
    index = edit.first + edit.count
    || (tokens.(index).owner == owner && from (index + 1))
  in
  from edit.first

(* Each edit starts at or after the first token the one before it leaves
   alone, and ends within the tokens. *)
let check_edits tokens edits =
  let token_count = Array.length tokens in
  let check next edit =
    if
      edit.first < next || edit.count < 0
      || edit.first >= token_count
      || edit.count > token_count - edit.first
    then invalid_arg "Emitter.emit: edits out of order or out of range";
    if not (in_one_file tokens edit) then
      invalid_arg "Emitter.emit: an edit spans files";
    edit.first + edit.count
  in
  ignore (List.fold_left check 0 edits)

let emit (unit : Reader.t) edits =
  check_edits unit.tokens edits;
  let buffer = Buffer.create (String.length unit.text) in
  let copy start stop =
    Buffer.add_substring buffer unit.text start (stop - start)
  in
  (* [copied] is the end of the text copied so far. *)
  let apply copied edit =
    let start, stop = replaced_bytes unit.tokens edit in
    copy copied start;
    (* The edit lies in one file (check_edits). *)
    let owner = unit.tokens.(edit.first).owner in
    Buffer.add_string buffer (marker owner edit.location);
    Buffer.add_string buffer edit.text;
    Buffer.add_string buffer (marker owner (end_location unit.tokens edit));
    stop
  in
  let copied = List.fold_left apply 0 edits in
  copy copied (String.length unit.text);
  Buffer.contents buffer
