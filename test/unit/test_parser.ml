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
      "(define (int) (function main (void)) (block (return 0)))";
    case "a definition with nested braces"
      "static int f(int x) { if (x) { return 1; } return 0; } int y;"
      "(define (static int) (function f (int x)) (block (if x (block \
       (return 1)) _) (return 0))) | (declaration (int) y)";
    case "a parenthesized function name" "int (f)(void) { }"
      "(define (int) (function (paren f) (void)) block)";
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
    case "an empty struct" "struct s {};" "(declaration ((struct s {})))";
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
      "(declaration (int) (init (array a) {}))";
    case "a comma alone" "int a[] = { , };"
      "error: in.i:1: expected an expression, found `,`";
    case "a range designator" "int a[] = { [0 ... 2] = 1, [3] = 2 };"
      "(declaration (int) (init (array a) ({} (designate ([...] 0 2) 1) \
       (designate ([] 3) 2))))";
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

(* Statements, in the body of [void f(void)]: the dump of its block. *)
let statement_case name body expected =
  case name
    ("void f(void) { " ^ body ^ " }")
    ("(define (void) (function f (void)) (block " ^ expected ^ "))")

let statement_cases =
  [
    statement_case "expression and null statements" "x = 1; ;"
      "(expr (= x 1)) ;";
    statement_case "declarations and statements mixed"
      "int a; a = 1; int b = a; { }"
      "(declaration (int) a) (expr (= a 1)) (declaration (int) (init b a)) \
       block";
    statement_case "if" "if (a) b;" "(if a (expr b) _)";
    statement_case "if and else" "if (a) b; else c;"
      "(if a (expr b) (expr c))";
    statement_case "a dangling else binds to the nearest if"
      "if (a) if (b) x; else y;" "(if a (if b (expr x) (expr y)) _)";
    statement_case "an else-if chain" "if (a) x; else if (b) y; else z;"
      "(if a (expr x) (if b (expr y) (expr z)))";
    statement_case "switch, case and default"
      "switch (a) { case 1: case 2: break; default: return; }"
      "(switch a (block (label (case 1) (label (case 2) break)) (label \
       default return)))";
    statement_case "a case value with a conditional"
      "switch (a) case 1 ? 2 : 3: ;" "(switch a (label (case (?: 1 2 3)) ;))";
    statement_case "while" "while (a) a--;" "(while a (expr (post-- a)))";
    statement_case "do" "do a++; while (a < 3);"
      "(do (expr (post++ a)) (< a 3))";
    statement_case "for without clauses" "for (;;) ;" "(for _ _ _ ;)";
    statement_case "for with expressions" "for (i = 0; i < n; i++) continue;"
      "(for (= i 0) (< i n) (post++ i) continue)";
    statement_case "for with a declaration" "for (int i = 0, j; ; ) break;"
      "(for (declaration (int) (init i 0) j) _ _ break)";
    statement_case "goto and a label" "goto end; end: return 1;"
      "(goto end) (label end (return 1))";
    statement_case "labels in a row" "a: b: ;" "(label a (label b ;))";
    statement_case "a block-scope _Static_assert" "_Static_assert(1, \"m\");"
      "(static-assert 1 (\"m\"))";
    statement_case "return with a comma expression" "return a, b;"
      "(return (, a b))";
  ]

