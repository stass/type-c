(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type integer_type =
  | Char
  | Signed_char
  | Unsigned_char
  | Short
  | Unsigned_short
  | Int
  | Unsigned_int
  | Long
  | Unsigned_long
  | Long_long
  | Unsigned_long_long

type byte_order = Little_endian | Big_endian

type t = {
  char_bit : int;
  char_signed : bool;
  sizeof_short : int;
  sizeof_int : int;
  sizeof_long : int;
  sizeof_long_long : int;
  sizeof_pointer : int;
  sizeof_float : int;
  sizeof_double : int;
  sizeof_long_double : int;
  has_int128 : bool;
  size_type : integer_type;
  ptrdiff_type : integer_type;
  wchar_type : integer_type;
  intmax_type : integer_type;
  uintmax_type : integer_type;
  intptr_type : integer_type;
  char16_type : integer_type;
  char32_type : integer_type;
  byte_order : byte_order;
  stdc_version : int;
}

type error =
  | Malformed_line of string
  | Duplicate_macro of string
  | Missing_macro of string
  | Malformed_macro of { name : string; value : string }

(* Raised at the first defect of a dump and caught in of_predefined_macros. *)
exception Invalid of error

module Macros = Map.Make (String)

let define_prefix = "#define "

let suffix_from text start =
  String.sub text start (String.length text - start)

(* The name ends at the first space, so a function-like macro gives a
   name with part of its parameter list; no macro the model reads is
   function-like, and the part still tells macros apart. *)
let name_and_value line =
  if not (String.starts_with ~prefix:define_prefix line) then
    raise (Invalid (Malformed_line line));
  let definition = suffix_from line (String.length define_prefix) in
  let name, value =
    match String.index_opt definition ' ' with
    | Some space ->
        (String.sub definition 0 space, suffix_from definition (space + 1))
    | None -> (definition, "")
  in
  if name = "" then raise (Invalid (Malformed_line line));
  (name, value)

let add_line macros line =
  if line = "" then macros
  else
    let name, value = name_and_value line in
    if Macros.mem name macros then raise (Invalid (Duplicate_macro name));
    Macros.add name value macros

let macros_of_dump dump =
  List.fold_left add_line Macros.empty (String.split_on_char '\n' dump)

let find macros name =
  match Macros.find_opt name macros with
  | Some value -> value
  | None -> raise (Invalid (Missing_macro name))

let malformed name value = raise (Invalid (Malformed_macro { name; value }))

let is_digit c = '0' <= c && c <= '9'

(* Only plain decimal digits: int_of_string alone would also take a sign,
   a base prefix and underscores. It returns None on overflow. *)
let decimal text =
  if text <> "" && String.for_all is_digit text then int_of_string_opt text
  else None

(* A size or a width: a positive decimal number. *)
let read_count macros name =
  let value = find macros name in
  match decimal value with
  | Some count when count > 0 -> count
  | Some _ | None -> malformed name value

(* The spellings that C11 6.7.2p2 allows for each type, as sorted words:
   the order of the specifiers does not matter. *)
let integer_type_of_words words =
  match List.sort String.compare words with
  | [ "char" ] -> Some Char
  | [ "char"; "signed" ] -> Some Signed_char
  | [ "char"; "unsigned" ] -> Some Unsigned_char
  | [ "short" ]
  | [ "int"; "short" ]
  | [ "short"; "signed" ]
  | [ "int"; "short"; "signed" ] ->
      Some Short
  | [ "short"; "unsigned" ] | [ "int"; "short"; "unsigned" ] ->
      Some Unsigned_short
  | [ "int" ] | [ "signed" ] | [ "int"; "signed" ] -> Some Int
  | [ "unsigned" ] | [ "int"; "unsigned" ] -> Some Unsigned_int
  | [ "long" ] | [ "int"; "long" ] | [ "long"; "signed" ]
  | [ "int"; "long"; "signed" ] ->
      Some Long
  | [ "long"; "unsigned" ] | [ "int"; "long"; "unsigned" ] ->
      Some Unsigned_long
  | [ "long"; "long" ]
  | [ "int"; "long"; "long" ]
  | [ "long"; "long"; "signed" ]
  | [ "int"; "long"; "long"; "signed" ] ->
      Some Long_long
  | [ "long"; "long"; "unsigned" ] | [ "int"; "long"; "long"; "unsigned" ]
    ->
      Some Unsigned_long_long
  | _ -> None

let read_integer_type macros name =
  let value = find macros name in
  let words = List.filter (( <> ) "") (String.split_on_char ' ' value) in
  match integer_type_of_words words with
  | Some integer_type -> integer_type
  | None -> malformed name value

(* The value names one of the __ORDER_*__ macros. A PDP-endian target is
   not supported. *)
let read_byte_order macros =
  let name = "__BYTE_ORDER__" in
  match find macros name with
  | "__ORDER_LITTLE_ENDIAN__" -> Little_endian
  | "__ORDER_BIG_ENDIAN__" -> Big_endian
  | value -> malformed name value

(* The version is a long constant such as 201710L. *)
let read_stdc_version macros =
  let name = "__STDC_VERSION__" in
  let value = find macros name in
  let digits =
    if String.ends_with ~suffix:"L" value then
      String.sub value 0 (String.length value - 1)
    else ""
  in
  match decimal digits with
  | Some version -> version
  | None -> malformed name value

let model_of_macros macros =
  let count = read_count macros in
  let integer_type = read_integer_type macros in
  {
    char_bit = count "__CHAR_BIT__";
    char_signed = not (Macros.mem "__CHAR_UNSIGNED__" macros);
    sizeof_short = count "__SIZEOF_SHORT__";
    sizeof_int = count "__SIZEOF_INT__";
    sizeof_long = count "__SIZEOF_LONG__";
    sizeof_long_long = count "__SIZEOF_LONG_LONG__";
    sizeof_pointer = count "__SIZEOF_POINTER__";
    sizeof_float = count "__SIZEOF_FLOAT__";
    sizeof_double = count "__SIZEOF_DOUBLE__";
    sizeof_long_double = count "__SIZEOF_LONG_DOUBLE__";
    has_int128 = Macros.mem "__SIZEOF_INT128__" macros;
    size_type = integer_type "__SIZE_TYPE__";
    ptrdiff_type = integer_type "__PTRDIFF_TYPE__";
    wchar_type = integer_type "__WCHAR_TYPE__";
    intmax_type = integer_type "__INTMAX_TYPE__";
    uintmax_type = integer_type "__UINTMAX_TYPE__";
    intptr_type = integer_type "__INTPTR_TYPE__";
    char16_type = integer_type "__CHAR16_TYPE__";
    char32_type = integer_type "__CHAR32_TYPE__";
    byte_order = read_byte_order macros;
    stdc_version = read_stdc_version macros;
  }

let of_predefined_macros dump =
  try Ok (model_of_macros (macros_of_dump dump))
  with Invalid error -> Error error

let sizeof_integer target = function
  | Char | Signed_char | Unsigned_char -> 1
  | Short | Unsigned_short -> target.sizeof_short
  | Int | Unsigned_int -> target.sizeof_int
  | Long | Unsigned_long -> target.sizeof_long
  | Long_long | Unsigned_long_long -> target.sizeof_long_long

let integer_type_name = function
  | Char -> "char"
  | Signed_char -> "signed char"
  | Unsigned_char -> "unsigned char"
  | Short -> "short"
  | Unsigned_short -> "unsigned short"
  | Int -> "int"
  | Unsigned_int -> "unsigned int"
  | Long -> "long"
  | Unsigned_long -> "unsigned long"
  | Long_long -> "long long"
  | Unsigned_long_long -> "unsigned long long"

let byte_order_name = function
  | Little_endian -> "little-endian"
  | Big_endian -> "big-endian"

let to_string target =
  let fields =
    [
      ("char_bit", string_of_int target.char_bit);
      ("char_signed", string_of_bool target.char_signed);
      ("sizeof_short", string_of_int target.sizeof_short);
      ("sizeof_int", string_of_int target.sizeof_int);
      ("sizeof_long", string_of_int target.sizeof_long);
      ("sizeof_long_long", string_of_int target.sizeof_long_long);
      ("sizeof_pointer", string_of_int target.sizeof_pointer);
      ("sizeof_float", string_of_int target.sizeof_float);
      ("sizeof_double", string_of_int target.sizeof_double);
      ("sizeof_long_double", string_of_int target.sizeof_long_double);
      ("has_int128", string_of_bool target.has_int128);
      ("size_type", integer_type_name target.size_type);
      ("ptrdiff_type", integer_type_name target.ptrdiff_type);
      ("wchar_type", integer_type_name target.wchar_type);
      ("intmax_type", integer_type_name target.intmax_type);
      ("uintmax_type", integer_type_name target.uintmax_type);
      ("intptr_type", integer_type_name target.intptr_type);
      ("char16_type", integer_type_name target.char16_type);
      ("char32_type", integer_type_name target.char32_type);
      ("byte_order", byte_order_name target.byte_order);
      ("stdc_version", string_of_int target.stdc_version);
    ]
  in
  String.concat ""
    (List.map (fun (field, value) -> field ^ ": " ^ value ^ "\n") fields)

(* Values come from the backend, so %S escapes any control character. *)
let error_message = function
  | Malformed_line line ->
      Printf.sprintf "unexpected line %S among the predefined macros" line
  | Duplicate_macro name ->
      Printf.sprintf "the C compiler defines %S twice" name
  | Missing_macro name ->
      Printf.sprintf "the C compiler does not define %s" name
  | Malformed_macro { name; value } ->
      Printf.sprintf "the C compiler defines %s as %S, which typec cannot read"
        name value
