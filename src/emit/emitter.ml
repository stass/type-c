(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
module Output_limit = Typec_sema.Output_limit

type piece = { text : string; location : Location.t }

(* The output of a unit as lowering makes it: the bytes charged so far,
   which only [charge] raises, and the limit they are held to. *)
type output = { unit : Reader.t; limit : int; mutable charged : int }

(* The first charge that would pass the limit, at the location of what
   it charges; [limited] catches it, so nothing more is made. *)
exception Over_limit of Location.t

let charge output location bytes =
  output.charged <- output.charged + bytes;
  if output.charged > output.limit then raise (Over_limit location)

let over_limit output location : Reader.error =
  let message =
    "the C text of the unit would pass " ^ Output_limit.described output.unit
  in
  { location; message = Rule.text (Rule.c_text message) }

(* The text of the unit outside its edits is at most the unit's own, so
   that is charged before anything is made. *)
let limited unit make =
  let size = Reader.length unit in
  let output = { unit; limit = Output_limit.of_unit unit; charged = size } in
  match make output with
  | made -> Ok made
  | exception Over_limit location -> Error (over_limit output location)

let unit output = output.unit

(* A piece is written on the line of its run (see [moved_lines]). *)
let made_piece output piece =
  let length = String.length piece.text in
  charge output piece.location (Output_limit.piece_charge length);
  piece

(* The token [index] of the unit at its own location. *)
let own_piece output index =
  let token = output.unit.tokens.(index) in
  made_piece output
    { text = Reader.spelling output.unit token; location = token.location }

let token output index =
  if Token.is_movable output.unit.tokens.(index).kind then
    Some (own_piece output index)
  else None

(* The bytes of typec's own text: those of identifiers, UTF-8 included,
   the blank, and the punctuators of C but for '#', '%' and '\\', with
   a '?' or a '/' only between two other bytes ({!check_own_text}). They
   spell no directive ('#', '%:', '??='), line splice, comment, line
   break or string literal, so no pragma line either, as the _Pragma
   operator takes a string literal (C11 6.10.9). *)
let is_plain_byte = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$' | ' ' -> true
  | '(' | ')' | '[' | ']' | '{' | '}' | ';' | ',' | '.' | ':' -> true
  | '=' | '*' | '&' | '!' | '<' | '>' | '-' | '+' | '|' | '~' | '^' -> true
  | '?' | '/' -> true
  | byte -> Char.code byte >= 0x80

(* A '?' that no other '?' can follow or precede, in this text or
   next to it, starts no trigraph. *)
let is_trigraph_free text =
  let last = String.length text - 1 in
  let lone index =
    text.[index] <> '?'
    || (index > 0 && index < last && text.[index - 1] <> '?'
       && text.[index + 1] <> '?')
  in
  List.for_all lone (List.init (last + 1) Fun.id)

(* A '/' inside the text with neither '/' nor '*' beside it, as the
   division of the length of a slice (design 13.5) has, starts and ends
   no comment, in this text or next to it. *)
let is_comment_free text =
  let last = String.length text - 1 in
  let beside_slash index =
    match text.[index] with '/' | '*' -> false | _ -> true
  in
  let lone index =
    text.[index] <> '/'
    || (index > 0 && index < last
       && beside_slash (index - 1) && beside_slash (index + 1))
  in
  List.for_all lone (List.init (last + 1) Fun.id)

(* typec's own text stands on the line of its location and holds no
   pragma line, so a '#pragma pack' never escapes the probe that a
   bracket brings (design 10.3), inside a bracket or out of one. *)
let check_own_text ~caller text =
  let trigraph_free = is_trigraph_free text in
  let comment_free = is_comment_free text in
  if
    not (String.for_all is_plain_byte text && trigraph_free && comment_free)
  then
    invalid_arg
      (Printf.sprintf "%s: %S holds a byte that typec's text never does"
         caller text)

let generated output location text =
  check_own_text ~caller:"Emitter.generated" text;
  made_piece output { text; location }

(* Each part is held to the limit as it is spelt, before the next is,
   so a text that repeats a long name for each of many items is refused
   before it is built; a separator is counted for each part, one more
   than it holds. The text is charged once, where it is written. *)
let joined output location ~separator spell items =
  let add (length, parts) item =
    let text = spell item in
    let length = length + String.length text + String.length separator in
    if output.charged + length > output.limit then
      raise (Over_limit location);
    (length, text :: parts)
  in
  let _, parts = List.fold_left add (0, []) items in
  String.concat separator (List.rev parts)

(* A pragma line is a whole line of the source, of a type of its own so
   that no bracket holds one, inside this module as outside it. *)
type pragma_line = { line : piece }

type moved_piece = Piece of piece | Pragma_line of pragma_line

(* Only a pragma line whose identifiers the rules of design 13.5 can
   read may move; the other lines are errors there, whose checks
   lowering makes. *)
let moved_token output index =
  match output.unit.tokens.(index).kind with
  | Pragma (Identifiers _) ->
      Some (Pragma_line { line = own_piece output index })
  | kind when Token.is_movable kind -> Some (Piece (own_piece output index))
  | _ -> None

type moved_pieces = moved_piece list

let copied output pieces =
  let copy = function
    | Piece piece -> Piece (made_piece output piece)
    | Pragma_line { line } -> Pragma_line { line = made_piece output line }
  in
  List.map copy pieces

type text =
  | Code of { location : Location.t; code : string }
  | Bracketed of { location : Location.t; pieces : piece list }
  | Moved of moved_pieces

type edit = { range : Reader.range; text : text; owner : int }

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

(* A line of moved text: the pieces that share a location, or a pragma
   line, which no piece may join (C11 6.10p2). *)
type run = Pieces of Location.t * string list | Line of pragma_line

(* The runs of moved text in order, the texts of each run reversed. *)
let runs pieces =
  let add runs = function
    | Pragma_line line -> Line line :: runs
    | Piece piece -> (
        match runs with
        | Pieces (location, texts) :: earlier when location = piece.location
          ->
            Pieces (location, piece.text :: texts) :: earlier
        | _ -> Pieces (piece.location, [ piece.text ]) :: runs)
  in
  List.rev (List.fold_left add [] pieces)

let run_marker = function
  | Pieces (location, _) -> marker_line location
  | Line { line } -> marker_line line.location

(* The lines of moved text: a marker for the location of each run, then
   the run on one line, so that every piece keeps its own file and line
   (design 13.4). *)
let moved_lines pieces =
  let lines run =
    match run with
    | Pieces (_, texts) ->
        [ run_marker run; String.concat " " (List.rev texts) ]
    | Line { line } -> [ run_marker run; line.text ]
  in
  List.concat_map lines (runs pieces)

let as_moved piece = Piece piece

(* The lines of a bracket at [location] around the lines of its moved
   text: the pragmas stand at its location, whose marker precedes the
   first and the last, and the second is on the line after the first. *)
let bracketed_lines location lines =
  marker_line location :: bracket (lines @ [ marker_line location ])

(* The newline in front starts moved text on a line of its own wherever
   the edit stands in a line. *)
let written = function
  | Code { location; code } -> marker location ^ code
  | Bracketed { location; pieces } ->
      let lines = moved_lines (List.map as_moved pieces) in
      "\n" ^ String.concat "\n" (bracketed_lines location lines)
  | Moved pieces -> "\n" ^ String.concat "\n" (moved_lines pieces)

(* The edit as the backend reads it: its text, which begins with a
   marker, then a marker for the location where the replaced tokens
   end. *)
let replacement (tokens : Token.t array) edit : Reader.replacement =
  let text =
    written edit.text ^ marker (end_location tokens edit.range)
  in
  { range = edit.range; text }

(* The bytes of [lines] with a line break in front of each, as [written]
   writes moved text. *)
let line_bytes lines =
  List.fold_left (fun bytes line -> bytes + String.length line + 1) 0 lines

(* The bytes that [written] gives [text] beyond the lines of its runs,
   whose pieces were charged as they were made ([made_piece]): the
   markers of the runs, and the markers and code of a code edit or the
   markers and pragmas of a bracket. Empty moved text is the line break
   alone. *)
let frame_bytes = function
  | Code { location; code } ->
      String.length (marker location) + String.length code
  | Bracketed { location; pieces } ->
      line_bytes (bracketed_lines location [])
      + line_bytes (List.map run_marker (runs (List.map as_moved pieces)))
  | Moved [] -> 1
  | Moved pieces -> line_bytes (List.map run_marker (runs pieces))

(* Each edit is charged as it is made, at the location of the construct
   it writes, its frame and the marker after it ([replacement]). *)
let made_edit output edit =
  let location =
    match edit.text with
    | Code { location; _ } | Bracketed { location; _ } -> location
    | Moved _ -> output.unit.tokens.(edit.owner).location
  in
  let after = marker (end_location output.unit.tokens edit.range) in
  charge output location (frame_bytes edit.text + String.length after);
  edit

let code output (range : Reader.range) ~location code =
  check_own_text ~caller:"Emitter.code" code;
  made_edit output
    { range; text = Code { location; code }; owner = range.first }

let closing output ~after ~location code =
  check_own_text ~caller:"Emitter.closing" code;
  made_edit output
    { range = Reader.range output.unit.tokens ~first:(after + 1) ~count:0;
      text = Code { location; code };
      owner = after }

let bracketed output ~(at : Tree.anchor) ~location pieces =
  made_edit output
    { range = Reader.range output.unit.tokens ~first:at.before ~count:0;
      text = Bracketed { location; pieces };
      owner = at.before }

let moved output (range : Reader.range) pieces =
  made_edit output { range; text = Moved pieces; owner = range.first }

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
  match edit.text with Bracketed _ -> true | Code _ | Moved _ -> false

(* The probe is a fact of the backend that every bracket rests on, so
   emission, the one place that writes a bracket, adds it. *)
let probes edits =
  if List.exists is_bracketed edits then [ packing_probe ] else []

let in_order edits =
  List.stable_sort
    (fun a b ->
      compare
        (a.range.first, a.range.count, a.owner)
        (b.range.first, b.range.count, b.owner))
    edits

(* Reader.rewrite checks that the ranges do not overlap. *)
let emit (unit : Reader.t) { edits; assertions } =
  let edits = in_order edits in
  List.iter (check_one_file unit.tokens) edits;
  Reader.rewrite unit (List.map (replacement unit.tokens) edits)
  ^ assertion_block (assertions @ probes edits)
