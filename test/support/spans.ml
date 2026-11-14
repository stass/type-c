(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* What the tokens of a read text leave out: the gaps before, between and
   after them. *)

open Typec_cpp

(* The gaps as (start, stop) byte ranges, one more than there are
   tokens, or None when the tokens are empty, overlap or are out of
   order. *)
let gaps (result : Reader.t) =
  let ordered = ref true and previous_end = ref 0 and gaps = ref [] in
  Array.iter
    (fun (token : Token.t) ->
      if token.length < 1 || token.start < !previous_end then ordered := false
      else begin
        gaps := (!previous_end, token.start) :: !gaps;
        previous_end := token.start + token.length
      end)
    result.tokens;
  let text_end = String.length result.text in
  if !ordered && !previous_end <= text_end then
    Some (List.rev ((!previous_end, text_end) :: !gaps))
  else None

(* The gaps and the tokens, alternating, spell the text. *)
let spell_text (result : Reader.t) =
  match gaps result with
  | None -> false
  | Some gaps ->
      let gaps = Array.of_list gaps in
      let buffer = Buffer.create (String.length result.text) in
      let add_gap (start, stop) =
        Buffer.add_string buffer (String.sub result.text start (stop - start))
      in
      add_gap gaps.(0);
      Array.iteri
        (fun index token ->
          Buffer.add_string buffer (Reader.spelling result token);
          add_gap gaps.(index + 1))
        result.tokens;
      Buffer.contents buffer = result.text

let is_space = function
  | ' ' | '\t' | '\r' | '\011' | '\012' | '\n' -> true
  | _ -> false

(* A line marker or #line, which must be a whole line of a gap and start
   with '#'. *)
let is_marker_line line =
  String.starts_with ~prefix:"#" line
  &&
  let directive = String.trim (String.sub line 1 (String.length line - 1)) in
  directive <> ""
  && (String.starts_with ~prefix:"line " directive
     || ('0' <= directive.[0] && directive.[0] <= '9'))

(* A gap holds only white space and whole lines that are line markers:
   none of the text was dropped from the tokens. *)
let gap_is_layout text (start, stop) =
  let gap = String.sub text start (stop - start) in
  let lines = String.split_on_char '\n' gap in
  let last = List.length lines - 1 in
  let starts_line = start = 0 || text.[start - 1] = '\n' in
  let ends_line = stop = String.length text in
  List.for_all Fun.id
    (List.mapi
       (fun index line ->
         let whole =
           (index > 0 || starts_line) && (index < last || ends_line)
         in
         String.for_all is_space line || (whole && is_marker_line line))
       lines)

let gaps_are_layout (result : Reader.t) =
  match gaps result with
  | None -> false
  | Some gaps -> List.for_all (gap_is_layout result.text) gaps
