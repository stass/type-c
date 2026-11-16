(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp

type text = Code of string | Bracketed of string
type edit = { range : Reader.range; location : Location.t; text : text }

(* The newline in front starts the marker on a line of its own wherever
   the edit stands in a line. The marker repeats the flags in effect at
   [location] and no enter or return flag, so the backend keeps or ends
   the exemption of a system header from warnings as the marker in effect
   there did (design 13.4). *)
let marker (location : Location.t) =
  Printf.sprintf "\n# %d \"%s\"%s\n" location.line location.file
    (Location.flag_spelling location.flags)

(* The presumed location of the line where the replaced bytes end: no
   token of cc -E output spans lines and markers stand on lines of their
   own, so it is the location of the last token replaced, or of the token
   an insertion precedes, and the rest of that line is in its state. *)
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

(* The packing bracket of design 10.3, which lays [text] out with the
   packing of the command line and leaves the packing around it as it
   was. It must begin a line, as each of its pragmas stands on one
   (C11 6.10p2). *)
let bracket text =
  String.concat "\n"
    [ "#pragma pack(push)"; "#pragma pack()"; text; "#pragma pack(pop)" ]

(* The marker follows the pragmas of a bracket, so the text keeps the
   line of its construct and the pragmas take the line before it; the
   newline in front starts the bracket on a line of its own wherever the
   edit stands in a line. *)
let written location = function
  | Code text -> marker location ^ text
  | Bracketed text -> "\n" ^ bracket (marker location ^ text)

(* The edit as the backend reads it: between markers that give its
   location and then the location where the replaced tokens end. *)
let replacement (tokens : Token.t array) edit : Reader.replacement =
  let text =
    written edit.location edit.text ^ marker (end_location tokens edit.range)
  in
  { range = edit.range; text }

type lowered = { edits : edit list; assertions : string list }

(* The assertions are typec's own text, so their marker names no file of
   the unit, and a failure reads as typec's. Flag 3 exempts them from the
   warnings that judge the user's code, such as -Wc++-compat, as for a
   system header (design 13.4); a failed assertion is an error all the
   same. *)
let assertions_location : Location.t =
  { file = "<typec>"; line = 1; flags = System }

let assertion_block = function
  | [] -> ""
  | assertions ->
      marker assertions_location
      ^ String.concat "" (List.map (fun line -> line ^ "\n") assertions)

(* Each structure stands in a bracket inside a region of its own packing,
   so the two are aligned alike only where '#pragma pack()' restores the
   packing of the command line in both, whatever it is. The outer push
   and pop keep the packing around the probe. *)
let packing_probe =
  let structure number =
    Printf.sprintf "struct __tc_pack_probe_%d { char c; int i; };" number
  in
  String.concat "\n"
    [
      "#pragma pack(push)";
      "#pragma pack(1)";
      bracket (structure 1);
      "#pragma pack(2)";
      bracket (structure 2);
      "#pragma pack(pop)";
      Assumptions.assertion
        ~holds:
          "_Alignof(struct __tc_pack_probe_1) \
           == _Alignof(struct __tc_pack_probe_2)"
        ~assumes:"'#pragma pack()' restores the packing of the command line"
        ~option:"-fapple-pragma-pack or -fxl-pragma-pack";
    ]

let is_bracketed edit =
  match edit.text with Bracketed _ -> true | Code _ -> false

(* The probe is a fact of the backend that every bracket rests on, so
   emission, the one place that writes a bracket, adds it. *)
let probes edits =
  if List.exists is_bracketed edits then [ packing_probe ] else []

(* Reader.rewrite checks the order of the ranges. *)
let emit (unit : Reader.t) { edits; assertions } =
  List.iter (check_one_file unit.tokens) edits;
  Reader.rewrite unit (List.map (replacement unit.tokens) edits)
  ^ assertion_block (assertions @ probes edits)
