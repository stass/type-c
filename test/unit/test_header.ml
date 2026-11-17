(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The reading of the -E -dI output of an interface and the header that
   is written from it (design 9.3), on texts given as data. *)

open Typec_cpp
open Typec_emit

let failures = ref 0

let check name passed =
  if not passed then begin
    Printf.eprintf "FAIL: %s\n" name;
    incr failures
  end

let contains text fragment =
  let length = String.length fragment in
  let rec from index =
    index + length <= String.length text
    && (String.sub text index length = fragment || from (index + 1))
  in
  from 0

let read text = Reader.read_interface ~name:"m.tci" text

let read_ok text =
  match read text with
  | Ok read -> read
  | Error error -> failwith (Reader.error_message error)

let refused_with text fragment =
  match read text with
  | Ok _ -> false
  | Error error -> contains error.message fragment

let name =
  match Header.name_of_path "dir/m.tci" with
  | Some name -> name
  | None -> failwith "m.tci has no name"

let written text = Header.write name (read_ok text)

let header text =
  match written text with
  | Ok header -> header
  | Error error -> failwith (Reader.error_message error)

let header_refused text fragment =
  match written text with
  | Ok _ -> false
  | Error error -> contains error.message fragment

let lines text = String.split_on_char '\n' text

(* The lines of [header] after the macro probe and before the two
   #endif of the guard and the redirect. *)
let body header =
  let rec after_probe = function
    | "_Static_assert(__tc_macro_probe__m, \"needs push_macro and pop_macro\");"
      :: "#undef __tc_macro_probe__m" :: rest ->
        rest
    | _ :: rest -> after_probe rest
    | [] -> []
  in
  match List.rev (after_probe (lines header)) with
  | "" :: "#endif" :: "#endif" :: body -> List.rev body
  | _ -> failwith "the header does not end with its two #endif"

(* An interface that includes a C header, between two declarations, as
   GCC writes it: the include line, then the marker that enters the
   file. *)
let gcc_text =
  "# 0 \"m.tci\"\n\
   # 0 \"<built-in>\"\n\
   #define __STDC__ 1\n\
   # 1 \"m.tci\"\n\
   int x;\n\
   #include \"a.tci\"\n\
   # 1 \"a.tci\" 1\n\
   #include <deep.h>\n\
   #ident \"deep\"\n\
   int a;\n\
   # 3 \"m.tci\" 2\n\
   x y;\n"

(* The same in Clang's form, whose include line ends with a comment and
   is followed by a marker of the interface's line. *)
let clang_text =
  "# 1 \"m.tci\"\n\
   int x;\n\
   #include <stdint.h> /* clang -E -dI */\n\
   # 2 \"m.tci\"\n\
   # 1 \"/usr/include/stdint.h\" 1 3\n\
   typedef int int32_t;\n\
   # 3 \"m.tci\" 2\n\
   x y;\n"

let test_include_lines () =
  let gcc = read_ok gcc_text in
  check "gcc: the include line of the interface's own text"
    (match gcc.includes with
    | [ { directive = "include"; header_name = "\"a.tci\""; next_token; _ } ]
      ->
        gcc.unit.tokens.(next_token).owner.name = "a.tci"
    | _ -> false);
  check "gcc: the text holds tokens" gcc.holds_text;
  let clang = read_ok clang_text in
  check "clang: the comment is not part of the line"
    (match clang.includes with
    | [ { directive = "include"; header_name = "<stdint.h>"; _ } ] -> true
    | _ -> false);
  check "an ordinary read refuses an include line"
    (Result.is_error (Reader.read ~name:"m.tci" gcc_text))

let test_directives () =
  check "a directive of the interface's own text"
    (refused_with "# 1 \"m.tci\"\n#ident \"x\"\nint x;\n"
       "#ident in an interface whose header is written");
  check "two spaces after the directive"
    (refused_with "# 1 \"m.tci\"\n#include  \"a.h\"\n" "malformed #include");
  check "text after the header name"
    (refused_with "# 1 \"m.tci\"\n#include \"a.h\" x\n" "malformed #include");
  check "a header name without its closing delimiter"
    (refused_with "# 1 \"m.tci\"\n#include <a.h\n" "malformed #include");
  check "a blank before the directive"
    (refused_with "# 1 \"m.tci\"\n# include \"a.h\"\n" "malformed #include")

let test_holds_text () =
  check "markers and GCC's predefined macros alone are no text"
    (not
       (read_ok
          "# 0 \"m.tci\"\n# 0 \"<built-in>\"\n#define __STDC__ 1\n\
           # 1 \"m.tci\"\n\n")
         .holds_text);
  check "the #define of the guard is text"
    (read_ok "# 1 \"m.tci\"\n#define M_TCI\n").holds_text;
  check "the text of an included file is not"
    (not
       (read_ok "# 1 \"m.tci\"\n# 1 \"a.h\" 1\nint a;\n# 2 \"m.tci\" 2\n")
         .holds_text);
  check "an empty text is refused"
    (match
       Header.check_interface ~source:"m.tci"
         (read_ok "# 1 \"m.tci\"\n\n")
         []
     with
    | Error error ->
        contains error.message "no #ifndef guard of its own"
    | Ok () -> false)

let test_skeleton () =
  let expected =
    [
      Header.first_line;
      "#ifdef __TYPEC__";
      "#include \"m.tci\"";
      "#else";
      "#ifndef __tc_module__m";
      "#define __tc_module__m";
      "#define __tc_macro_probe__m 1";
      "#pragma push_macro(\"__tc_macro_probe__m\")";
      "#undef __tc_macro_probe__m";
      "#pragma pop_macro(\"__tc_macro_probe__m\")";
      "#ifndef __tc_macro_probe__m";
      "#error \"this header needs #pragma push_macro and pop_macro\"";
      "#endif";
      "_Static_assert(__tc_macro_probe__m, \"needs push_macro and \
       pop_macro\");";
      "#undef __tc_macro_probe__m";
      "#pragma push_macro(\"int\")";
      "#undef int";
      "#pragma push_macro(\"x\")";
      "#undef x";
      "int x ;";
      "#pragma pop_macro(\"int\")";
      "#pragma pop_macro(\"x\")";
      "#include \"a.h\"";
      "#pragma push_macro(\"x\")";
      "#undef x";
      "#pragma push_macro(\"y\")";
      "#undef y";
      "x y ;";
      "#pragma pop_macro(\"x\")";
      "#pragma pop_macro(\"y\")";
      "#endif";
      "#endif";
      "";
    ]
  in
  check "the header of the GCC text" (lines (header gcc_text) = expected);
  check "<stdint.h> stays as it is"
    (List.mem "#include <stdint.h>" (body (header clang_text)))

let test_runs () =
  let pragma_text =
    "# 1 \"m.tci\"\n\
     int b, a;\n\
     #pragma GCC diagnostic ignored \"-Wpadded\"\n\
     int c = defined + b;\n"
  in
  check "identifiers in the order of first appearance, pragmas included, \
         without defined"
    (body (header pragma_text)
    = [
        "#pragma push_macro(\"int\")";
        "#undef int";
        "#pragma push_macro(\"b\")";
        "#undef b";
        "#pragma push_macro(\"a\")";
        "#undef a";
        "#pragma push_macro(\"GCC\")";
        "#undef GCC";
        "#pragma push_macro(\"diagnostic\")";
        "#undef diagnostic";
        "#pragma push_macro(\"ignored\")";
        "#undef ignored";
        "#pragma push_macro(\"c\")";
        "#undef c";
        "int b , a ;";
        "#pragma GCC diagnostic ignored \"-Wpadded\"";
        "int c = defined + b ;";
        "#pragma pop_macro(\"int\")";
        "#pragma pop_macro(\"b\")";
        "#pragma pop_macro(\"a\")";
        "#pragma pop_macro(\"GCC\")";
        "#pragma pop_macro(\"diagnostic\")";
        "#pragma pop_macro(\"ignored\")";
        "#pragma pop_macro(\"c\")";
      ]);
  check "an interface with no token has an empty body"
    (body (header "# 1 \"m.tci\"\n#define M_TCI\n") = [])

let test_literals () =
  let text =
    "# 1 \"m.tci\"\nchar *s = \"???=\"; char c = '?'; int d = 1?2:3;\n"
  in
  check "a '\\' between every two adjacent '?' of a literal"
    (List.mem "char * s = \"?\\?\\?=\" ; char c = '?' ; int d = 1 ? 2 : 3 ;"
       (body (header text)))

let test_refusals () =
  check "#include_next"
    (header_refused "# 1 \"m.tci\"\n#include_next <a.h>\n" "#include_next");
  check "a trigraph in an include line"
    (header_refused "# 1 \"m.tci\"\n#include \"a??=.h\"\n" "trigraph sequence");
  check "a trigraph in a pragma line"
    (header_refused "# 1 \"m.tci\"\n#pragma x \"??/\"\n" "trigraph sequence");
  check "an extended identifier"
    (header_refused "# 1 \"m.tci\"\nint \\u00e9t\\u00e9;\n"
       "outside the basic character set");
  check "a '$' in an identifier is basic"
    (Result.is_ok (written "# 1 \"m.tci\"\nint a$b;\n"))

let test_names () =
  let module_guard path =
    match Header.name_of_path path with
    | None -> None
    | Some name -> (
        match
          Header.write name (read_ok "# 1 \"m.tci\"\n#define M\n")
        with
        | Ok header -> Some (List.nth (lines header) 4)
        | Error _ -> None)
  in
  check "a module's '_' and '-' are escaped"
    (module_guard "ir_expr-2.tci" = Some "#ifndef __tc_module__ir_5fexpr_2d2");
  check "a blank in the name" (Header.name_of_path "a b.tci" = None);
  check "a quote in the name" (Header.name_of_path "a\".tci" = None);
  check "another suffix" (Header.name_of_path "a.tc" = None);
  check "a directory may hold any byte"
    (Option.is_some (Header.name_of_path "a b/\"c\"/m.tci"))

let () =
  test_include_lines ();
  test_directives ();
  test_holds_text ();
  test_skeleton ();
  test_runs ();
  test_literals ();
  test_refusals ();
  test_names ();
  if !failures > 0 then exit 1
