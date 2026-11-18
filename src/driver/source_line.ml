(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let path (location : Typec_cpp.Location.t) =
  if String.contains location.file '\\' then None else Some location.file

(* 16 MiB holds any source file written by hand, and bounds what a line
   marker that names a huge file, or one that reads without end as
   /proc/self/pagemap does, makes the driver hold. *)
let longest_read = 16 * 1024 * 1024

(* The bytes of the longest line shown whole: a hand-written line fits,
   and a generated or minified one is cut so that the diagnostic stays
   readable. *)
let longest_shown = 200

(* Line [line] of [text], counting from 1, without its newline. The
   empty tail after the last newline is not a line, nor is a line that
   runs into the end of [text] where the driver stopped reading. *)
let nth_line text ~line =
  let length = String.length text in
  let read_whole = length < longest_read in
  let rec from start remaining =
    if start >= length then None
    else
      let stop =
        Option.value (String.index_from_opt text start '\n') ~default:length
      in
      if remaining > 1 then from (stop + 1) (remaining - 1)
      else if stop < length || read_whole then
        Some (String.sub text start (stop - start))
      else None
  in
  if line < 1 then None else from 0 line

let without_carriage_return text =
  if String.ends_with ~suffix:"\r" text then
    String.sub text 0 (String.length text - 1)
  else text

let is_continuation_byte c = Char.code c land 0xC0 = 0x80
let is_lead_byte c = Char.code c >= 0xC0

(* A character of UTF-8 has at most three continuation bytes. *)
let longest_continuation = 3

(* The byte where [text], longer than [longest_shown], is cut: the
   start of the character that holds byte [longest_shown], so that no
   character of UTF-8 is split into bytes that would be escaped. Stray
   continuation bytes, which start no character, are cut where they
   fall. *)
let cut_point text =
  let rec back point steps =
    if steps = longest_continuation || not (is_continuation_byte text.[point])
    then point
    else back (point - 1) (steps + 1)
  in
  let point = back longest_shown 0 in
  if is_lead_byte text.[point] then point else longest_shown

let cut text =
  if String.length text <= longest_shown then text
  else String.sub text 0 (cut_point text) ^ "..."

(* Tabs pass unescaped: the margin keeps their stops. *)
let escape_but_tabs text =
  String.split_on_char '\t' text
  |> List.map Typec_cpp.Reader.escape
  |> String.concat "\t"

let margin line = Printf.sprintf "%5d | " line

let shown ~line text =
  margin line ^ escape_but_tabs (cut (without_carriage_return text))

let quote ~line text = Option.map (shown ~line) (nth_line text ~line)

(* The number is read, and the margin it would have is compared, so
   that the format has the one spelling in [margin]. *)
let is_shown text =
  match Scanf.sscanf_opt text " %u" Fun.id with
  | Some line -> String.starts_with ~prefix:(margin line) text
  | None -> false
