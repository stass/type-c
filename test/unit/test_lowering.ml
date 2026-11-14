(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Lowering of type declarations (design 13.5) through the stages that
   typec chains: parse, read the declarations, lower and emit. A case
   compares the emitted C with its line markers removed and its white
   space collapsed, so that it reads as C; test/golden shows the
   markers. *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_emit
open Typec_test_support

let lp64 = Canned_targets.target Canned_targets.lp64_macros

let emitted source =
  let text =
    match Reader.read ~name:"in.tc" source with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  let unit =
    match Parser.parse ~keywords:(Target.keywords lp64 Gnu) text with
    | Ok unit -> unit
    | Error error -> failwith (Parser.error_message error)
  in
  match Declarations.read lp64 text unit with
  | Ok declarations ->
      Emitter.emit text
        (Lowering.edits text (Declarations.type_declarations declarations))
  | Error error -> failwith (Reader.error_message error)

let is_marker line = String.starts_with ~prefix:"# " line

let words text =
  String.split_on_char '\n' text
  |> List.filter (fun line -> not (is_marker line))
  |> String.concat " "
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")
  |> String.concat " "

let failures = ref 0

let lowers name source expected =
  let actual = words (emitted source) in
  if actual <> expected then begin
    incr failures;
    Printf.eprintf "FAIL: %s\n  expected: %s\n  actual:   %s\n" name expected
      actual
  end

let () =
  lowers "an alias" "type id = unsigned int;" "typedef unsigned int id ;";
  lowers "the name in a declarator" "type handler = void (*)(int);"
    "typedef void (* handler )(int);";
  lowers "the name before a suffix" "type table = char *[4];"
    "typedef char * table [4];";
  lowers "the name inside the innermost parentheses"
    "type f = int (*(*)(void))[3];" "typedef int (*(* f )(void))[3];";
  lowers "a function type" "type f = int (int);" "typedef int f (int);";
  lowers "a forward declaration" "type node;"
    "struct node; typedef struct node node;";
  lowers "a structure that takes the name as its tag"
    "type pair = struct __attribute__((packed)) { pair *next; };"
    "struct pair; typedef struct pair pair; struct __attribute__((packed)) \
     pair { pair *next; };";
  lowers "a union with a tag of its own" "type u = union w { u *p; };"
    "union w; typedef union w u; union w { u *p; };";
  lowers "a type declaration in a block"
    "void f(void) { type t = int; t x; }"
    "void f(void) { typedef int t ; t x; }";
  (* A pragma between the tokens that lowering replaces stays in place,
     so each of them is edited alone. *)
  lowers "a pragma in the head" "type\n#pragma weak w\nt = int;"
    "typedef #pragma weak w int t ;";
  (* The edits of a declaration nested in another's definition are
     sorted among the outer one's. *)
  lowers "a type declaration in a statement expression of a definition"
    "void f(void) { type a = typeof(({ type b = int; (b)1; })) *; }"
    "void f(void) { typedef typeof(({ typedef int b ; (b)1; })) * a ; }";
  if !failures > 0 then exit 1
