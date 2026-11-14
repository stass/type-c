(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The types that expression typing gives (C11 6.3, 6.5) and the
   constraints it checks in function bodies (6.8), on an LP64 and an ILP32
   target. *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let lp64 = Canned_targets.target Canned_targets.lp64_macros
let ilp32 = Canned_targets.target Canned_targets.ilp32_macros

(* Declarations that most cases use. *)
let prelude =
  "struct s { int m; const char k; unsigned b : 3; } s; const struct s cs; \
   struct s *ps; int x; const int cx; char c; unsigned short us; \
   unsigned u; long l; unsigned long ul; double d; const char *p; int *ip; \
   const int *cip; void *vp; const void *cvp; int a[3]; int f(int); \
   int g(int, ...); int h(); int (*fp)(int); _Complex double z; \
   _Complex float zf; enum { A } e; int half __attribute__((vector_size(16))); "

let read target source =
  let text =
    match Reader.read ~name:"in.c" source with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  match Parser.parse ~keywords:(Target.keywords target Gnu) text with
  | Ok unit ->
      Result.map
        (fun result -> (unit, result))
        (Declarations.read target text unit)
  | Error error -> failwith (Parser.error_message error)

(* The last expression statement of the body of [t]. *)
let probed (unit : Tree.translation_unit) =
  let in_body = function
    | Tree.Function_definition
        { node = { declarator; body = Parsed block; _ }; _ }
      when Tree.declared_name declarator = Some "t" -> (
        match List.rev block.node.items with
        | Block_statement { node = Expression_statement e; _ } :: _ -> Some e
        | _ -> None)
    | _ -> None
  in
  List.find_map in_body unit

let describe (typed : Expressions.typed) =
  String.concat ""
    [ Type_name.of_ctype typed.expression_type;
      (if typed.lvalue then " lvalue" else "");
      (match typed.bit_field with
      | Bit_field width -> Printf.sprintf " :%d" width
      | Bit_field_value width -> Printf.sprintf " value:%d" width
      | Not_bit_field -> "") ]

let failures = ref 0

let fail_case source message =
  incr failures;
  Printf.eprintf "FAIL: %s\n  %s\n" source message

let in_function ?(declarations = prelude) ?(parameters = "void") body =
  declarations ^ "void t(" ^ parameters ^ ") { " ^ body ^ "; }"

(* The last expression of [body] has the type [expected] describes. *)
let types ?(target = lp64) ?declarations ?parameters body expected =
  let source = in_function ?declarations ?parameters body in
  match read target source with
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)
  | Ok (unit, result) -> (
      match Option.bind (probed unit) (Declarations.expression result) with
      | None -> fail_case source "the expression is not typed"
      | Some typed ->
          let actual = describe typed in
          if actual <> expected then
            fail_case source (Printf.sprintf "%S, expected %S" actual expected))

let contains text part =
  let length = String.length part in
  let rec at index =
    index + length <= String.length text
    && (String.sub text index length = part || at (index + 1))
  in
  at 0

let rejects_source ?(target = lp64) source expected =
  match read target source with
  | Ok _ -> fail_case source "accepted"
  | Error { message; _ } ->
      if not (contains message expected) then
        fail_case source (Printf.sprintf "message %S lacks %S" message expected)

let rejects ?target ?declarations body expected =
  rejects_source ?target (in_function ?declarations body) expected

let accepts_source ?(target = lp64) source =
  match read target source with
  | Ok _ -> ()
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)

let accepts ?target ?declarations body =
  accepts_source ?target (in_function ?declarations body)

