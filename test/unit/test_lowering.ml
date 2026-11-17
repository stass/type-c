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

(* The text that [source] is read to, its tree and its declarations. *)
let read source =
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
  | Ok declarations -> (text, unit, declarations)
  | Error error -> failwith (Reader.error_message error)

(* The text that [source] is read to, its tree and its edits. *)
let lowered source =
  let text, unit, declarations = read source in
  (text, unit, Lowering.edits text declarations)

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

(* [run] takes time about linear in its size, from [small] on. *)
let grows_linearly name ~small run =
  match Timing.outgrows ~degree:1 ~small run with
  | None -> ()
  | Some times ->
      incr failures;
      Printf.eprintf "FAIL: %s\n  %s\n" name times

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
  let source count =
    "type box(T) = struct { T value; };\n"
    ^ String.concat "" (List.init count (fun _ -> "box(int) *p;\n"))
  in
  let small = 5000 in
  let _, _, edits = lowered (source small) in
  compares "the edits of many applications"
    (string_of_int (List.length edits))
    (string_of_int (small + 2));
  grows_linearly "the time to lower many applications" ~small
    (fun count -> ignore (lowered (source count)))

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
  let source count =
    let fields = List.init count (Printf.sprintf "T x%d") in
    "type many(T) = | A(" ^ String.concat ", " fields ^ ");\nmany(void) m;\n"
  in
  let small = 8000 in
  compares "the instance without its many void fields"
    (between
       (words (emitted (source small)))
       ~first:"enum many__v_tag" ~last:"#pragma pack(pop)")
    "enum many__v_tag { many__v_A }; struct many__v { enum many__v_tag tag; \
     }; #pragma pack(pop)";
  grows_linearly "the time to lower many void fields" ~small
    (fun count -> ignore (emitted (source count)))

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
  let source count =
    "result(int, int) f(void) {\n"
    ^ String.concat ""
        (List.init count (fun _ -> "  try result(int, int).Ok(1);\n"))
    ^ "  return Ok(0);\n}\n"
  in
  let small = 4000 in
  let last = Printf.sprintf "struct result__ii __tc_t%d" (small - 1) in
  compares "the temporary of the last of many tries"
    (between (words (emitted (source small))) ~first:last ~last:"=")
    (last ^ " =");
  grows_linearly "the time to lower many tries" ~small
    (fun count -> ignore (emitted (source count)))

(* The cleanups of the error paths are indexed by try once, so the time
   to lower many tries in the scope of a defer is linear in the tries,
   not in their square. *)
let many_tries_in_a_defer_scope () =
  let source count =
    "result(int, int) f(void) {\n  defer (void)0;\n"
    ^ String.concat ""
        (List.init count (fun _ -> "  try result(int, int).Ok(1);\n"))
    ^ "  return Ok(0);\n}\n"
  in
  let small = 4000 in
  (* The occurrences of the copy in [text]. *)
  let copies text =
    let copy = "{ ( void ) 0 ; }" in
    let width = String.length copy in
    let rec count from found =
      if from + width > String.length text then found
      else if String.sub text from width = copy then
        count (from + width) (found + 1)
      else count (from + 1) found
    in
    count 0 0
  in
  compares "each try and the return in the scope of a defer run its copy"
    (string_of_int (copies (words (emitted (source small)))))
    (string_of_int (small + 1));
  grows_linearly "the time to lower many tries in the scope of a defer"
    ~small (fun count -> ignore (emitted (source count)))

(* Design 6 and 13.5: each exit of the scope of a defer runs a copy of
   its statement, as a block, innermost and latest first; a jump that
   runs copies becomes a block that holds them and then the jump. *)