(* Typedef names in block, parameter and statement scopes (C11 6.2.1). *)
let scope_cases =
  [
    case "a declarator's name is in scope from its end"
      "typedef int T; void f(void) { T T = sizeof(T), U = T; T * x; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (declaration (T) (init T (sizeof (paren T))) (init U T)) (expr \
       (* T x))))";
    case "an object hides a typedef name to the end of its block"
      "typedef int T; void f(void) { { int T; T * x; } T * y; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (block (declaration (int) T) (expr (* T x))) (declaration (T) \
       (pointer y))))";
    case "a typedef name in a block ends with it"
      "void f(void) { { typedef int T; T * p; } T * q; }"
      "(define (void) (function f (void)) (block (block (declaration \
       (typedef int) T) (declaration (T) (pointer p))) (expr (* T q))))";
    case "an enumerator hides a typedef name in a block"
      "typedef int A; void f(void) { enum { A }; A * y; }"
      "(declaration (typedef int) A) | (define (void) (function f (void)) \
       (block (declaration ((enum A))) (expr (* A y))))";
    case "the parameter scope continues in the body"
      "typedef int A; int f(enum { A } x) { A * y; }"
      "(declaration (typedef int) A) | (define (int) (function f ((enum A) \
       x)) (block (expr (* A y))))";
    case "a parameter hides a typedef name in the body"
      "typedef int T; void f(int T) { T * x; }"
      "(declaration (typedef int) T) | (define (void) (function f (int T)) \
       (block (expr (* T x))))";
    case "the parameters of the return type are not in the body"
      "typedef int T; int (*f(void))(int T) { T * x; }"
      "(declaration (typedef int) T) | (define (int) (function (paren \
       (pointer (function f (void)))) (int T)) (block (declaration (T) \
       (pointer x))))";
    case "a for declaration is in scope in the for statement only"
      "typedef int T; void f(void) { for (int T = 0; T; ) T * 2; T * x; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (for (declaration (int) (init T 0)) T _ (expr (* T 2))) \
       (declaration (T) (pointer x))))";
    case "a condition's declarations are in scope in both branches"
      "typedef int T; void f(void) { if (sizeof(enum { T = 1 })) T * 2; \
       else T * 3; T * x; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (if (sizeof-type (type (enum (T 1)))) (expr (* T 2)) (expr (* \
       T 3))) (declaration (T) (pointer x))))";
    case "a substatement's declarations end with it"
      "typedef int T; void f(void) { if (1) (void)sizeof(enum { T = 1 }); \
       else (T)1; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (if 1 (expr (cast (type void) (sizeof-type (type (enum (T \
       1)))))) (expr (cast (type T) 1)))))";
    case "a do body's declarations end before its condition"
      "typedef int T; void f(void) { do (void)sizeof(enum { T = 2 }); \
       while ((T)0); }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (do (expr (cast (type void) (sizeof-type (type (enum (T \
       2)))))) (cast (type T) 0))))";
    case "a while condition's declarations end with the statement"
      "typedef int T; void f(void) { while (sizeof(enum { T })) T * x; \
       T * y; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (while (sizeof-type (type (enum T))) (expr (* T x))) \
       (declaration (T) (pointer y))))";
    case "a switch's declarations end with the statement"
      "typedef int T; void f(void) { switch (sizeof(enum { T })) T * x; \
       T * y; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (switch (sizeof-type (type (enum T))) (expr (* T x))) \
       (declaration (T) (pointer y))))";
    case "a label opens no scope"
      "typedef int T; void f(void) { L: (void)sizeof(enum { T }); T * 2; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (label L (expr (cast (type void) (sizeof-type (type (enum \
       T)))))) (expr (* T 2))))";
    case "a label named as a typedef name"
      "typedef int T; void f(void) { T: ; T x; goto T; }"
      "(declaration (typedef int) T) | (define (void) (function f (void)) \
       (block (label T ;) (declaration (T) x) (goto T)))";
    case "an object named as a typedef name is no type after it"
      "typedef int T; void f(void) { T T; T x; }"
      "error: in.i:1: expected `;` after an expression, found `x`";
  ]

