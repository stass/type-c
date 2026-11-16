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

(* The text that [source] is read to, its tree and its edits. *)
let lowered source =
  let text =
    let preprocessed = Preprocessed.text ~name:"in.tc" source in
    match Reader.read ~name:"in.tc" preprocessed with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  let scopes =
    let keywords = Target.keywords lp64 Gnu in
    match Parser.parse_with_scopes ~keywords text with
    | Ok (_, scopes) -> scopes
    | Error error -> failwith (Parser.error_message error)
  in
  let unit = List.map fst scopes.declarations in
  match Declarations.read lp64 text scopes with
  | Ok declarations ->
      let edits = Lowering.edits text declarations in
      (text, unit, edits)
  | Error error -> failwith (Reader.error_message error)

let emitted source =
  let text, _, edits = lowered source in
  Emitter.emit text { edits; assertions = [] }

let is_marker line = String.starts_with ~prefix:"# " line

let words text =
  String.split_on_char '\n' text
  |> List.filter (fun line -> not (is_marker line))
  |> String.concat " "
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")
  |> String.concat " "

let failures = ref 0

let compares name actual expected =
  if actual <> expected then begin
    incr failures;
    Printf.eprintf "FAIL: %s\n  expected: %s\n  actual:   %s\n" name expected
      actual
  end

let lowers name source expected =
  compares name (words (emitted source)) expected

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

(* The lines of [text] before the line marker of typec's own text that
   ends a unit with a bracket, which holds the packing probe. *)
let before_typec_text text =
  let rec take = function
    | [] -> []
    | line :: _ when line = "# 1 \"<typec>\" 3" -> []
    | line :: rest -> line :: take rest
  in
  String.concat "\n" (take (String.split_on_char '\n' text))

(* Design 10.3: the instances that a variant or a record alias uses
   stand directly after its forward declaration, inside the text that
   lowering writes for it; [source] is emitted with a bracket at the
   anchor there of its last type declaration that has one. *)
let bracketed_after_forward source =
  let text, unit, edits = lowered source in
  let at =
    match List.rev (List.filter_map Tree.after_forward_declaration unit) with
    | at :: _ -> at
    | [] -> failwith "bracketed_after_forward: no anchor"
  in
  let location = text.tokens.(0).location in
  let bracket =
    Emitter.bracketed text ~at ~location
      [ Emitter.generated location "struct s { int i; };" ]
  in
  let edits = bracket :: edits in
  words (before_typec_text (Emitter.emit text { edits; assertions = [] }))

let bracket =
  "#pragma pack(push) #pragma pack() struct s { int i; }; #pragma pack(pop)"

let anchors () =
  compares "a bracket after the forward declaration of a variant"
    (bracketed_after_forward "type e = | A | B(int x);")
    ("struct e; typedef struct e e; " ^ bracket
   ^ " enum e_tag { e_A, e_B }; struct e { enum e_tag tag; union { struct { \
      int x ; } B; } u; };");
  (* The declaration that a variant completes wrote the forward
     declaration (design 10.1 rule 7), so the bracket begins the text of
     the variant. *)
  compares "a bracket after the forward declaration of a completed variant"
    (bracketed_after_forward "type list; type list = | Nil;")
    ("struct list; typedef struct list list; " ^ bracket
   ^ " enum list_tag { list_Nil }; struct list { enum list_tag tag; };");
  compares "a bracket after the forward declaration of a record alias"
    (bracketed_after_forward "type pair = struct { pair *next; };")
    ("struct pair; typedef struct pair pair; " ^ bracket
   ^ " struct pair { pair *next; };");
  (* Only a type declaration at file scope that lowering writes with a
     forward declaration of its own has the anchor: an alias, a distinct
     type, an incomplete variant and a generic have none, nor has a
     variant in a block, which is no external declaration. *)
  let _, unit, _ =
    lowered
      "type a = int; type d = distinct int; type n; type n = | N;\n\
       type g(T) = | G(T x);\n\
       void f(void) { type b = | B; }"
  in
  let anchored = List.filter_map Tree.after_forward_declaration unit in
  compares "the anchors after forward declarations"
    (string_of_int (List.length anchored))
    "1"

(* Every application is a range that lowering replaces, so the time to
   lower a unit is linear in its applications, not in their square. *)
let many_applications () =
  let count = 20000 in
  let source =
    "type box(T) = struct { T value; };\n"
    ^ String.concat "" (List.init count (fun _ -> "box(int) *p;\n"))
  in
  let started = Sys.time () in
  let _, _, edits = lowered source in
  let took = Sys.time () -. started in
  compares "the edits of many applications"
    (string_of_int (List.length edits))
    (string_of_int (count + 2));
  if took > 2.0 then
    compares "the time to lower many applications"
      (Printf.sprintf "%.1f s" took)
      "under 2 s"

(* The words of [text] from the first [first] to the [last] after it,
   inclusive; empty where either is missing. *)