let many_defers () =
  let source count =
    "void g(int);\nvoid f(int c) {\n"
    ^ String.concat ""
        (List.init count (fun index ->
             Printf.sprintf "  defer g(%d);\n" index))
    ^ "}\n"
  in
  let small = 4000 in
  let text = words (emitted (source small)) in
  let ending = "{ g ( 1 ) ; } { g ( 0 ) ; } }" in
  compares "the copy of the first of many defers runs last"
    (String.sub text
       (String.length text - String.length ending)
       (String.length ending))
    ending;
  grows_linearly "the time to lower many defers" ~small
    (fun count -> ignore (emitted (source count)))

let trap = "__builtin_trap();"

let defers () =
  lowers "a defer at the end of a block"
    "void g(void); void f(void) { defer g(); g(); }"
    "void g(void); void f(void) { g(); { g ( ) ; } }";
  lowers "a defer that is the last item"
    "void g(void); void f(void) { defer g(); }"
    "void g(void); void f(void) { { g ( ) ; } }";
  lowers "two defers run in reverse order"
    "void a(void); void b(void); void f(void) { defer a(); defer b(); }"
    "void a(void); void b(void); void f(void) { { b ( ) ; } { a ( ) ; } }";
  lowers "the end of an inner block runs only its own"
    "void a(void); void b(void); void f(void) { defer a(); { defer b(); } \
     b(); }"
    "void a(void); void b(void); void f(void) { { { b ( ) ; } } b(); { a ( ) \
     ; } }";
  lowers "a break that leaves the scope"
    "void a(void); void f(int c) { while (c) { defer a(); if (c) break; } }"
    "void a(void); void f(int c) { while (c) { if (c) { { a ( ) ; } break ; \
     } { a ( ) ; } } }";
  lowers "a continue that leaves the scope"
    "void a(void); void f(int c) { for (;;) { defer a(); continue; } }"
    ("void a(void); void f(int c) { for (;;) { { { a ( ) ; } continue ; } "
   ^ trap ^ " } }");
  lowers "a break of a loop inside the scope runs nothing"
    "void a(void); void f(int c) { defer a(); while (c) break; }"
    "void a(void); void f(int c) { while (c) break; { a ( ) ; } }";
  lowers "a break of a switch after its labels"
    "void a(void); void f(int c) { switch (c) { case 1: { defer a(); L: \
     break; } } }"
    ("void a(void); void f(int c) { switch (c) { case 1: { L: { { a ( ) ; } \
      break ; } " ^ trap ^ " } } }");
  lowers "a return without a value"
    "void a(void); void f(int c) { defer a(); if (c) return; a(); }"
    "void a(void); void f(int c) { if (c) { { a ( ) ; } return ; } a(); { a \
     ( ) ; } }";
  lowers "a return leaves every scope, innermost first"
    "void a(void); void b(void); void f(int c) { defer a(); { defer b(); if \
     (c) return; } }"
    "void a(void); void b(void); void f(int c) { { if (c) { { b ( ) ; } { a \
     ( ) ; } return ; } { b ( ) ; } } { a ( ) ; } }";
  lowers "a return of a void expression"
    "void a(void); void f(void) { defer a(); return a(); }"
    ("void a(void); void f(void) { { a() ; { a ( ) ; } return; } " ^ trap
   ^ " }");
  lowers "a return of a value"
    "void a(void); long f(int x, char *s) { defer a(); return x; }"
    ("void a(void); long f(int x, char *s) { typedef \
      __typeof__(((__typeof__(f) *)0)(*(__typeof__(x) *)0, *(__typeof__(s) \
      *)0)) __tc_ret; { { __tc_ret __tc_r = ( x ); { a ( ) ; } return \
      __tc_r; } " ^ trap ^ " } }");
  lowers "a return of a value from a function without parameters"
    "void a(void); int f(void) { defer a(); if (1) return 1; return 2; }"
    ("void a(void); int f(void) { typedef \
      __typeof__(((__typeof__(f) *)0)()) __tc_ret; { if (1) { __tc_ret \
      __tc_r = ( 1 ); { a ( ) ; } return __tc_r; } { __tc_ret __tc_r = ( 2 \
      ); { a ( ) ; } return __tc_r; } " ^ trap ^ " } }");
  lowers "a return in the operand of a return"
    "void a(void); int f(int c) { defer a(); return ({ if (c) return 1; 2; \
     }); }"
    ("void a(void); int f(int c) { typedef \
      __typeof__(((__typeof__(f) *)0)(*(__typeof__(c) *)0)) __tc_ret; { { \
      __tc_ret __tc_r = ( ({ if (c) { __tc_ret __tc_r = ( 1 ); { a ( ) ; } \
      return __tc_r; } 2; }) ); { a ( ) ; } return __tc_r; } " ^ trap
   ^ " } }");
  compares "a return in the operand of a try runs the copies"
    (between
       (words
          (emitted
             "type r = result(int, int); r g(int); void a(void); r f(int c) \
              { defer a(); int x = try ({ if (c) return Ok(0); g(c); }); \
              return Ok(x); }"))
       ~first:"if ( c )" ~last:"{ a ( ) ; }")
    "if ( c ) { __tc_ret __tc_r = ( ((struct result__ii){ .tag = \
     result__ii_Ok, .u.Ok = { 0 } }) ); { a ( ) ; }";
  (* The text of [f] alone, after the definition of [o]. *)
  let tested_defer form =
    let text =
      words
        (emitted
           ("type o = | A(int x) | B; void a(int); void b(void); void f(o p) \
             { defer " ^ form ^ " b(); }"))
    in
    let start = String.length (between text ~first:"" ~last:"void f(o p)") in
    String.sub text start (String.length text - start)
  in
  compares "a single-pattern if that ends a deferred statement"
    (tested_defer "if (case A(v) = p) a(v);")
    " { b(); { { const struct o *const __tc_match = &( p ); const \
     __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == \
     o_A) { const __typeof__(__tc_match->u.A.x) v = __tc_match->u.A.x; a ( v \
     ) ; } else { switch (__tc_tag) { case o_A: case o_B: break; default: \
     __builtin_trap(); } } } } }";
  compares "a single-pattern if with else that ends a deferred statement"
    (tested_defer "if (case A(v) = p) a(v); else b();")
    " { b(); { { const struct o *const __tc_match = &( p ); const \
     __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == \
     o_A) { const __typeof__(__tc_match->u.A.x) v = __tc_match->u.A.x; a ( v \
     ) ; } else { switch (__tc_tag) { case o_A: case o_B: break; default: \
     __builtin_trap(); } b ( ) ; } } } }";
  compares "a single-pattern while that ends a deferred statement"
    (tested_defer "while (case A(v) = p) a(v);")
    " { b(); { for (;;) { const struct o *const __tc_match = &( p ); const \
     __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == \
     o_A) { const __typeof__(__tc_match->u.A.x) v = __tc_match->u.A.x; a ( v \
     ) ; } else { switch (__tc_tag) { case o_A: case o_B: break; default: \
     __builtin_trap(); } break; } } } }";
  lowers "a defer in a statement expression of a kept type name"
    "void g(void); int f(int x) { return _Generic(x, __typeof__(({ int y = \
     0; { defer g(); } y; })): 1, default: 0); }"
    "void g(void); int f(int x) { return _Generic(x, __typeof__(({ int y = \
     0; { { g ( ) ; } } y; })): 1, default: 0); }";
  lowers "a defer in a match arm runs at its jumps alone"
    "type e = | A | B; void a(void); void f(e v) { match (v) { case A: \
     defer a(); return; case B: return; } }"
    ("struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum \
      e_tag tag; }; void a(void); void f(e v) { { const struct e *const \
      __tc_match = &( v ); switch (__tc_match->tag) { case e_A: { { { a ( ) \
      ; } return ; } " ^ trap ^ " } case e_B: { return; " ^ trap
   ^ " } default: " ^ trap ^ " } } }")

