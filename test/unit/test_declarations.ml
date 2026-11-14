(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let lp64 = Canned_targets.target Canned_targets.lp64_macros
let ilp32 = Canned_targets.target Canned_targets.ilp32_macros

let read target source =
  let text =
    match Reader.read ~name:"in.c" source with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  match Parser.parse ~keywords:(Target.keywords target Gnu) text with
  | Ok unit -> Declarations.read target text unit
  | Error error -> failwith (Parser.error_message error)

let linkage_name : Declarations.linkage -> string = function
  | External -> "external"
  | Internal -> "internal"
  | No_linkage -> "none"

let value_name (constant : Integer_constant.t) =
  match constant.value with
  | Known value -> Exact_integer.to_string value
  | Opaque -> "opaque"

(* An identifier as words: its kind, type, linkage and the rest. *)
let describe (declared : Declarations.declared) =
  match declared with
  | Object { object_type; linkage; storage } ->
      let storage_name =
        match storage with
        | Static_storage -> "static"
        | Thread_storage -> "thread"
        | Automatic_storage -> "automatic"
      in
      String.concat " "
        [ "object"; Type_name.of_ctype object_type; linkage_name linkage;
          storage_name ]
  | Function { function_type; linkage; inline; noreturn; gnu_inline } ->
      String.concat " "
        ([ "function"; Type_name.of_ctype function_type; linkage_name linkage ]
        @ (if inline then [ "inline" ] else [])
        @ (if noreturn then [ "noreturn" ] else [])
        @ if gnu_inline then [ "gnu_inline" ] else [])
  | Typedef t -> "typedef " ^ Type_name.of_ctype t
  | Enumerator { enumerator_type; value } ->
      Printf.sprintf "enumerator %s = %s"
        (Type_name.of_ctype enumerator_type)
        (value_name value)

let failures = ref 0

let fail_case source message =
  incr failures;
  Printf.eprintf "FAIL: %s\n  %s\n" source message

(* [source] declares [name] at file scope as [expected] describes. *)
let declares ?(target = lp64) source name expected =
  match read target source with
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)
  | Ok result -> (
      match Scope.find result.file_scope name with
      | None -> fail_case source (name ^ " is not declared")
      | Some entity ->
          let actual = describe entity.declared in
          if actual <> expected then
            fail_case source
              (Printf.sprintf "%s is %S, expected %S" name actual expected))

let contains text part =
  let length = String.length part in
  let rec at index =
    index + length <= String.length text
    && (String.sub text index length = part || at (index + 1))
  in
  at 0

(* [source] is an error whose message contains [expected]. *)
let rejects ?(target = lp64) source expected =
  match read target source with
  | Ok _ -> fail_case source "accepted"
  | Error { message; _ } ->
      if not (contains message expected) then
        fail_case source (Printf.sprintf "message %S lacks %S" message expected)

(* [source] has no error. *)
let accepts ?(target = lp64) source =
  match read target source with
  | Ok _ -> ()
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)

(* The type and value of an integer constant (6.4.4.1p5). *)
let constant_type ?(target = lp64) spelling expected =
  let actual =
    match Number.classify spelling with
    | Integer { base; digits; suffix } -> (
        let constant =
          Integer_constant.of_integer_constant target base digits suffix
        in
        match constant with
        | Ok constant ->
            Integer.name constant.integer_type ^ " = " ^ value_name constant
        | Error error -> Integer_constant.error_message error)
    | Floating _ | Not_a_constant -> "not an integer constant"
  in
  if actual <> expected then
    fail_case spelling (Printf.sprintf "%S, expected %S" actual expected)

let evaluates_int ?(target = lp64) expression value =
  declares ~target
    (Printf.sprintf "enum { V = %s };" expression)
    "V" ("enumerator int = " ^ value)

let specifier_combinations () =
  let valid =
    [ ("char", "char"); ("signed char", "signed char");
      ("char unsigned", "unsigned char"); ("short", "short");
      ("short int signed", "short"); ("unsigned short int", "unsigned short");
      ("int", "int"); ("signed", "int"); ("int signed", "int");
      ("unsigned", "unsigned int"); ("long", "long");
      ("long signed int", "long"); ("int long unsigned", "unsigned long");
      ("long long", "long long"); ("long int long signed", "long long");
      ("long unsigned long", "unsigned long long"); ("float", "float");
      ("double", "double"); ("double long", "long double");
      ("_Bool", "_Bool"); ("_Complex float", "_Complex float");
      ("double _Complex", "_Complex double");
      ("long _Complex double", "_Complex long double");
      ("const volatile int", "const volatile int");
      ("int const const", "const int");
      ("_Atomic int", "_Atomic int"); ("_Atomic(long)", "_Atomic long") ]
  in
  List.iter
    (fun (specifiers, type_name) ->
      declares (specifiers ^ " x;") "x"
        ("object " ^ type_name ^ " external static"))
    valid;
  List.iter
    (fun specifiers -> rejects (specifiers ^ " x;") "6.7.2p2")
    [ "long long long"; "short long"; "signed unsigned"; "char short";
      "float double"; "_Complex"; "_Complex int"; "void int";
      "struct s { int a; } int"; "_Bool signed"; "const" ];
  rejects "typedef int T; T unsigned x;" "6.7.2p2"