(* Old-style definitions and bodies that system headers define. *)
let definition_cases =
  [
    case "an old-style definition" "int f(a, b) int a; char *b; { return a; }"
      "(define (int) (function f (identifiers a b)) (declaration (int) a) \
       (declaration (char) (pointer b)) (block (return a)))";
    case "an old-style definition without declarations"
      "int f(a) { return a; }"
      "(define (int) (function f (identifiers a)) (block (return a)))";
    case "a typedef name in the declaration list"
      "typedef int T; int f(a) T a; { T * p; }"
      "(declaration (typedef int) T) | (define (int) (function f \
       (identifiers a)) (declaration (T) a) (block (declaration (T) (pointer \
       p))))";
    case "an enumerator of the declaration list is in scope in the body"
      "typedef int T; int f(a) enum { T } a; { return T * a; }"
      "(declaration (typedef int) T) | (define (int) (function f \
       (identifiers a)) (declaration ((enum T)) a) (block (return (* T \
       a))))";
    case "a declaration list only after an identifier list"
      "int f(int a) int b; { }"
      "error: in.i:1: expected `;` after a declaration, found `int`";
    case "a body in a system header is skipped"
      "# 1 \"in.i\"\n# 1 \"sys.h\" 1 3\n\
       static int g(void) { __asm__ volatile (\"\"); return 0; }\n\
       # 2 \"in.i\" 2\nint h(void) { return 0; }\n"
      "(define (static int) (function g (void)) {...}) | (define (int) \
       (function h (void)) (block (return 0)))";
    case "an unterminated body in a system header"
      "# 1 \"in.i\"\n# 1 \"sys.h\" 1 3\nint g(void) {\n"
      "error: sys.h:1: expected `}` to end the function body, found end of \
       input";
    case "a nested function definition" "void f(void) { int g(void) { } }"
      "error: in.i:1: expected `;` after a declaration, found `{`";
  ]

(* Spans are token indices; a pragma inside a node belongs to it. *)
let span_cases =
  [
    case "spans of a declaration" "int *p = &x;"
      "(declaration@0-6 (int@0-0) (init@1-5 (pointer@1-2 p@2-2) (&@4-5 \
       x@5-5)))";
    case "spans of a function definition" "int f(void) { { } }"
      "(define@0-8 (int@0-0) (function@1-4 f@1-1 (@3-3 void@3-3)) \
       (block@5-8 block@6-7))";
    case "spans of statements"
      "void f(void) { if (a) b;\n#pragma inner\nelse L: case 1: ; }"
      "(define@0-20 (void@0-0) (function@1-4 f@1-1 (@3-3 void@3-3)) \
       (block@5-20 (if@6-19 a@8-8 (expr@10-11 b@10-10) (label@14-19 L@14-15 \
       (label@16-19 (case@16-18 1@17-17) ;@19-19)))))";
    case "spans of loops and jumps"
      "void f(void) { do ; while (a); for (;;) goto L; }"
      "(define@0-21 (void@0-0) (function@1-4 f@1-1 (@3-3 void@3-3)) \
       (block@5-21 (do@6-12 ;@7-7 a@10-10) (for@13-20 _ _ _ (goto@18-20 \
       L@19-19))))";
    case "spans of while and switch"
      "void f(void) { while (a) switch (b) break; }"
      "(define@0-16 (void@0-0) (function@1-4 f@1-1 (@3-3 void@3-3)) \
       (block@5-16 (while@6-15 a@8-8 (switch@10-15 b@12-12 break@14-15))))";
    case "a pragma inside an expression"
      "int x = 1 +\n#pragma inner\n2;\n#pragma outer\n"
      "(declaration@0-7 (int@0-0) (init@1-6 x@1-1 (+@3-6 1@3-3 2@6-6)))";
    case "spans of chains" "int x = a = b ? c : d;"
      "(declaration@0-10 (int@0-0) (init@1-9 x@1-1 (=@3-9 a@3-3 (?:@5-9 \
       b@5-5 c@7-7 d@9-9))))";
  ]

