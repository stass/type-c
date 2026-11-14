(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_test_support

(* A text, read as from the file "in.i", and how its tokens must show. *)
type case = { name : string; text : string; expected : string }

let encoding_name = function
  | Token.Plain -> ""
  | Token.Utf8 -> "(u8)"
  | Token.Char16 -> "(u)"
  | Token.Char32 -> "(U)"
  | Token.Wide -> "(L)"

let kind_name = function
  | Token.Identifier -> "id"
  | Token.Integer -> "int"
  | Token.Floating -> "float"
  | Token.Version -> "version"
  | Token.Character encoding -> "char" ^ encoding_name encoding
  | Token.String encoding -> "str" ^ encoding_name encoding
  | Token.Punctuator -> "punct"
  | Token.Pragma -> "pragma"
  | Token.Typec_pragma -> "typec-pragma"

(* "kind spelling" for each token. *)
let show_kind result token =
  kind_name token.Token.kind ^ " " ^ Reader.spelling result token

(* "spelling owner presumed-file:line" for each token, where "!" after the
   owner's name marks a system header. *)
let show_place result (token : Token.t) =
  Printf.sprintf "%s %s%s %s:%d"
    (Reader.spelling result token)
    token.owner.name
    (if token.owner.system_header then "!" else "")
    token.location.file token.location.line

let outcome show case =
  match Reader.read ~name:"in.i" case.text with
  | Error error -> "error: " ^ Reader.error_message error
  | Ok result when not (Spans.spell_text result) ->
      "the tokens and gaps do not spell the text"
  | Ok result when not (Spans.gaps_are_layout result) ->
      "a gap holds more than white space and line markers"
  | Ok result ->
      Array.to_list result.tokens
      |> List.map (show result)
      |> String.concat " | "

let case name text expected = { name; text; expected }

(* Each spelling is one constant of the kind. *)
let numbers kind spellings =
  List.map
    (fun spelling ->
      case ("number " ^ spelling) spelling (kind ^ " " ^ spelling))
    spellings

(* Each spelling is a preprocessing number that is no constant. *)
let invalid_numbers spellings =
  List.map
    (fun spelling ->
      case ("invalid number " ^ spelling) spelling
        ("error: in.i:1: invalid number " ^ spelling))
    spellings

let kind_cases =
  [
    case "a declaration" "int x = 42;"
      "id int | id x | punct = | int 42 | punct ;";
    case "digraphs" "<: :> <% %> %: %:%: %:% <::"
      "punct <: | punct :> | punct <% | punct %> | punct %: | punct %:%: \
       | punct %: | punct % | punct <: | punct :";
    case "longest punctuators" "-> ++ -- << >> <= >= == != && || ... <<= >>="
      "punct -> | punct ++ | punct -- | punct << | punct >> | punct <= \
       | punct >= | punct == | punct != | punct && | punct || | punct ... \
       | punct <<= | punct >>=";
    case "assignments" "*= /= %= += -= &= ^= |= ## #"
      "punct *= | punct /= | punct %= | punct += | punct -= | punct &= \
       | punct ^= | punct |= | punct ## | punct #";
    case "maximal munch" "x+++++y..z"
      "id x | punct ++ | punct ++ | punct + | id y | punct . | punct . | id z";
    case "member access is no number" "a.b .5 a.5"
      "id a | punct . | id b | float .5 | id a | float .5";
    case "characters" {|'a' L'b' u'c' U'd' '\'' '\\' '"'|}
      ({|char 'a' | char(L) L'b' | char(u) u'c' | char(U) U'd'|}
      ^ {| | char '\'' | char '\\' | char '"'|});
    case "u8 is no character prefix in C11" "u8'a'" "id u8 | char 'a'";
    case "strings" {|"a" u8"b" u"c" U"d" L"e" "\"q" "'"|}
      ({|str "a" | str(u8) u8"b" | str(u) u"c" | str(U) U"d" | str(L) L"e"|}
      ^ {| | str "\"q" | str "'"|});
    case "a prefix needs the quote next to it" {|u8 "x" Lx"y" uu"z"|}
      {|id u8 | str "x" | id Lx | str "y" | id uu | str "z"|};
    case "a NUL byte in a literal" "\"a\000b\"" "str \"a\000b\"";
    case "GNU and extended identifiers"
      "$x a$b _1 caf\\u00e9 x\\U0001F600 caf\xc3\xa9 \xe2\x82\xac"
      "id $x | id a$b | id _1 | id caf\\u00e9 | id x\\U0001F600 \
       | id caf\xc3\xa9 | id \xe2\x82\xac";
    case "pragmas"
      "#pragma once\n#pragma typec checked\n#  pragma  typec\n\
       #pragma typecx\n#pragma\nx"
      "pragma #pragma once | typec-pragma #pragma typec checked \
       | typec-pragma #  pragma  typec | pragma #pragma typecx \
       | pragma #pragma | id x";
    case "a # inside a line is a punctuator" "a # b ## c\n%: d"
      "id a | punct # | id b | punct ## | id c | punct %: | id d";
    case "a # after a blank is a punctuator" " # 1 \"f.h\" 1\n\t#pragma x"
      "punct # | int 1 | str \"f.h\" | int 1 | punct # | id pragma | id x";
    case "white space" "\t a \011\012\r\n b " "id a | id b";
    case "empty" "" "";
    case "unexpected character" "a @ b"
      "error: in.i:1: unexpected character '@'";
    case "unexpected backquote" "`" "error: in.i:1: unexpected character '`'";
    case "unexpected control byte" "a\001"
      "error: in.i:1: unexpected byte 0x01";
    case "unexpected NUL byte" "\000" "error: in.i:1: unexpected byte 0x00";
    case "a lone backslash" "a \\x" "error: in.i:1: unexpected character '\\'";
    case "invalid UTF-8" "\xff" "error: in.i:1: invalid UTF-8";
    case "truncated UTF-8" "a\xc3" "error: in.i:1: invalid UTF-8";
    case "overlong UTF-8" "\xc0\x80" "error: in.i:1: invalid UTF-8";
    case "UTF-8 surrogate" "\xed\xa0\x80" "error: in.i:1: invalid UTF-8";
    case "short universal character name" "a\\u12g"
      "error: in.i:1: incomplete universal character name";
    case "unterminated string" "\"abc" "error: in.i:1: unterminated literal";
    case "string ends at the newline" "\n\"a\nb\""
      "error: in.i:2: unterminated literal";
    case "no line splice in a string" "\"a\\\nb\""
      "error: in.i:1: unterminated literal";
    case "unterminated character" "'a" "error: in.i:1: unterminated literal";
    case "empty character" "''" "error: in.i:1: empty character constant";
    case "block comment" "a /* c */"
      "error: in.i:1: comment in preprocessed text";
    case "line comment" "a // c" "error: in.i:1: comment in preprocessed text";
    case "other directives" "#define X 1"
      "error: in.i:1: unsupported directive #define";
    case "null directive" "#\n" "error: in.i:1: unsupported directive #";
  ]
  @ numbers "int"
      [
        "0"; "7"; "0777"; "0x1F"; "0XaBu"; "0b101"; "0B1"; "1u"; "1U"; "1l";
        "1LL"; "1ull"; "1LLu"; "1uLL"; "1lu"; "1i"; "1ui"; "2J"; "1Il";
      ]
  @ numbers "float"
      [
        "1.0"; "1."; ".5"; "1e10"; "1E+10"; "1e-3f"; "1.5L"; "0x1p3";
        "0x1.8P-2"; "0X.8p0"; "0x1.p1"; "09.5"; "09e1"; "0e0"; "1.0i";
        "1.0fi"; "1.0if"; "1.0Fj";
      ]
  @ numbers "version" [ "10.13.4"; "10_4"; "10_13_4"; "1.2_3" ]
  @ invalid_numbers
      [
        "08"; "0x"; "0b"; "1e"; "1e+"; "0x1.8"; "0x1p"; "1f"; "1lL"; "1lll";
        "1uu"; "1ii"; "1.0ff"; "1..2"; "0b2"; "0b1.0"; "0b1p1"; "0x.p1";
        "1.2.3.4"; "1.2."; "1_"; "0x1e+1"; "1a"; "1$"; "1\\u00e9"; "1.0u";
      ]

let place_cases =
  [
    case "no line markers" "a\nb\n\n c" "a in.i in.i:1 | b in.i in.i:2 \
                                         | c in.i in.i:4";
    case "Clang's prologue and a system header"
      "# 1 \"t.c\"\n\
       # 1 \"<built-in>\" 1\n\
       # 1 \"<built-in>\" 3\n\
       bi\n\
       # 1 \"<command line>\" 1\n\
       # 1 \"<built-in>\" 2\n\
       # 1 \"t.c\" 2\n\
       a\n\
       # 1 \"/usr/include/s.h\" 1 3 4\n\
       b\n\
       # 5 \"/usr/include/s.h\" 3 4\n\
       c\n\
       # 3 \"t.c\" 2\n\
       d"
      "bi <built-in> <built-in>:1 | a t.c t.c:1 \
       | b /usr/include/s.h! /usr/include/s.h:1 \
       | c /usr/include/s.h! /usr/include/s.h:5 | d t.c t.c:3";
    case "GCC's prologue"
      "# 0 \"t.c\"\n# 0 \"<built-in>\"\n# 0 \"<command-line>\"\n\
       # 1 \"t.c\"\na\n# 1 \"h.h\" 1 3\nb\n# 2 \"t.c\" 2\nc"
      "a t.c t.c:1 | b h.h! h.h:1 | c t.c t.c:2";
    case "a marker without flags renames only"
      "# 1 \"t.c\"\na\n# 10 \"other.c\"\nb\n# 1 \"h.h\" 1\nc\n\
       # 11 \"other.c\" 2\nd"
      "a t.c t.c:1 | b t.c other.c:10 | c h.h h.h:1 | d t.c other.c:11";
    case "#line and a marker without a file name renumber"
      "# 1 \"t.c\"\n#line 7 \"r.c\"\na\n#line 20\nb\n# 30\nc\n# 40 \nd"
      "a t.c r.c:7 | b t.c r.c:20 | c t.c r.c:30 | d t.c r.c:40";
    case "only the marker that opens a file says it is a system header"
      "# 1 \"t.c\"\n# 1 \"s.h\" 1 3\n#line 9 \"x.h\"\na\n# 4 \"s.h\"\nb\n\
       # 1 \"h.h\" 1\nc\n# 3 \"h.h\" 3\nd"
      "a s.h! x.h:9 | b s.h! s.h:4 | c h.h h.h:1 | d h.h h.h:3";
    case "GCC's system flag around a macro expansion keeps the owner"
      "# 1 \"t.c\"\na\n# 1 \"t.c\" 3\nb\n# 1 \"t.c\"\nc"
      "a t.c t.c:1 | b t.c t.c:1 | c t.c t.c:1";
    case "nested includes"
      "# 1 \"t.c\"\n# 1 \"a.h\" 1\n# 1 \"b.h\" 1\nb\n# 2 \"a.h\" 2\na\n\
       # 2 \"t.c\" 2\nt"
      "b b.h b.h:1 | a a.h a.h:2 | t t.c t.c:2";
    case "text before the first marker keeps the input's name"
      "a\n# 1 \"t.c\"\nb" "a in.i in.i:1 | b in.i t.c:1";
    case "a first marker that enters names the main file"
      "# 1 \"t.c\" 1\na" "a t.c t.c:1";
    case "a pragma belongs to its file"
      "# 1 \"t.c\"\n# 1 \"h.h\" 1 3\n#pragma typec x\n"
      "#pragma typec x h.h! h.h:1";
    case "line counting across carriage returns"
      "# 5 \"t.c\"\r\n\r\na" "a t.c t.c:6";
    case "GCC's line 0" "# 0 \"t.c\"\na" "a t.c t.c:0";
    case "the largest line number" "# 2147483647 \"t.c\"\na\nb"
      "a t.c t.c:2147483647 | b t.c t.c:2147483648";
    case "a name keeps its escapes" "# 1 \"a\\\"b\\\\.c\"\nx"
      "x a\\\"b\\\\.c a\\\"b\\\\.c:1";
    case "an error is placed by the presumed line" "# 7 \"t.c\"\na\n@"
      "error: t.c:8: unexpected character '@'";
    case "return from the main file" "# 1 \"t.c\" 2"
      "error: in.i:1: line marker returns from the main file";
    case "return past the main file" "# 1 \"t.c\"\n# 1 \"h.h\" 1\n\
                                      # 2 \"t.c\" 2\n# 3 \"t.c\" 2"
      "error: t.c:2: line marker returns from the main file";
    case "line number too large" "# 2147483648 \"t.c\""
      "error: in.i:1: line number out of range";
    case "flags out of order" "# 1 \"t.c\" 3 1"
      "error: in.i:1: invalid line marker flags";
    case "enter and return" "# 1 \"t.c\" 1 2"
      "error: in.i:1: invalid line marker flags";
    case "flag 4 without 3" "# 1 \"t.c\" 4"
      "error: in.i:1: invalid line marker flags";
    case "unknown flag" "# 1 \"t.c\" 5"
      "error: in.i:1: invalid line marker flags";
    case "a flag of two digits" "# 1 \"t.c\" 11"
      "error: in.i:1: invalid line marker flags";
    case "a flag twice" "# 1 \"t.c\" 1 3 4 4"
      "error: in.i:1: invalid line marker flags";
    case "text after the flags" "# 1 \"t.c\" 1x"
      "error: in.i:1: unexpected text at the end of a directive";
    case "a name without quotes" "# 1 t.c"
      "error: in.i:1: unexpected text at the end of a directive";
    case "an unterminated name" "# 1 \"t.c"
      "error: in.i:1: unterminated literal";
    case "a message escapes control characters" "# 1 \"a\027[2Jb\"\n@"
      "error: a\\x1B[2Jb:1: unexpected character '@'";
    case "a message escapes other bytes" "1\xc2\x9b"
      "error: in.i:1: invalid number 1\\xC2\\x9B";
    case "a message cuts a long spelling" ("1" ^ String.make 100 'x')
      ("error: in.i:1: invalid number 1" ^ String.make 39 'x' ^ "...");
    case "#line without a number" "#line\n"
      "error: in.i:1: missing line number";
    case "#line with a name for a number" "#line \"x\""
      "error: in.i:1: missing line number";
    case "#line takes no flags" "#line 1 \"f\" 3"
      "error: in.i:1: unexpected text at the end of a directive";
  ]

(* Each owner is one value, so tokens of one owner share it. *)
let owners_are_shared () =
  let text =
    "# 1 \"t.c\"\na\n# 1 \"h.h\" 1\nb\n# 2 \"t.c\" 2\nc\n# 2 \"t.c\" 3\nd"
  in
  match Reader.read ~name:"in.i" text with
  | Ok { tokens = [| a; _; c; d |]; _ } ->
      a.owner == c.owner && c.owner == d.owner
  | _ -> false

let () =
  let failed_cases show cases =
    List.filter_map
      (fun case ->
        let actual = outcome show case in
        if actual = case.expected then None else Some (case, actual))
      cases
  in
  let failed =
    failed_cases show_kind kind_cases @ failed_cases show_place place_cases
  in
  List.iter
    (fun (case, actual) ->
      Printf.eprintf "FAIL: %s\n  expected: %s\n  actual:   %s\n" case.name
        case.expected actual)
    failed;
  let shared = owners_are_shared () in
  if not shared then prerr_endline "FAIL: owners are shared";
  if failed <> [] || not shared then exit 1
