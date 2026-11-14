(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type radix = Binary | Octal_or_decimal | Hexadecimal

(* The spelling being classified and how much of it is read. *)
type cursor = { spelling : string; mutable at : int }

(* Raised at the first part of the spelling that is not a constant. *)
exception Not_a_constant

let at_end cursor = cursor.at >= String.length cursor.spelling

let peek cursor =
  if at_end cursor then None else Some cursor.spelling.[cursor.at]

let advance cursor count = cursor.at <- cursor.at + count

let next cursor =
  let c = cursor.spelling.[cursor.at] in
  advance cursor 1;
  c

let is_digit = Char_class.is_digit
let is_hex_digit = Char_class.is_hex_digit
let is_octal_digit = function '0' .. '7' -> true | _ -> false
let is_binary_digit = function '0' | '1' -> true | _ -> false

(* GNU: one imaginary suffix may stand among the other suffixes. *)
let is_imaginary_suffix = function
  | 'i' | 'I' | 'j' | 'J' -> true
  | _ -> false

(* Consumes the characters [accepted] holds and returns how many there
   were. *)
let skip cursor accepted =
  let start = cursor.at in
  while Option.fold ~none:false ~some:accepted (peek cursor) do
    advance cursor 1
  done;
  cursor.at - start

(* Consumes one of [characters] if it is next. *)
let accept cursor characters =
  match peek cursor with
  | Some c when String.contains characters c ->
      advance cursor 1;
      true
  | _ -> false

let read_radix cursor =
  let spelling = cursor.spelling in
  if String.length spelling < 2 || spelling.[0] <> '0' then Octal_or_decimal
  else
    match spelling.[1] with
    | 'x' | 'X' ->
        advance cursor 2;
        Hexadecimal
    | 'b' | 'B' ->
        advance cursor 2;
        Binary
    | _ -> Octal_or_decimal

let is_digit_of = function
  | Binary -> is_binary_digit
  | Octal_or_decimal -> is_digit
  | Hexadecimal -> is_hex_digit

(* An exponent, e for decimal and p for hexadecimal, with an optional sign
   and decimal digits; binary constants have none. Returns whether there
   is one. *)
let read_exponent cursor radix =
  let letters =
    match radix with
    | Octal_or_decimal -> "eE"
    | Hexadecimal -> "pP"
    | Binary -> ""
  in
  let present = accept cursor letters in
  if present then begin
    ignore (accept cursor "+-");
    if skip cursor is_digit = 0 then raise Not_a_constant
  end;
  present

let at_most_once counts =
  if List.exists (fun count -> count > 1) counts then raise Not_a_constant

(* One of each at most, in any order: u or U; l, L, ll or LL; and an
   imaginary suffix. *)
let read_integer_suffix cursor =
  let unsigned = ref 0 and long = ref 0 and imaginary = ref 0 in
  while not (at_end cursor) do
    match next cursor with
    | 'u' | 'U' -> incr unsigned
    | ('l' | 'L') as l ->
        ignore (accept cursor (String.make 1 l));
        incr long
    | c when is_imaginary_suffix c -> incr imaginary
    | _ -> raise Not_a_constant
  done;
  at_most_once [ !unsigned; !long; !imaginary ]

(* One of each at most, in any order: f, F, l or L; and an imaginary
   suffix. *)
let read_floating_suffix cursor =
  let size = ref 0 and imaginary = ref 0 in
  while not (at_end cursor) do
    match next cursor with
    | 'f' | 'F' | 'l' | 'L' -> incr size
    | c when is_imaginary_suffix c -> incr imaginary
    | _ -> raise Not_a_constant
  done;
  at_most_once [ !size; !imaginary ]

(* A decimal constant other than 0 starts with a nonzero digit, so a
   leading 0 makes the digits octal. *)
let check_octal whole_digits =
  if whole_digits.[0] = '0' && not (String.for_all is_octal_digit whole_digits)
  then raise Not_a_constant

let classify_exn spelling =
  let cursor = { spelling; at = 0 } in
  let radix = read_radix cursor in
  let digits_start = cursor.at in
  let whole_digits = skip cursor (is_digit_of radix) in
  let has_point = radix <> Binary && accept cursor "." in
  let fraction_digits =
    if has_point then skip cursor (is_digit_of radix) else 0
  in
  let has_exponent = read_exponent cursor radix in
  if whole_digits + fraction_digits = 0 then raise Not_a_constant;
  if has_point || has_exponent then begin
    (* A hexadecimal floating constant needs its binary exponent. *)
    if radix = Hexadecimal && not has_exponent then raise Not_a_constant;
    read_floating_suffix cursor;
    Token.Floating
  end
  else begin
    if radix = Octal_or_decimal then
      check_octal (String.sub spelling digits_start whole_digits);
    read_integer_suffix cursor;
    Token.Integer
  end

(* Two or three groups of decimal digits joined by '.' or '_', as Clang
   parses the versions of its availability attribute. *)
let is_version spelling =
  let dotted = String.map (fun c -> if c = '_' then '.' else c) spelling in
  let groups = String.split_on_char '.' dotted in
  let count = List.length groups in
  2 <= count && count <= 3
  && List.for_all (fun group -> group <> "" && String.for_all is_digit group)
       groups

let classify spelling =
  match classify_exn spelling with
  | kind -> Some kind
  | exception Not_a_constant ->
      if is_version spelling then Some Token.Version else None