(* The GNU profile (design 13.3). *)
let attribute_cases =
  [
    case "an attribute among the specifiers"
      "__attribute__((noreturn)) static void f(void);"
      "(declaration ((attributes noreturn) static void) (function f (void)))";
    case "attributes after a declarator"
      "int f(const char *, ...) __attribute__((__format__(__printf__, 1, \
       2), , unused)) __attribute__((cold));"
      "(declaration (int) (declarator (function f (const char pointer) ...) \
       (attributes (format ( __printf__ , 1 , 2 )) unused cold)))";
    case "version numbers in an argument"
      "void g(void) __attribute__((availability(macos,introduced=10.4.1)));"
      "(declaration (void) (declarator (function g (void)) (attributes \
       (availability ( macos , introduced = 10.4.1 )))))";
    case "a keyword as an attribute name"
      "int h(void) __attribute__((__const__));"
      "(declaration (int) (declarator (function h (void)) (attributes const)))";
    case "an empty attribute list" "int i __attribute__(()), j;"
      "(declaration (int) i j)";
    case "attributes of a structure"
      "struct __attribute__((packed)) s { char c; } \
       __attribute__((aligned(4))) v;"
      "(declaration ((struct (attribute packed) s (member (char) c) \
       (attribute (aligned ( 4 ))))) v)";
    case "attributes after a body belong to it"
      "struct s { int a; } __attribute__((packed)) *p;"
      "(declaration ((struct s (member (int) a) (attribute packed))) (pointer \
       p))";
    case "attributes of members"
      "struct t { int a __attribute__((aligned(8))); int b : 3 \
       __attribute__((packed)), : 0 __attribute__((x)); };"
      "(declaration ((struct t (member (int) (field a (attributes (aligned ( 8 \
       ))))) (member (int) (bits b 3 (attributes packed)) (bits 0 (attributes \
       x))))))";
    case "attributes of an enumeration and an enumerator"
      "enum __attribute__((flag_enum)) e { A __attribute__((deprecated)) = 1, \
       B } __attribute__((x));"
      "(declaration ((enum (attribute flag_enum) e (A (attributes deprecated) \
       1) B (attribute x))))";
    case "attributes of parameters"
      "void k(int x __attribute__((unused)), int __attribute__((y)));"
      "(declaration (void) (function k (int x (attributes unused)) (int \
       (attributes y))))";
    case "attributes before a function body"
      "int m(void) __attribute__((noinline)) { return 0; }"
      "(define (int) (function m (void)) (attributes noinline) (block (return \
       0)))";
    case "an attribute declaration in a block"
      "void f(int a) { switch (a) { case 1: f(2); \
       __attribute__((fallthrough)); case 2: ; } }"
      "(define (void) (function f (int a)) (block (switch a (block (label \
       (case 1) (expr (call f 2))) (declaration ((attributes fallthrough))) \
       (label (case 2) ;)))))";
  ]

let keyword_cases =
  [
    case "alternate spellings"
      "__const int a1; __volatile__ __signed__ char a2; char *__restrict a3; \
       static __inline__ int a4(void); __thread int a5; int a6 = \
       __alignof__(int);"
      "(declaration (const int) a1) | (declaration (volatile signed char) a2) \
       | (declaration (char) (pointer restrict a3)) | (declaration (static \
       inline int) (function a4 (void))) | (declaration (_Thread_local int) \
       a5) | (declaration (int) (init a6 (alignof (type int))))";
    case "__extension__ before declarations and expressions"
      "__extension__ typedef long long ll; struct { __extension__ int a; } v; \
       int x = __extension__ 1;"
      "(declaration (typedef long long) ll) | (declaration ((struct (member \
       (int) a))) v) | (declaration (int) (init x 1))";
    case "typeof of a type and of an expression"
      "typeof(int *) a; __typeof__(a) b; __typeof(1 + 2) c;"
      "(declaration ((typeof (type int pointer))) a) | (declaration ((typeof \
       a)) b) | (declaration ((typeof (+ 1 2))) c)";
    case "a typedef name after typeof is a declarator"
      "typedef int T; typeof(1) T;"
      "(declaration (typedef int) T) | (declaration ((typeof 1)) T)";
    case "_Float16" "_Float16 h(_Float16);"
      "(declaration (_Float16) (function h (_Float16)))";
    case "the builtin va_list type"
      "typedef __builtin_va_list va_list; int x = __builtin_va_arg(ap, int *);"
      "(declaration (typedef __builtin_va_list) va_list) | (declaration (int) \
       (init x (va_arg ap (type int pointer))))";
    case "offsetof" "int x = __builtin_offsetof(struct s, a.b[1].c);"
      "(declaration (int) (init x (offsetof (type (struct s)) a .b ([] 1) \
       .c)))";
    case "a lone semicolon at file scope" "int x;;"
      "(declaration (int) x) | ;";
    case "an ellipsis alone" "int f(...);"
      "(declaration (int) (function f ...))";
    case "a fixed underlying type"
      "typedef enum : unsigned char { C } small; enum f : long;"
      "(declaration (typedef (enum (: unsigned char) C)) small) | \
       (declaration ((enum f (: long))))";
    case "an enumeration bit-field" "struct u { enum e : 2; };"
      "(declaration ((struct u (member ((enum e)) (bits 2)))))";
    case "an attribute after a fixed type"
      "enum G : const int __attribute__((packed)) { D };"
      "(declaration ((enum G (: const int) (attribute packed) D)))";
    case "__complex__" "__complex__ double z;"
      "(declaration (_Complex double) z)";
    case "__extension__ before assembler and a lone semicolon"
      "__extension__ __asm__(\"\"); __extension__ ;"
      "(asm (\"\")) | ;";
  ]