let between text ~first ~last =
  let find part from =
    let length = String.length part in
    let rec at index =
      if index + length > String.length text then None
      else if String.sub text index length = part then Some index
      else at (index + 1)
    in
    at from
  in
  match find first 0 with
  | None -> ""
  | Some start -> (
      match find last start with
      | None -> ""
      | Some stop -> String.sub text start (stop + String.length last - start))

(* Design 3.5 rule 6: an instance leaves out the text of each field
   whose type is void, with the comma after it; a constructor left
   without fields has no payload, and a variant left without payloads
   no union. [lowers_instance] compares the definition of the instance
   [name] that [source] uses, from its enumeration of tags to its end. *)
let lowers_instance case source name expected =
  let text = words (emitted source) in
  compares case
    (between text ~first:("enum " ^ name ^ "_tag") ~last:"#pragma pack(pop)")
    (expected ^ " #pragma pack(pop)")

(* Each field of an instance is looked up among its void fields in a
   set, so the time to lower a variant is linear in its fields, not in
   their square. *)
let many_void_fields () =
  let count = 32000 in
  let fields = List.init count (fun index -> Printf.sprintf "T x%d" index) in
  let source =
    "type many(T) = | A(" ^ String.concat ", " fields ^ ");\nmany(void) m;\n"
  in
  let started = Sys.time () in
  let text = emitted source in
  let took = Sys.time () -. started in
  compares "the instance without its many void fields"
    (between (words text) ~first:"enum many__v_tag" ~last:"#pragma pack(pop)")
    "enum many__v_tag { many__v_A }; struct many__v { enum many__v_tag tag; \
     }; #pragma pack(pop)";
  if took > 2.0 then
    compares "the time to lower many void fields"
      (Printf.sprintf "%.1f s" took)
      "under 2 s"

let void_fields () =
  let two = "type two(A, B) = | Two(A a, B b) | One(A only);\n" in
  lowers_instance "the first field void" (two ^ "two(void, long) t = One;")
    "two__vl"
    "enum two__vl_tag { two__vl_Two, two__vl_One }; struct two__vl { enum \
     two__vl_tag tag; union { struct { __tc_arg__l b ; } Two; } u; };";
  lowers_instance "the last field void" (two ^ "two(long, void) t = One(1);")
    "two__lv"
    "enum two__lv_tag { two__lv_Two, two__lv_One }; struct two__lv { enum \
     two__lv_tag tag; union { struct { __tc_arg__l a ; } Two; struct { \
     __tc_arg__l only ; } One; } u; };";
  lowers_instance "every field void" (two ^ "two(void, void) t = Two;")
    "two__vv"
    "enum two__vv_tag { two__vv_Two, two__vv_One }; struct two__vv { enum \
     two__vv_tag tag; };";
  (* The name that an application in a removed field lowers to goes
     with the field. *)
  lowers_instance "the middle field void"
    "type id(T) = T;\ntype three(A) = | Three(int a, id(A) b, long c);\n\
     three(void) t = Three(1, 2);"
    "three__v"
    "enum three__v_tag { three__v_Three }; struct three__v { enum \
     three__v_tag tag; union { struct { int a ; long c ; } Three; } u; };";
  compares "constructors of an instance with void fields"
    (between
       (words (emitted (two ^ "two(void, long) t = Two(1), u = One;")))
       ~first:"two__vl t =" ~last:"} ;")
    "two__vl t = { .tag = two__vl_Two, .u.Two = { 1 } } , u = { .tag = \
     two__vl_One } ;"

(* The edits inside the operand of a try are found by one search of the
   unit's edits, and each temporary is numbered from the one before it,
   so the time to lower a function is linear in its tries, not in their
   square. *)
let many_tries () =
  let count = 16000 in
  let source =
    "result(int, int) f(void) {\n"
    ^ String.concat ""
        (List.init count (fun _ -> "  try result(int, int).Ok(1);\n"))
    ^ "  return Ok(0);\n}\n"
  in
  let started = Sys.time () in
  let text = emitted source in
  let took = Sys.time () -. started in
  let last = Printf.sprintf "struct result__ii __tc_t%d" (count - 1) in
  compares "the temporary of the last of many tries"
    (between (words text) ~first:last ~last:"=")
    (last ^ " =");
  if took > 2.0 then
    compares "the time to lower many tries"
      (Printf.sprintf "%.1f s" took)
      "under 2 s"

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
  lowers "names that hold the word _Pragma"
    "type my_Pragma = int; type box = | my_Pragma_of(int v);"
    "typedef int my_Pragma ; struct box; typedef struct box box; enum \
     box_tag { box_my_Pragma_of }; struct box { enum box_tag tag; union { \
     struct { int v ; } my_Pragma_of; } u; };";
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
  anchors ();
  many_applications ();
  many_void_fields ();
  void_fields ();
  many_tries ();
  if !failures > 0 then exit 1
