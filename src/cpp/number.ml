(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type base = Binary | Octal | Decimal | Hexadecimal
type integer_length = Not_long | Long | Long_long

type integer_suffix = {
  unsigned : bool;
  length : integer_length;
  imaginary : bool;
}

type floating_type = Double | Float | Long_double
type floating_suffix = { floating_type : floating_type; imaginary : bool }

type t =
  | Integer of { base : base; digits : string; suffix : integer_suffix }
  | Floating of { suffix : floating_suffix }
  | Not_a_constant

(* The spelling being classified and how much of it is read. *)
type cursor = { spelling : string; mutable at : int }

(* Raised at the first part of the spelling that no constant has. *)
exception Rejected

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

(* A leading 0 makes an integer octal but leaves a floating constant such
   as 09.5 decimal, so [integer_base] decides it. *)
let read_base cursor =
  let spelling = cursor.spelling in
  let prefix = String.sub spelling 0 (Int.min 2 (String.length spelling)) in
  match String.lowercase_ascii prefix with
  | "0x" ->
      advance cursor 2;
      Hexadecimal
  | "0b" ->
      advance cursor 2;
      Binary
  | _ -> Decimal

let is_digit_of = function
  | Binary -> is_binary_digit
  | Octal | Decimal -> is_digit
  | Hexadecimal -> is_hex_digit

(* An exponent, e for decimal and p for hexadecimal, with an optional sign
   and decimal digits; binary constants have none. Returns whether there
   is one. *)
let read_exponent cursor base =
  let letters =
    match base with
    | Octal | Decimal -> "eE"
    | Hexadecimal -> "pP"
    | Binary -> ""
  in
  let present = accept cursor letters in
  if present then begin
    ignore (accept cursor "+-");
    if skip cursor is_digit = 0 then raise Rejected
  end;
  present

(* Each part of a suffix may stand once. *)
let set_once part value =
  if Option.is_some !part then raise Rejected;
  part := Some value

(* One of each at most, in any order: u or U; l, L, ll or LL; and an
   imaginary suffix. *)
let read_integer_suffix cursor =
  let unsigned = ref None and length = ref None and imaginary = ref None in
  while not (at_end cursor) do
    match next cursor with
    | 'u' | 'U' -> set_once unsigned ()
    | ('l' | 'L') as l ->
        let doubled = accept cursor (String.make 1 l) in
        set_once length (if doubled then Long_long else Long)
    | c when is_imaginary_suffix c -> set_once imaginary ()
    | _ -> raise Rejected
  done;
  {
    unsigned = Option.is_some !unsigned;
    length = Option.value !length ~default:Not_long;
    imaginary = Option.is_some !imaginary;
  }

(* One of each at most, in any order: f, F, l or L; and an imaginary
   suffix. *)
let read_floating_suffix cursor =
  let floating_type = ref None and imaginary = ref None in
  while not (at_end cursor) do
    match next cursor with
    | 'f' | 'F' -> set_once floating_type Float
    | 'l' | 'L' -> set_once floating_type Long_double
    | c when is_imaginary_suffix c -> set_once imaginary ()
    | _ -> raise Rejected
  done;
  {
    floating_type = Option.value !floating_type ~default:Double;
    imaginary = Option.is_some !imaginary;
  }

(* An integer whose digits [whole] start with 0 is octal, with octal
   digits only. *)
let integer_base base whole =
  match base with
  | Decimal when whole.[0] = '0' ->
      if not (String.for_all is_octal_digit whole) then raise Rejected;
      Octal
  | _ -> base

let classify_exn spelling =
  let cursor = { spelling; at = 0 } in
  let base = read_base cursor in
  let digits_start = cursor.at in
  let whole_digits = skip cursor (is_digit_of base) in
  let has_point = base <> Binary && accept cursor "." in
  let fraction_digits =
    if has_point then skip cursor (is_digit_of base) else 0
  in
  let has_exponent = read_exponent cursor base in
  if whole_digits + fraction_digits = 0 then raise Rejected;
  if has_point || has_exponent then begin
    (* A hexadecimal floating constant needs its binary exponent. *)
    if base = Hexadecimal && not has_exponent then raise Rejected;
    Floating { suffix = read_floating_suffix cursor }
  end
  else begin
    let whole = String.sub spelling digits_start whole_digits in
    let base = integer_base base whole in
    Integer { base; digits = whole; suffix = read_integer_suffix cursor }
  end

let classify spelling =
  match classify_exn spelling with
  | constant -> constant
  | exception Rejected -> Not_a_constant