let block_pointer_cases =
  [
    case "block pointers"
      "void (^b)(int); int (^ _Nonnull c)(void); void (^const d)(void);"
      "(declaration (void) (function (paren (block-pointer b)) (int))) | \
       (declaration (int) (function (paren (block-pointer _Nonnull c)) \
       (void))) | (declaration (void) (function (paren (block-pointer const \
       d)) (void)))";
    case "a block pointer parameter"
      "void k(int (^)(int) __attribute__((noescape)));"
      "(declaration (void) (function k (int (function (paren block-pointer) \
       (int)) (attributes noescape))))";
    case "nullability qualifiers"
      "int * _Nullable p; char * _Nonnull const q; void *_Null_unspecified r; \
       int *_Nullable_result s;"
      "(declaration (int) (pointer _Nullable p)) | (declaration (char) \
       (pointer _Nonnull const q)) | (declaration (void) (pointer \
       _Null_unspecified r)) | (declaration (int) (pointer _Nullable_result \
       s))";
  ]

let assembler_cases =
  [
    case "asm labels"
      "int n(void) __asm(\"_n\"); int o __asm__(\"_\" \"o\") = 1;"
      "(declaration (int) (declarator (function n (void)) (asm \"_n\"))) | \
       (declaration (int) (init o (asm \"_\" \"o\") 1))";
    case "an asm label and attributes"
      "int p(void) __asm(\"_p\") __attribute__((x));"
      "(declaration (int) (declarator (function p (void)) (asm \"_p\") \
       (attributes x)))";
    case "no asm label on a definition" "int q(void) __asm(\"_q\") { }"
      "error: in.i:1: expected `;` after a declaration, found `{`";
    case "file-scope assembler" "__asm__(\".globl x\");"
      "(asm (\".globl x\"))";
    statement_case "basic assembler" "asm(\"nop\");" "(asm (\"nop\"))";
    statement_case "a clobber only"
      "__asm__ __volatile__(\"\" ::: \"memory\");"
      "(asm volatile (\"\") outputs inputs (clobbers (\"memory\")) labels)";
    statement_case "operands"
      "asm(\"mov %1, %0\" : \"=r\"(d), \"=m\"(*p) : [src] \"r\"(s + 1) : \
       \"cc\");"
      "(asm (\"mov %1, %0\") (outputs (operand (\"=r\") d) (operand (\"=m\") \
       (* p))) (inputs (operand [src] (\"r\") (+ s 1))) (clobbers (\"cc\")) \
       labels)";
    statement_case "asm goto"
      "asm goto(\"jmp %l0\" :::: done, out); done: ;"
      "(asm goto (\"jmp %l0\") outputs inputs clobbers (labels done out)) \
       (label done ;)";
    statement_case "asm inline volatile" "asm inline volatile (\"\");"
      "(asm inline volatile (\"\"))";
  ]

let gnu_statement_cases =
  [
    case "a statement expression" "int x = ({ int y = 1; y + 1; });"
      "(declaration (int) (init x (({}) (block (declaration (int) (init y 1)) \
       (expr (+ y 1))))))";
    statement_case "a statement expression is a block scope"
      "typedef int T; int a = ({ typedef char T; T c = 1; c; }); T * p;"
      "(declaration (typedef int) T) (declaration (int) (init a (({}) (block \
       (declaration (typedef char) T) (declaration (T) (init c 1)) (expr \
       c))))) (declaration (T) (pointer p))";
    statement_case "nested statement expressions"
      "a = ({ ({ 1; }); }) + ({ 2; });"
      "(expr (= a (+ (({}) (block (expr (({}) (block (expr 1)))))) (({}) \
       (block (expr 2))))))";
    statement_case "a case range" "switch (a) { case 1 ... 3: break; }"
      "(switch a (block (label (case-range 1 3) break)))";
    statement_case "__extension__ in a block"
      "__extension__ int a = 1; __extension__ __extension__ (long)a++;"
      "(declaration (int) (init a 1)) (expr (cast (type long) (post++ a)))";
  ]

