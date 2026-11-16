(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type piece = { text : string; location : Location.t }

let token (unit : Reader.t) index =
  let token = unit.tokens.(index) in
  match token.kind with
  | Pragma _ | Typec_pragma | Punctuator Hash -> None
  | Identifier _ | Number | Character _ | String _ | Punctuator _ ->
      Some { text = Reader.spelling unit token; location = token.location }

(* The bytes of typec's own text: those of identifiers, UTF-8 included,
   the blank, and the punctuators of C but for '#', '%', '?', '/' and
   '\\'. They spell no directive ('#', '%:', '??='), line splice,
   comment, line break or string literal, so no pragma line either, as
   the _Pragma operator takes a string literal (C11 6.10.9). *)
let is_plain_byte = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$' | ' ' -> true
  | '(' | ')' | '[' | ']' | '{' | '}' | ';' | ',' | '.' | ':' -> true
  | '=' | '*' | '&' | '!' | '<' | '>' | '-' | '+' | '|' | '~' | '^' -> true
  | byte -> Char.code byte >= 0x80

(* typec's own text stands on the line of its location and holds no
   pragma line, so a '#pragma pack' never escapes the probe that a
   bracket brings (design 10.3), inside a bracket or out of one. *)
let check_own_text ~caller text =
  if not (String.for_all is_plain_byte text) then
    invalid_arg
      (Printf.sprintf "%s: %S holds a byte that typec's text never does"
         caller text)

let generated location text =
  check_own_text ~caller:"Emitter.generated" text;
  { text; location }

type text = Code of string | Bracketed of piece list
type edit = { range : Reader.range; location : Location.t; text : text }

let code range ~location text =
  check_own_text ~caller:"Emitter.code" text;
  { range; location; text = Code text }

let first_token : Tree.external_declaration -> int = function
  | External_declaration declaration -> declaration.span.first
  | Type_declaration { declaration; _ } -> declaration.span.first
  | Function_definition definition -> definition.span.first
  | Top_level_asm assembler -> assembler.span.first
  | Empty_declaration span -> span.first

let bracketed (unit : Reader.t) ~before ~location pieces =
  { range = Reader.range unit.tokens ~first:(first_token before) ~count:0;
    location;
    text = Bracketed pieces }

(* A line marker for [location], on a line of its own. It repeats the
   flags in effect at [location] and no enter or return flag, so the
   backend keeps or ends the exemption of a system header from warnings
   as the marker in effect there did (design 13.4). *)
let marker_line (location : Location.t) =
  Printf.sprintf "# %d \"%s\"%s" location.line location.file
    (Location.flag_spelling location.flags)

(* The newline in front starts the marker on a line of its own wherever
   the edit stands in a line. *)
let marker location = "\n" ^ marker_line location ^ "\n"

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

(* The lines of the packing bracket of design 10.3 around [lines], which
   lays them out with the packing of the command line and leaves the
   packing around them as it was; each pragma stands on a line of its
   own (C11 6.10p2). *)
let bracket lines =
  [ "#pragma pack(push)"; "#pragma pack()" ] @ lines @ [ "#pragma pack(pop)" ]

(* The lines of moved text: a marker for each run of pieces that share a
   location, then the run on one line, so that every piece keeps its own
   file and line (design 13.4). *)
let moved_lines pieces =
  let add runs (piece : piece) =
    match runs with
    | (location, texts) :: earlier when location = piece.location ->
        (location, piece.text :: texts) :: earlier
    | _ -> (piece.location, [ piece.text ]) :: runs
  in
  let lines (location, texts) =
    [ marker_line location; String.concat " " (List.rev texts) ]
  in
  List.concat_map lines (List.rev (List.fold_left add [] pieces))

(* The pragmas of a bracket open at the line of the edit, the second on
   the line after it, and the last stands on it. The newline in front starts the bracket on a line of
   its own wherever the edit stands in a line. *)
let written location = function
  | Code text -> marker location ^ text
  | Bracketed pieces ->
      let opening = marker_line location in
      let lines = bracket (moved_lines pieces @ [ marker_line location ]) in
      "\n" ^ String.concat "\n" (opening :: lines)

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
  let assertion =
    Assumptions.assertion
      ~holds:
        "_Alignof(struct __tc_pack_probe_1) \
         == _Alignof(struct __tc_pack_probe_2)"
      ~assumes:"'#pragma pack()' restores the packing of the command line"
      ~option:"-fapple-pragma-pack or -fxl-pragma-pack"
  in
  String.concat "\n"
    ([ "#pragma pack(push)"; "#pragma pack(1)" ]
    @ bracket [ structure 1 ]
    @ [ "#pragma pack(2)" ]
    @ bracket [ structure 2 ]
    @ [ "#pragma pack(pop)"; assertion ])

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