(* Design 6 rule 1: a goto leaves the scopes that hold it and not its
   label, which a label before the defer is not in. *)
let goto_defers () =
  lowers "a goto out of the scope"
    "void a(void); void f(int c) { { defer a(); if (c) goto L; a(); } L: ; }"
    "void a(void); void f(int c) { { if (c) { { a ( ) ; } goto L ; } a(); { \
     a ( ) ; } } L: ; }";
  lowers "a goto out of two scopes, innermost first"
    "void a(void); void b(void); void f(int c) { { defer a(); { defer b(); \
     if (c) goto L; } } L: ; }"
    "void a(void); void b(void); void f(int c) { { { if (c) { { b ( ) ; } { \
     a ( ) ; } goto L ; } { b ( ) ; } } { a ( ) ; } } L: ; }";
  lowers "a goto out of the inner of two scopes"
    "void a(void); void b(void); void f(int c) { defer a(); { defer b(); if \
     (c) goto M; } M: ; }"
    "void a(void); void b(void); void f(int c) { { if (c) { { b ( ) ; } goto \
     M ; } { b ( ) ; } } M: ; { a ( ) ; } }";
  lowers "a goto within the scope runs nothing"
    "void a(void); void f(int c) { defer a(); L: if (c) goto L; if (c) goto \
     M; M: ; }"
    "void a(void); void f(int c) { L: if (c) goto L; if (c) goto M; M: ; { a \
     ( ) ; } }";
  lowers "a goto back to before the defer"
    "void a(void); void f(int c) { L: c--; defer a(); if (c) goto L; }"
    "void a(void); void f(int c) { L: c--; if (c) { { a ( ) ; } goto L ; } { \
     a ( ) ; } }";
  lowers "a goto out of a loop body"
    "void a(void); void f(int c) { while (c) { defer a(); if (c) goto out; \
     c--; } out: ; }"
    "void a(void); void f(int c) { while (c) { if (c) { { a ( ) ; } goto out \
     ; } c--; { a ( ) ; } } out: ; }";
  lowers "a labelled goto after its labels"
    "void a(void); void f(void) { { defer a(); M: goto L; } L: ; }"
    ("void a(void); void f(void) { { M: { { a ( ) ; } goto L ; } " ^ trap
   ^ " } L: ; }");
  lowers "a goto out of a statement expression in the scope"
    "void a(void); int f(int c) { { defer a(); c = ({ if (c) goto L; c; }); \
     } L: return c; }"
    "void a(void); int f(int c) { { c = ({ if (c) { { a ( ) ; } goto L ; } \
     c; }); { a ( ) ; } } L: return c; }";
  lowers "a goto out of a match arm"
    "type e = | A | B; void a(void); void f(e v, int c) { match (v) { case \
     A: defer a(); if (c) goto L; return; case B: return; } L: ; }"
    ("struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum \
      e_tag tag; }; void a(void); void f(e v, int c) { { const struct e \
      *const __tc_match = &( v ); switch (__tc_match->tag) { case e_A: { if \
      (c) { { a ( ) ; } goto L ; } { { a ( ) ; } return ; } " ^ trap
   ^ " } case e_B: { return; " ^ trap ^ " } default: " ^ trap
   ^ " } } L: ; }")