(* [__extension__] makes no node: the node around it holds it. *)
let gnu_span_cases =
  [
    case "spans of __extension__"
      "__extension__ int x = __extension__ 1;"
      "(declaration@0-6 (int@1-1) (init@2-5 x@2-2 1@5-5))";
    case "spans of attributes" "int f(void) __attribute__((a, b(1)));"
      "(declaration@0-16 (int@0-0) (declarator@1-15 (function@1-4 f@1-1 \
       (@3-3 void@3-3)) (attributes a@8-8 (b@10-13 ( 1 )@11-13))))";
  ]

let gnu_error_cases =
  [
    case "an attribute without its parentheses" "int x __attribute__(a);"
      "error: in.i:1: expected `((` after `__attribute__`, found `a`";
    case "unclosed attribute arguments" "int x __attribute__((a(1, 2;"
      "error: in.i:1: expected `)` to end the arguments of an attribute, \
       found end of input";
    case "a mismatched bracket in attribute arguments"
      "int x __attribute__((a(1]));"
      "error: in.i:1: expected `)`, found `]`";
    case "an attribute without a name" "int x __attribute__((1));"
      "error: in.i:1: expected an attribute name, found `1`";
    case "attributes without a comma" "int x __attribute__((a b));"
      "error: in.i:1: expected `,` or `)` after an attribute, found `b`";
    case "asm without parentheses" "void f(void) { asm volatile; }"
      "error: in.i:1: expected `(` after `asm`, found `;`";
    case "an operand without parentheses"
      "void f(void) { asm(\"\" : \"=r\" x); }"
      "error: in.i:1: expected `(` after the constraint of an operand, found \
       `x`";
    case "too many assembler sections"
      "void f(void) { asm(\"\" : : : : l : x); }"
      "error: in.i:1: expected `:` or `)` in `asm`, found `:`";
    case "typeof without parentheses" "typeof int x;"
      "error: in.i:1: expected `(` after `typeof`, found `int`";
    case "an unterminated statement expression" "int x = ({ 1; );"
      "error: in.i:1: expected an expression, found `)`";
    case "a mismatched bracket in a skipped body"
      "# 1 \"in.i\"\n# 1 \"sys.h\" 1 3\nint g(void) { ) }\n"
      "error: sys.h:1: expected `}`, found `)`";
    case "an inner mismatched bracket in attribute arguments"
      "int a __attribute__((aligned( ( } )));"
      "error: in.i:1: expected `)`, found `}`";
    case "a closer ends no conditional in a skipped body"
      "# 1 \"in.i\"\n# 1 \"sys.h\" 1 3\nint f(void) { a ? } int g(void) { \
       }\n"
      "error: sys.h:1: expected `:` of a conditional, found `}`";
    case "an enumeration as a fixed type"
      "enum E : enum F : int { A } { B };"
      "error: in.i:1: expected an integer type after `:`, found `enum`";
    case "a structure as a fixed type" "enum E : struct s { B };"
      "error: in.i:1: expected an integer type after `:`, found `struct`";
    case "a long chain of fixed types"
      ("enum E : "
      ^ String.concat "" (List.init 100_000 (fun _ -> "enum : "))
      ^ "int x;")
      "error: in.i:1: expected an integer type after `:`, found `enum`";
  ]

