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

let escaped field =
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
