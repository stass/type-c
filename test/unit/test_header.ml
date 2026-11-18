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

(* The header of the interface [name] that [read] holds, held to the
   output limit of its unit. *)
let written_as name (read : Reader.interface) =
  let write output = Header.write output ~source:"m.tci" name read in
  match Emitter.limited read.unit ~trap:Trap.builtin write with
  | Ok (written, _) -> written
  | Error error -> Error error

let written text = written_as name (read_ok text)

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

let includes (read : Reader.interface) =
  let include_line : Reader.own_part -> _ = function
    | Include_line line -> Some line
    | Guard_line _ | Own_token _ -> None
  in
  List.filter_map include_line read.own_text

let test_include_lines () =
  let gcc = read_ok gcc_text in
  check "gcc: the include line of the interface's own text"
    (match includes gcc with
    | [ { directive = "include"; header_name = "\"a.tci\""; next_token; _ } ]
      ->
        gcc.unit.tokens.(next_token).owner.name = "a.tci"
    | _ -> false);
  check "gcc: the text holds tokens" gcc.holds_text;
  let clang = read_ok clang_text in
  check "clang: the comment is not part of the line"
    (match includes clang with
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

(* The text of the interface begins where a marker places the main file
   at line 1 or later, so GCC's predefined macros, at line 0, are not in
   it; within it a marker that names another file, as a #line of a
   generated interface writes, leaves the text where it is, for tokens
   and include lines alike. *)
let gcc_prelude =
  "# 0 \"m.tci\"\n# 0 \"<built-in>\"\n#define __STDC__ 1\n\
   # 0 \"<command-line>\"\n# 1 \"m.tci\"\n"

let clang_prelude =
  "# 1 \"m.tci\"\n# 1 \"<built-in>\" 1\n# 1 \"<built-in>\" 3\n\
   #define __STDC__ 1\n# 1 \"m.tci\" 2\n"

let test_line_markers () =
  let generated = "# 1 \"gen.y\"\nint a;\n#include \"b.h\"\nint d;\n" in
  let generated_body =
    [
      "#pragma push_macro(\"int\")";
      "#undef int";
      "#pragma push_macro(\"a\")";
      "#undef a";
      "int a ;";
      "#pragma pop_macro(\"int\")";
      "#pragma pop_macro(\"a\")";
      "#include \"b.h\"";
      "#pragma push_macro(\"int\")";
      "#undef int";
      "#pragma push_macro(\"d\")";
      "#undef d";
      "int d ;";
      "#pragma pop_macro(\"int\")";
      "#pragma pop_macro(\"d\")";
    ]
  in
  check "gcc: a leading #line keeps the text"
    (body (header (gcc_prelude ^ generated)) = generated_body);
  check "clang: a leading #line keeps the text"
    (body (header (clang_prelude ^ generated)) = generated_body);
  check "a leading #line: the text holds tokens"
    (read_ok (gcc_prelude ^ generated)).holds_text;
  check "a #line after the guard keeps the include line"
    (List.mem "#include \"b.h\""
       (body (header (gcc_prelude ^ "#define M\n" ^ generated))));
  check "GCC's predefined macros are no text"
    (not (read_ok gcc_prelude).holds_text);
  let own_name_text =
    gcc_prelude ^ "int a;\n# 7 \"m.tci\"\nint b;\n# 9 \"dir/m.tci\"\nint c;\n\
                   #include \"b.h\"\nint d;\n"
  in
  check "a #line of the interface's own name keeps its text"
    (body (header own_name_text)
    = [
        "#pragma push_macro(\"int\")";
        "#undef int";
        "#pragma push_macro(\"a\")";
        "#undef a";
        "#pragma push_macro(\"b\")";
        "#undef b";
        "#pragma push_macro(\"c\")";
        "#undef c";
        "int a ;";
        "int b ;";
        "int c ;";
        "#pragma pop_macro(\"int\")";
        "#pragma pop_macro(\"a\")";
        "#pragma pop_macro(\"b\")";
        "#pragma pop_macro(\"c\")";
        "#include \"b.h\"";
        "#pragma push_macro(\"int\")";
        "#undef int";
        "#pragma push_macro(\"d\")";
        "#undef d";
        "int d ;";
        "#pragma pop_macro(\"int\")";
        "#pragma pop_macro(\"d\")";
      ]);
  check "GCC's markers around a macro of a system header"
    (List.mem "void * p = ( ( void * ) 0 ) ;"
       (body
          (header
             (gcc_prelude
            ^ "void *p =\n# 1 \"m.tci\" 3\n((void *)0)\n# 1 \"m.tci\"\n;\n"))))

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

(* The guard of an instance's definition, which lowering writes as its
   #ifndef and #endif lines, is the one name of a run that the macro
   bracket does not name, and the header writes its #define. *)
let test_guards () =
  let text =
    "# 1 \"m.tci\"\n#ifndef __tc_instance__v\nstruct v;\n#endif\n"
  in
  check "a guarded definition, its guard outside the macro bracket"
    (body (header text)
    = [
        "#pragma push_macro(\"struct\")";
        "#undef struct";
        "#pragma push_macro(\"v\")";
        "#undef v";
        "#ifndef __tc_instance__v";
        "#define __tc_instance__v";
        "struct v ;";
        "#endif";
        "#pragma pop_macro(\"struct\")";
        "#pragma pop_macro(\"v\")";
      ]);
  check "two spaces after #ifndef"
    (refused_with "# 1 \"m.tci\"\n#ifndef  g\n" "malformed #ifndef");
  check "text after the name of #ifndef"
    (refused_with "# 1 \"m.tci\"\n#ifndef g h\n" "malformed #ifndef");
  check "#ifndef without a name"
    (refused_with "# 1 \"m.tci\"\n#ifndef\n" "malformed #ifndef");
  check "text after #endif"
    (refused_with "# 1 \"m.tci\"\n#endif g\n" "malformed #endif");
  check "a guard line in the step's output"
    (match
       Header.check_interface ~source:"m.tci"
         (read_ok "# 1 \"m.tci\"\n#ifndef g\n#endif\n")
         []
     with
    | Error error -> contains error.message "#ifndef or #endif line"
    | Ok () -> false)

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
        match written_as name (read_ok "# 1 \"m.tci\"\n#define M\n") with
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

(* The output limit (design 3.5 rule 7): the unit is charged its own
   text first, then a filler piece of [filler] bytes and the blank after
   it, so the header has [room] bytes left, and then each line of the
   header and its line break as it is written. *)
let charged_with_room (read : Reader.interface) room =
  let limit = Typec_sema.Output_limit.of_unit read.unit in
  let filler = limit - Reader.length read.unit - room - 1 in
  let write output =
    let start = { Location.file = "m.tci"; line = 1; flags = No_flags } in
    ignore (Emitter.generated output start (String.make filler 'a'));
    Header.write output ~source:"m.tci" name read
  in
  Emitter.limited read.unit ~trap:Trap.builtin write

let is_limit_refusal (error : Reader.error) =
  String.starts_with
    ~prefix:"the C text of the unit would pass the output limit"
    error.message

let refused_at_line line = function
  | Error (error : Reader.error) ->
      is_limit_refusal error && error.location.line = line
  | Ok _ -> false

(* The lines of a macro bracket, which the macro probe's own push and
   pop of its probe are not. *)
let is_bracket_line line =
  (String.starts_with ~prefix:"#pragma push_macro(" line
  || String.starts_with ~prefix:"#pragma pop_macro(" line
  || String.starts_with ~prefix:"#undef " line)
  && not (contains line "__tc_macro_probe__")

let line_bytes lines =
  List.fold_left (fun bytes line -> bytes + String.length line + 1) 0 lines

let test_output_limit () =
  let text = "# 1 \"m.tci\"\n\nint alpha;\nint beta;\n" in
  let read = read_ok text in
  let header = header text in
  let header_bytes = String.length header in
  check "every byte of the header is charged after the unit's text"
    (match
       Emitter.limited read.unit ~trap:Trap.builtin (fun output ->
           Header.write output ~source:"m.tci" name read)
     with
     | Ok (Ok _, charged) -> charged = Reader.length read.unit + header_bytes
     | Ok (Error _, _) | Error _ -> false);
  check "a header that takes the rest of the limit is written"
    (match charged_with_room read header_bytes with
     | Ok (Ok written, charged) ->
         written = header
         && charged = Typec_sema.Output_limit.of_unit read.unit
     | Ok (Error _, _) | Error _ -> false);
  (* The last line, the guard's #endif, stands for no line of the
     interface. *)
  check "a byte less is refused at the interface's first line"
    (refused_at_line 1 (charged_with_room read (header_bytes - 1)));
  let skeleton_bytes =
    header_bytes - line_bytes (body header) - line_bytes [ "#endif"; "#endif" ]
  in
  check "a bracket's first line is refused at its run's first line"
    (refused_at_line 2 (charged_with_room read skeleton_bytes));
  let bracket_bytes =
    line_bytes (List.filter is_bracket_line (lines header))
  in
  check "a header whose macro brackets alone pass the limit is refused"
    (bracket_bytes > 0
    &&
    match charged_with_room read (header_bytes - bracket_bytes) with
    | Error error -> is_limit_refusal error
    | Ok _ -> false)

let () =
  test_include_lines ();
  test_directives ();
  test_holds_text ();
  test_line_markers ();
  test_skeleton ();
  test_runs ();
  test_guards ();
  test_literals ();
  test_refusals ();
  test_names ();
  test_output_limit ();
  if !failures > 0 then exit 1