let storage_classes () =
  declares "static int x;" "x" "object int internal static";
  declares "extern int x;" "x" "object int external static";
  declares "_Thread_local int x;" "x" "object int external thread";
  declares "static _Thread_local int x;" "x" "object int internal thread";
  declares "_Thread_local extern int x;" "x" "object int external thread";
  rejects "static extern int x;" "6.7.1p2";
  rejects "static static int x;" "6.7.1p2";
  rejects "typedef _Thread_local int T;" "6.7.1p2";
  rejects "auto int x;" "6.9p2";
  rejects "register int x;" "6.9p2";
  rejects "_Thread_local int f(void);" "6.7.1p4";
  rejects "inline int x;" "6.7.4p1";
  rejects "_Noreturn typedef void T(void);" "6.7.4p1";
  declares "inline int f(void);" "f" "function int (void) external inline";
  declares "_Noreturn void f(void);" "f"
    "function void (void) external noreturn";
  rejects "_Alignas(8) typedef int T;" "6.7.5p2";
  rejects "_Alignas(8) int f(void);" "6.7.5p2";
  rejects "void f(_Alignas(8) int x);" "6.7.5p2";
  rejects "struct s { _Alignas(8) int a : 3; };" "6.7.5p2";
  rejects "int a[sizeof(_Alignas(8) int)];" "6.7.5p2";
  accepts
    "_Alignas(8) int x; _Alignas(long) char y; \
     struct s { _Alignas(16) int a; };";
  rejects "_Alignas(x) int y;" "6.5.1p2";
  rejects "void f(static int x);" "6.7.6.3p2";
  declares "void f(register int x);" "f" "function void (int) external"

let declarators () =
  declares "int *a[3];" "a" "object int *[3] external static";
  declares "int (*a)[3];" "a" "object int (*)[3] external static";
  declares "int *const p;" "p" "object int *const external static";
  declares "char *(*f)(int, ...);" "f"
    "object char *(*)(int, ...) external static";
  declares "void (*signal(int, void (*)(int)))(int);" "signal"
    "function void (*(int, void (*)(int)))(int) external";
  declares "int f();" "f" "function int () external";
  declares "int f(void);" "f" "function int (void) external";
  declares "typedef void V; int f(V);" "f" "function int (void) external";
  declares "int f(int a[const 3], char g(void));" "f"
    "function int (int *, char (*)(void)) external";
  declares "int f(int n, int a[n]);" "f" "function int (int, int *) external";
  declares "int f(int n, int (*a)[n]);" "f"
    "function int (int, int (*)[*]) external";
  declares "int f(int (*a)[*]);" "f" "function int (int (*)[*]) external";
  rejects "int f(const void);" "void";
  rejects "int f(void, int);" "void";
  rejects "int f(int a, int a);" "6.7p3";
  rejects "int f(a, b);" "6.7.6.3p3";
  rejects "int a[*];" "6.7.6.2p4";
  rejects "int f(int (*a)[static 3]);" "6.7.6.2p1";
  rejects "int a[const 3];" "6.7.6.2p1";
  rejects "int a[n];" "6.5.1p2";
  rejects "int n; int a[n];" "6.7.6.2p2";
  rejects "int a[-1];" "negative";
  declares "int a[0];" "a" "object int[0] external static";
  rejects "int f(void)[3];" "array";
  rejects "int a[3](void);" "function"

let typedefs () =
  declares "typedef int T; typedef T *U; typedef U V[2]; V v;" "v"
    "object int *[2] external static";
  declares "typedef int A[]; typedef const A B; B b;" "b"
    "object const int[] external static";
  declares "typedef int T; typedef int T;" "T" "typedef int";
  rejects "typedef int T; typedef long T;" "6.7p3";
  rejects "typedef int A[]; typedef int A[3];" "6.7p3";
  accepts "struct s { int x; }; typedef int A[sizeof(struct s)]; \
           typedef int A[4];";
  rejects "typedef int A[3]; typedef int A[4];" "6.7p3";
  rejects "typedef int T; int T;" "6.7p3";
  declares "typedef int F(void); F f;" "f" "function int (void) external";
  rejects "typedef int f(void) {}" "6.9.1p4";
  rejects "register int f(void) {}" "6.9.1p4";
  declares "static int f(int x) { }" "f" "function int (int) internal"

