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
  | Token.Number -> "number"
  | Token.Character encoding -> "char" ^ encoding_name encoding
  | Token.String encoding -> "str" ^ encoding_name encoding
  | Token.Punctuator _ -> "punct"
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

let kind_cases =
  [
    case "a declaration" "int x = 42;"
      "id int | id x | punct = | number 42 | punct ;";
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
      "id a | punct . | id b | number .5 | id a | number .5";
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
      "punct # | number 1 | str \"f.h\" | number 1 | punct # | id pragma \
       | id x";
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
    case "a preprocessing number need not be a constant"
      "08 1e+ 1..2 10.13.4 10_4 0x1e+1 1$ 1\\u00e9 1\xc3\xa9 1.0u"
      "number 08 | number 1e+ | number 1..2 | number 10.13.4 | number 10_4 \
       | number 0x1e+1 | number 1$ | number 1\\u00e9 | number 1\xc3\xa9 \
       | number 1.0u";
    case "a preprocessing number takes a sign only after e or p"
      "1+2 1e+2 0x1p-3 1E-x 1P+ 1.e5.x 0x1+1"
      "number 1 | punct + | number 2 | number 1e+2 | number 0x1p-3 \
       | number 1E-x | number 1P+ | number 1.e5.x | number 0x1 | punct + \
       | number 1";
    case "invalid UTF-8 in a number" "1\xff" "error: in.i:1: invalid UTF-8";
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
    case "a marker and #line may hold any blanks"
      "#\011 1 \"t.c\"\na\n#line\t\t7 \"r.c\"\nb"
      "a t.c t.c:1 | b t.c r.c:7";
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
    case "a message escapes other bytes" "# 1 \"a\xc2\x9bb\"\n@"
      "error: a\\xC2\\x9Bb:1: unexpected character '@'";
    case "#line without a number" "#line\n"
      "error: in.i:1: missing line number";
    case "#line with a name for a number" "#line \"x\""
      "error: in.i:1: missing line number";
    case "#line takes no flags" "#line 1 \"f\" 3"
      "error: in.i:1: unexpected text at the end of a directive";
  ]

(* The constant a preprocessing number is, as words: the kind, the base
   or type, then each part of the suffix. *)
let show_constant constant =
  let word name present = if present then [ name ] else [] in
  match constant with
  | Number.Integer { base; suffix } ->
      let base_name =
        match base with
        | Number.Binary -> "binary"
        | Number.Octal -> "octal"
        | Number.Decimal -> "decimal"
        | Number.Hexadecimal -> "hexadecimal"
      in
      let length =
        match suffix.length with
        | Number.Not_long -> []
        | Number.Long -> [ "long" ]
        | Number.Long_long -> [ "long long" ]
      in
      String.concat " "
        ([ "integer"; base_name ]
        @ word "unsigned" suffix.unsigned
        @ length
        @ word "imaginary" suffix.imaginary)
  | Number.Floating { suffix } ->
      let type_name =
        match suffix.floating_type with
        | Number.Double -> "double"
        | Number.Float -> "float"
        | Number.Long_double -> "long double"
      in
      String.concat " "
        ([ "floating"; type_name ] @ word "imaginary" suffix.imaginary)
  | Number.Not_a_constant -> "not a constant"

