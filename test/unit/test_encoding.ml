(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let lp64 = Canned_targets.target Canned_targets.lp64_macros
let failures = ref 0

let fail_case source message =
  incr failures;
  Printf.eprintf "FAIL: %s\n  %s\n" source message

(* [file] is "in.c", C text, unless a case reads Type-C text. *)
let read ~file source =
  let text =
    match Reader.read ~name:file (Preprocessed.text ~name:file source) with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  let keywords = Target.keywords lp64 Gnu in
  match Parser.parse_with_scopes ~keywords text with
  | Ok (_, ({ Parser.file_scope; _ } as scopes)) ->
      Result.map
        (fun result -> (file_scope, result))
        (Declarations.read lp64 ~product:Unit_text text scopes)
  | Error error -> Error error

(* The encoding of the typedef name [t] that [source] declares at file
   scope. *)
let encoding_of ?(file = "in.c") source =
  match read ~file source with
  | Error error -> Error (Reader.error_message error)
  | Ok ((file_scope : Parser.file_scope), result) -> (
      let entity =
        Option.bind
          (List.assoc_opt "t" file_scope.ordinary)
          (Declarations.entity result)
      in
      match entity with
      | Some { declared = Typedef { typedef_type = t; _ }; _ } ->
          Ok (Encoding.encode (Declarations.tags result) t)
      | Some _ | None -> Error "t is no typedef name")

let reason_name : Encoding.reason -> string = function
  | Int128 -> "__int128"
  | Va_list -> "va_list"
  | Unknown_type _ -> "unknown"
  | Array_not_under_pointer -> "array not under a pointer"
  | Function_not_under_pointer -> "function not under a pointer"
  | Opaque_length -> "opaque length"
  | Variable_length -> "variable length"
  | Unnamed -> "unnamed"
  | Several_names names -> "names " ^ String.concat ", " names
  | Not_at_file_scope -> "not at file scope"
  | Too_long -> "too long"

let outcome_text = function
  | Ok code -> "encoding " ^ code
  | Error { Encoding.reason; _ } -> "no row: " ^ reason_name reason

let expect source expected = function
  | Error message -> fail_case source message
  | Ok outcome ->
      let actual = outcome_text outcome in
      if actual <> expected then
        fail_case source (Printf.sprintf "%s, expected %s" actual expected)

let encodes ?file source code =
  expect source ("encoding " ^ code) (encoding_of ?file source)

let refuses ?file source reason =
  expect source ("no row: " ^ reason) (encoding_of ?file source)

let get = function Ok t -> t | Error _ -> failwith "no type"
let int_type = get (Ctype.integer lp64 Int)

let generic name =
  match Spelling.type_name ~at_file_scope:true name with
  | Ok name -> name
  | Error _ -> failwith ("generic: " ^ name)

let instance name arguments : Ctype.instance =
  { generic = generic name; arguments; argument_types = [];
    mentions_parameter = false }

let arithmetic_rows () =
  encodes "typedef void t;" "v";
  encodes "typedef _Bool t;" "b";
  encodes "typedef char t;" "c";
  encodes "typedef signed char t;" "a";
  encodes "typedef unsigned char t;" "h";
  encodes "typedef short t;" "s";
  encodes "typedef unsigned short t;" "t";
  encodes "typedef int t;" "i";
  encodes "typedef unsigned t;" "j";
  encodes "typedef long t;" "l";
  encodes "typedef unsigned long t;" "m";
  encodes "typedef long long t;" "x";
  encodes "typedef unsigned long long t;" "y";
  encodes "typedef float t;" "f";
  encodes "typedef double t;" "d";
  encodes "typedef long double t;" "e";
  encodes "typedef _Complex double t;" "Cd";
  (* Typedef names are transparent. *)
  encodes "typedef unsigned int u32; typedef u32 t;" "j"

(* Qualifiers are written A, r, V, K, and those of an array on its
   element. *)
let qualifier_rows () =
  encodes "typedef const int t;" "Ki";
  encodes "typedef int t;" "i";
  encodes "typedef const volatile _Atomic int * restrict t;" "rPAVKi";
  encodes "typedef _Atomic(int) t;" "Ai";
  encodes "typedef const int (*t)[3];" "PYKi3E";
  encodes "typedef int (*t)[];" "PYiE";
  encodes "typedef int (*t)[2][3];" "PYYi3E2E"

let pointer_and_function_rows () =
  encodes "typedef int *t;" "Pi";
  encodes "typedef void **t;" "PPv";
  encodes "typedef int (*t)(void);" "PFivE";
  encodes "typedef int (*t)();" "PFiNE";
  encodes "int f() { return 0; } typedef __typeof__(f) *t;" "PFiNE";
  encodes "int f(a) int a; { return a; } typedef __typeof__(f) *t;" "PFiNE";
  encodes "typedef int (*t)(int, ...);" "PFiizE";
  encodes "typedef int (*t)(long, char *);" "PFilPcE";
  (* Parameters are adjusted and lose their top-level qualifiers; the
     return type keeps its own. *)
  encodes "typedef void (*t)(int a[3], int g(void));" "PFvPiPFivEE";
  encodes "typedef void (*t)(const int);" "PFviE";
  encodes "typedef void (*t)(const int *);" "PFvPKiE";
  encodes "typedef const int (*t)(void);" "PFKivE"

(* A type with a tag of its own specifier is [T]; one that Type-C
   declares, or an untagged one named by its one typedef, is its name. *)
let named_rows () =
  encodes "struct n { int x; }; typedef struct n t;" "T1n";
  encodes "union u; typedef union u *t;" "PT1u";
  encodes "enum e { A }; typedef enum e t;" "T1e";
  encodes "typedef struct { int x; } n; typedef n t;" "1n";
  encodes "typedef struct { int x; } n, *np; typedef np t;" "P1n";
  encodes "typedef const struct { int x; } n; typedef n t;" "K1n";
  encodes "typedef enum { A } e; typedef e t;" "1e";
  encodes "typedef struct { int x; } a_longer_name; typedef a_longer_name t;"
    "13a_longer_name";
  encodes "typedef struct { int x; } \xc3\xa9; typedef \xc3\xa9 t;"
    "2\xc3\xa9";
  let file = "in.tc" in
  encodes ~file "type n = struct { int x; }; typedef n t;" "1n";
  encodes ~file "type n = union { int x; n *p; }; typedef n *t;" "P1n";
  encodes ~file "type n = struct m { int x; }; typedef n t;" "T1m";
  encodes ~file "type expr = | A | B; typedef expr *t;" "P4expr";
  encodes ~file "type parse_error = | Eof | Bad; typedef parse_error t;"
    "11parse_error";
  encodes ~file "type d = distinct int; typedef const d t;" "K1d"

let unnamed_rows () =
  refuses "typedef struct { int x; } a, b; typedef a t;" "names a, b";
  refuses "typedef struct { int x; } *np; typedef np t;" "unnamed";
  refuses "typedef struct { int x; } n[2]; typedef n *t;" "unnamed";
  (* Another typedef of the named type does not name it again. *)
  encodes "typedef struct { int x; } n; typedef n m; typedef m t;" "1n";
  encodes "typedef struct { int x; } n, n; typedef n t;" "1n";
  encodes "typedef struct { int x; } (n); typedef n t;" "1n";
  (* A tag is declared in the scope that holds its first mention. *)
  encodes "struct o { struct in { int x; } i; }; typedef struct in t;" "T2in";
  refuses "typedef void (*t)(struct q *);" "not at file scope";
  refuses "int g(struct r *p) { return 0; } typedef __typeof__(g) *t;"
    "not at file scope"

let no_row_types () =
  refuses "typedef __int128 t;" "__int128";
  refuses "typedef unsigned __int128 *t;" "__int128";
  refuses "typedef _Float16 t;" "unknown";
  refuses "typedef _Float128 *t;" "unknown";
  refuses "typedef int t __attribute__((vector_size(16)));" "unknown";
  refuses "typedef __builtin_va_list t;" "va_list";
  refuses "typedef int t[3];" "array not under a pointer";
  refuses "typedef int t(void);" "function not under a pointer";
  refuses "struct s { int x; }; typedef int (*t)[sizeof (struct s)];"
    "opaque length"

let built_rows () =
  let tags = Ctype.create_tags () in
  let encode t = outcome_text (Encoding.encode tags t) in
  let check name actual expected =
    if actual <> expected then
      fail_case name (Printf.sprintf "%s, expected %s" actual expected)
  in
  let pointer t = get (Ctype.pointer_to t) in
  let variable = get (Ctype.array_of tags int_type Variable) in
  check "a variable length" (encode (pointer variable))
    "no row: variable length";
  let local =
    Ctype.declare_record tags Struct (Some "s") ~at_file_scope:false
  in
  check "a struct in a block" (encode (pointer (Ctype.record local)))
    "no row: not at file scope";
  let vector_int () =
    Ctype.declare_instance tags Struct (instance "vector" [ "i" ])
      ~define:ignore
  in
  let first = vector_int () in
  check "vector(int)" (encode (Ctype.record first)) "encoding I6vectoriE";
  check "vector(int) *" (encode (pointer (Ctype.record first)))
    "encoding PI6vectoriE";
  if vector_int () != first then fail_case "vector(int) again" "another tag";
  check "the name of vector(int)"
    (Encoding.instance_name (instance "vector" [ "i" ]))
    "vector__i";
  check "the name of pair(vector(int), int)"
    (Encoding.instance_name (instance "pair" [ "I6vectoriE"; "i" ]))
    "pair__I6vectoriEi";
  check "the name of vector(expr *)"
    (Encoding.instance_name (instance "vector" [ "P4expr" ]))
    "vector__P4expr";
  check "the name of result(uint32_t, parse_error)"
    (Encoding.instance_name (instance "result" [ "j"; "11parse_error" ]))
    "result__j11parse_error";
  (* The code is the encoding of the instance as a type but its [E]. *)
  check "the code of vector(int)"
    (string_of_int (Encoding.code_length (instance "vector" [ "i" ])))
    (string_of_int (String.length "I6vectori"));
  check "the code of pair(vector(int), int)"
    (string_of_int
       (Encoding.code_length (instance "pair" [ "I6vectoriE"; "i" ])))
    (string_of_int (String.length "I4pairI6vectoriEi"))

let () =
  arithmetic_rows ();
  qualifier_rows ();
  pointer_and_function_rows ();
  named_rows ();
  unnamed_rows ();
  no_row_types ();
  built_rows ();
  if !failures > 0 then exit 1