let tags () =
  declares "struct s { int a; }; struct s x;" "x"
    "object struct s external static";
  declares "struct s; struct s *p; struct s { int a; };" "p"
    "object struct s * external static";
  accepts "struct s { struct s *next; };";
  rejects "struct s { int a; }; struct s { int a; };" "defined";
  rejects "struct s; union s *p;" "6.7.2.3p2";
  rejects "struct s { int a; }; enum s e;" "6.7.2.3p2";
  rejects "struct s { struct s x; };" "incomplete";
  (* A tag in a prototype is a new type there (6.7.2.3p8). *)
  rejects "void f(struct t *p); struct t { int a; }; void f(struct t *p);"
    "6.7p4";
  accepts "struct t { int a; }; void f(struct t *p); void f(struct t *p);";
  (* Tags nested in a structure are declared at file scope. *)
  declares "struct o { struct i { int a; } x; }; struct i y;" "y"
    "object struct i external static";
  declares "struct o { enum { K = 3 } k; }; int a[K];" "a"
    "object int[3] external static";
  (* A member declaration without declarators violates 6.7.2.1p2, which
     GCC and Clang accept, declaring no tag of its own; typec follows. *)
  accepts "struct t { int a; }; void f(struct u { struct t; struct t m; } *p);";
  accepts
    "struct t { int a; }; \
     void f(struct u { __attribute__((unused)) struct t; struct t m; } *p);";
  (* An anonymous structure is a member; a tagged one declares a tag. *)
  accepts "struct s { union { int a; float b; }; int c; };";
  rejects "struct s { union { int a; }; int a; };" "a";
  accepts "struct s { struct t { int a; }; int a; };";
  declares "enum e; enum e { A }; enum e x;" "x"
    "object enum e external static";
  rejects "enum e { A }; enum e { B };" "defined";
  rejects "struct s { int a : 33; };" "bit-field";
  rejects "struct s { int a : -1; };" "bit-field";
  rejects "struct s { int x; int a : x; };" "6.5.1p2";
  rejects "int x; struct s { int a : x; };" "6.7.2.1p4";
  rejects "struct s { int a : sizeof(struct s *[2]); };" "P16";
  accepts "struct s { int a : sizeof(int); unsigned : 0; _Bool b : 1; };";
  rejects "struct s { int a[]; int b; };" "flexible";
  accepts "struct s { int b; int a[]; };"

let linkage () =
  declares "static int x; extern int x;" "x" "object int internal static";
  declares "static int f(void); int f(void);" "f"
    "function int (void) internal";
  declares "static void f(void); void f(void) {}" "f"
    "function void (void) internal";
  rejects "int x; static int x;" "6.2.2p7";
  rejects "static int x; int x;" "6.2.2p7";
  rejects "extern int x; static int x;" "6.2.2p7";
  declares "int x; int x; extern int x;" "x" "object int external static";
  rejects "int x; long x;" "6.7p4";
  rejects "int x; int x(void);" "6.7p3";
  rejects "enum { A }; int A;" "6.7p3";
  rejects "enum { A, A };" "6.7p3";
  rejects "int f(int); int f(long);" "6.7p4";
  rejects "int f(int); int f() {}" "6.7p4"

let composites () =
  declares "int a[]; int a[3];" "a" "object int[3] external static";
  declares "int a[3]; int a[];" "a" "object int[3] external static";
  declares "int f(); int f(int);" "f" "function int (int) external";
  declares "int f(int (*)[]); int f(int (*)[4]);" "f"
    "function int (int (*)[4]) external";
  declares "int f(int); int f();" "f" "function int (int) external";
  declares "inline int f(void); _Noreturn int f(void);" "f"
    "function int (void) external inline noreturn";
  rejects "int f(x) {}" "6.9.1p6";
  declares "int f(); int f(a, b) char *b; int a; {}" "f"
    "function int () external";
  declares "int f(a, b) char *b; int a[3]; {}" "f" "function int () external";
  accepts "int f(int, char *); int f(a, b) int a; char *b; {}";
  rejects "int f(float); int f(a) float a; {}" "6.7p4";
  rejects "int f(a) int a; int c; {}" "6.9.1p6";
  rejects "int f(a) int a; int a; {}" "6.7p3";
  rejects "int f(a) static int a; {}" "6.7.6.3p2";
  rejects "int f(a) int; {}" "6.9.1p6";
  rejects "int f(a) int a = 1; { return a; }" "6.9.1p6";
  declares "int a[sizeof (struct { int x; })]; int a[4];" "a"
    "object int[4] external static";
  declares "struct s { int x; }; int a[sizeof (struct s)];" "a"
    "object int[<constant>] external static"