(* Each spelling with the constant it is. *)
let constant_cases =
  [
    ("0", "integer octal");
    ("7", "integer decimal");
    ("0777", "integer octal");
    ("0x1F", "integer hexadecimal");
    ("0XaBu", "integer hexadecimal unsigned");
    ("0b101", "integer binary");
    ("0B1", "integer binary");
    ("1u", "integer decimal unsigned");
    ("1U", "integer decimal unsigned");
    ("1l", "integer decimal long");
    ("1LL", "integer decimal long long");
    ("1ull", "integer decimal unsigned long long");
    ("1LLu", "integer decimal unsigned long long");
    ("1uLL", "integer decimal unsigned long long");
    ("1lu", "integer decimal unsigned long");
    ("1i", "integer decimal imaginary");
    ("1ui", "integer decimal unsigned imaginary");
    ("2J", "integer decimal imaginary");
    ("1Il", "integer decimal long imaginary");
    ("1.0", "floating double");
    ("1.", "floating double");
    (".5", "floating double");
    ("1e10", "floating double");
    ("1E+10", "floating double");
    ("1e-3f", "floating float");
    ("1.5L", "floating long double");
    ("0x1p3", "floating double");
    ("0x1.8P-2", "floating double");
    ("0X.8p0", "floating double");
    ("0x1.p1", "floating double");
    ("09.5", "floating double");
    ("09e1", "floating double");
    ("0e0", "floating double");
    ("1.0i", "floating double imaginary");
    ("1.0fi", "floating float imaginary");
    ("1.0if", "floating float imaginary");
    ("1.0Fj", "floating float imaginary");
    ("1.0lJ", "floating long double imaginary");
    ("0xfull", "integer hexadecimal unsigned long long");
    ("00", "integer octal");
    ("0u", "integer octal unsigned");
    ("1jul", "integer decimal unsigned long imaginary");
    ("08e1", "floating double");
    ("0x0p0fi", "floating float imaginary");
  ]
  @ List.map
      (fun spelling -> (spelling, "not a constant"))
      [
        ""; "08"; "0x"; "0b"; "1e"; "1e+"; "0x1.8"; "0x1p"; "1f"; "1lL";
        "1lll"; "1uu"; "1ii"; "1.0ff"; "1.0fl"; "1..2"; "0b2"; "0b1.0";
        "0b1p1"; "0x.p1"; "1.2.3.4"; "1.2."; "1_"; "0x1e+1"; "1a"; "1$";
        "1\\u00e9"; "1.0u"; "10.13.4"; "10_4"; "10_13_4"; "1.2_3"; "x";
        "1.0ii"; "1.0ij"; "1Ll"; "1llL"; "1lul"; "1uLu";
      ]

let failed_constant_cases () =
  List.filter_map
    (fun (spelling, expected) ->
      let actual = show_constant (Number.classify spelling) in
      if actual = expected then None else Some (spelling, expected, actual))
    constant_cases

(* Every spelling of C11 6.4.6 with the punctuator it is, digraphs as the
   punctuator they stand for (6.4.6p3). *)
let punctuator_cases =
  Punctuator.
    [
      ("[", Left_bracket); ("]", Right_bracket); ("(", Left_paren);
      (")", Right_paren); ("{", Left_brace); ("}", Right_brace);
      (".", Dot); ("->", Arrow); ("++", Plus_plus); ("--", Minus_minus);
      ("&", Ampersand); ("*", Star); ("+", Plus); ("-", Minus);
      ("~", Tilde); ("!", Exclaim); ("/", Slash); ("%", Percent);
      ("<<", Less_less); (">>", Greater_greater); ("<", Less);
      (">", Greater); ("<=", Less_equal); (">=", Greater_equal);
      ("==", Equal_equal); ("!=", Exclaim_equal); ("^", Caret);
      ("|", Pipe); ("&&", Ampersand_ampersand); ("||", Pipe_pipe);
      ("?", Question); (":", Colon); (";", Semicolon); ("...", Ellipsis);
      ("=", Equal); ("*=", Star_equal); ("/=", Slash_equal);
      ("%=", Percent_equal); ("+=", Plus_equal); ("-=", Minus_equal);
      ("<<=", Less_less_equal); (">>=", Greater_greater_equal);
      ("&=", Ampersand_equal); ("^=", Caret_equal); ("|=", Pipe_equal);
      (",", Comma); ("#", Hash); ("##", Hash_hash); ("<:", Left_bracket);
      (":>", Right_bracket); ("<%", Left_brace); ("%>", Right_brace);
      ("%:", Hash); ("%:%:", Hash_hash);
    ]

(* The spellings that do not read as their punctuator alone. Each is read
   after a blank, where "#" starts no directive. *)
let failed_punctuator_cases () =
  List.filter
    (fun (spelling, punctuator) ->
      match Reader.read ~name:"in.i" (" " ^ spelling) with
      | Ok { tokens = [| token |]; _ } ->
          token.kind <> Token.Punctuator punctuator
      | Ok _ | Error _ -> true)
    punctuator_cases

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
  let failed_constants = failed_constant_cases () in
  List.iter
    (fun (spelling, expected, actual) ->
      Printf.eprintf "FAIL: constant %S\n  expected: %s\n  actual:   %s\n"
        spelling expected actual)
    failed_constants;
  let failed_punctuators = failed_punctuator_cases () in
  List.iter
    (fun (spelling, _) -> Printf.eprintf "FAIL: punctuator %S\n" spelling)
    failed_punctuators;
  let shared = owners_are_shared () in
  if not shared then prerr_endline "FAIL: owners are shared";
  if
    failed <> [] || failed_constants <> [] || failed_punctuators <> []
    || not shared
  then exit 1
