(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_test_support

(* A text, read as from the file "in.i", and the dump of its external
   declarations, separated by " | ", or its error. *)
type case = { name : string; text : string; expected : string }

let case name text expected = { name; text; expected }

let outcome ~spans text =
  match Reader.read ~name:"in.i" text with
  | Error error -> "read error: " ^ Reader.error_message error
  | Ok reader -> (
      match Parser.parse reader with
      | Error error -> "error: " ^ Parser.error_message error
      | Ok unit -> (
          let dump = Tree_dump.translation_unit reader unit in
          match Tree_dump.span_violation (Tree_dump.group dump) with
          | Some violation -> "span violation: " ^ violation
          | None ->
              List.map (Tree_dump.to_string ~spans) dump
              |> String.concat " | "))

let declarator_cases =
  [
    case "a plain declaration" "int x;" "(declaration (int) x)";
    case "several declarators" "int x, *p, a[3];"
      "(declaration (int) x (pointer p) (array a 3))";
    case "qualified pointers" "char *const *volatile p;"
      "(declaration (char) (pointer const (pointer volatile p)))";
    case "an array of pointers" "int *a[3];"
      "(declaration (int) (pointer (array a 3)))";
    case "a pointer to an array" "int (*p)[3];"
      "(declaration (int) (array (paren (pointer p)) 3))";
    case "arrays of arrays" "int m[2][3];"
      "(declaration (int) (array (array m 2) 3))";
    case "a function returning a pointer to an array of three"
      "int (*(*f)(int))[3];"
      "(declaration (int) (array (paren (pointer (function (paren (pointer \
       f)) (int)))) 3))";
    case "signal" "void (*signal(int, void (*)(int)))(int);"
      "(declaration (void) (function (paren (pointer (function signal (int) \
       (void (function (paren pointer) (int)))))) (int)))";
    case "a variadic prototype" "int printf(const char *, ...);"
      "(declaration (int) (function printf (const char pointer) ...))";
    case "void parameters" "int f(void);"
      "(declaration (int) (function f (void)))";
    case "an old-style declaration" "int f(a, b);"
      "(declaration (int) (function f (identifiers a b)))";
    case "no parameters" "int f();"
      "(declaration (int) (function f (identifiers)))";
    case "parameter arrays"
      "void f(int a[static 3], int b[const 4], int c[const static 5], int \
       d[*], int e[]);"
      "(declaration (void) (function f (int (array a static 3)) (int (array \
       b const 4)) (int (array c const static 5)) (int (array d *)) (int \
       (array e))))";
    case "an abstract array of pointers to functions"
      "void f(int (*[2])(void));"
      "(declaration (void) (function f (int (function (paren (pointer \
       (array 2))) (void)))))";
    case "a variable-length array parameter" "void f(int n, int a[n]);"
      "(declaration (void) (function f (int n) (int (array a n))))";
    case "storage classes and specifiers"
      "static inline _Noreturn void f(void); extern _Thread_local int t; \
       register int r; auto int a;"
      "(declaration (static inline _Noreturn void) (function f (void))) | \
       (declaration (extern _Thread_local int) t) | (declaration (register \
       int) r) | (declaration (auto int) a)";
    case "a multiset of type specifiers" "unsigned long long int x;"
      "(declaration (unsigned long long int) x)";
    case "_Atomic as specifier and qualifier"
      "_Atomic(int) a; _Atomic int b; int *_Atomic c;"
      "(declaration ((atomic (type int))) a) | (declaration (_Atomic int) \
       b) | (declaration (int) (pointer _Atomic c))";
    case "_Alignas" "_Alignas(16) char a[4]; _Alignas(long) char b;"
      "(declaration ((alignas 16) char) (array a 4)) | (declaration \
       ((alignas (type long)) char) b)";
    case "_Static_assert" "_Static_assert(sizeof(int) == 4, \"int\" \"32\");"
      "(static-assert (== (sizeof-type (type int)) 4) (\"int\" \"32\"))";
    case "a function definition" "int main(void) { return 0; }"
      "(define (int) (function main (void)) {...})";
    case "a definition with nested braces"
      "static int f(int x) { if (x) { return 1; } return 0; } int y;"
      "(define (static int) (function f (int x)) {...}) | (declaration (int) \
       y)";
    case "a parenthesized function name" "int (f)(void) { }"
      "(define (int) (function (paren f) (void)) {...})";
    case "complex" "double _Complex z; _Bool b;"
      "(declaration (double _Complex) z) | (declaration (_Bool) b)";
  ]

let typedef_cases =
  [
    case "a typedef name as a type" "typedef int T; T * x;"
      "(declaration (typedef int) T) | (declaration (T) (pointer x))";
    case "several typedef names in one declaration"
      "typedef int T, *P; P p; T t;"
      "(declaration (typedef int) T (pointer P)) | (declaration (P) p) | \
       (declaration (T) t)";
    case "a typedef name is in scope after its declarator"
      "typedef int T, A[sizeof(T)];"
      "(declaration (typedef int) T (array A (sizeof-type (type T))))";
    case "a cast and a call" "typedef int T; int f; int a = (T)(x), b = (f)(x);"
      "(declaration (typedef int) T) | (declaration (int) f) | (declaration \
       (int) (init a (cast (type T) (paren x))) (init b (call (paren f) x)))";
    case "a type specifier ends the typedef name" "typedef int T; unsigned T;"
      "(declaration (typedef int) T) | (declaration (unsigned) T)";
    case "a qualifier does not end it" "typedef int T; const T x;"
      "(declaration (typedef int) T) | (declaration (const T) x)";
    case "a typedef name redeclared as a parameter"
      "typedef int T; void f(int T, int a[sizeof T]); T y;"
      "(declaration (typedef int) T) | (declaration (void) (function f (int \
       T) (int (array a (sizeof T))))) | (declaration (T) y)";
    case "a parameter shadows the typedef name until the prototype ends"
      "typedef int T; void f(int T, T x);"
      "error: in.i:1: expected a parameter declaration, found `T`";
    case "a typedef name in parentheses is a parameter list"
      "typedef int T; void f(int (T));"
      "(declaration (typedef int) T) | (declaration (void) (function f (int \
       (function (T)))))";
    case "a typedef name as a member name"
      "typedef int T; struct s { int T; T x; };"
      "(declaration (typedef int) T) | (declaration ((struct s (member (int) \
       T) (member (T) x))))";
    case "a typedef name as a tag" "typedef struct T T; struct T *p;"
      "(declaration (typedef (struct T)) T) | (declaration ((struct T)) \
       (pointer p))";
    case "an enumerator shadows a typedef name in a prototype"
      "typedef int T; void f(enum { T } e); T y;"
      "(declaration (typedef int) T) | (declaration (void) (function f \
       ((enum T) e))) | (declaration (T) y)";
    case "an object hides a typedef name" "typedef int T; int T; int x = T;"
      "(declaration (typedef int) T) | (declaration (int) T) | (declaration \
       (int) (init x T))";
    case "a type name is not an expression" "typedef int T; int x = T;"
      "error: in.i:1: expected an expression, found the type name `T`";
    case "sizeof a type and an expression"
      "typedef int T; int a = sizeof(T), b = sizeof(a), c = sizeof a;"
      "(declaration (typedef int) T) | (declaration (int) (init a \
       (sizeof-type (type T))) (init b (sizeof (paren a))) (init c (sizeof \
       a)))";
  ]

let aggregate_cases =
  [
    case "a struct with bit-fields"
      "struct s { unsigned a : 3, : 0; int b, *c; } v;"
      "(declaration ((struct s (member (unsigned) (bits a 3) (bits 0)) \
       (member (int) b (pointer c)))) v)";
    case "anonymous members"
      "struct s { union { int i; float f; }; struct { int x; }; };"
      "(declaration ((struct s (member ((union (member (int) i) (member \
       (float) f)))) (member ((struct (member (int) x)))))))";
    case "a member _Static_assert"
      "struct s { int a; _Static_assert(1, \"m\"); };"
      "(declaration ((struct s (member (int) a) (static-assert 1 (\"m\")))))";
    case "a tag reference" "struct s; union u *p;"
      "(declaration ((struct s))) | (declaration ((union u)) (pointer p))";
    case "an enum" "enum e { A, B = 2, C = B + 1, };"
      "(declaration ((enum e A (B 2) (C (+ B 1)))))";
    case "an enumerator is in scope after it" "enum { A, B = A };"
      "(declaration ((enum A (B A))))";
    case "an empty struct" "struct s {};"
      "error: in.i:1: expected a member declaration, found `}`";
    case "a struct with neither tag nor body" "struct;"
      "error: in.i:1: expected a tag or `{` after `struct` or `union`, found \
       `;`";
  ]

let initialiser_cases =
  [
    case "a braced list" "int a[] = { 1, 2, 3, };"
      "(declaration (int) (init (array a) ({} 1 2 3)))";
    case "designators"
      "struct p v = { .x = 1, [2].y = 3, [0] = { 4 }, 5 };"
      "(declaration ((struct p)) (init v ({} (designate .x 1) (designate \
       ([] 2) .y 3) (designate ([] 0) ({} 4)) 5)))";
    case "a string initialiser" "char s[] = \"ab\" L\"c\";"
      "(declaration (char) (init (array s) (string \"ab\" L\"c\")))";
    case "an empty list" "int a[] = {};"
      "error: in.i:1: expected an expression, found `}`";
    case "a designator without =" "int a[] = { [0] 1 };"
      "error: in.i:1: expected `=` after a designator, found `1`";
  ]

(* Each expression is the initialiser of [x]. *)
let expression_case name expression expected =
  case name
    ("int x = " ^ expression ^ ";")
    ("(declaration (int) (init x " ^ expected ^ "))")

let expression_cases =
  [
    expression_case "multiplicative over additive" "a + b * c - d / e % f"
      "(- (+ a (* b c)) (% (/ d e) f))";
    expression_case "shift below additive" "a << b + c >> d"
      "(>> (<< a (+ b c)) d)";
    expression_case "relational below shift" "a < b << c"
      "(< a (<< b c))";
    expression_case "relational operators" "a < b > c <= d >= e"
      "(>= (<= (> (< a b) c) d) e)";
    expression_case "equality below relational" "a == b < c != d"
      "(!= (== a (< b c)) d)";
    expression_case "bitwise and, xor, or" "a | b ^ c & d == e"
      "(| a (^ b (& c (== d e))))";
    expression_case "logical and below bitwise or" "a && b | c"
      "(&& a (| b c))";
    expression_case "logical or below logical and" "a || b && c || d"
      "(|| (|| a (&& b c)) d)";
    expression_case "conditional below logical or" "a || b ? c : d"
      "(?: (|| a b) c d)";
    expression_case "conditional is right-associative" "a ? b : c ? d : e"
      "(?: a b (?: c d e))";
    expression_case "a comma in the middle operand" "a ? b, c : d"
      "(?: a (, b c) d)";
    expression_case "assignment is right-associative" "a = b += c <<= d"
      "(= a (+= b (<<= c d)))";
    expression_case "every compound assignment"
      "a *= b /= c %= d -= e >>= f &= g ^= h |= i"
      "(*= a (/= b (%= c (-= d (>>= e (&= f (^= g (|= h i))))))))";
    expression_case "a comma expression in parentheses" "(a, b = c, d)"
      "(paren (, (, a (= b c)) d))";
    expression_case "unary operators" "-a + !b * ~c - &d - *e - +f"
      "(- (- (- (+ (- a) (* (! b) (~ c))) (& d)) (* e)) (+ f))";
    expression_case "prefix and postfix" "++a - b-- + --c - d++"
      "(- (+ (- (++ a) (post-- b)) (-- c)) (post++ d))";
    expression_case "postfix binds tighter than prefix" "*p++"
      "(* (post++ p))";
    expression_case "postfix chains" "a[1].b->c(2, 3)[4]"
      "(index (call (-> (. (index a 1) b) c) 2 3) 4)";
    expression_case "a call without arguments" "f()" "(call f)";
    expression_case "sizeof binds tighter than a binary operator"
      "sizeof a + 1"
      "(+ (sizeof a) 1)";
    expression_case "sizeof of sizeof" "sizeof sizeof ++a"
      "(sizeof (sizeof (++ a)))";
    expression_case "_Alignof" "_Alignof(char *)"
      "(alignof (type char pointer))";
    expression_case "casts" "(unsigned char)(long)-a"
      "(cast (type unsigned char) (cast (type long) (- a)))";
    expression_case "a cast binds tighter than a binary operator"
      "(int)a + b"
      "(+ (cast (type int) a) b)";
    expression_case "a compound literal" "(struct p){ .x = 1 }.x"
      "(. (literal (type (struct p)) ({} (designate .x 1))) x)";
    expression_case "sizeof a compound literal" "sizeof (int[]){ 1, 2 }"
      "(sizeof (literal (type int array) ({} 1 2)))";
    expression_case "_Generic"
      "_Generic(a, int: 1, char *: 2, default: 3)"
      "(generic a (case (type int) 1) (case (type char pointer) 2) (default \
       3))";
    expression_case "constants" "1u + 2.5f + 'c' + L'd' + 0x1p3"
      "(+ (+ (+ (+ 1u 2.5f) 'c') L'd') 0x1p3)";
    expression_case "concatenated strings" "\"a\" \"b\""
      "(string \"a\" \"b\")";
  ]

(* Spans are token indices; a pragma inside a node belongs to it. *)
let span_cases =
  [
    case "spans of a declaration" "int *p = &x;"
      "(declaration@0-6 (int@0-0) (init@1-5 (pointer@1-2 p@2-2) (&@4-5 \
       x@5-5)))";
    case "spans of a function definition" "int f(void) { { } }"
      "(define@0-8 (int@0-0) (function@1-4 f@1-1 (@3-3 void@3-3)) {...}@5-8)";
    case "a pragma inside an expression"
      "int x = 1 +\n#pragma inner\n2;\n#pragma outer\n"
      "(declaration@0-7 (int@0-0) (init@1-6 x@1-1 (+@3-6 1@3-3 2@6-6)))";
    case "spans of chains" "int x = a = b ? c : d;"
      "(declaration@0-10 (int@0-0) (init@1-9 x@1-1 (=@3-9 a@3-3 (?:@5-9 \
       b@5-5 c@7-7 d@9-9))))";
  ]

let error_cases =
  [
    case "an implicit int" "x;"
      "error: in.i:1: expected a declaration, found `x`";
    case "a GNU attribute"
      "int f(void) __attribute__((noreturn));"
      "error: in.i:1: expected `;` after a declaration, found \
       `__attribute__`";
    case "__extension__" "__extension__ int x;"
      "error: in.i:1: expected a declaration, found `__extension__`";
    case "a lone semicolon" "int x;;"
      "error: in.i:1: expected a declaration, found `;`";
    case "an unterminated body" "int f(void) {\n{\n"
      "error: in.i:2: expected `}` to end the function body, found end of \
       input";
    case "a body after a non-function" "int x { }"
      "error: in.i:1: expected `;` after a declaration, found `{`";
    case "a body after a pointer to a function" "int (*f)(void) { }"
      "error: in.i:1: expected `;` after a declaration, found `{`";
    case "a missing declarator" "int *;"
      "error: in.i:1: expected a declarator, found `;`";
    case "a pp-number that is no constant" "int x = 1.2.3;"
      "error: in.i:1: expected a constant, found the preprocessing number \
       `1.2.3`";
    case "a keyword as a member name" "int x = a.int;"
      "error: in.i:1: expected a member name after `.`, found `int`";
    case "a statement keyword at file scope" "if (x) y;"
      "error: in.i:1: expected a declaration, found `if`";
    case "an error on a later line" "int x;\nint y = (1;\n"
      "error: in.i:2: expected `)` after an expression, found `;`";
    case "a long token is shortened"
      ("int x = 1 \"" ^ String.make 60 'a' ^ "\";")
      ("error: in.i:1: expected `;` after a declaration, found `\""
      ^ String.make 39 'a' ^ "...`");
    case "a cast where a unary expression must be" "int x = ++(int)a;"
      "error: in.i:1: expected `{` of a compound literal, found `a`";
    case "a parameter list after an abstract declarator in a type name"
      "int x = sizeof(int (a));"
      "error: in.i:1: expected a declarator, found `a`";
    case "_Imaginary is not in the grammar" "_Imaginary float x;"
      "error: in.i:1: expected a declaration, found `_Imaginary`";
    case "the left operand of = is a unary expression" "int x = a + b = c;"
      "error: in.i:1: the left operand of `=` is not a unary expression";
    case "nor a cast" "int x = (int)a = 1;"
      "error: in.i:1: the left operand of `=` is not a unary expression";
    case "the last operand of ?: is not an assignment"
      "int x = (a ? b : c = d);"
      "error: in.i:1: the left operand of `=` is not a unary expression";
    case "a typedef name ends an identifier list"
      "typedef int T; int f(a, T);"
      "error: in.i:1: expected a parameter name, found the type name `T`";
    case "an ellipsis alone" "int f(...);"
      "error: in.i:1: expected a parameter declaration, found `...`";
    case "too many brackets"
      ("int x = " ^ String.make (Parser.max_nesting + 1) '(')
      (Printf.sprintf
         "error: in.i:1: more than %d nested brackets or conditionals"
         Parser.max_nesting);
    case "an empty file" "" "";
    case "only pragmas" "#pragma once\n#pragma typec checked\n" "";
  ]

let repeat count text = String.concat "" (List.init count (fun _ -> text))

(* Declarations whose [:] tokens close no [?], so that the brackets the
   cursor counts would be out of step after them if a [:] closed the
   wrong thing. *)
let colons =
  "int g = _Generic(a, int: 1, default: a ? 2 : 3);\n\
   struct bits { int f : 1 ? 2 : 3; int : 4; \
   int s[sizeof(struct { int q : 1; })]; };\n\
   int d[] = { [a ? 1 : 2] = 0 };\n\
   int body(void) { L: switch (a) { case 1 ? 2 : 3: break; default: ; } }\n"

(* Texts that nest [levels] deep in each construct the parser recurses
   into, after [colons]. *)
let nesting_texts levels =
  let around opening inner closing =
    repeat levels opening ^ inner ^ repeat levels closing
  in
  List.map (fun (name, text) -> (name, colons ^ text))
  [
    ("parentheses", "int x = " ^ around "(" "1" ")" ^ ";");
    ("conditionals", "int x = " ^ around "a ? " "b" " : c" ^ ";");
    ("subscripts", "int x = a" ^ around "[a" "" "]" ^ ";");
    ("declarators", "int " ^ around "(" "x" ")" ^ ";");
    ("initialisers", "int x = " ^ around "{" "1" "}" ^ ";");
    ("structs", "struct s { " ^ around "struct { " "int x;" " } m;" ^ " };");
    ("type names", around "_Atomic(" "int" ")" ^ " x;");
    ("a function body", "int f(void) " ^ around "{" "" "}");
  ]

(* Each construct parses just within the bound and fails just beyond it,
   at the token where it went too deep. *)
let failed_nesting_cases () =
  let parses text =
    match Reader.read ~name:"in.i" text with
    | Error _ -> Some "read error"
    | Ok reader -> (
        match Parser.parse reader with
        | Ok _ -> None
        | Error error -> Some error.message)
  in
  let too_deep =
    Printf.sprintf "more than %d nested brackets or conditionals"
      Parser.max_nesting
  in
  let within = nesting_texts (Parser.max_nesting - 8)
  and beyond = nesting_texts (Parser.max_nesting + 1) in
  List.concat
    [
      List.filter_map
        (fun (name, text) ->
          Option.map (fun message -> (name ^ " within the bound", message))
            (parses text))
        within;
      List.filter_map
        (fun (name, text) ->
          match parses text with
          | Some message when message = too_deep -> None
          | Some message -> Some (name ^ " beyond the bound", message)
          | None -> Some (name ^ " beyond the bound", "parsed"))
        beyond;
    ]

(* Chains that the parser reads in loops, so their length is not bounded
   by the nesting bound. *)
let failed_chain_cases () =
  let length = 100_000 in
  let chain separator last =
    String.concat separator (List.init length (fun _ -> "a")) ^ last
  in
  let texts =
    [
      ("binary operators", "int x = " ^ chain " + " ";");
      ("assignments", "int x = " ^ chain " = " ";");
      ("conditionals", "int x = " ^ chain " ? a : " ";");
      ("comma operators", "int x = (" ^ chain ", " ");");
      ("sizeof", "int x = " ^ repeat length "sizeof " ^ "a;");
      ("unary operators", "int x = " ^ repeat length "- " ^ "a;");
      ("increments", "int x = " ^ repeat length "++" ^ "a;");
      ("casts", "int x = " ^ repeat length "(int)" ^ "a;");
      ("postfix operators", "int x = a" ^ repeat length "[0]" ^ ";");
      ("pointers", "int " ^ String.make length '*' ^ "p;");
      ("arrays", "int a" ^ repeat length "[1]" ^ ";");
      ("a body", "int f(void) {" ^ repeat length "{}" ^ "}");
    ]
  in
  List.filter_map
    (fun (name, text) ->
      match Reader.read ~name:"in.i" text with
      | Error _ -> Some (name, "read error")
      | Ok reader -> (
          match Parser.parse reader with
          | Ok _ -> None
          | Error error -> Some (name, error.message)))
    texts

let () =
  let failed_cases ~spans cases =
    List.filter_map
      (fun case ->
        let actual = outcome ~spans case.text in
        if actual = case.expected then None else Some (case, actual))
      cases
  in
  let failed =
    List.concat_map (failed_cases ~spans:false)
      [
        declarator_cases;
        typedef_cases;
        aggregate_cases;
        initialiser_cases;
        expression_cases;
        error_cases;
      ]
    @ failed_cases ~spans:true span_cases
  in
  List.iter
    (fun (case, actual) ->
      Printf.eprintf "FAIL: %s\n  expected: %s\n  actual:   %s\n" case.name
        case.expected actual)
    failed;
  let failed_limits = failed_nesting_cases () @ failed_chain_cases () in
  List.iter
    (fun (name, message) -> Printf.eprintf "FAIL: %s: %s\n" name message)
    failed_limits;
  if failed <> [] || failed_limits <> [] then exit 1