let constant_expressions () =
  evaluates_int "1 + 2 * 3" "7";
  evaluates_int "-7 / 2" "-3";
  evaluates_int "-7 % 2" "-1";
  evaluates_int "7 >> 1" "3";
  evaluates_int "-7 >> 1" "-4";
  evaluates_int "1 << 31" "-2147483648";
  evaluates_int "-1 << 1" "-2";
  evaluates_int "~0" "-1";
  evaluates_int "!5" "0";
  evaluates_int "5 > 3 && 2" "1";
  evaluates_int "0 || 0" "0";
  evaluates_int "-1 < 0u" "0";
  evaluates_int "-1 < 0l" "1";
  evaluates_int "(unsigned char)300" "44";
  evaluates_int "(signed char)200" "-56";
  evaluates_int "(_Bool)256" "1";
  evaluates_int "(int)4294967296" "0";
  rejects "enum { V = (int)3.5 };" "P16";
  evaluates_int "1 ? 2 : 1 / 0" "2";
  evaluates_int "0 && 1 / 0" "0";
  evaluates_int "1 || (1 << 99)" "1";
  evaluates_int "0 ? (1, 2) : 3" "3";
  evaluates_int "2 ?: 1 / 0" "2";
  evaluates_int "0 ?: 3" "3";
  evaluates_int "sizeof(int) + sizeof(long) + sizeof(char *)" "20";
  evaluates_int ~target:ilp32 "sizeof(long) + sizeof(void (*)(void))" "8";
  evaluates_int "sizeof(_Complex double) + sizeof(long double)" "32";
  evaluates_int "sizeof(const short)" "2";
  evaluates_int "sizeof(enum { Q = -1 })" "4";
  let opaque length =
    declares ("int a[" ^ length ^ "];") "a"
      "object int[<constant>] external static"
  in
  opaque "sizeof(_Bool)";
  opaque "sizeof(int[3])";
  opaque "sizeof(_Atomic int)";
  opaque "_Alignof(int)";
  opaque "sizeof 1";
  opaque "__alignof__ 1";
  opaque "sizeof(struct q { int a; }) - sizeof(struct q)";
  opaque "(int)3.5";
  evaluates_int "'a'" "97";
  evaluates_int "'\\377'" "-1";
  evaluates_int ~target:ilp32 "'\\377'" "255";
  evaluates_int "'ab'" "24930";
  evaluates_int "'\\xff\\xfe'" "65534";
  evaluates_int "'abcde'" "1650680933";
  evaluates_int "'\\n' + '\\0' + '\\'' + '\\e'" "76";
  evaluates_int "'\\u0041'" "65";
  evaluates_int "L'\\xffffffff'" "-1";
  evaluates_int "u'\\xffff' == 65535" "1";
  evaluates_int "U'\\U0001F600'" "128512";
  evaluates_int "L'\\u00e9'" "233";
  (* A source character is UTF-8; a plain constant takes ASCII only. *)
  evaluates_int "L'\xc3\xa9' + U'\xf0\x9f\x98\x80'" "128745";
  rejects "enum { V = '\xc3\xa9' };" "code unit";
  rejects "enum { V = L'\xc3' };" "UTF-8";
  rejects "_Thread_local int t; int t;" "6.7.1p3";
  rejects "int t; _Thread_local int t;" "6.7.1p3";
  evaluates_int "0x7fffffff" "2147483647";
  evaluates_int "017 + 0b101" "20";
  constant_type "0xffffffff" "unsigned int = 4294967295";
  constant_type "4294967295" "long = 4294967295";
  constant_type "1u" "unsigned int = 1";
  constant_type "0x8000000000000000" "unsigned long = 9223372036854775808";
  constant_type "077777777777l" "long = 8589934591";
  constant_type "1ull" "unsigned long long = 1";
  constant_type "0b11LL" "long long = 3";
  constant_type ~target:ilp32 "4294967295" "long long = 4294967295";
  constant_type ~target:ilp32 "0xffffffffl" "unsigned long = 4294967295";
  constant_type ("0000000000000000000000000000000000000000000000000000000"
                 ^ "00000000000000000000000000000000000000000000000000000001")
    "int = 1";
  evaluates_int "0x80000000u - 0x80000001u == -1u" "1";
  evaluates_int "-1ull > 0" "1";
  evaluates_int "(1LL << 40) >> 39" "2";
  evaluates_int ~target:ilp32 "sizeof(int) - 5 > 0" "1";
  evaluates_int "sizeof(int) - 5 > 0" "1";
  rejects "enum { V = 2147483647 + 1 };" "6.6p4";
  rejects "enum { V = -(-2147483647 - 1) };" "6.6p4";
  rejects "enum { V = (-2147483647 - 1) / -1 };" "6.6p4";
  rejects "enum { V = (-2147483647 - 1) % -1 };" "6.6p4";
  rejects "enum { V = 65536 * 65536 };" "6.6p4";
  rejects "enum { V = 1 / 0 };" "6.5.5p5";
  rejects "enum { V = 1 % 0 };" "6.5.5p5";
  rejects "enum { V = 1 << 32 };" "6.5.7p3";
  rejects "enum { V = 1 << -1 };" "6.5.7p3";
  rejects "enum { V = 18446744073709551616 };" "6.4.4.1p6";
  rejects "enum { V = 9223372036854775808 };" "6.4.4.1p6";
  rejects "enum { V = 0x10000000000000000 };" "6.4.4.1p6";
  rejects "enum { V = 1i };" "imaginary";
  rejects "enum { V = 1.0 };" "6.7.2.2p2";
  rejects "enum { V = (1, 2) };" "6.7.2.2p2";
  rejects "int x; enum { V = x };" "6.7.2.2p2";
  rejects "enum { V = y };" "6.5.1p2";
  rejects "enum { V = sizeof(void) };" "6.5.3.4p1";
  rejects "enum { V = sizeof(struct u) };" "6.5.3.4p1";
  rejects "enum { V = '\\400' };" "6.4.4.4p9";
  rejects "enum { V = '\\q' };" "6.4.4.4p1";
  rejects "enum { V = '\\u00e9' };" "code unit";
  rejects "enum { V = L'ab' };" "one character";
  rejects "enum { V = u'\\U0001F600' };" "code unit";
  rejects "enum { V = U'\\ud800' };" "6.4.3p2";
  rejects "enum { V = _Generic(1, int: 2) };" "_Generic";
  rejects "_Static_assert(1 == 2, \"no\");" "\"no\"";
  accepts "_Static_assert(sizeof(int) == 4, \"\"); \
           _Static_assert(sizeof(struct { int a; }) == 4, \"\");";
  rejects "int x; _Static_assert(x, \"\");" "6.7.10p2"