(* The places of each defer site of [source] (Reachability.place), which
   lowering, the check of the moved text and the pragma rule all read:
   the site's deferred statement, then each place in the order that
   Declarations checks them, by its kind and its tokens, or the line of
   its [}]. *)
let defer_places source =
  let text, _, declarations = read source in
  let spelled (span : Tree.span) =
    List.init (span.last - span.first + 1) (fun offset ->
        Reader.spelling text text.tokens.(span.first + offset))
    |> String.concat " "
  in
  let line index = string_of_int text.tokens.(index).location.line in
  let place : Reachability.place -> string = function
    | Block_end closing -> "end at line " ^ line closing
    | Trap closing -> "trap at line " ^ line closing
    | Left_by (Jump statement) -> "jump " ^ spelled statement
    | Left_by (Value_return { statement; operand = _ }) ->
        "return " ^ spelled statement
    | Left_by (Error_path try_span) -> "try " ^ spelled try_span
  in
  let site (site : Reachability.defer_site) =
    spelled site.deferred ^ ": "
    ^ String.concat ", " (List.map place site.places)
  in
  Expressions.defers (Declarations.typed declarations)
  |> List.concat_map (fun (defers : Expressions.function_defers) ->
         List.map site defers.sites)
  |> String.concat "; "

(* Design 6 rule 1 and 13.5: each scope has the exits that leave it and
   the end of its block, a trap where the block cannot complete and
   nothing at the end of a match arm. A break leaves the scope only if
   the loop it leaves holds the scope. *)
