(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* What the tokens of a read text leave out: the gaps before, between and
   after them. Each check takes the text that the reader read, which a
   stage never sees. *)

open Typec_cpp

(* The gaps as (start, stop) byte ranges, one more than there are
   tokens, or None when the tokens are empty, overlap or are out of
   order. *)
let gaps text (result : Reader.t) =
  let ordered = ref true and previous_end = ref 0 and gaps = ref [] in
  Array.iter
    (fun (token : Token.t) ->
      if token.length < 1 || token.start < !previous_end then ordered := false
      else begin
        gaps := (!previous_end, token.start) :: !gaps;
        previous_end := token.start + token.length
      end)
    result.tokens;
  let text_end = String.length text in
  if !ordered && !previous_end <= text_end then
    Some (List.rev ((!previous_end, text_end) :: !gaps))
  else None

(* The gaps and the tokens, alternating, spell the text: the tokens are
   in order and apart, and the text that the reader keeps for emission
   is the text it read. *)
let spell_text text (result : Reader.t) =
  Option.is_some (gaps text result) && Reader.rewrite result [] = text

let is_space = function
  | ' ' | '\t' | '\r' | '\011' | '\012' | '\n' -> true
  | _ -> false

(* [text] from its first byte that is not a space. String.trim would keep
   the vertical tab, which the reader takes as a blank. *)
let drop_leading_space text =
  let length = String.length text in
  let start = ref 0 in
  while !start < length && is_space text.[!start] do
    incr start
  done;
  String.sub text !start (length - !start)

let is_digit byte = '0' <= byte && byte <= '9'

(* A line marker or #line, which must be a whole line of a gap: '#', any
   blanks, and then a digit or "line" and a blank. *)
let is_marker_line line =
  String.starts_with ~prefix:"#" line
  &&
  let directive =
    drop_leading_space (String.sub line 1 (String.length line - 1))
  in
  (directive <> "" && is_digit directive.[0])
  || String.length directive > 4
     && String.starts_with ~prefix:"line" directive
     && is_space directive.[4]

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

let gaps_are_layout text (result : Reader.t) =
  match gaps text result with
  | None -> false
  | Some gaps -> List.for_all (gap_is_layout text) gaps
