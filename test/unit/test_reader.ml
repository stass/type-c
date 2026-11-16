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
  | Token.Identifier _ -> "id"
  | Token.Number -> "number"
  | Token.Character encoding -> "char" ^ encoding_name encoding
  | Token.String encoding -> "str" ^ encoding_name encoding
  | Token.Punctuator _ -> "punct"
  | Token.Pragma _ -> "pragma"
  | Token.Typec_pragma -> "typec-pragma"

(* Each [show] takes the text read, the reader's result and a token. *)

(* "kind spelling" for each token. *)
let show_kind _text result token =
  kind_name token.Token.kind ^ " " ^ Reader.spelling result token

(* "spelling owner presumed-file:line" for each token, where "!" after the
   owner's name marks a system header, and the flags 3 and 4 in effect
   follow. *)
let show_place _text result (token : Token.t) =
  Printf.sprintf "%s %s%s %s:%d%s"
    (Reader.spelling result token)
    token.owner.name
    (if token.owner.system_header then "!" else "")
    token.location.file token.location.line
    (Location.flag_spelling token.location.flags)

let outcome show case =
  match Reader.read ~name:"in.i" case.text with
  | Error error -> "error: " ^ Reader.error_message error
  | Ok result when not (Spans.spell_text case.text result) ->
      "the tokens and gaps do not spell the text"
  | Ok result when not (Spans.gaps_are_layout case.text result) ->
      "a gap holds more than white space and line markers"
  | Ok result ->
      Array.to_list result.tokens
      |> List.map (show case.text result)
      |> String.concat " | "

let case name text expected = { name; text; expected }

(* The messages that name the option that likely made the text. *)
let comment_message =
  "comment in preprocessed text, as when an option such as -C keeps the \
   comments"

let no_marker_message =
  "token before the first line marker, as when an option such as -P removes \
   the line markers"

(* A case whose text, read as the file "in.i", has no line markers of its
   own, after the marker that opens that file. *)
let opened case = { case with text = Preprocessed.text ~name:"in.i" case.text }

let kind_cases =
  List.map opened
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
      "id $x | id a$b | id _1 | id caf\xc3\xa9 | id x\xf0\x9f\x98\x80 \
       | id caf\xc3\xa9 | id \xe2\x82\xac";
    case "an identifier is read as UTF-8, whatever spells its characters"
      "\\u00e9t\\u00E9 \\U000000e9t\xc3\xa9 \xc3\xa9t\xc3\xa9"
      "id \xc3\xa9t\xc3\xa9 | id \xc3\xa9t\xc3\xa9 | id \xc3\xa9t\xc3\xa9";
    case "the bounds of the characters of an identifier"
      "\\u00a8 \\u00aa \\u00ff \\u167f \\u1681 \\u2054 \\uD7FF \\uFFFD \
       \\U00010000 \\U000EFFFD a\\u0300 \\u0370"
      "id \xc2\xa8 | id \xc2\xaa | id \xc3\xbf | id \xe1\x99\xbf \
       | id \xe1\x9a\x81 | id \xe2\x81\x94 | id \xed\x9f\xbf \
       | id \xef\xbf\xbd | id \xf0\x90\x80\x80 | id \xf3\xaf\xbf\xbd \
       | id a\xcc\x80 | id \xcd\xb0";
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
    case "a universal character name for a basic character" "_\\u0041"
      "error: in.i:1: character U+0041 cannot be written as a universal \
       character name";
    case "a universal character name for a control character" "a\\u009F"
      "error: in.i:1: character U+009F cannot be written as a universal \
       character name";
    case "a universal character name for a surrogate" "a\\uD800"
      "error: in.i:1: universal character name \\uD800 names no character";
    case "a universal character name beyond Unicode" "a\\U00110000"
      "error: in.i:1: universal character name \\U00110000 names no \
       character";
    case "a universal character name for a dollar sign" "a\\u0024"
      "error: in.i:1: character U+0024 cannot be part of an identifier";
    case "a universal character name for an at sign" "a\\u0040"
      "error: in.i:1: character U+0040 cannot be part of an identifier";
    case "a character outside the identifier ranges" "a\\u00A1"
      "error: in.i:1: character U+00A1 cannot be part of an identifier";
    case "a UTF-8 character outside the identifier ranges" "a\xc2\xa1"
      "error: in.i:1: character U+00A1 cannot be part of an identifier";
    case "a private use character" "a\\uE000"
      "error: in.i:1: character U+E000 cannot be part of an identifier";
    case "a noncharacter of a plane" "a\\U0001FFFE"
      "error: in.i:1: character U+1FFFE cannot be part of an identifier";
    case "a combining character begins an identifier" "\\u0300a"
      "error: in.i:1: character U+0300 cannot begin an identifier";
    case "a UTF-8 combining character begins an identifier" "\xe2\x83\x90"
      "error: in.i:1: character U+20D0 cannot begin an identifier";
    case "a basic character in a number" "1\\u0041"
      "error: in.i:1: character U+0041 cannot be written as a universal \
       character name";
    case "unterminated string" "\"abc" "error: in.i:1: unterminated literal";
    case "string ends at the newline" "\n\"a\nb\""
      "error: in.i:2: unterminated literal";
    case "no line splice in a string" "\"a\\\nb\""
      "error: in.i:1: unterminated literal";
    case "unterminated character" "'a" "error: in.i:1: unterminated literal";
    case "empty character" "''" "error: in.i:1: empty character constant";
    case "block comment" "a /* c */"
      ("error: in.i:1: " ^ comment_message);
    case "line comment" "a // c" ("error: in.i:1: " ^ comment_message);
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

(* What the text after [pragma] is for a pragma token, as
   "pragma [identifiers]" or "pragma not tokens: reason", and the kind
   and spelling of any other token. *)
let show_pragma text result (token : Token.t) =
  match token.kind with
  | Token.Pragma (Identifiers names) ->
      "pragma [" ^ String.concat " " names ^ "]"
  | Token.Pragma (Not_tokens reason) -> "pragma not tokens: " ^ reason
  | _ -> show_kind text result token

(* The reader reads the text of a pragma line as preprocessing tokens,
   under its own rules, and a line that is none passes whole (design
   13.5). *)
let pragma_cases =
  List.map opened
  [
    case "the identifiers of a pragma, in order"
      "#pragma GCC visibility push(default)\n#pragma weak f = g\n\
       #pragma omp parallel for\n"
      "pragma [GCC visibility push default] | pragma [weak f g] \
       | pragma [omp parallel for]";
    case "no identifiers" "#pragma\n#pragma 4 + (2)\n" "pragma [] | pragma []";
    case "literals are tokens, and their prefixes are no identifiers"
      "#pragma message(\"don't\") u8\"s\" L'c' '\\'' 1.0e+3\n"
      "pragma [message]";
    case "an identifier by its name in UTF-8"
      "#pragma caf\\u00e9 caf\xc3\xa9\n" "pragma [caf\xc3\xa9 caf\xc3\xa9]";
    case "a quote that begins no literal ending on the line"
      "#pragma mark - Don't edit\nx\n#pragma weak f '\ny\n\
       #pragma x \"open\n"
      "pragma not tokens: unterminated literal | id x \
       | pragma not tokens: unterminated literal | id y \
       | pragma not tokens: unterminated literal";
    case "a byte that begins no token"
      "#pragma x @\n#pragma a \\ b\n#pragma \xff\n"
      "pragma not tokens: unexpected character '@' \
       | pragma not tokens: unexpected character '\\' \
       | pragma not tokens: invalid UTF-8";
    case "an identifier that the reader refuses"
      "#pragma mark \xe2\x80\x94 Helpers\n#pragma \\u0300a\n"
      "pragma not tokens: character U+2014 cannot be part of an identifier \
       | pragma not tokens: character U+0300 cannot begin an identifier";
    case "an empty character constant" "#pragma ''\n"
      "pragma not tokens: empty character constant";
    case "a #pragma typec line is not read as tokens"
      "#pragma typec 'x\n#pragma typecx 'y\n"
      "typec-pragma #pragma typec 'x \
       | pragma not tokens: unterminated literal";
  ]

(* "spelling = written" for each token: the name of an identifier
   against its bytes in the text, which emission copies. *)
let show_written text result (token : Token.t) =
  Reader.spelling result token ^ " = "
  ^ String.sub text token.start token.length

let written_cases =
  List.map opened
  [
    case "a name in UTF-8 keeps the bytes as written"
      "caf\\u00e9 x\\U0001F600 caf\xc3\xa9 1\\u00e9 \"\\u00e9\""
      "caf\xc3\xa9 = caf\\u00e9 | x\xf0\x9f\x98\x80 = x\\U0001F600 \
       | caf\xc3\xa9 = caf\xc3\xa9 | 1\\u00e9 = 1\\u00e9 \
       | \"\\u00e9\" = \"\\u00e9\"";
  ]

let place_cases =
  [
    case "no line markers, as under -P" "\n\na\nb"
      ("error: in.i:3: " ^ no_marker_message);
    case "#line in place of line markers, as under -fuse-line-directives"
      "#line 1 \"t.c\"\na" ("error: t.c:1: " ^ no_marker_message);
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
      "bi <built-in> <built-in>:1 3 | a t.c t.c:1 \
       | b /usr/include/s.h! /usr/include/s.h:1 3 4 \
       | c /usr/include/s.h! /usr/include/s.h:5 3 4 | d t.c t.c:3";
    case "GCC's prologue"
      "# 0 \"t.c\"\n# 0 \"<built-in>\"\n# 0 \"<command-line>\"\n\
       # 1 \"t.c\"\na\n# 1 \"h.h\" 1 3\nb\n# 2 \"t.c\" 2\nc"
      "a t.c t.c:1 | b h.h! h.h:1 3 | c t.c t.c:2";
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
      "a s.h! x.h:9 3 | b s.h! s.h:4 | c h.h h.h:1 | d h.h h.h:3 3";
    case "GCC's system flag around a macro expansion keeps the owner"
      "# 1 \"t.c\"\na\n# 1 \"t.c\" 3 4\nb\n# 1 \"t.c\"\nc"
      "a t.c t.c:1 | b t.c t.c:1 3 4 | c t.c t.c:1";
    case "the marker for #pragma GCC system_header keeps the owner"
      "# 1 \"t.c\"\n# 1 \"h.h\" 1\na\n# 3 \"h.h\" 3\nb\n# 2 \"t.c\" 2\nc"
      "a h.h h.h:1 | b h.h h.h:3 3 | c t.c t.c:2";
    case "#line and a marker without a file name keep the flags"
      "# 1 \"t.c\"\n# 1 \"h.h\" 1 3 4\na\n#line 7 \"r.h\"\nb\n# 20\nc\n\
       # 2 \"t.c\" 2\nd"
      "a h.h! h.h:1 3 4 | b h.h! r.h:7 3 4 | c h.h! r.h:20 3 4 \
       | d t.c t.c:2";
    case "nested includes"
      "# 1 \"t.c\"\n# 1 \"a.h\" 1\n# 1 \"b.h\" 1\nb\n# 2 \"a.h\" 2\na\n\
       # 2 \"t.c\" 2\nt"
      "b b.h b.h:1 | a a.h a.h:2 | t t.c t.c:2";
    case "a token before the first marker" "a\n# 1 \"t.c\"\nb"
      ("error: in.i:1: " ^ no_marker_message);
    case "a first marker that enters a file" "# 1 \"t.c\" 1\na"
      "error: in.i:1: line marker enters a file before the main file";
    case "a pragma belongs to its file"
      "# 1 \"t.c\"\n# 1 \"h.h\" 1 3\n#pragma typec x\n"
      "#pragma typec x h.h! h.h:1 3";
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
      "error: a\\u009Bb:1: unexpected character '@'";
    case "a message escapes a character as a universal character name"
      "# 1 \"\xc3\xa9\xf0\x9f\x98\x80\"\n@"
      "error: \\u00E9\\U0001F600:1: unexpected character '@'";
    case "a message escapes a byte that is not UTF-8" "# 1 \"\xc3a\"\n@"
      "error: \\xC3a:1: unexpected character '@'";
    case "a message escapes each byte of a truncated character"
      "# 1 \"a\xe2\x82b\"\n@"
      "error: a\\xE2\\x82b:1: unexpected character '@'";
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
  | Number.Integer { base; digits; suffix } ->
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
        ([ "integer"; base_name; digits ]
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
    ("0", "integer octal 0");
    ("7", "integer decimal 7");
    ("0777", "integer octal 0777");
    ("0x1F", "integer hexadecimal 1F");
    ("0XaBu", "integer hexadecimal aB unsigned");
    ("0b101", "integer binary 101");
    ("0B1", "integer binary 1");
    ("1u", "integer decimal 1 unsigned");
    ("1U", "integer decimal 1 unsigned");
    ("1l", "integer decimal 1 long");
    ("1LL", "integer decimal 1 long long");
    ("1ull", "integer decimal 1 unsigned long long");
    ("1LLu", "integer decimal 1 unsigned long long");
    ("1uLL", "integer decimal 1 unsigned long long");
    ("1lu", "integer decimal 1 unsigned long");
    ("1i", "integer decimal 1 imaginary");
    ("1ui", "integer decimal 1 unsigned imaginary");
    ("2J", "integer decimal 2 imaginary");
    ("1Il", "integer decimal 1 long imaginary");
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
    ("0xfull", "integer hexadecimal f unsigned long long");
    ("00", "integer octal 00");
    ("0u", "integer octal 0 unsigned");
    ("1jul", "integer decimal 1 unsigned long imaginary");
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
      let text = Preprocessed.text ~name:"in.i" (" " ^ spelling) in
      match Reader.read ~name:"in.i" text with
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

(* The main file is the one at the bottom of the stack: the first marker
   opens it, and a marker that enters a file of the same name opens
   another file. A marker without a flag, which [#line] also writes,
   changes no owner. *)
let main_cases =
  [
    ( "# 1 \"m.tc\"\na\n# 1 \"m.tc\" 1\nb\n# 2 \"m.tc\" 2\nc\n",
      [ ("m.tc", true); ("m.tc", false); ("m.tc", true) ] );
    ("# 1 \"m.tc\"\na\n# 7 \"n.tc\"\nb\n", [ ("m.tc", true); ("m.tc", true) ])
  ]

let failed_main_cases () =
  List.filter
    (fun (text, expected) ->
      match Reader.read ~name:"in.i" text with
      | Ok { tokens; _ } ->
          Array.to_list tokens
          |> List.map (fun (token : Token.t) ->
                 (token.owner.name, token.owner.main))
          <> expected
      | Error _ -> true)
    main_cases

(* The owner rule (design 9.2 rule 2): a declaring file, the file of the
   text, and whether that text owns the declarations. *)
let file ?(main = false) name = { File.name; system_header = false; main }

let owner_cases =
  [ (file "ir.tci", file "ir.tci", true);
    (file "include/ir.tci", file ~main:true "src/ir.tc", true);
    (file "ir.tci", file "ir.tc", false);
    (file "ir.tci", file ~main:true "client.tc", false);
    (file "ir.tci", file ~main:true "ir.tci.tc", false);
    (file "ir.tc", file ~main:true "ir.tc", false);
    (file ~main:true "ir.tc", file ~main:true "ir.tc", true);
    (file "ir.h", file ~main:true "ir.tc", false);
    (file "ir.tci", file ~main:true "ir.c", false) ]

let failed_owner_cases () =
  List.filter
    (fun (declaring, text, expected) -> File.owns ~declaring text <> expected)
    owner_cases

let () =
  let failed_cases show cases =
    List.filter_map
      (fun case ->
        let actual = outcome show case in
        if actual = case.expected then None else Some (case, actual))
      cases
  in
  let failed =
    failed_cases show_kind kind_cases
    @ failed_cases show_written written_cases
    @ failed_cases show_place place_cases
    @ failed_cases show_pragma pragma_cases
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
  let failed_mains = failed_main_cases () in
  List.iter
    (fun (text, _) -> Printf.eprintf "FAIL: main file in %S\n" text)
    failed_mains;
  let failed_owners = failed_owner_cases () in
  List.iter
    (fun ((declaring : File.t), (text : File.t), _) ->
      Printf.eprintf "FAIL: owner rule for %s in %s\n" declaring.name
        text.name)
    failed_owners;
  if
    failed <> [] || failed_constants <> [] || failed_punctuators <> []
    || (not shared) || failed_mains <> [] || failed_owners <> []
  then exit 1