let places () =
  compares "the places of nested scopes, an arm, a jump and a try"
    (defer_places
       "type r = result(int, int); type e = | A | B; r g(int); void a(void);\n\
        void b(void); r f(e v, int c) {\n\
        defer a();\n\
        { defer b(); if (c) goto out; int x = try g(c); }\n\
        match (v) { case A: defer b(); return Ok(1); case B: return Ok(2); }\n\
        while (c) { defer b(); while (c) break; if (c) break; }\n\
        out: { defer b(); for (;;) ; }\n\
        }")
    "a ( ) ;: try try g ( c ), return return Ok ( 1 ) ;, return return Ok \
     ( 2 ) ;, trap at line 8; b ( ) ;: try try g ( c ), jump goto out ;, \
     end at line 4; b ( ) ;: return return Ok ( 1 ) ;; b ( ) ;: jump break \
     ;, end at line 6; b ( ) ;: trap at line 7"

(* Design 13.5, the [try] row: the error path of a try runs the copies
   of the scopes it stands in, innermost first, before its return. *)
let try_defers () =
  (* The error path of the try in [body], the text of [f], from its trap
     of a tag that is not Err to its return. *)
  let error_path body =
    let text =
      words
        (emitted
           ("type r = result(int, int); type o = | A(int x) | B; r g(int); \
             void a(void); void b(void); void k(int); r f(o p, int c) { "
           ^ body ^ " }"))
    in
    between text ~first:trap ~last:"return ("
  in
  let runs copies = trap ^ copies ^ " return (" in
  compares "a try in the scope of a defer"
    (error_path "defer a(); try g(c); return Ok(0);")
    (runs " { a ( ) ; }");
  compares "a try in two scopes"
    (error_path "defer a(); { defer b(); try g(c); } return Ok(0);")
    (runs " { b ( ) ; } { a ( ) ; }");
  compares "a try after two defers of one block"
    (error_path "defer a(); defer b(); try g(c); return Ok(0);")
    (runs " { b ( ) ; } { a ( ) ; }");
  compares "a try before the defer runs nothing"
    (error_path "try g(c); defer a(); return Ok(0);")
    (runs "");
  compares "a try in a loop body with a defer"
    (error_path
       "defer b(); while (c) { defer a(); int x = try g(c); c = x; } return \
        Ok(0);")
    (runs " { a ( ) ; } { b ( ) ; }");
  (* The copy is the text of S with its own edits, which lowering the
     defer moves out of the text. *)
  compares "a try in the scope of a defer whose statement is lowered"
    (error_path "defer if (case A(v) = p) k(v); try g(c); return Ok(0);")
    (runs
       " { { const struct o *const __tc_match = &( p ); const \
        __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag \
        == o_A) { const __typeof__(__tc_match->u.A.x) v = \
        __tc_match->u.A.x; k ( v ) ; } else { switch (__tc_tag) { case o_A: \
        case o_B: break; default: __builtin_trap(); } } } }")

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
  many_tries_in_a_defer_scope ();
  many_defers ();
  defers ();
  goto_defers ();
  places ();
  try_defers ();
  if !failures > 0 then exit 1
