(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Prints the AFL++ dictionary of the fuzz targets: every spelling of a
   keyword and of a punctuator, from the tables the reader and the parser
   match against, and the pieces of cc -E output that byte mutations
   rarely assemble on their own. *)

open Typec_cpp
open Typec_syntax

let pieces =
  [
    (* Line markers and directives. *)
    "# 1 \"";
    "\" 1\n";
    "\" 2\n";
    "\" 1 3 4\n";
    "# 1 \"/usr/include/system.h\" 1 3 4\n";
    "#line ";
    "#pragma ";
    "#pragma typec ";
    "#pragma GCC system_header\n";
    "#pragma GCC diagnostic push\n";
    "\n";
    "\r\n";
    (* Literals. *)
    "u8\"";
    "u'";
    "U'";
    "L\"";
    "\\x";
    "\\u00";
    "\\U0001";
    "0x";
    "0b";
    "e+";
    "p-";
    "ULL";
    (* GNU syntax. *)
    "__attribute__((";
  ]

(* AFL++ reads a value between double quotes, where a quote, a backslash
   and any byte outside printable ASCII are written as \xNN. *)
let escape value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun byte ->
      if Char.Ascii.is_print byte && byte <> '"' && byte <> '\\' then
        Buffer.add_char buffer byte
      else Buffer.add_string buffer (Printf.sprintf "\\x%02x" (Char.code byte)))
    value;
  Buffer.contents buffer

let print_entry name value = Printf.printf "%s=\"%s\"\n" name (escape value)

let () =
  List.iter (fun (spelling, _, _) -> print_entry "keyword" spelling)
    Keyword.spellings;
  List.iter (fun (spelling, _) -> print_entry "punctuator" spelling)
    Punctuator.spellings;
  List.iter (print_entry "piece") pieces
