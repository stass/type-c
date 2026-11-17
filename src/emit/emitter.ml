(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
module Output_limit = Typec_sema.Output_limit

type piece = { text : string; location : Location.t }

(* A pragma line is a whole line of the source, of a type of its own so
   that no bracket holds one, inside this module as outside it. *)
type pragma_line = { line : piece }

type moved_piece = Piece of piece | Pragma_line of pragma_line

(* The pieces of a moved edit, made and charged when first forced. *)
type moved_pieces = moved_piece list Lazy.t

(* The output of a unit as lowering makes it: how it traps, and whether
   lowering has written a trap; the bytes charged so far, which only
   [charge] raises, and the limit they are held to; and the pieces of
   each moved edit, latest first, which [limited] forces so that every
   edit is charged before the charge is read. *)
type output = {
  unit : Reader.t;
  trap : Trap.t;
  mutable trap_called : bool;
  limit : int;
  mutable charged : int;
  mutable moved : moved_pieces list;
}

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

(* Forcing pieces may make more moved edits, which are forced in turn,
   until none is left unmade. *)
let rec force_moved output =
  match output.moved with
  | [] -> ()
  | moved ->
      output.moved <- [];
      List.iter (fun pieces -> ignore (Lazy.force pieces)) (List.rev moved);
      force_moved output

(* The text of the unit outside its edits is at most the unit's own, so
   that is charged before anything is made. *)
let limited unit ~trap make =
  let size = Reader.length unit in
  let output =
    { unit;
      trap;
      trap_called = false;
      limit = Output_limit.of_unit unit;
      charged = size;
      moved = [] }
  in
  let made_in_full () =
    let made = make output in
    force_moved output;
    made
  in
  match made_in_full () with
  | made -> Ok (made, output.charged)
  | exception Over_limit location -> Error (over_limit output location)

let unit output = output.unit

let trap_call output =
  output.trap_called <- true;
  Trap.call output.trap

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

(* Whether [holds] holds at each index of [text]: a loop, since the text
   of a node of a tree can be long, and a list of its indices would take
   memory many times its length. *)
let at_every_index text holds =
  let rec from index =
    index >= String.length text || (holds index && from (index + 1))
  in
  from 0

(* A '?' that no other '?' can follow or precede, in this text or
   next to it, starts no trigraph. *)
let is_trigraph_free text =
  let last = String.length text - 1 in
  let lone index =
    text.[index] <> '?'
    || (index > 0 && index < last && text.[index - 1] <> '?'
       && text.[index + 1] <> '?')
  in
  at_every_index text lone

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
  at_every_index text lone

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

(* Each part is held to the limit as it is added, before the next is
   spelt, so a text that repeats a long name for each of many parts is
   refused before it is built. One buffer holds the text, so that a
   writer that adds the parts of a tree takes time linear in its length
   at any depth. The text is charged once, where it is written. *)
let assembled output location ~separator write =
  let text = Buffer.create 64 in
  let started = ref false in
  let add part =
    if !started then Buffer.add_string text separator;
    started := true;
    if output.charged + Buffer.length text + String.length part > output.limit
    then raise (Over_limit location);
    Buffer.add_string text part
  in
  write add;
  Buffer.contents text

let joined output location ~separator spell items =
  assembled output location ~separator (fun add ->
      List.iter (fun item -> add (spell item)) items)

(* Only a pragma line whose identifiers the rules of design 13.5 can
   read may move; the other lines are errors there, whose checks
   lowering makes. *)
let moved_token output index =
  match output.unit.tokens.(index).kind with
  | Pragma (Identifiers _) ->
      Some (Pragma_line { line = own_piece output index })
  | kind when Token.is_movable kind -> Some (Piece (own_piece output index))
  | _ -> None

let copied output pieces =
  let copy = function
    | Piece piece -> Piece (made_piece output piece)
    | Pragma_line { line } -> Pragma_line { line = made_piece output line }
  in
  List.map copy (Lazy.force pieces)

(* A text in a packing bracket: one with no guard, or the definition of
   an instance under the guard that a header gives it. *)
type bracketed_text =
  | Unguarded of piece list
  | Guarded of { instance : Spelling.c_name; pieces : piece list }

type text =
  | Code of { location : Location.t; code : string }
  | Bracketed of { location : Location.t; texts : bracketed_text list }
  | Moved of moved_pieces

type edit = {
  range : Reader.range;
  text : text;
  owner : int;
  extent : Tree.span;
  encloses : bool;
}

let own_extent owner (range : Reader.range) : Tree.span =
  if range.count = 0 then { first = owner; last = owner }
  else { first = range.first; last = Reader.end_token range }

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

let bracketed_pieces = function
  | Unguarded pieces | Guarded { pieces; _ } -> pieces

(* The include guard of the definition of an instance (design 13.5). *)
let instance_guard (instance : Spelling.c_name) =
  "__tc_instance__" ^ (instance :> string)

(* The guard's lines stand on lines of their own (C11 6.10p2) around
   the lines of the definition; the header writes its #define. *)
let guard_opening instance = "#ifndef " ^ instance_guard instance
let guard_closing = "#endif"

let bracketed_text_lines = function
  | Unguarded pieces -> moved_lines (List.map as_moved pieces)
  | Guarded { instance; pieces } ->
      (guard_opening instance :: moved_lines (List.map as_moved pieces))
      @ [ guard_closing ]

(* The lines of a bracket at [location] around the lines of its moved
   text: the pragmas stand at its location, whose marker precedes the
   first and the last, and the second is on the line after the first. *)
let bracketed_lines location lines =
  marker_line location :: bracket (lines @ [ marker_line location ])

(* The newline in front starts moved text on a line of its own wherever
   the edit stands in a line. *)
let written = function
  | Code { location; code } -> marker location ^ code
  | Bracketed { location; texts } ->
      let lines = List.concat_map bracketed_text_lines texts in
      "\n" ^ String.concat "\n" (bracketed_lines location lines)
  | Moved pieces -> "\n" ^ String.concat "\n" (moved_lines (Lazy.force pieces))

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

(* The bytes that [written] gives moved text beyond the lines of its
   runs, whose pieces were charged as they were made ([made_piece]): the
   markers of the runs. Empty moved text is the line break alone. *)
let moved_frame_bytes = function
  | [] -> 1
  | pieces -> line_bytes (List.map run_marker (runs pieces))

(* The bytes that [written] gives code: its marker and the code. *)
let code_frame_bytes location code =
  String.length (marker location) + String.length code

let guard_bytes = function
  | Unguarded _ -> 0
  | Guarded { instance; _ } ->
      line_bytes [ guard_opening instance; guard_closing ]

(* The bytes that [written] gives a bracket beyond the pieces of its
   texts, which were charged as they were made ([made_piece]): its
   markers and pragmas, and the markers of the runs and the lines of the
   guard of each text. *)
let bracket_frame_bytes location texts =
  let text_frame_bytes text =
    let pieces = List.map as_moved (bracketed_pieces text) in
    guard_bytes text + line_bytes (List.map run_marker (runs pieces))
  in
  List.fold_left
    (fun bytes text -> bytes + text_frame_bytes text)
    (line_bytes (bracketed_lines location []))
    texts

(* Each edit is charged at the location of the construct it writes, its
   frame and the marker after the tokens it replaces ([replacement]):
   code and a bracket as they are made, moved text when its pieces
   are. *)
let charge_edit output location (range : Reader.range) ~frame =
  let after = marker (end_location output.unit.tokens range) in
  charge output location (frame + String.length after)

let code output (range : Reader.range) ~location code =
  check_own_text ~caller:"Emitter.code" code;
  charge_edit output location range ~frame:(code_frame_bytes location code);
  { range;
    text = Code { location; code };
    owner = range.first;
    extent = own_extent range.first range;
    encloses = false }

let closing output ~after ~location code =
  check_own_text ~caller:"Emitter.closing" code;
  let range = Reader.range output.unit.tokens ~first:(after + 1) ~count:0 in
  charge_edit output location range ~frame:(code_frame_bytes location code);
  { range;
    text = Code { location; code };
    owner = after;
    extent = { first = after; last = after };
    encloses = false }

let bracketed output ~(at : Tree.anchor) ~location texts =
  let range = Reader.range output.unit.tokens ~first:at.before ~count:0 in
  charge_edit output location range
    ~frame:(bracket_frame_bytes location texts);
  { range;
    text = Bracketed { location; texts };
    owner = at.before;
    extent = { first = at.before; last = at.before };
    encloses = false }

let moved output (range : Reader.range) pieces =
  let owner = range.first in
  let location = output.unit.tokens.(owner).location in
  let charged =
    lazy
      (let made = Lazy.force pieces in
       charge_edit output location range ~frame:(moved_frame_bytes made);
       made)
  in
  output.moved <- charged :: output.moved;
  { range;
    text = Moved charged;
    owner;
    extent = own_extent owner range;
    encloses = false }

let extended edit ~(extent : Tree.span) =
  if extent.first > edit.extent.first || edit.extent.last > extent.last then
    invalid_arg "Emitter.extended: an extent that does not hold the edit's";
  { edit with extent }

let enclosing edit ~extent = { (extended edit ~extent) with encloses = true }

type lowered = { trap : Trap.t; edits : edit list; assertions : string list }

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
let packing_probe ~suffix =
  let tag number = Printf.sprintf "__tc_pack_probe_%d%s" number suffix in
  let structure number =
    Printf.sprintf "struct %s { char c; int i; };" (tag number)
  in
  let assertion =
    Assumptions.assertion
      ~holds:
        (Printf.sprintf "_Alignof(struct %s) == _Alignof(struct %s)" (tag 1)
           (tag 2))
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
   emission, the one place that writes a bracket, adds it. Its
   structures are named for a header (design 13.5), as a client may
   include several headers that hold one. *)
let probes ~suffix edits =
  if List.exists is_bracketed edits then [ packing_probe ~suffix ] else []

(* How far the construct of [edit] reaches around its place: one that
   holds another reaches at least as far on each side, and one that
   encloses its extent reaches past every other edit of that extent. *)
let reach edit = (-edit.extent.first, edit.extent.last, edit.encloses)

(* Of two insertions at one place, the one whose construct holds the
   other's opens first and closes last. *)
let nesting a b =
  let is_closing = a.owner < a.range.first in
  if is_closing then compare (reach a) (reach b)
  else compare (reach b) (reach a)

let in_order edits =
  let order a b =
    match
      compare
        (a.range.first, a.range.count, a.owner)
        (b.range.first, b.range.count, b.owner)
    with
    | 0 when a.range.count = 0 -> nesting a b
    | by_place -> by_place
  in
  List.stable_sort order edits

(* The first token of the unit's own text, after the universe text. *)
let first_own_token (tokens : Token.t array) =
  Array.find_index (fun (token : Token.t) -> not (File.is_universe token.owner))
    tokens

(* The first token of the main file, where the text of an interface
   stands (design 9.3): the header writes no token of an included file. *)
let first_main_token (tokens : Token.t array) =
  Array.find_index
    (fun (token : Token.t) -> token.owner.origin = File.Main)
    tokens

(* Whether [edit] goes in front of an insertion before the token
   [first]: it begins before that token, or closes the construct that
   ends at the token before it. *)
let precedes_insertion ~first edit =
  edit.range.first < first || (edit.range.first = first && edit.owner < first)

(* The replacements of [edits], in order, with the trap's prototype in
   front of the token [first]. The prototype is typec's text as the
   assertions are; the marker after it restores the presumed location of
   that token. An interface's included text precedes its own, so edits
   may stand in front of the prototype. Edits stand at the unit's own
   tokens, so there is a token [first] wherever an edit calls the
   trap. *)
let with_prototype (tokens : Token.t array) prototype ~first edits =
  let replacements = List.map (replacement tokens) in
  match (prototype, first) with
  | [], _ | _, None -> replacements edits
  | _ :: _, Some first ->
      let text =
        marker assertions_location
        ^ String.concat "\n" prototype
        ^ marker tokens.(first).location
      in
      let before, after = List.partition (precedes_insertion ~first) edits in
      replacements before
      @ ({ Reader.range = Reader.range tokens ~first ~count:0; text }
        :: replacements after)

(* The trap is a fact that the edits rest on, as the probe is, so
   emission writes its prototype and definition where there are edits. *)
let trap_lines trap edits =
  match edits with
  | [] -> ([], [])
  | _ :: _ -> (Trap.prototype trap, Trap.definition trap)

(* In a header, the definition of the trap stands under its guard, as
   another header may define it too (design 9.3); the builtin trap has
   none. *)
let guarded_trap_definition trap =
  match Trap.definition_guard trap with
  | None -> []
  | Some guard ->
      (("#ifndef " ^ guard) :: Trap.definition trap) @ [ guard_closing ]

(* A header writes the trap's declarations only where lowering wrote a
   trap, so that a header that traps nowhere never clashes with another
   of a different trap function. Moved edits write theirs when forced,
   so all are forced before this is read. *)
let header_trap_lines output =
  if output.trap_called then
    (Trap.prototype output.trap, guarded_trap_definition output.trap)
  else ([], [])

(* Reader.rewrite checks that the ranges do not overlap. *)
let header_text output ~header_module edits =
  force_moved output;
  let unit = output.unit in
  let edits = in_order edits in
  List.iter (check_one_file unit.tokens) edits;
  let prototype, definition = header_trap_lines output in
  Reader.rewrite unit
    (with_prototype unit.tokens prototype
       ~first:(first_main_token unit.tokens) edits)
  ^ assertion_block (definition @ probes ~suffix:("__" ^ header_module) edits)

let emit (unit : Reader.t) { trap; edits; assertions } =
  let edits = in_order edits in
  List.iter (check_one_file unit.tokens) edits;
  let prototype, definition = trap_lines trap edits in
  Reader.rewrite unit
    (with_prototype unit.tokens prototype
       ~first:(first_own_token unit.tokens) edits)
  ^ assertion_block (assertions @ definition @ probes ~suffix:"" edits)