(* 6.4.4, 6.4.5, 6.5.1. *)
let primaries () =
  types "1" "int";
  types "1u" "unsigned int";
  types "2147483648" "long";
  types ~target:ilp32 "2147483648" "long long";
  types "1.0f" "float";
  types "1.0" "double";
  types "1.0L" "long double";
  types "1.0i" "_Complex double";
  types "2i" "<an imaginary integer constant>";
  types "'a'" "int";
  types "L'a'" "int";
  types ~target:ilp32 "L'a'" "unsigned int";
  types "u'a'" "unsigned short";
  types "\"ab\"" "char[3] lvalue";
  types "\"a\" \"b\"" "char[3] lvalue";
  types "\"\\x41\\n\"" "char[3] lvalue";
  types "\"\xc3\xa9\"" "char[3] lvalue";
  types "u8\"\xc3\xa9\"" "char[3] lvalue";
  types "L\"ab\"" "int[3] lvalue";
  types "\"a\" L\"b\"" "int[3] lvalue";
  types "u\"\\U0001F600\"" "unsigned short[3] lvalue";
  types "U\"\\U0001F600\"" "unsigned int[2] lvalue";
  rejects "u\"a\" L\"b\"" "6.4.5p2";
  types "x" "int lvalue";
  types "cx" "const int lvalue";
  types "(cx)" "const int lvalue";
  types "A" "int";
  types "f" "int (int)";
  types "a" "int[3] lvalue";
  types "__func__" "const char[2] lvalue";
  types "__FUNCTION__" "const char[2] lvalue";
  types "__PRETTY_FUNCTION__" "const char[<constant>] lvalue";
  types "__builtin_expect(x, 0)" "<the builtin '__builtin_expect'>";
  rejects "y" "'y' is not declared (C11 6.5.1p2)";
  types
    ~declarations:
      "__attribute__((overloadable)) int o(int); \
       __attribute__((overloadable)) int o(double); "
    "o(1)" "<the overloaded 'o'>"

(* 6.5.2. *)
let postfix () =
  types "a[1]" "int lvalue";
  types "1[a]" "int lvalue";
  types "p[x]" "const char lvalue";
  rejects "x[1]" "6.5.2.1p1";
  rejects "a[1.0]" "6.5.2.1p1";
  types "f(1)" "int";
  types "fp(1)" "int";
  types "(*fp)(1)" "int";
  types "g(1, 2, 3)" "int";
  types "h(1, 2)" "int";
  rejects "f()" "6.5.2.2p2";
  rejects "f(1, 2)" "6.5.2.2p2";
  rejects "g()" "6.5.2.2p2";
  rejects "x(1)" "6.5.2.2p1";
  types "s.m" "int lvalue";
  types "cs.m" "const int lvalue";
  types "s.k" "const char lvalue";
  types "s.b" "unsigned int lvalue :3";
  types "ps->m" "int lvalue";
  types "f(1), s" "struct s";
  rejects "s.q" "'q' is not a member";
  rejects "x.m" "6.5.2.3p1";
  rejects "ps.m" "6.5.2.3p1";
  rejects "s->m" "6.5.2.3p2";
  types ~declarations:"struct o { union { int u; struct { char v; }; }; } o; "
    "o.v" "char lvalue";
  rejects ~declarations:"struct q *pq; " "pq->a" "incomplete";
  types "x++" "int";
  types "p--" "const char *";
  types "s.b++" "unsigned int";
  rejects "cx++" "modifiable lvalue (C11 6.5.2.4p1)";
  rejects "x++ ++" "not an lvalue (C11 6.5.2.4p1)";
  rejects "s++" "6.5.2.4p1";
  types "(struct s){ 0 }" "struct s lvalue";
  types "(int[]){ 1, 2 }"
    "<a compound literal of an array of unknown length> lvalue";
  types "(int[2]){ 1, x }" "int[2] lvalue"

(* 6.5.3, 6.5.4. *)
let unary () =
  types "&x" "int *";
  types "&cx" "const int *";
  types "&a" "int (*)[3]";
  types "&f" "int (*)(int)";
  types "&*p" "const char *";
  types "&a[1]" "int *";
  rejects "&s.b" "bit-field";
  rejects "&1" "6.5.3.2p1";
  types "*p" "const char lvalue";
  types "*a" "int lvalue";
  types "*f" "int (int)";
  types "*vp" "void lvalue";
  rejects "*x" "6.5.3.2p2";
  types "-c" "int";
  types "+ul" "unsigned long";
  types "-d" "double";
  types "~us" "int";
  types "~z" "_Complex double";
  types "-s.b" "int";
  types "!p" "int";
  types "!d" "int";
  rejects "-p" "6.5.3.3p1";
  rejects "~d" "6.5.3.3p1";
  rejects "!s" "6.5.3.3p1";
  types "++x" "int";
  types "--s.b" "unsigned int value:3";
  rejects "++cx" "6.5.3.1p1";
  rejects "++a" "6.5.3.1p1";
  types "sizeof x" "unsigned long";
  types ~target:ilp32 "sizeof x" "unsigned int";
  types "sizeof(struct s)" "unsigned long";
  types "_Alignof(int)" "unsigned long";
  types "__alignof__ x" "unsigned long";
  rejects "sizeof s.b" "6.5.3.4p1";
  types "__real__ z" "double lvalue";
  types "__imag__ zf" "float lvalue";
  types "__real__ d" "double lvalue";
  types "(const int)x" "int";
  types "(void)x" "void";
  types "(char *)0" "char *";
  types "(struct s *)vp" "struct s *"

