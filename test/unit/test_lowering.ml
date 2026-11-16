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
    let preprocessed = Preprocessed.text ~name:"in.tc" source in
    match Reader.read ~name:"in.tc" preprocessed with
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
        (Lowering.edits text
           (Declarations.type_declarations declarations)
           (Declarations.constructions declarations)
           (Declarations.matchings declarations)
           (Declarations.answered declarations))
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

(* Design 13.5: a compound literal, or in an initialiser the braced list
   alone; the arguments keep their tokens. *)
let constructors () =
  let variant = "type e = | A | B(int x, int y);\n" in
  let lowered = "struct e; typedef struct e e; enum e_tag { e_A, e_B }; \
                 struct e { enum e_tag tag; union { struct { int x ; int y ; \
                 } B; } u; };"
  in
  lowers "an initialiser" (variant ^ "e a = A, b = e.B(1, 2);")
    (lowered
   ^ " e a = { .tag = e_A } , b = { .tag = e_B, .u.B = { 1, 2 } } ;");
  lowers "an assignment and a return"
    (variant ^ "e f(e v) { v = B(1, 2); return (A); }")
    (lowered
   ^ " e f(e v) { v = ((struct e){ .tag = e_B, .u.B = { 1, 2 } }) ; return ( \
      ((struct e){ .tag = e_A }) ); }");
  (* C text keeps C's meaning of a name that a target type would make a
     constructor in Type-C text. *)
  lowers "a parameter named as a constructor in C text"
    (variant ^ "# 1 \"c.h\" 1\ne pick(e A) { return A; }\n")
    (lowered ^ " e pick(e A) { return A; }");
  (* A braced list stands in only for a whole variant reached with no
     brace elided before it, here the second element, and not for an
     atomic one, which Clang refuses. *)
  lowers "brace elision into an array of variants"
    (variant ^ "struct t { e a[2]; int n; } s = { A, B(1, 2), 5 };")
    (lowered
   ^ " struct t { e a[2]; int n; } s = { ((struct e){ .tag = e_A }) , { .tag = \
      e_B, .u.B = { 1, 2 } } , 5 };");
  lowers "an atomic object" (variant ^ "_Atomic e g = A;")
    (lowered ^ " _Atomic e g = ((struct e){ .tag = e_A }) ;");
  lowers "a pragma before the arguments"
    (variant ^ "e x = B\n#pragma weak w\n(1, 2);")
    (lowered ^ " e x = { .tag = e_B, .u.B = { #pragma weak w 1, 2 } } ;");
  lowers "a constructor in the arguments of another"
    (variant ^ "type p = | P(e first, e second);\n"
    ^ "p f(void) { return P(e.B(1, 2), A); }")
    (lowered
   ^ " struct p; typedef struct p p; enum p_tag { p_P }; struct p { enum \
      p_tag tag; union { struct { e first ; e second ; } P; } u; }; p \
      f(void) { return ((struct p){ .tag = p_P, .u.P = { { .tag = e_B, \
      .u.B = { 1, 2 } } , { .tag = e_A } } }) ; }")

let () =
  lowers "a variant without fields" "type e = | A | B;"
    "struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum \
     e_tag tag; };";
  lowers "a variant with fields"
    "type expr = | Number(long value) | Nil | Add(expr *left, expr *right);"
    "struct expr; typedef struct expr expr; enum expr_tag { expr_Number, \
     expr_Nil, expr_Add }; struct expr { enum expr_tag tag; union { struct \
     { long value ; } Number; struct { expr *left ; expr *right ; } Add; } \
     u; };";
  lowers "a variant that completes an incomplete one"
    "type list; type list = | Nil | Cons(int head, list *tail);"
    "struct list; typedef struct list list; enum list_tag { list_Nil, \
     list_Cons }; struct list { enum list_tag tag; union { struct { int \
     head ; list *tail ; } Cons; } u; };";
  lowers "a pragma between the tokens of a constructor"
    "type e = | A\n#pragma pack()\n(int x);"
    "struct e; typedef struct e e; enum e_tag { e_A }; struct e { enum e_tag \
     tag; union { struct { #pragma pack() int x ; } A; } u; };";
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
  constructors ();
  if !failures > 0 then exit 1
