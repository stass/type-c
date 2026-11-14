(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t = {
  first : int;
  limit : int;
  kind : string;
  cast : string option;
  category : string;
  qual_type : string;
  desugared : string option;
}

let needs_escape c = c = '\\' || c < ' ' || c = '\x7f'

(* A field that is [-] alone is written [\x2d], so that it is not taken
   for an absent one. *)
let escaped field =
  if field = "-" then "\\x2d"
  else
    let buffer = Buffer.create (String.length field) in
    let add c =
      if needs_escape c then Printf.bprintf buffer "\\x%02x" (Char.code c)
      else Buffer.add_char buffer c
    in
    String.iter add field;
    Buffer.contents buffer

let optional = function Some field -> escaped field | None -> "-"

let to_line record =
  String.concat "\t"
    [
      string_of_int record.first;
      string_of_int record.limit;
      escaped record.kind;
      optional record.cast;
      escaped record.category;
      escaped record.qual_type;
      optional record.desugared;
    ]

exception Malformed of string

let hex_digit c =
  match c with
  | '0' .. '9' -> Char.code c - Char.code '0'
  | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
  | _ -> raise (Malformed "an escape that to_line does not write")

(* The inverse of [escaped]: every backslash starts a \xHH escape of a
   byte that needs one, or of the [-] that is a whole field. *)
let unescaped field =
  let buffer = Buffer.create (String.length field) in
  let length = String.length field in
  let rec copy index =
    if index < length then
      if field.[index] <> '\\' then begin
        Buffer.add_char buffer field.[index];
        copy (index + 1)
      end
      else if index + 4 <= length && field.[index + 1] = 'x' then begin
        let high = hex_digit field.[index + 2]
        and low = hex_digit field.[index + 3] in
        let byte = (16 * high) + low in
        if not (needs_escape (Char.chr byte) || field = "\\x2d") then
          raise (Malformed "an escape of a byte that needs none");
        Buffer.add_char buffer (Char.chr byte);
        copy (index + 4)
      end
      else raise (Malformed "a backslash that starts no escape")
  in
  copy 0;
  Buffer.contents buffer

let required field =
  if field = "-" then raise (Malformed "a required field is absent");
  unescaped field

let read_category field =
  let category = required field in
  if category <> "lvalue" && category <> "prvalue" && category <> "xvalue"
  then raise (Malformed "a value category that Clang does not give");
  category

let read_optional field = if field = "-" then None else Some (unescaped field)

(* An offset is decimal digits only: int_of_string would also take a
   sign, a base prefix or underscores. *)
let offset field =
  if field = "" || not (String.for_all (fun c -> '0' <= c && c <= '9') field)
  then raise (Malformed "an offset that is not a decimal number");
  match int_of_string_opt field with
  | Some offset -> offset
  | None -> raise (Malformed "an offset out of range")

let read_line line =
  match String.split_on_char '\t' line with
  | [ first; limit; kind; cast; category; qual_type; desugared ] ->
      let first = offset first and limit = offset limit in
      if limit < first then
        raise (Malformed "a range that ends before it starts");
      {
        first;
        limit;
        kind = required kind;
        cast = read_optional cast;
        category = read_category category;
        qual_type = required qual_type;
        desugared = read_optional desugared;
      }
  | _ -> raise (Malformed "not seven fields")

let of_line line =
  match read_line line with
  | record -> Ok record
  | exception Malformed message -> Error message
