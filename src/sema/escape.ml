(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type element = Code_point of int | Code_unit of int

type error =
  | Unknown_escape
  | Escape_out_of_range
  | Invalid_universal_character
  | Invalid_utf8

(* Raised at the first element that cannot be decoded; caught in
   [decode]. *)
exception Invalid of error

type cursor = { text : string; mutable at : int }

let at_end cursor = cursor.at >= String.length cursor.text

let next cursor =
  if at_end cursor then raise (Invalid Unknown_escape);
  let c = cursor.text.[cursor.at] in
  cursor.at <- cursor.at + 1;
  c

let peek cursor = if at_end cursor then None else Some cursor.text.[cursor.at]

let hex_value = function
  | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
  | 'a' .. 'f' as c -> Some (Char.code c - Char.code 'a' + 10)
  | 'A' .. 'F' as c -> Some (Char.code c - Char.code 'A' + 10)
  | _ -> None

let octal_value = function
  | '0' .. '7' as c -> Some (Char.code c - Char.code '0')
  | _ -> None

let simple_escape = function
  | '\'' | '"' | '?' | '\\' as c -> Some (Char.code c)
  | 'a' -> Some 7
  | 'b' -> Some 8
  | 'f' -> Some 12
  | 'n' -> Some 10
  | 'r' -> Some 13
  | 't' -> Some 9
  | 'v' -> Some 11
  | 'e' -> Some 27
  | _ -> None

(* Reads digits while [value_of] accepts them, at most [limit], into a
   value that may not exceed [max_value]; returns it and the count. *)
let read_digits cursor ~radix ~value_of ~limit ~max_value =
  let rec loop value count =
    match Option.bind (peek cursor) value_of with
    | Some digit when count < limit ->
        cursor.at <- cursor.at + 1;
        let value = (value * radix) + digit in
        if value > max_value then raise (Invalid Escape_out_of_range);
        loop value (count + 1)
    | Some _ | None -> (value, count)
  in
  loop 0 0

let largest_code_point = 0x10FFFF
let is_surrogate code_point = code_point >= 0xD800 && code_point <= 0xDFFF

(* 6.4.3p2 also forbids most characters below U+00A0, which GCC and Clang
   accept. *)
let universal_character cursor length =
  let code_point, count =
    read_digits cursor ~radix:16 ~value_of:hex_value ~limit:length
      ~max_value:0xFFFFFFFF
  in
  if
    count <> length
    || code_point > largest_code_point
    || is_surrogate code_point
  then raise (Invalid Invalid_universal_character);
  Code_point code_point

let escape_sequence cursor ~max_code_unit =
  match next cursor with
  | 'x' ->
      let value, count =
        read_digits cursor ~radix:16 ~value_of:hex_value ~limit:max_int
          ~max_value:max_code_unit
      in
      if count = 0 then raise (Invalid Unknown_escape);
      Code_unit value
  | '0' .. '7' ->
      cursor.at <- cursor.at - 1;
      let value, _ =
        read_digits cursor ~radix:8 ~value_of:octal_value ~limit:3
          ~max_value:max_code_unit
      in
      Code_unit value
  | 'u' -> universal_character cursor 4
  | 'U' -> universal_character cursor 8
  | c -> (
      match simple_escape c with
      | Some code_point -> Code_point code_point
      | None -> raise (Invalid Unknown_escape))

(* The continuation bytes of a UTF-8 sequence carry six bits each. *)
let continuation cursor value =
  if at_end cursor then raise (Invalid Invalid_utf8);
  let byte = Char.code (next cursor) in
  if byte land 0xC0 <> 0x80 then raise (Invalid Invalid_utf8);
  (value lsl 6) lor (byte land 0x3F)

(* A sequence of [length] bytes encodes a code point of at least
   [minimum], which rejects overlong encodings. *)
let utf8_sequence cursor first =
  let length, initial, minimum =
    if first land 0xE0 = 0xC0 then (2, first land 0x1F, 0x80)
    else if first land 0xF0 = 0xE0 then (3, first land 0x0F, 0x800)
    else if first land 0xF8 = 0xF0 then (4, first land 0x07, 0x10000)
    else raise (Invalid Invalid_utf8)
  in
  let value = ref initial in
  for _ = 2 to length do
    value := continuation cursor !value
  done;
  let code_point = !value in
  if code_point < minimum || code_point > largest_code_point
     || is_surrogate code_point
  then raise (Invalid Invalid_utf8);
  Code_point code_point

let element cursor ~max_code_unit =
  match next cursor with
  | '\\' -> escape_sequence cursor ~max_code_unit
  | c when Char.code c < 0x80 -> Code_point (Char.code c)
  | c -> utf8_sequence cursor (Char.code c)

let decode ~max_code_unit text =
  let cursor = { text; at = 0 } in
  let rec elements read =
    if at_end cursor then List.rev read
    else elements (element cursor ~max_code_unit :: read)
  in
  match elements [] with
  | decoded -> Ok decoded
  | exception Invalid error -> Error error

let error_message = function
  | Unknown_escape -> "unknown escape sequence (C11 6.4.4.4p1)"
  | Escape_out_of_range ->
      "escape sequence out of range for its character type (C11 6.4.4.4p9)"
  | Invalid_universal_character ->
      "invalid universal character name (C11 6.4.3p2)"
  | Invalid_utf8 -> "source character that is not valid UTF-8"