let enumerations () =
  declares "enum { A, B, C };" "C" "enumerator int = 2";
  declares "enum { A = 5, B, C = A + B };" "C" "enumerator int = 11";
  declares "enum e { A = 0x80000000 };" "A" "enumerator enum e = 2147483648";
  declares "enum e { A = 1, B = 0x80000000 };" "A" "enumerator enum e = 1";
  declares "enum e { A = -1, B = 0x80000000 };" "A" "enumerator enum e = -1";
  declares "enum e { A = 2147483647, B };" "B" "enumerator enum e = 2147483648";
  (* While the list is read, an enumerator has the type of its value. *)
  declares "enum e { A = 2147483647, B, C = B - B - 1 < 0 };" "C"
    "enumerator enum e = 1";
  declares "enum e { A = 0xffffffffffffffff };" "A"
    "enumerator enum e = 18446744073709551615";
  rejects "enum e { A = 0xffffffffffffffff, B };" "6.7.2.2p2";
  rejects "enum e { A = 0x8000000000000000, B = -1 };" "6.7.2.2p4";
  rejects "struct s { int a; }; enum e { A = sizeof(struct s), B };" "P16";
  let compatible source expected =
    match read lp64 source with
    | Error error -> fail_case source (Reader.error_message error)
    | Ok result -> (
        match Scope.find_tag result.file_scope "e" with
        | Some (Enum_tag tag) ->
            let actual =
              match Ctype.enum_integer result.tags tag with
              | Some (Answer integer) -> Some (Integer.name integer)
              | Some (Depends_on _) | None -> None
            in
            if actual <> Some expected then
              fail_case source ("compatible type is not " ^ expected)
        | Some (Record_tag _) | None -> fail_case source "no enum e")
  in
  compatible "enum e { A };" "unsigned int";
  compatible "enum e { A = -1 };" "int";
  compatible "enum e { A = 0x100000000 };" "unsigned long";
  compatible "enum e { A = -1, B = 0x80000000 };" "long"

(* A constant expression deeper than the bound is an error, not a crash;
   the parser reads the chain in a loop. *)
let deep_expression () =
  let terms = Declarations.max_expression_depth + 1 in
  let chain = String.concat " + " (List.init terms (fun _ -> "1")) in
  rejects ("enum { V = " ^ chain ^ " };") "too deeply";
  let chain = String.concat " + " (List.init 1000 (fun _ -> "1")) in
  evaluates_int chain "1000"

(* Huge constants take bounded work. *)
let huge_constants () =
  rejects ("enum { V = 0x" ^ String.make 100_000 'f' ^ " };") "6.4.4.1p6";
  rejects ("enum { V = '\\x" ^ String.make 100_000 'f' ^ "' };") "6.4.4.4p9";
  evaluates_int ("'" ^ String.make 100_000 'a' ^ "'") "1633771873"

let errors_are_located () =
  match read lp64 "int x;\nint y[\n  -1];" with
  | Error { location; _ } when location.line = 2 -> ()
  | Error { location; _ } ->
      fail_case "located error" (Printf.sprintf "line %d" location.line)
  | Ok _ -> fail_case "located error" "accepted"

(* The integer type of the enumeration tagged [tag], in words. *)
let enum_integer_of ?(target = lp64) source tag expected =
  match read target source with
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)
  | Ok result -> (
      let actual =
        match Scope.find_tag result.file_scope tag with
        | Some (Enum_tag enum) -> (
            match Ctype.enum_integer result.tags enum with
            | Some (Answer integer) -> Integer.name integer
            | Some (Depends_on unknown) -> "depends on " ^ unknown.construct
            | None -> "incomplete")
        | Some (Record_tag _) | None -> "no enumeration"
      in
      if actual <> expected then
        fail_case source (Printf.sprintf "%S, expected %S" actual expected))

(* The GNU profile that the parser reads. *)
let gnu_profile () =
  declares "int * _Nonnull const p;" "p" "object int *const external static";
  declares "struct e {} x;" "x" "object struct e external static";
  declares "int x __asm__(\"y\") __attribute__((unused));;" "x"
    "object int external static";
  (* An array of a constant length, not a variable length array. *)
  declares
    "struct s { int a; }; char c[__builtin_offsetof(struct s, a) + 1];" "c"
    "object char[<constant>] external static";
  (* typeof of a type name is that type. *)
  declares "typeof(const int *) t;" "t" "object const int * external static";
  declares "__typeof__(struct u { int a; }) v; struct u w;" "w"
    "object struct u external static"

(* What typec does not type yet is an unknown type, never a guess, and an
   error only where a declaration needs what that type is (design 13.3). *)