(* 6.5.5 to 6.5.14. *)
let binary () =
  types "c * c" "int";
  types "u * l" "long";
  types ~target:ilp32 "u * l" "unsigned long";
  types "1 / 2.0f" "float";
  types "ul % 2" "unsigned long";
  types "z + 1" "_Complex double";
  types "zf * 1.0" "_Complex double";
  types "e + 1u" "unsigned int";
  rejects "d % 2" "6.5.5p2";
  rejects "p * 2" "6.5.5p2";
  types "p + 1" "const char *";
  types "1 + p" "const char *";
  types "a + 1" "int *";
  types "vp + 1" "void *";
  types "p - p" "long";
  types ~target:ilp32 "p - p" "int";
  types "p - 1" "const char *";
  rejects "1 - p" "6.5.6p3";
  rejects "p + p" "6.5.6p2";
  rejects "s + 1" "6.5.6p2";
  types "c << l" "int";
  types "ul >> 1" "unsigned long";
  rejects "d << 1" "6.5.7p2";
  types "p < p" "int";
  types "d >= 1" "int";
  rejects "z < 1.0" "6.5.8p2";
  types "p == 0" "int";
  types "z == 1" "int";
  rejects "s == s" "6.5.9p2";
  types "x & 1u" "unsigned int";
  types "c ^ c" "int";
  rejects "d | 1" "6.5.12p2";
  types "p && 1" "int";
  types "d || z" "int";
  rejects "s && 1" "6.5.13p2";
  (* The operation on an unknown type is unknown in turn, but for a
     comparison, which gives int. *)
  types "half + 1" "<the attribute 'vector_size'>";
  types "half < 1" "int"

(* 6.5.15 to 6.5.17. *)
let conditional_and_assignment () =
  types "x ? c : us" "int";
  types "x ? 1 : 2.0" "double";
  types "x ? p : 0" "const char *";
  types "x ? 0 : ip" "int *";
  types "x ? (void *)0 : ip" "int *";
  types "x ? ip : ((void *)0)" "int *";
  types "x ? vp : ip" "void *";
  types "x ? cvp : ip" "const void *";
  types "x ? ip : cip" "const int *";
  types "x ? s : cs" "struct s";
  types "x ? (void)0 : (void)1" "void";
  types "x ?: 1.0" "double";
  types "p ?: 0" "const char *";
  types ~declarations:"int (*a3)[3]; int (*au)[]; int x; "
    "x ? a3 : au" "int (*)[3]";
  (* GNU C: pointers to incompatible types give a pointer to void. *)
  types "x ? ip : p" "void *";
  types "x ? (const int *)ip : (volatile long *)ip" "void *";
  (* A cast operand that is no constant in a constant expression context
     is no error here; whether one of an opaque value, or one that fails
     to evaluate, is null is unknown, and so is the type. *)
  let opaque = "<a null pointer constant of an opaque value>" in
  types "x ? (void *)(1 / 0) : ip" opaque;
  types "x ? (void *)(2147483647 + 1) : ip" opaque;
  types "x ? (void *)(long)0.0 : ip" opaque;
  rejects "s ? 1 : 2" "6.5.15p2";
  rejects "x ? s : 1" "6.5.15p3";
  types "x = 1.5" "int";
  types "s.b = 1" "unsigned int value:3";
  types "sizeof (s.b = 1)" "unsigned long";
  types "sizeof (0, s.b)" "unsigned long";
  types "sizeof ++s.b" "unsigned long";
  types "p += 1" "const char *";
  types "x += 1.0" "int";
  types "x <<= 1" "int";
  rejects "cx = 1" "6.5.16p2";
  rejects "a = a" "6.5.16p2";
  rejects "1 = x" "6.5.16p2";
  rejects "s += 1" "6.5.6p2";
  rejects "d %= 2" "6.5.5p2";
  types "(1, a)" "int *";
  types "(x, cx)" "int";
  types "(x, s.b)" "unsigned int value:3";
  types "(s.b)" "unsigned int lvalue :3"

(* GNU C. *)
let gnu () =
  types "({ int y = 2; y; })" "int";
  types "({ ; })" "void";
  types "({ a; })" "int *";
  types "({ x; int y; })" "void";
  types "l: ; &&l" "void *";
  types "__builtin_types_compatible_p(int, long)" "int";
  types "__builtin_offsetof(struct s, m)" "unsigned long";
  types ~declarations:"__builtin_va_list ap; "
    "__builtin_va_arg(ap, const int)" "int";
  (* A va_list parameter is adjusted as the target's va_list is (design
     P20). *)
  types ~parameters:"__builtin_va_list ap" "ap" "<a va_list parameter> lvalue";
  types ~parameters:"int n, int b[n]" "b" "int * lvalue";
  types ~parameters:"const int a[static 2]" "a" "const int * lvalue"

