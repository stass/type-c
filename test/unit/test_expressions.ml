(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The types that expression typing gives (C11 6.3, 6.5) and the
   constraints it checks in function bodies (6.8), on an LP64 and an ILP32
   target with Clang, whose types typec gives, and with GCC where it types
   a construct otherwise (Backend_difference). *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let lp64 = Canned_targets.(target (as_clang lp64_macros))
let ilp32 = Canned_targets.(target (as_clang ilp32_macros))
let lp64_gcc = Canned_targets.(target (as_gcc lp64_macros))
let ilp32_gcc = Canned_targets.(target (as_gcc ilp32_macros))
let aarch64 = Canned_targets.(target (as_clang aarch64_macros))
let aarch64_gcc = Canned_targets.(target (as_gcc aarch64_macros))

(* The ILP32 macros with these in place of theirs. *)
let ilp32_with replacements =
  let replaced (name, value) =
    (name, Option.value (List.assoc_opt name replacements) ~default:value)
  in
  List.map replaced Canned_targets.ilp32_macros

(* GCC's uint32_t of arm-none-eabi, and the uint16_t of AVR, whose int
   has 16 bits. *)
let ilp32_long_uint32_gcc =
  let macros = ilp32_with [ ("__UINT32_TYPE__", "long unsigned int") ] in
  Canned_targets.(target (as_gcc macros))

let int16_macros =
  ilp32_with
    [
      ("__SIZEOF_INT__", "2");
      ("__UINT16_TYPE__", "unsigned int");
      ("__UINT32_TYPE__", "long unsigned int");
    ]
let int16 = Canned_targets.target int16_macros
let int16_gcc = Canned_targets.(target (as_gcc int16_macros))

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

(* The last expression statement of the body of the last function
   definition, which [in_function] puts last. *)
let probed (unit : Tree.translation_unit) =
  let body = function
    | Tree.Function_definition { node = { body = Parsed block; _ }; _ } ->
        Some block
    | _ -> None
  in
  let last_expression (block : Tree.block) =
    match List.rev block.node.items with
    | Block_statement { node = Expression_statement e; _ } :: _ -> Some e
    | _ -> None
  in
  Option.bind (List.find_map body (List.rev unit)) last_expression

let describe (typed : Expressions.typed) =
  String.concat ""
    [ Type_name.of_ctype typed.expression_type;
      (if typed.lvalue then " lvalue" else "");
      (match typed.bit_field with
      | Bit_field field -> Printf.sprintf " :%d" field.width
      | Bit_field_value field -> Printf.sprintf " value:%d" field.width
      | Not_bit_field -> "") ]

let failures = ref 0

let fail_case source message =
  incr failures;
  Printf.eprintf "FAIL: %s\n  %s\n" source message

let in_function ?(declarations = prelude) ?(name = "t") ?(parameters = "void")
    body =
  declarations ^ "void " ^ name ^ "(" ^ parameters ^ ") { " ^ body ^ "; }"

(* The last expression of [body] has the type [expected] describes. *)
let types ?(target = lp64) ?declarations ?name ?parameters body expected =
  let source = in_function ?declarations ?name ?parameters body in
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
  (* The name is the UTF-8 bytes of the function's name, as in Clang and
     GCC, however the source spells it. *)
  types ~name:"x\\U0001F600" "__func__" "const char[6] lvalue";
  types ~name:"caf\\u00e9" "__FUNCTION__" "const char[6] lvalue";
  types "__PRETTY_FUNCTION__" "const char[<constant>] lvalue";
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
  types "(int[]){ 1, 2 }" "int[2] lvalue";
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
  types "({ l: x + 1; })" "int";
  types "({ l: m: a; })" "int *";
  types "({ l: x; }) + 1" "int";
  accepts "if (({ l: x; })) ;";
  types "({ l: x; ; })" "void";
  types "({ x; l: ; })" "void";
  types "({ l: { x; } })" "void";
  (* Clang gives void past a case label, which only a jump into the
     statement expression reaches, and both backends refuse that. *)
  rejects "switch (x) case 0: ({ case 1: x; }) + 1" "6.5.6p2";
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

(* The table of builtin functions (design 13.3). *)
let builtins () =
  (* With a prototype, the name has its function type. *)
  types "__builtin_memcpy" "void *(void *, const void *, unsigned long)";
  types "__builtin_expect(x, 0)" "long";
  types "__builtin_strlen(p)" "unsigned long";
  types ~target:ilp32 "__builtin_strlen(p)" "unsigned int";
  types "__builtin_bswap64(ul)" "unsigned long";
  types ~target:ilp32 "__builtin_bswap64(ul)" "unsigned long long";
  types "__builtin_bswap16(u)" "unsigned short";
  types "__builtin_bswap32(u)" "unsigned int";
  types ~target:ilp32_long_uint32_gcc "__builtin_bswap32(u)" "unsigned long";
  types ~target:int16 "__builtin_bswap16(u)" "unsigned short";
  types ~target:int16_gcc "__builtin_bswap16(u)" "unsigned int";
  rejects "__builtin_abs()" "6.5.2.2p2";
  (* Of one compiler, or of each in its own way. *)
  types ~target:lp64_gcc "__builtin_setjmp" "int (void *)";
  types ~target:ilp32 "__builtin_setjmp" "int (void **)";
  (* Of one compiler on some architectures only. *)
  types ~target:aarch64_gcc "__builtin_setjmp" "int (void *)";
  rejects ~target:aarch64 "__builtin_longjmp"
    "'__builtin_longjmp' is not a builtin of Clang, the backend, on this \
     target's architecture (AArch64)";
  types ~target:lp64_gcc "__builtin_puts(p)" "int";
  rejects ~target:ilp32 "__builtin_puts(p)"
    "'__builtin_puts' is not a builtin of Clang, the backend";
  rejects ~target:lp64_gcc "__c11_atomic_load(ip, 0)"
    "'__c11_atomic_load' is not a builtin of GCC, the backend";
  types ~target:ilp32 ~declarations:(prelude ^ "_Atomic int *ai; ")
    "__c11_atomic_load(ai, 0)" "int";
  rejects "__builtin_foo(1)" "'__builtin_foo' is not declared (C11 6.5.1p2)";
  (* A declaration of the name hides the builtin. *)
  types ~declarations:(prelude ^ "char *__builtin_isnan(int); ")
    "__builtin_isnan(1)" "char *";
  (* A rule types a call; the name alone has an unknown type. *)
  types "__builtin_constant_p" "<the builtin '__builtin_constant_p'>";
  types "__builtin_constant_p(ps)" "int";
  types "__builtin_isnan(d)" "int";
  types "__builtin_add_overflow(x, l, &x)" "_Bool";
  types ~declarations:(prelude ^ "__builtin_va_list ap; ")
    "__builtin_va_start(ap, x)" "void";
  types "__atomic_load_n(ip, 0)" "int";
  types "__atomic_load_n(cip, 0)" "<the result of '__atomic_load_n'>";
  types "__atomic_fetch_add(&p, 1, 0)" "const char *";
  rejects "__atomic_load_n(x, 0)"
    "the first argument of '__atomic_load_n' is not a pointer";
  rejects "__atomic_load_n()" "takes at least one argument";
  (* GCC and Clang apply the rule through parentheses. *)
  types "(__builtin_add_overflow)(x, x, &x)" "_Bool";
  types "__builtin_complex(d, d)" "_Complex double";
  types "__builtin_complex(1.0f, 2.0f)" "_Complex float";
  rejects "__builtin_complex(x, x)" "is not of a real floating type";
  (* A selection, as _Generic is. *)
  types "__builtin_choose_expr(1, x, d)" "int lvalue";
  types "__builtin_choose_expr(0, x, d)" "double lvalue";
  types "__builtin_choose_expr(1, s.b, d)" "unsigned int lvalue :3";
  types "__builtin_choose_expr(__builtin_choose_expr(1, 0, 1), x, d)"
    "double lvalue";
  types "x ? __builtin_choose_expr(1, (void *)0, 1) : ip" "int *";
  types "x ? __builtin_choose_expr(0, (void *)0, vp) : ip" "void *";
  types "__builtin_choose_expr(sizeof(struct s) == 8, x, d)"
    "<the condition of __builtin_choose_expr>";
  types "__builtin_choose_expr(__builtin_constant_p(x), x, d)"
    "<the condition of __builtin_choose_expr>";
  rejects "__builtin_choose_expr(x, x, d)" "not an integer constant expression";
  rejects "__builtin_choose_expr(1 / 0, x, d)" "6.5.5p5";
  (* A type that typec does not state (P21). *)
  types ~target:lp64_gcc "__builtin_shuffle(x)"
    "<the builtin '__builtin_shuffle'>";
  types "__builtin_inff128()" "<the builtin '__builtin_inff128'>";
  (* One entry for each name, of some compiler. *)
  let names =
    List.map
      (fun (entry : Builtin_function.entry) -> entry.name)
      Builtin_function.table
  in
  if List.length (List.sort_uniq String.compare names) <> List.length names
  then fail_case "the table" "two entries of one name";
  List.iter
    (fun (entry : Builtin_function.entry) ->
      if entry.gcc = None && entry.clang = None then
        fail_case entry.name "an entry of no compiler")
    Builtin_function.table

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
  types "_Generic(s.b, unsigned: 1L, default: 2)" "long";
  types "_Generic(s.b = 1, unsigned: 1L, default: 2)" "long";
  (* Unknown where the controlling type or a compatibility is. *)
  types "_Generic(__builtin_inff128(), int: 1, default: 2)"
    "<the builtin '__builtin_inff128'>";
  types "_Generic(x, typeof(__builtin_inff128()): 1, int: 2)"
    "<the builtin '__builtin_inff128'>";
  (* Whether an operand of unknown type is a null pointer constant is
     unknown. *)
  types "x ? (void *)_Generic(__builtin_inff128(), int: 0, default: 0) : ip"
    "<a null pointer constant of an opaque value>";
  types "x ? (void *)__builtin_inff128() : ip"
    "<a null pointer constant of an opaque value>";
  types
    "_Generic(x, int *: 1, struct s *: 2, \
     typeof(__builtin_inff128()) *: 3, default: 4L)"
    "long";
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

(* Each construct that GCC types otherwise than Clang has Clang's type
   with Clang and an unknown type with GCC, but where GCC's type is
   Clang's (Backend_difference). *)
let bit_field_declarations =
  "struct v { unsigned b : 3; unsigned u8 : 8; unsigned f : 32; \
   _Bool bo : 1; enum { V0 } e : 2; enum { V1 } fe : 32; \
   unsigned long long l : 40; long lw : 32; unsigned long long fl : 64; \
   } v; int a[2]; "

let bit_field_value = "<the value of a bit-field narrower than its type>"
let promotion = "<the promotion of a bit-field ranked above int>"

let both ?(declarations = bit_field_declarations) ~clang ~gcc body =
  types ~declarations body clang;
  types ~target:lp64_gcc ~declarations body gcc

let bit_field_values () =
  both "v.b" ~clang:"unsigned int lvalue :3"
    ~gcc:(bit_field_value ^ " lvalue :3");
  both "v.u8" ~clang:"unsigned int lvalue :8"
    ~gcc:(bit_field_value ^ " lvalue :8");
  both "v.e" ~clang:"enum <anonymous> lvalue :2"
    ~gcc:(bit_field_value ^ " lvalue :2");
  both "v.b++" ~clang:"unsigned int" ~gcc:bit_field_value;
  both "v.b++ + 0" ~clang:"unsigned int" ~gcc:bit_field_value;
  both "({ v.b; })" ~clang:"unsigned int" ~gcc:bit_field_value;
  (* Clang takes the real part of a bit-field as its value, and GCC's is
     the bit-field, which it assigns. *)
  let real_part = "<the real part of a bit-field>" in
  both "__real__ v.b" ~clang:"unsigned int" ~gcc:(real_part ^ " lvalue :3");
  both "__real__ v.f" ~clang:"unsigned int" ~gcc:(real_part ^ " lvalue :32");
  both "__imag__ v.b" ~clang:"unsigned int" ~gcc:bit_field_value;
  both "__imag__ v.f" ~clang:"unsigned int" ~gcc:"unsigned int";
  rejects ~declarations:bit_field_declarations "__real__ v.f = 1"
    "not an lvalue";
  accepts ~target:lp64_gcc ~declarations:bit_field_declarations
    "__real__ v.f = 1";
  rejects ~target:lp64_gcc ~declarations:bit_field_declarations
    "sizeof (__real__ v.b)" "6.5.3.4p1";
  accepts ~target:lp64_gcc ~declarations:bit_field_declarations
    "sizeof (__imag__ v.l)";
  both "v.b = 1" ~clang:"unsigned int value:3"
    ~gcc:(bit_field_value ^ " value:3");
  both "_Generic(v.b++, unsigned: 1L, default: 2)" ~clang:"long"
    ~gcc:bit_field_value;
  both "typeof(v.b = 1) y; y" ~clang:"unsigned int lvalue"
    ~gcc:(bit_field_value ^ " lvalue");
  (* Both promote a bit-field narrower than int to int, also where they
     type its value otherwise. *)
  both "v.b + 0" ~clang:"int" ~gcc:"int";
  both "(v.b = 1) + 0" ~clang:"int" ~gcc:"int";
  both "a[v.b]" ~clang:"int lvalue" ~gcc:"int lvalue";
  (* A bit-field of the full width of its type has that type in both. *)
  both "v.f" ~clang:"unsigned int lvalue :32" ~gcc:"unsigned int lvalue :32";
  both "v.bo" ~clang:"_Bool lvalue :1" ~gcc:"_Bool lvalue :1";
  both "v.fe++" ~clang:"enum <anonymous>" ~gcc:"enum <anonymous>";
  both "v.fl" ~clang:"unsigned long long lvalue :64"
    ~gcc:"unsigned long long lvalue :64";
  (* The width of an enumerated type whose integer type typec does not
     know is unknown too, and so is GCC's type of the bit-field. *)
  let declarations =
    "enum __attribute__((packed)) p { P0 }; struct { enum p e : 2; } w; "
  in
  both ~declarations "w.e" ~clang:"enum p lvalue :2"
    ~gcc:(bit_field_value ^ " lvalue :2");
  both ~declarations "_Generic(w.e, enum p: 1L, default: 2)" ~clang:"long"
    ~gcc:bit_field_value

let bit_field_promotions () =
  both "v.l + 1" ~clang:"unsigned long long" ~gcc:promotion;
  both "-v.l" ~clang:"unsigned long long" ~gcc:promotion;
  both "1 ? v.l : v.l" ~clang:"unsigned long long" ~gcc:promotion;
  both "v.l == 0" ~clang:"int" ~gcc:"int";
  both "v.fl + 1" ~clang:"unsigned long long" ~gcc:"unsigned long long";
  (* A bit-field of a type wider than int and of int's width promotes as
     in Clang; one of a type as wide as int ranked above it stays of that
     type in GCC. *)
  both "v.lw + 0" ~clang:"int" ~gcc:"int";
  types ~target:ilp32 ~declarations:bit_field_declarations "v.lw + 0" "int";
  types ~target:ilp32_gcc ~declarations:bit_field_declarations "v.lw + 0"
    promotion;
  types ~target:ilp32_gcc ~declarations:bit_field_declarations "v.f + 0"
    "unsigned int"

let anonymous_members () =
  let declarations =
    "struct t { const struct { int z; }; volatile union { int y; }; \
     const struct { const int c; struct { int n; }; }; } an; \
     const struct t can; "
  in
  let member = "<a member of a qualified anonymous member> lvalue" in
  both ~declarations "an.z" ~clang:"int lvalue" ~gcc:member;
  both ~declarations "an.y" ~clang:"int lvalue" ~gcc:member;
  both ~declarations "an.n" ~clang:"int lvalue" ~gcc:member;
  both ~declarations "an.c" ~clang:"const int lvalue" ~gcc:"const int lvalue";
  both ~declarations "can.z" ~clang:"const int lvalue"
    ~gcc:"const int lvalue";
  accepts ~declarations "an.z = 1";
  accepts ~target:lp64_gcc ~declarations "an.z = 1";
  rejects ~declarations "can.z = 1" "modifiable lvalue"

(* A function of an old-style definition, typed as
   Backend_difference.Old_style_function says. *)
let old_style_definitions () =
  let old_style = "<a function of an old-style definition>" in
  let designates declarations ~clang ~gcc =
    both ~declarations "f" ~clang ~gcc
  in
  designates "int f(a, b) long a; char *b; { return 0; } " ~clang:"int ()"
    ~gcc:"int ()";
  designates "int f() { return 0; } " ~clang:"int ()" ~gcc:"int ()";
  designates "int f(int); int f(a) int a; { return 0; } " ~clang:"int ()"
    ~gcc:old_style;
  designates "int f(void); int f() { return 0; } " ~clang:"int (void)"
    ~gcc:"int (void)";
  designates "int f(a, b) char a; float b; { return 0; } int f(); "
    ~clang:"int (int, double)" ~gcc:old_style;
  designates "int f(a) int a[3]; { return 0; } int f(); "
    ~clang:"int (int *)" ~gcc:old_style;
  designates "int f() { return 0; } int f(); " ~clang:"int ()" ~gcc:"int ()";
  designates "int f(a) long a; { return 0; } int f(); int f(); "
    ~clang:"int (long)" ~gcc:old_style;
  designates "int f(int); int f(a) int a; { return 0; } int f(); "
    ~clang:"int (int)" ~gcc:"int (int)";
  designates "int f(a) long a; { return 0; } int f(long); "
    ~clang:"int (long)" ~gcc:"int (long)";
  (* A promoted type that depends on an unknown integer type is unknown. *)
  designates
    "enum __attribute__((packed)) p { P0 }; \
     int f(a) enum p a; { return 0; } int f(); "
    ~clang:"int (<the attribute 'packed'>)" ~gcc:old_style;
  (* The uses compare and convert as unprototyped. *)
  let declarations = "int f(a) int a; { return 0; } " in
  both ~declarations "_Generic(f, int (*)(long): 1L, default: 2)"
    ~clang:"long" ~gcc:"long";
  accepts ~declarations "int (*q)(long) = f";
  accepts ~declarations "f(1, 2)";
  rejects ~declarations:(declarations ^ "int f(); ") "f(1, 2)" "6.5.2.2p2"

let enum_integer_composites () =
  let declarations = "enum e { E0 = 1 } *ep; unsigned *up; int x; " in
  let composite =
    "<the composite of an enumerated type and its integer type> *"
  in
  both ~declarations "x ? ep : up" ~clang:"unsigned int *" ~gcc:composite;
  both ~declarations "x ? up : ep" ~clang:"unsigned int *" ~gcc:composite;
  both ~declarations "x ? ep : ep" ~clang:"enum e *" ~gcc:"enum e *"

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
  rejects "case 1: ;" "6.8.1p2";
  rejects "default: ;" "6.8.1p2";
  accepts "return";
  accepts "__asm__ (\"\" : \"=r\" (x) : \"r\" (p))";
  rejects "__asm__ (\"\" : : \"r\" (undeclared))" "6.5.1p2";
  rejects "int v = undeclared" "6.5.1p2";
  rejects "int v = { 1, { undeclared } }" "6.5.1p2"

(* 6.8.1p3, 6.8.6.1p1: a label is defined once in its scope, the
   function or the block of a GNU local label, and a goto or an asm goto
   names one defined there. *)
let labels () =
  accepts "goto a; a: ; again: if (x) goto again";
  accepts "__asm__ goto (\"\" : : : : a); a: ;";
  accepts "{ __label__ a; a: ; } { __label__ a; a: goto a; } a: goto a";
  accepts "({ if (x) goto out; 0; }); out: ;";
  accepts "({ __asm__ goto (\"\" : : : : out); 0; }); out: ;";
  rejects "a: ; a: ;" "6.8.1p3";
  rejects "a: ; { a: ; }" "6.8.1p3";
  rejects "({ a: 0; }); a: ;" "6.8.1p3";
  rejects "__label__ a; a: ; a: ;" "6.8.1p3";
  rejects "goto b" "6.8.6.1p1";
  rejects "__asm__ goto (\"\" : : : : b)" "6.8.6.1p1";
  rejects "{ __label__ b; goto b; } b: ;" "6.8.6.1p1";
  (* A label in an expression that a type or a constant holds is one of
     the function, as everywhere in the body. *)
  let defined_twice inside = rejects (inside ^ "; b: ;") "6.8.1p3" in
  defined_twice "int n = x; int v[n + ({ b: 0; })]; (void)v";
  defined_twice "__typeof__ (({ b: 0; })) y = 0; (void)y";
  defined_twice "_Atomic (__typeof__ (({ b: 0; }))) y = 0; (void)y";
  defined_twice "_Alignas (sizeof ({ b: 0; })) int y; (void)y";
  defined_twice "enum { E = sizeof ({ b: 0; }) }";
  defined_twice "struct t { int m : sizeof ({ b: 0; }); } v; (void)v";
  defined_twice
    "struct t { _Static_assert (sizeof ({ b: 0; }), \"\"); int m; } v; (void)v";
  defined_twice "void q (int (*r)[sizeof ({ b: 0; })])";
  defined_twice "for (int v[sizeof ({ b: 0; })]; ; ) break";
  defined_twice "_Static_assert (sizeof ({ b: 0; }), \"\")";
  defined_twice "switch (x) { case sizeof ({ b: 0; }): ; }";
  defined_twice "int v[8] = { [sizeof ({ b: 0; })] = 1 }; (void)v";
  defined_twice "(void)sizeof (int [({ b: 1; })])";
  defined_twice "(void)_Alignof (int [sizeof ({ b: 0; })])";
  defined_twice "(void)(int (*)[({ b: 1; })])0";
  defined_twice "(void)(int [sizeof ({ b: 0; })]){ 0 }";
  defined_twice "(void)_Generic (0, int (*)[({ b: 1; })]: 1, default: 2)";
  defined_twice
    "(void)__builtin_types_compatible_p (int [sizeof ({ b: 0; })], int)";
  defined_twice
    "struct u { int v[8]; }; \
     (void)__builtin_offsetof (struct u, v[sizeof ({ b: 0; })])";
  (* GNU: the address of a label is taken in a function body. *)
  rejects_source "void *q = &&a;" "Labels as Values";
  rejects_source "int q = sizeof (&&a);" "Labels as Values";
  rejects_source "void t(int (*q)[sizeof (&&a)]) { a: ; }" "Labels as Values";
  rejects_source "int t(r) int r[sizeof (&&a)]; { a: return 0; }"
    "Labels as Values";
  accepts "static void *q = &&a; a: (void)q";
  accepts "void r(int (*q)[sizeof (&&a)]); a: ;";
  (* GNU: a block declares a local label once; an inner block may declare
     it again. *)
  rejects "__label__ a, a; a: ;" "Local Labels";
  rejects "{ __label__ a; __label__ a; }" "Local Labels";
  accepts "{ __label__ a; { __label__ a; a: ; } a: ; }";
  (* GNU: a goto does not jump into a statement expression from outside
     it, but may jump out of one or within it. *)
  rejects "goto b; (void)({ b: 0; })" "Statement Exprs";
  rejects "(void)({ b: 0; }); goto b" "Statement Exprs";
  rejects "(void)({ goto b; 0; }); (void)({ b: 0; })" "Statement Exprs";
  rejects "(void)({ ({ b: 0; }); goto b; 0; })" "Statement Exprs";
  rejects "__asm__ goto (\"\" : : : : b); (void)({ b: 0; })" "Statement Exprs";
  rejects "goto b; (void)sizeof ({ b: 0; })" "Statement Exprs";
  accepts "(void)({ b: 0; ({ goto b; 0; }); })";
  accepts "void *q = &&b; (void)q; (void)({ b: 0; })";
  (* The backends disagree on a goto into or out of a statement
     expression that a type or a constant holds, which Clang does not
     check, and on a computed goto into one, which GCC does not: both stay
     with them. *)
  accepts "int n = x; goto b; int v[n + ({ b: 0; })]; (void)v";
  accepts "int n = x; (void)({ int v[n + ({ b: 0; })]; (void)v; goto b; 0; })";
  accepts "int n = x; (void)({ b: 0; }); int v[n + ({ goto b; 0; })]; (void)v";
  accepts "(void)({ b: 0; }); _Static_assert (sizeof ({ goto b; 0; }), \"\")";
  accepts "(void)({ b: 0; }); switch (x) { case sizeof ({ goto b; 0; }): ; }";
  accepts "(void)({ b: 0; }); int v[8] = { [sizeof ({ goto b; 0; })] = 1 }; \
           (void)v";
  accepts "void *q = &&b; goto *q; (void)({ b: 0; })";
  (* The parser keeps the arguments of an attribute as tokens, so typing
     cannot tell a label defined in one from no label: the address of an
     undefined label stays with the backend, as both compile this one
     with optimization. *)
  accepts
    "int y __attribute__ ((aligned (sizeof ({ b: 0; })))); void *q = &&b; \
     (void)q; (void)y"

(* Constraints of statements that both backends accept in GNU C, so
   typec leaves them to the backend: any storage class but _Thread_local
   in a for declaration (6.8.5p3, which 6.7.1p3 refuses in a block anyway),
   and a return whose value does not match the function's (6.8.6.4p1),
   which both refuse by default but accept under -Wno-return-mismatch. *)
let left_to_backend () =
  accepts "for (static int i = 0; i < 1; ) ;";
  accepts "for (extern int i; i < 1; ) ;";
  accepts "for (typedef int T; ; ) break";
  rejects "for (_Thread_local int i = 0; ; ) break" "6.7.1p3";
  accepts "return x";
  accepts_source "int f(void) { return; }"

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

(* The class of constant expression (C11 6.6) that typing gives. *)
let describe_constant (constant : Expressions.constant) =
  let kind_name : Expressions.kind -> string = function
    | Arithmetic_constant -> "arithmetic"
    | Address_constant -> "address"
    | Designator { static_storage; named } ->
        (if static_storage then "static" else "automatic")
        ^ if named then " named" else ""
    | Backend_constant -> "backend"
    | Not_constant -> "not constant"
  in
  match constant with
  | Integer_expression { value; flaw } ->
      let value =
        match value.value with
        | Known value -> Exact_integer.to_string value
        | Opaque -> "opaque"
      in
      let flaw =
        match flaw with
        | None -> ""
        | Some (Comma_operator _) -> " comma"
        | Some (Invalid _) -> " invalid"
      in
      "integer " ^ value ^ flaw
  | Not_integer { kind; _ } -> kind_name kind
  | Unevaluable _ -> "unevaluable"

let classes ?parameters body expected =
  let source = in_function ?parameters body in
  match read lp64 source with
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)
  | Ok (unit, result) -> (
      match Option.bind (probed unit) (Declarations.constant result) with
      | None -> fail_case source "the expression is not classed"
      | Some constant ->
          let actual = describe_constant constant in
          if actual <> expected then
            fail_case source (Printf.sprintf "%S, expected %S" actual expected))

let constants () =
  classes "1 + 2 * 3" "integer 7";
  classes "(1, 2)" "integer 2 comma";
  classes "0 ? (1, 2) : 3" "integer 3";
  classes "1 / 0" "integer opaque invalid";
  classes "0 && 1 / 0" "integer 0";
  classes "(int)1.5" "integer opaque";
  classes "sizeof x + sizeof (char)" "integer 5";
  classes "sizeof a" "integer opaque";
  classes "A + 1" "integer 1";
  classes "1.0 + 2" "arithmetic";
  classes "(double)1 < 2" "arithmetic";
  classes "x" "static named";
  classes "a[1]" "static named";
  classes "s.m" "static named";
  classes "\"ab\"[1]" "static";
  classes "f" "static";
  classes "*&x" "static";
  classes "&x" "address";
  classes "&a[1]" "address";
  classes "a + 1" "address";
  classes "&s.m" "address";
  classes "(char *)&x - 1" "address";
  classes "(void *)0" "address";
  classes "(int *)16" "address";
  classes "x + 1" "not constant";
  classes "x = 1" "not constant";
  classes "&ps->m" "not constant";
  classes "&a[x]" "not constant";
  classes "cx + 1" "backend";
  classes "f(1)" "backend";
  classes "0 && f(1)" "backend";
  classes "1 ? 2 : x" "backend";
  classes "(long)&x" "backend";
  classes "(int){ 1 }" "automatic";
  classes ~parameters:"int n" "n" "automatic named";
  classes ~parameters:"int n" "&n" "not constant";
  classes "_Generic(1, int: 2, default: x)" "integer 2";
  classes "(struct s *)0 == 0" "backend";
  classes "sizeof (struct s)" "integer opaque";
  classes "(typeof(half))1" "unevaluable";
  (* 6.6p3: an operand that is not evaluated may be anything. *)
  classes "sizeof (x = 1)" "integer 4";
  types "struct s y[] = { s, s, { 1 } }; y" "struct s[3] lvalue";
  types "static const char n[] = \"abc\"; n" "const char[4] lvalue";
  (* The null pointer check does not fail on an unknown type. *)
  types "x ? (void *)(int)(typeof(half))0 : ip"
    "<a null pointer constant of an opaque value>"

let () =
  primaries ();
  postfix ();
  unary ();
  binary ();
  conditional_and_assignment ();
  gnu ();
  builtins ();
  generic ();
  bit_field_values ();
  bit_field_promotions ();
  anonymous_members ();
  old_style_definitions ();
  enum_integer_composites ();
  statements ();
  labels ();
  left_to_backend ();
  block_declarations ();
  block_linkage ();
  deep_bodies ();
  constants ();
  if !failures > 0 then exit 1