let unknown_types () =
  declares "_Float16 h;" "h" "object <'_Float16'> external static";
  declares "_Float16 f(_Float16, const _Float16 *);" "f"
    "function <'_Float16'> (<'_Float16'>, const <'_Float16'> *) external";
  declares "_Complex _Float16 z;" "z"
    "object <'_Complex _Float16'> external static";
  rejects "int _Float16 i;" "6.7.2p2";
  declares "_Complex _Float128 f(__float128);" "f"
    "function <'_Complex _Float128'> (<'__float128'>) external";
  rejects "__float128 _Float128 q;" "6.7.2p2";
  declares "void (^b)(void);" "b" "object <a block pointer> external static";
  declares "int q(void *, int (^)(const void *, const void *));" "q"
    "function int (void *, <a block pointer>) external";
  accepts "typedef struct { int (^e)(const char *, int); } glob_t;";
  declares "int x; typeof(x) *p;" "p"
    "object <'typeof' of an expression> * external static";
  declares "int x; typedef typeof(x) t;" "t"
    "typedef <'typeof' of an expression>";
  (* Whether the declaration declares a function depends on the type. *)
  rejects "int x; typeof(x) y;"
    "whether 'y' is a function or an object depends on 'typeof' of an \
     expression at in.c:1";
  (* The size of an unknown type is the backend's, as an aggregate's is. *)
  declares "char c[sizeof(_Float16)];" "c"
    "object char[<constant>] external static";
  declares "char c[sizeof(_Float16[2])];" "c"
    "object char[<constant>] external static";
  rejects "enum { A = sizeof(_Float16) };" "P16";
  (* The value of a cast needs its type. *)
  rejects "char c[(_Float16)2];"
    "the value of a cast depends on '_Float16' at in.c:1";
  (* A redeclaration with an unknown type is not checked, and the composite
     is unknown: the known parts must still agree. *)
  declares "double x; _Float16 x;" "x" "object <'_Float16'> external static";
  declares "_Float16 x; double x;" "x" "object <'_Float16'> external static";
  declares "int f(double); int f(_Float16);" "f"
    "function int (<'_Float16'>) external";
  rejects "int f(_Float16); double f(_Float16);" "6.7p4";
  rejects "int f(_Float16); int f(_Float16, int);" "6.7p4";
  declares "typedef double T; typedef _Float16 T;" "T" "typedef <'_Float16'>";
  rejects "typedef _Float16 *T; typedef _Float16 T[2];" "6.7p3";
  (* A bit-field or member of an unknown type is the backend's to check. *)
  accepts "struct s { _Float16 f : 3; void (^b)(void); };";
  rejects "struct s { _Float16 f : -1; };" "bit-field";
  (* An array of unknown elements, a pointer to them and a qualified one. *)
  declares "_Float16 a[2][3];" "a" "object <'_Float16'>[2][3] external static";
  declares "const _Float16 *const volatile p;" "p"
    "object const <'_Float16'> *const volatile external static";
  (* The qualifiers written on an unknown type are known, but not those
     within it, so two unknown types are not compared by them. *)
  rejects "_Atomic(const _Float16) x;" "_Atomic(T)";
  declares "const _Float16 x; _Float16 x;" "x"
    "object const <'_Float16'> external static";
  (* So is whether an unknown type is a function type. *)
  rejects "typedef int F(void); typedef int F __attribute__((foo));" "6.7p3";
  rejects "typedef int F(void); typedef F G __attribute__((foo)); const G g;"
    "function type has qualifiers"

(* An enumeration with a fixed type (C23 6.7.2.2, Clang): complete from the
   type on, its enumerators of the enumerated type with values that the
   type holds. *)
let fixed_enumerations () =
  enum_integer_of "enum e : unsigned char { A, B = 200 };" "e"
    "unsigned char";
  declares "enum e : unsigned char { A, B = 200, C };" "C"
    "enumerator enum e = 201";
  declares "enum e : long { A = -1 };" "A" "enumerator enum e = -1";
  enum_integer_of "enum e : const short;" "e" "short";
  declares "enum e : int; char c[sizeof(enum e)];" "c"
    "object char[4] external static";
  (* CF_ENUM in the macOS SDK. *)
  declares "typedef enum E : int E; enum E : int { X, Y };" "Y"
    "enumerator enum E = 1";
  (* A value that typec does not evaluate decides no type here. *)
  declares "struct s { int a; }; enum e : int { A = sizeof(struct s), B };"
    "B" "enumerator enum e = opaque";
  rejects "enum e : unsigned char { A = 256 };" "not representable";
  rejects "enum e : unsigned char { A = 255, B };" "not representable";
  rejects "enum e : unsigned char { A = -1 };" "not representable";
  rejects "enum e : int; enum e : long;" "another fixed type";
  rejects "enum e : int { A }; enum e { B };" "defined twice";
  rejects "enum e : float { A };" "not an integer type";
  (* A fixed type that typec does not know leaves the integer type unknown,
     so the enumerators, which need it, are an error. *)
  enum_integer_of "typedef int I __attribute__((mode(DI))); enum e : I;" "e"
    "depends on the attribute 'mode'";
  declares
    "typedef int I __attribute__((mode(DI))); enum e : I; \
     char c[sizeof(enum e)];"
    "c" "object char[<constant>] external static";
  rejects "typedef int I __attribute__((mode(DI))); enum e : I { A };"
    "the value of each enumerator depends on the attribute 'mode'"

(* The GNU attributes: those that change nothing the declarations compute
   are accepted, [noreturn] marks a function, and any other makes the type
   it applies to unknown, in every position of a declaration that the
   reader reads. *)
let attributes () =
  accepts
    "struct __attribute__((aligned(8))) s { int a __attribute__((aligned)); \
     } __attribute__((unused)); enum e { A __attribute__((deprecated)) }; \
     __attribute__((cold)) void f(int x __attribute__((unused))) \
     __attribute__((cold));";
  declares "typedef int TI __attribute__((mode(TI)));" "TI"
    "typedef <the attribute 'mode'>";
  declares "typedef int V __attribute__((__vector_size__(16)));" "V"
    "typedef <the attribute 'vector_size'>";
  declares "__attribute__((packed)) enum p { P } x;" "x"
    "object <the attribute 'packed'> external static";
  declares "__attribute__((packed)) enum p { P } x;" "P" "enumerator int = 0";
  let unknown_mode = "<the attribute 'mode'>" in
  List.iter
    (fun (source, name, expected) -> declares source name expected)
    [ ("struct __attribute__((mode(DI))) s { int a; } x;", "x",
       "object " ^ unknown_mode ^ " external static");
      ("struct s { int a; } __attribute__((mode(DI))) x;", "x",
       "object " ^ unknown_mode ^ " external static");
      ("enum __attribute__((mode(DI))) e { A } x;", "x",
       "object " ^ unknown_mode ^ " external static");
      ("struct s { int a __attribute__((mode(DI))); } x;", "x",
       "object struct s external static");
      ("void f(void) __attribute__((mode(DI))) {}", "f",
       "function " ^ unknown_mode ^ " external");
      ("int f(a) int a __attribute__((mode(DI))); { return a; }", "f",
       "function int () external");
      ("void g(int a __attribute__((mode(DI))));", "g",
       "function void (" ^ unknown_mode ^ ") external");
      ("int x __attribute__((mode(DI)));", "x",
       "object " ^ unknown_mode ^ " external static");
      ("__attribute__((mode(DI))) int x;", "x",
       "object " ^ unknown_mode ^ " external static");
      ("__attribute__((mode(DI))) int x, *y;", "y",
       "object " ^ unknown_mode ^ " external static") ];
  accepts "struct s { int a : 3 __attribute__((mode(DI))); };";
  (* A structure keeps its members; an enumeration's integer type is
     unknown wherever its tag names it, as packed and mode change it. *)
  declares "struct __attribute__((mode(DI))) s { int a; }; struct s y;" "y"
    "object struct s external static";
  enum_integer_of "enum __attribute__((mode(DI))) e { A };" "e"
    "depends on the attribute 'mode'";
  enum_integer_of "enum e { A } __attribute__((packed));" "e"
    "depends on the attribute 'packed'";
  declares "enum __attribute__((packed)) e { A }; enum e y;" "y"
    "object enum e external static";
  rejects "enum __attribute__((packed)) e { A = 0x100000000 };"
    "the type of enumerators that int does not hold depends on the \
     attribute 'packed'";
  accepts "enum e { A __attribute__((swift_name(\"a\"))) };";
  rejects "enum e { A __attribute__((mode(DI))) };"
    "the enumerator 'A' depends on the attribute 'mode' at in.c:1";
  (* Of the attributes, the first that typec does not know is named. *)
  declares "__attribute__((mode(DI))) __attribute__((vector_size(8))) int x;"
    "x" ("object " ^ unknown_mode ^ " external static");
  declares "__attribute__((mode(DI), vector_size(8))) int x;" "x"
    ("object " ^ unknown_mode ^ " external static");
  (* A function stays a function: Clang's overloads redeclare one with
     other types, which typec does not check. *)
  declares
    "__attribute__((overloadable)) float t(float); \
     __attribute__((overloadable)) double t(double);"
    "t" "function <the attribute 'overloadable'> external";
  rejects "int f(void) __attribute__((weak_import)); int f;"
    "different kind of identifier";
  declares "int x; int x __attribute__((mode(DI)));" "x"
    ("object " ^ unknown_mode ^ " external static");
  declares
    "typedef int V __attribute__((vector_size(16))); \
     char c[sizeof(V)];"
    "c" "object char[<constant>] external static";
  rejects "typedef int V __attribute__((vector_size(16))); char c[(V)1];"
    "the value of a cast depends on the attribute 'vector_size'";
  (* [gnu_inline] swaps what [inline] and [extern inline] define (GNU89),
     so it is recorded, through redeclarations and next to [noreturn]. *)
  declares "extern inline __attribute__((gnu_inline)) int f(void) { return 0; }"
    "f" "function int (void) external inline gnu_inline";
  declares "extern inline int f(void) { return 0; }" "f"
    "function int (void) external inline";
  declares "extern inline int h(void) __attribute__((gnu_inline)); int h(void);"
    "h" "function int (void) external inline gnu_inline";
  declares "__attribute__((gnu_inline, noreturn)) extern inline void g(void);"
    "g" "function void (void) external inline noreturn gnu_inline";
  (* GCC and Clang ignore it on a function without inline. *)
  declares
    "int k(void) __attribute__((gnu_inline)); extern inline int k(void);" "k"
    "function int (void) external inline";
  (* [noreturn] marks a function as [_Noreturn] does (design 4.4), from the
     specifiers for every declarator and from a declarator for its own. *)
  declares "void die(void) __attribute__((noreturn));" "die"
    "function void (void) external noreturn";
  declares "__attribute__((noreturn)) void a(void), b(void);" "b"
    "function void (void) external noreturn";
  declares "void a(void) __attribute__((noreturn)), b(void);" "b"
    "function void (void) external";
  declares "void d(void) __attribute__((noreturn)) {}" "d"
    "function void (void) external noreturn";
  declares "void e(void); void e(void) __attribute__((noreturn));" "e"
    "function void (void) external noreturn";
  (* Only the declaration of a function at file scope records the effect
     of noreturn and gnu_inline; elsewhere the type the attribute applies
     to is unknown, as GCC and Clang make noreturn part of the type of a
     pointer to a function. *)
  let unknown_noreturn = "<the attribute 'noreturn'>" in
  declares "__attribute__((noreturn)) int x;" "x"
    ("object " ^ unknown_noreturn ^ " external static");
  declares "__attribute__((gnu_inline)) int x;" "x"
    "object <the attribute 'gnu_inline'> external static";
  declares "void f(__attribute__((noreturn)) void (*g)(void));" "f"
    ("function void (" ^ unknown_noreturn ^ ") external");
  (* Inside the declarator of a function, GCC and Clang give the effect to
     the function, which typec does not record yet. *)
  rejects "void (__attribute__((noreturn)) b)(void);"
    "the declaration of the function 'b' depends on the attribute \
     'noreturn'";
  rejects "void * __attribute__((noreturn)) f(void);"
    "the declaration of the function 'f' depends on the attribute \
     'noreturn'";
  declares "__attribute__((noreturn)) void a(void), *b;" "b"
    ("object " ^ unknown_noreturn ^ " external static");
  declares "__attribute__((noreturn)) void a(void), *b;" "a"
    "function void (void) external noreturn";
  declares "void g(__attribute__((noreturn)) void cb(void));" "g"
    ("function void (" ^ unknown_noreturn ^ " *) external");
  declares "struct s { __attribute__((noreturn)) void (*f)(void); } x;" "x"
    "object struct s external static";
  declares "char c[sizeof(__attribute__((noreturn)) int)];" "c"
    "object char[<constant>] external static";
  accepts "int h(a) int a __attribute__((noreturn)); { return a; }";
  declares "void (* __attribute__((noreturn)) p)(void);" "p"
    ("object " ^ unknown_noreturn ^ " external static");
  declares "typedef void F(void) __attribute__((noreturn));" "F"
    ("typedef " ^ unknown_noreturn);
  declares "struct __attribute__((noreturn)) s { int a; } x;" "x"
    ("object " ^ unknown_noreturn ^ " external static");
  rejects "enum e { A __attribute__((noreturn)) };"
    "the enumerator 'A' depends on the attribute 'noreturn'";
  rejects "inline void (* __attribute__((gnu_inline)) p)(void);" "6.7.4p1";
  declares "int * __attribute__((aligned(8))) q, (__attribute__((unused)) r);"
    "q" "object int * external static";
  declares "void (* __attribute__((mode(DI))) *pp)(void);" "pp"
    "object <the attribute 'mode'> * external static";
  declares "int (^ __attribute__((mode(DI))) b)(void);" "b"
    "object <the attribute 'mode'> external static"

(* The typedef names that GCC and Clang declare before the first token.
   The representation of __builtin_va_list is the target's, so the reader
   sees no more of it than that it is a complete object type compatible
   only with itself. *)
let builtin_typedefs () =
  declares "" "__builtin_va_list" "typedef __builtin_va_list";
  declares "" "__int128_t" "typedef __int128";
  declares "" "__uint128_t" "typedef unsigned __int128";
  declares "__uint128_t r = 0;" "r" "object unsigned __int128 external static";
  declares "typedef __builtin_va_list va_list; va_list ap;" "ap"
    "object __builtin_va_list external static";
  declares
    "typedef __builtin_va_list va_list; int vf(const char *, va_list); \
     int vf(const char *f, __builtin_va_list ap) { return 0; }"
    "vf" "function int (const char *, __builtin_va_list) external";
  declares "struct w { __builtin_va_list ap; } w; __builtin_va_list a[2];" "a"
    "object __builtin_va_list[2] external static";
  declares "char c[sizeof(__builtin_va_list)];" "c"
    "object char[<constant>] external static";
  (* A limitation (design P20): i386 and arm64 Darwin accept it. *)
  rejects "int g(__builtin_va_list); int g(char *);" "6.7p4";
  rejects "int g(__builtin_va_list); int g(__builtin_va_list *);" "6.7p4";
  rejects "__builtin_va_list a; void *a;" "6.7p4";
  rejects "struct b { __builtin_va_list f : 1; };" "bit-field";
  (* A target without __int128 has no names for it, as in GCC and Clang. *)
  rejects ~target:ilp32 "__uint128_t u;" "'__uint128_t' is not a typedef name";
  rejects ~target:ilp32 "__int128_t i;" "'__int128_t' is not a typedef name";
  declares ~target:ilp32 "__builtin_va_list ap;" "ap"
    "object __builtin_va_list external static"

let () =
  builtin_typedefs ();
  gnu_profile ();
  unknown_types ();
  fixed_enumerations ();
  attributes ();
  specifier_combinations ();
  storage_classes ();
  declarators ();
  typedefs ();
  tags ();
  linkage ();
  composites ();
  constant_expressions ();
  enumerations ();
  deep_expression ();
  huge_constants ();
  errors_are_located ();
  if !failures > 0 then exit 1