(* 6.5.1.1: the selection has the type, the lvalue and the null pointer
   constant of the expression it selects. *)
let generic () =
  types "_Generic(x, int: 1)" "int";
  types "_Generic(x, int: x)" "int lvalue";
  types "_Generic(x, default: 1.0f, long: 1)" "float";
  types "_Generic(x, long: 1, default: s)" "struct s lvalue";
  types "_Generic(x, int: s.b)" "unsigned int lvalue :3";
  types "_Generic(f, int (*)(int): f, default: 1)" "int (int)";
  (* The controlling type after lvalue conversion (C17 6.5.1.1p2, as GCC
     and Clang in every mode). *)
  types "_Generic(cx, int: 1L, const int: 'c')" "long";
  types "_Generic(a, int *: d, default: c)" "double lvalue";
  types "_Generic(\"s\", char *: 1u, default: 1)" "unsigned int";
  types "_Generic(e, unsigned: 1L, default: 1)" "long";
  types ~target:ilp32 "_Generic(1L, int: 1, long: 2L)" "long";
  (* GCC gives a bit-field a type of its own width. *)
  types "_Generic(s.b, unsigned: 1, default: 2)" "<the type of a bit-field>";
  types "_Generic(s.b = 1, unsigned: 1, default: 2)"
    "<the type of a bit-field>";
  (* Unknown where the controlling type or a compatibility is. *)
  types "_Generic(__builtin_foo, int: 1, default: 2)"
    "<the builtin '__builtin_foo'>";
  types "_Generic(x, typeof(__builtin_foo): 1, int: 2)"
    "<the builtin '__builtin_foo'>";
  (* Whether an operand of unknown type is a null pointer constant is
     unknown. *)
  types "x ? (void *)_Generic(__builtin_foo, int: 0, default: 0) : ip"
    "<a null pointer constant of an opaque value>";
  types "x ? (void *)__builtin_foo : ip"
    "<a null pointer constant of an opaque value>";
  types "_Generic(x, int *: 1, struct s *: 2, typeof(__builtin_foo) *: 3, \
         default: 4L)" "long";
  types "1 ? _Generic(0, int: (void *)0) : ip" "int *";
  types "1 ? _Generic(0, int: 0) : ip" "int *";
  types "1 ? _Generic(0, int: vp) : ip" "void *";
  accepts "_Generic(x, int: x) = 1";
  rejects "_Generic(x, int: 1) = 1" "not an lvalue";
  accepts "_Generic(x, int: 1, const int: 2)";
  (* The associations that are not selected must be valid C. *)
  rejects "_Generic(x, int: 1, long: y)" "'y'";
  rejects "_Generic(x, int: 1, long: x.m)" "6.5.2.3p1";
  rejects "_Generic(x, int: 1, signed: 2)" "6.5.1.1p2";
  rejects "_Generic(x, unsigned: 1, enum { B } : 2, int: 3)" "6.5.1.1p2";
  rejects "_Generic(x, default: 1, int: 2, default: 3)" "second default";
  rejects "_Generic(x, long: 1)" "compatible with no";
  rejects "_Generic(h, int (*)(int): 1, int (*)(double): 2)"
    "more than one";
  rejects "_Generic(h, int (*)(int): 1, int (*)(double): 2, default: 3)"
    "more than one"

(* 6.8: the constraints that typing checks. *)
let statements () =
  accepts "if (p) x; else if (d) x; while (ip) break; do continue; while (z)";
  accepts "for (int i = 0; i < 3; i++) { if (i) continue; }";
  accepts
    "for (;;) { switch (x) { case 1: continue; case A: default: break; } }";
  accepts "switch (c) { case 'a' ... 'z': { case 1 + sizeof (int): ; } }";
  rejects "if (s) ;" "6.8.4.1p1";
  rejects "while (s) ;" "6.8.5p2";
  rejects "for (; s; ) ;" "6.8.5p2";
  rejects "switch (d) { }" "6.8.4.2p1";
  rejects "switch (x) { case x: ; }" "6.8.4.2p3";
  rejects "switch (x) { case 1.0: ; }" "6.8.4.2p3";
  rejects "break" "6.8.6.3p1";
  rejects "switch (x) { continue; }" "6.8.6.2p1";
  rejects "case 1: ;" "6.8.1p2";
  rejects "default: ;" "6.8.1p2";
  accepts "return";
  accepts "__asm__ (\"\" : \"=r\" (x) : \"r\" (p))";
  rejects "__asm__ (\"\" : : \"r\" (undeclared))" "6.5.1p2";
  rejects "int v = undeclared" "6.5.1p2";
  rejects "int v = { 1, { undeclared } }" "6.5.1p2"