let error_cases =
  [
    case "an implicit int" "x;"
      "error: in.i:1: expected a declaration, found `x`";
    case "an unterminated body" "int f(void) {\n{\n"
      "error: in.i:2: expected `}` to end a compound statement, found end \
       of input";
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
    case "an ellipsis after an identifier list" "int f(a, ...);"
      "error: in.i:1: expected a parameter name, found `...`";
    case "too many brackets"
      ("int x = " ^ String.make (Parser.max_nesting + 1) '(')
      (Printf.sprintf
         "error: in.i:1: more than %d nested brackets or conditionals"
         Parser.max_nesting);
    case "if without parentheses" "void f(void) { if a; }"
      "error: in.i:1: expected `(` after `if`, found `a`";
    case "do without while" "void f(void) { do x; y; }"
      "error: in.i:1: expected `while` after the body of `do`, found `y`";
    case "else without if" "void f(void) { else x; }"
      "error: in.i:1: expected an expression, found `else`";
    case "a declaration after a label" "void f(void) { L: int x; }"
      "error: in.i:1: expected an expression, found `int`";
    case "do without its semicolon" "void f(void) { do ; while (1) }"
      "error: in.i:1: expected `;` after `do` ... `while`, found `}`";
    case "default without a colon" "void f(void) { switch (a) { default ; } }"
      "error: in.i:1: expected `:` after `default`, found `;`";
    case "case without a value" "void f(void) { switch (a) { case: ; } }"
      "error: in.i:1: expected an expression, found `:`";
    case "return without a semicolon" "int f(void) { return }"
      "error: in.i:1: expected an expression, found `}`";
    case "goto without a label" "void f(void) { goto 1; }"
      "error: in.i:1: expected a label after `goto`, found `1`";
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
    ("statements", "void f(void) " ^ around "{ if (a) " ";" " }");
    ("typeof", around "typeof(" "int" ")" ^ " x;");
    ( "attribute arguments",
      "int x __attribute__((a" ^ around "(" "" ")" ^ "));" );
    (* Each level opens two brackets. *)
    ( "statement expressions",
      "int x = "
      ^ repeat ((levels + 1) / 2) "({ "
      ^ "1"
      ^ repeat ((levels + 1) / 2) "; })"
      ^ ";" );
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
  let in_body statements = "void f(void) { " ^ statements ^ " }" in
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
      ("statements in a block", in_body (repeat length "a; "));
      ("ifs", in_body (repeat length "if (a) " ^ ";"));
      ("else-if chains", in_body (repeat length "if (a) ; else " ^ ";"));
      ( "dangling elses",
        in_body (repeat length "if (a) " ^ ";" ^ repeat length " else ;") );
      ("labels", in_body (repeat length "a: " ^ ";"));
      ("case labels", in_body ("switch (a) " ^ repeat length "case 1: " ^ ";"));
      ("default labels", in_body (repeat length "default: " ^ ";"));
      ("switches", in_body (repeat length "switch (a) " ^ ";"));
      ("whiles", in_body (repeat length "while (a) " ^ ";"));
      ("fors", in_body (repeat length "for (int i = 0;;) " ^ ";"));
      ( "dos",
        in_body (repeat length "do " ^ ";" ^ repeat length " while (a);") );
      ( "attribute specifiers",
        "int x" ^ repeat length " __attribute__((a))" ^ ";" );
      ("attributes in a list", "int x __attribute__((" ^ chain ", " "));");
      ("attribute arguments", "int x __attribute__((a(" ^ chain ", " ")));");
      ( "asm operands",
        in_body
          ("asm(\"\" : : "
          ^ String.concat ", " (List.init length (fun _ -> "\"r\"(a)"))
          ^ ");") );
      ( "case ranges",
        in_body ("switch (a) " ^ repeat length "case 1 ... 2: " ^ ";") );
      ("block pointers", "int " ^ String.make length '^' ^ "p;");
      ("nullability qualifiers", "int *" ^ repeat length "_Nonnull " ^ "p;");
      ("statement expressions in a row", in_body (repeat length "({ a; }); "));
      ("__extension__", "int x = " ^ repeat length "__extension__ " ^ "a;");
      ( "range designators",
        "int a[] = {" ^ repeat length "[0 ... 1] = 1, " ^ "};" );
      ( "offsetof designators",
        "int x = __builtin_offsetof(struct s, a" ^ repeat length ".a" ^ ");" );
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
        statement_cases;
        scope_cases;
        definition_cases;
        attribute_cases;
        keyword_cases;
        block_pointer_cases;
        assembler_cases;
        gnu_statement_cases;
        gnu_error_cases;
        error_cases;
      ]
    @ failed_cases ~spans:true (span_cases @ gnu_span_cases)
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