(* Declarations in blocks are read as those at file scope. *)
let block_declarations () =
  types "int y = 2; struct t { int a; } v; y + v.a" "int";
  types "typedef const int T; T y = 1; y" "const int lvalue";
  types "enum { B = 3 } y; B" "int";
  types "int n = x; int vla[n]; vla" "int[*] lvalue";
  types "int n = x; sizeof (int[n])" "unsigned long";
  types "extern int x; x" "int lvalue";
  types "int f(int); f" "int (int)";
  types ~declarations:"int ar[]; " "extern int ar[3]; ar" "int[3] lvalue";
  types ~declarations:"int ar[3]; " "int ar; { extern int ar[]; ar; }; ar"
    "int lvalue";
  (* A declaration with linkage in another block is the same entity but
     not visible: its type does not compose (6.2.7p4). *)
  types ~declarations:"void f1(void) { extern int g(int); } "
    "extern int g(); g(1, 2)" "int";
  types ~declarations:"void f1(void) { extern int a2[10]; } "
    "extern int a2[]; a2" "int[] lvalue";
  types ~declarations:"int a2[3]; void f1(void) { extern int a2[]; } "
    "extern int a2[]; sizeof (char[sizeof a2])" "unsigned long";
  rejects_source "void f1(void) { extern int q; } static int q;" "6.2.2p7";
  rejects_source "void f1(void) { extern int q; } double q;" "6.7p4";
  rejects_source "void f1(void) { extern int q; } void f2(void) { \
                  extern double q; }" "6.7p4";
  rejects "int y; extern int y;" "6.7p3";
  rejects "int y; int y;" "6.7p3";
  rejects ~declarations:"double x; " "extern int x;" "6.7p4";
  rejects "static int g(void);" "6.7.1p7";
  rejects "_Thread_local int y;" "6.7.1p3";
  accepts "static _Thread_local int y; extern _Thread_local int w";
  rejects "int a[*];" "6.7.6.2p4";
  (* A body sees a tag as complete only after its definition. *)
  rejects_source "struct q; void t(void) { struct q *p; p->a; } \
                  struct q { int a; };" "incomplete";
  accepts_source "struct q { int a; }; void t(void) { struct q *p; p->a; }";
  (* Parameters, prototype and old style. *)
  accepts_source "int t(int n, char b[n]) { return b[0] + n; }";
  accepts_source "int t(a, b) int a; char *b; { return a + *b; }"

(* A block-scope declaration with linkage denotes the entity of its name
   (6.2.2p4). *)
let block_linkage () =
  let entity_of source name =
    match read lp64 source with
    | Error error -> failwith (Reader.error_message error)
    | Ok (_, result) -> Declarations.linked result name
  in
  let source =
    "static int si; void t(void) { extern int si; si; } int e; \
     void u(void) { extern int e; extern int fresh; }"
  in
  (match entity_of source "si" with
  | Some { declared = Entity.Object { linkage = Internal; _ }; _ } -> ()
  | Some _ | None -> fail_case source "si is not internal");
  match entity_of source "fresh" with
  | Some { declared = Entity.Object { linkage = External; _ }; _ } -> ()
  | Some _ | None -> fail_case source "fresh is not external"

(* A chain deeper than the bound is an error, not a crash. *)
let deep_bodies () =
  let terms n = String.concat " + " (List.init n (fun _ -> "x")) in
  types (terms 1000) "int";
  rejects (terms (Expressions.max_depth + 1)) "too deeply";
  let chain n =
    String.concat " else " (List.init n (fun _ -> "if (x) x;")) ^ " x"
  in
  types (chain 1000) "int lvalue";
  rejects (chain (Expressions.max_depth + 1)) "too deeply"

let () =
  primaries ();
  postfix ();
  unary ();
  binary ();
  conditional_and_assignment ();
  gnu ();
  generic ();
  statements ();
  block_declarations ();
  block_linkage ();
  deep_bodies ();
  if !failures > 0 then exit 1
