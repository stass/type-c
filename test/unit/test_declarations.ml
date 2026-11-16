(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let lp64 = Canned_targets.target Canned_targets.lp64_macros
let ilp32 = Canned_targets.target Canned_targets.ilp32_macros
let lp64_clang = Canned_targets.(target (as_clang lp64_macros))
let aarch64_gcc = Canned_targets.(target (as_gcc aarch64_macros))
let aarch64_clang = Canned_targets.(target (as_clang aarch64_macros))

(* [file] is "in.c", C text, unless a case reads Type-C text. A parse
   error is the case's error as a typing error is. *)
let read ?(file = "in.c") target source =
  let text =
    match Reader.read ~name:file (Preprocessed.text ~name:file source) with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  let keywords = Target.keywords target Gnu in
  match Parser.parse_with_scopes ~keywords text with
  | Ok (_, ({ Parser.file_scope; _ } as scopes)) ->
      Result.map
        (fun result -> (file_scope, result))
        (Declarations.read target text scopes)
  | Error error -> Error error

(* What [name] denotes at file scope at the end of what [read] read. *)
let file_scope_entity ((file_scope : Parser.file_scope), result) name =
  Option.bind
    (List.assoc_opt name file_scope.ordinary)
    (Declarations.entity result)

let file_scope_tag ((file_scope : Parser.file_scope), result) name =
  Option.bind (List.assoc_opt name file_scope.tags) (Declarations.tag result)

let linkage_name : Entity.linkage -> string = function
  | External -> "external"
  | Internal -> "internal"
  | No_linkage -> "none"

let value_name (constant : Integer_constant.t) =
  match constant with
  | Known value -> Exact_integer.to_string value
  | Opaque -> "opaque"

(* An identifier as words: its kind, type, linkage and the rest. *)
let describe (declared : Entity.declared) =
  match declared with
  | Object { object_type; linkage; storage; _ } ->
      let storage_name =
        match storage with
        | Static_storage -> "static"
        | Thread_storage -> "thread"
        | Automatic_storage -> "automatic"
      in
      String.concat " "
        [ "object"; Type_name.of_ctype object_type; linkage_name linkage;
          storage_name ]
  | Function
      {
        function_type;
        linkage;
        inline;
        noreturn;
        gnu_inline;
        overload;
        old_style_definition = _;
      } ->
      String.concat " "
        ([ "function"; Type_name.of_ctype function_type; linkage_name linkage ]
        @ (if inline then [ "inline" ] else [])
        @ (if noreturn then [ "noreturn" ] else [])
        @ (if gnu_inline then [ "gnu_inline" ] else [])
        @ if overload then [ "overload" ] else [])
  | Typedef { typedef_type; _ } -> "typedef " ^ Type_name.of_ctype typedef_type
  | Enumerator { enumerator_type; value } ->
      Printf.sprintf "enumerator %s = %s"
        (Type_name.of_ctype enumerator_type)
        (value_name value)

let failures = ref 0

let fail_case source message =
  incr failures;
  Printf.eprintf "FAIL: %s\n  %s\n" source message

(* [source] declares [name] at file scope as [expected] describes. *)
let declares ?file ?(target = lp64) source name expected =
  match read ?file target source with
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)
  | Ok read -> (
      match file_scope_entity read name with
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
let rejects ?file ?(target = lp64) source expected =
  match read ?file target source with
  | Ok _ -> fail_case source "accepted"
  | Error { message; _ } ->
      if not (contains message expected) then
        fail_case source (Printf.sprintf "message %S lacks %S" message expected)

(* [source] has no error. *)
let accepts ?file ?(target = lp64) source =
  match read ?file target source with
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
        | Ok (integer, value) ->
            Integer.name integer ^ " = " ^ value_name value
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
      (* GNU: plain _Complex is _Complex double. *)
      ("_Complex", "_Complex double");
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
      "float double"; "_Complex _Complex double"; "_Complex _Bool";
      "_Complex __int128"; "_Complex void"; "void int";
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

(* The reader follows the links that the parser records (design 13.3): a
   declaration redeclares the one that its scope holds, a use names the
   one visible there. *)
let links () =
  (* A declaration in a prototype redeclares nothing at file scope. *)
  declares "void f(enum { A } a); enum { A = 1 };" "A" "enumerator int = 1";
  declares "void f(int x); int x[2];" "x" "object int[2] external static";
  rejects "void f(int x, enum { x } e);" "6.7p3";
  (* An enumerator in a declarator's own array length enters scope before
     the declarator does (6.2.1p7), and before a later length uses it. *)
  declares "int a[sizeof (enum { A = 2 })][A];" "a"
    "object int[4][2] external static";
  rejects "int x[sizeof (enum { x })];" "6.7p3";
  (* A tag is completed by a later declaration in its scope, and not by
     one in a prototype, which declares another tag (6.7.2.3p4, p8). *)
  accepts
    "struct s; struct s *p; struct s { int a; }; int c[sizeof (struct s)];";
  rejects "struct s; int c[sizeof (struct s)]; struct s { int a; };"
    "6.5.3.4p1";
  rejects "struct s; void f(struct s { int a; } *p); int c[sizeof (struct s)];"
    "6.5.3.4p1";
  declares "enum e; enum e { A = 300 }; char c[sizeof (enum e)];" "c"
    "object char[4] external static";
  (* What an initialiser at file scope declares is declared. *)
  declares "int x = sizeof (enum { A = 1 }); int y[A];" "y"
    "object int[1] external static";
  rejects "int x = sizeof (enum { A = 1 }); int A;" "different kind";
  rejects "int n = sizeof (struct t { int a; }); struct t { int a; };"
    "defined twice"

(* [source] gives the object or function with linkage [name], in whatever
   scope it is declared, as [expected] describes, or none where [expected]
   is empty. *)
let links_to ?(target = lp64) source name expected =
  match read target source with
  | Error error -> fail_case source ("error: " ^ Reader.error_message error)
  | Ok (_, result) ->
      let actual =
        match Declarations.linked result name with
        | Some entity -> describe entity.declared
        | None -> ""
      in
      if actual <> expected then
        fail_case source
          (Printf.sprintf "%s links to %S, expected %S" name actual expected)

let linkage_table () =
  links_to "static int x; extern int x;" "x" "object int internal static";
  links_to "int f(); int f(int);" "f" "function int (int) external";
  links_to "int x[]; void g(int x); int x[2];" "x"
    "object int[2] external static";
  links_to "void g(int x);" "x" "";
  links_to "typedef int T;" "T" "";
  links_to "enum { A };" "A" ""

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
  (* A universal character name and the UTF-8 character it names spell
     one identifier. *)
  rejects "int caf\\u00e9; long caf\xc3\xa9;" "6.7p4";
  rejects "int x\xf0\x9f\x98\x80; static int x\\U0001F600;" "6.2.2p7";
  declares "int caf\\u00e9; extern int caf\xc3\xa9;" "caf\xc3\xa9"
    "object int external static";
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

(* Clang gives an enumerated type and its compatible integer type the
   integer type as their composite and GCC the enumerated type, which
   with GCC makes the composite unknown. *)
let enum_integer_composites () =
  let enum = "enum e { E0 = 1 }; " in
  let clang_declares source = declares ~target:lp64_clang (enum ^ source) in
  clang_declares "extern enum e x; extern unsigned x;" "x"
    "object unsigned int external static";
  clang_declares "extern unsigned x; extern enum e x;" "x"
    "object unsigned int external static";
  clang_declares "extern enum e *y; extern unsigned *y;" "y"
    "object unsigned int * external static";
  clang_declares "void f(enum e); void f(unsigned);" "f"
    "function void (unsigned int) external";
  clang_declares "enum e g(void); unsigned g(void);" "g"
    "function unsigned int (void) external";
  accepts ~target:lp64_clang
    (enum ^ "extern enum e x; extern unsigned x; \
             typedef typeof(x) T; typedef unsigned T;");
  rejects ~target:lp64_clang
    (enum ^ "extern enum e x; extern unsigned x; \
             typedef typeof(x) T; typedef enum e T;")
    "6.7p3";
  let composite =
    "<the composite of an enumerated type and its integer type>"
  in
  declares (enum ^ "extern enum e x; extern unsigned x;") "x"
    ("object " ^ composite ^ " external static");
  declares (enum ^ "extern const enum e x; extern const unsigned x;") "x"
    ("object const " ^ composite ^ " external static");
  declares (enum ^ "void f(enum e); void f(unsigned);") "f"
    ("function void (" ^ composite ^ ") external");
  declares (enum ^ "extern enum e x; extern enum e x;") "x"
    "object enum e external static";
  (* Both compilers select 1 here; the unknown type covers more than the
     difference (TODO.md). *)
  rejects
    (enum ^ "extern enum e x; extern unsigned x; \
             enum { V = _Generic(x, unsigned: 1, default: 2) };")
    ("the value of _Generic depends on the composite of an enumerated type \
      and its integer type at in.c:1, which GCC types otherwise than Clang")

(* Clang keeps the qualifiers of a function's return type and GCC drops
   all but _Atomic of them, which with GCC makes a redeclaration that
   turns on them unknown. *)
let return_qualifiers () =
  let qualifiers = "<the qualifiers of a function's return type>" in
  declares "const int cf(void);" "cf" "function const int (void) external";
  rejects ~target:lp64_clang "const int cf(void); int cf(void);" "6.7p4";
  declares "const int cf(void); int cf(void);" "cf"
    ("function " ^ qualifiers ^ " (void) external");
  (* Only the return type is unknown, so a call's arguments are counted. *)
  rejects "const int cf(void); int cf(void); void t(void) { cf(1); }"
    "6.5.2.2p2";
  declares "const int cf(void); const int cf(void);" "cf"
    "function const int (void) external";
  rejects "_Atomic int af(void); int af(void);" "6.7p4";
  rejects "const int cf(void); long cf(void);" "6.7p4";
  rejects ~target:lp64_clang "typedef const int F(void); typedef int F(void);"
    "6.7p3";
  accepts "typedef const int F(void); typedef int F(void);";
  rejects "typedef const int F(void); typedef long F(void);" "6.7p3";
  (* GCC drops volatile and restrict too, and keeps _Atomic. *)
  rejects ~target:lp64_clang "volatile int vf(void); int vf(void);" "6.7p4";
  accepts "volatile int vf(void); int vf(void);";
  accepts "int *restrict rf(void); int *rf(void);";
  accepts "const _Atomic int af(void); _Atomic int af(void);";
  rejects "const _Atomic int af(void); int af(void);" "6.7p4";
  (* The difference counts wherever a function type stands. *)
  rejects ~target:lp64_clang
    "int g(const int (*)(void)); int g(int (*)(void));" "6.7p4";
  accepts "int g(const int (*)(void)); int g(int (*)(void));";
  rejects ~target:lp64_clang
    "typedef const int (*P)(void); typedef int (*P)(void);" "6.7p3";
  accepts "typedef const int (*P)(void); typedef int (*P)(void);";
  rejects ~target:lp64_clang "const int h(); int h(x) int x; { return x; }"
    "6.7p4";
  accepts "const int h(); int h(x) int x; { return x; }"

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
  evaluates_int "sizeof 1 + sizeof ((char)1) + sizeof 1.0f" "9";
  opaque "sizeof \"ab\"";
  opaque "__alignof__ 1";
  opaque "sizeof(struct q { int a; }) - sizeof(struct q)";
  opaque "(int)3.5";
  opaque "(int)_Generic(0, int: (1.5))";
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
  (* Each operation computes in the type that typing gives it: a shift in
     the promoted left operand's, whatever the count's; a comparison, a
     logical operator and [!] in int; ?: in the branches' common type. *)
  evaluates_int "(unsigned char)255 << 1" "510";
  evaluates_int "-1 >> 1u" "-1";
  rejects "enum { V = 1 << 40L };" "6.5.7p3";
  evaluates_int "-(unsigned char)1 < 0" "1";
  evaluates_int "~(unsigned short)0" "-1";
  evaluates_int "(1u < 2u) - 2 < 0" "1";
  evaluates_int "!0u - 2 < 0" "1";
  evaluates_int "(1u && 1u) - 2 < 0" "1";
  evaluates_int "(1 ? -1 : 0u) > 0" "1";
  evaluates_int "(0 ? 0u : -1L) < 0" "1";
  evaluates_int ~target:ilp32 "(0 ? 0u : -1L) < 0" "0";
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
  (* GNU C: the size of void and of a function is 1. *)
  evaluates_int "sizeof(void) + sizeof(int (void))" "2";
  declares "void *p; char c[sizeof *p];" "c" "object char[1] external static";
  declares "void f(void); char c[sizeof f];" "c"
    "object char[1] external static";
  rejects "enum { V = sizeof(struct u) };" "6.5.3.4p1";
  rejects "enum { V = '\\400' };" "6.4.4.4p9";
  rejects "enum { V = '\\q' };" "6.4.4.4p1";
  rejects "enum { V = '\\u00e9' };" "code unit";
  rejects "enum { V = L'ab' };" "one character";
  rejects "enum { V = u'\\U0001F600' };" "code unit";
  rejects "enum { V = U'\\ud800' };" "6.4.3p2";
  evaluates_int "_Generic(1, int: 2)" "2";
  evaluates_int "_Generic(1.0, int: 2, default: 3)" "3";
  evaluates_int "_Generic((const char)1, char: 2, default: 3)" "2";
  declares "int f(int); enum { V = _Generic(1, int: 2, default: f(1)) };" "V"
    "enumerator int = 2";
  rejects "int f(int); enum { V = _Generic(1, int: f(1), default: 2) };"
    "6.7.2.2p2";
  rejects "enum { V = _Generic(__builtin_shuffle(1), int: 1, default: 2) };"
    "the value of _Generic depends on the builtin '__builtin_shuffle'";
  (* GCC types the value of a narrow bit-field otherwise than Clang. *)
  declares ~target:lp64_clang
    "struct { unsigned b : 3; } v; \
     enum { V = _Generic(v.b++, unsigned: 1, default: 2) };"
    "V" "enumerator int = 1";
  rejects
    "struct { unsigned b : 3; } v; \
     enum { V = _Generic(v.b++, unsigned: 1, default: 2) };"
    "the value of _Generic depends on the value of a bit-field narrower \
     than its type at in.c:1, which GCC types otherwise than Clang";
  evaluates_int "__builtin_choose_expr(1, 2, 3)" "2";
  evaluates_int "__builtin_choose_expr(0, 2, (short)3)" "3";
  rejects "int f(int); enum { V = __builtin_choose_expr(1, f(1), 2) };"
    "6.7.2.2p2";
  evaluates_int "__builtin_types_compatible_p(int, int)" "1";
  evaluates_int "__builtin_types_compatible_p(int, long)" "0";
  evaluates_int "__builtin_types_compatible_p(const int, volatile int)" "1";
  evaluates_int "__builtin_types_compatible_p(const int *, int *)" "0";
  evaluates_int "__builtin_types_compatible_p(int[], const int[3])" "1";
  evaluates_int "__builtin_types_compatible_p(int *const[2][3], int *[2][3])"
    "1";
  evaluates_int "__builtin_types_compatible_p(enum { B }, unsigned)" "1";
  evaluates_int "__builtin_types_compatible_p(_Atomic int, _Atomic int)" "1";
  (* GCC drops _Atomic as a top-level qualifier, Clang keeps it, so with
     GCC the comparison of an _Atomic type with another is unknown. *)
  evaluates_int ~target:lp64_clang
    "__builtin_types_compatible_p(_Atomic int, long)" "0";
  evaluates_int ~target:lp64_clang
    "__builtin_types_compatible_p(_Atomic int[2], int[2])" "0";
  declares ~target:lp64_clang
    "int a[__builtin_types_compatible_p(_Atomic int, int) + 1];" "a"
    "object int[1] external static";
  declares "int a[__builtin_types_compatible_p(_Atomic int, int) + 1];" "a"
    "object int[<constant>] external static";
  rejects "enum { V = __builtin_types_compatible_p(_Atomic int, long) };"
    "does not evaluate";
  declares
    "int a[__builtin_types_compatible_p(typeof(__builtin_shuffle(1)), int)];"
    "a" "object int[<constant>] external static";
  declares "int a[__builtin_types_compatible_p(int, signed)];" "a"
    "object int[1] external static";
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
  (* An enumeration among members or in an array length declares its
     enumerators in the scope around it, here file scope (6.2.1p4). *)
  declares "struct s { enum { C } m; };" "C" "enumerator int = 0";
  declares "int a[sizeof (enum { A, B })];" "B" "enumerator int = 1";
  rejects "enum e { A = 0xffffffffffffffff, B };" "6.7.2.2p2";
  rejects "enum e { A = 0x8000000000000000, B = -1 };" "6.7.2.2p4";
  rejects "struct s { int a; }; enum e { A = sizeof(struct s), B };" "P16";
  let compatible source expected =
    match read lp64 source with
    | Error error -> fail_case source (Reader.error_message error)
    | Ok ((_, result) as read) -> (
        match file_scope_tag read "e" with
        | Some (Enum_tag tag) ->
            let actual =
              match Ctype.enum_integer (Declarations.tags result) tag with
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

(* The evaluator recurses as deep as the tree, which the parser bounds
   (test_parser): a constant expression just within the bound is
   evaluated. *)
let deep_expression () =
  let within = Parser.max_depth - 16 in
  let chain = String.concat " + " (List.init within (fun _ -> "1")) in
  evaluates_int chain (string_of_int within)

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
  | Ok ((_, result) as read) -> (
      let actual =
        match file_scope_tag read tag with
        | Some (Enum_tag enum) -> (
            match Ctype.enum_integer (Declarations.tags result) enum with
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
    "object struct u external static";
  (* typeof of an identifier is the type of what it denotes, unconverted,
     as musl's fortify headers declare a function. *)
  declares "const int x; typeof(x) y;" "y" "object const int external static";
  declares "int a[3]; typeof((a)) b;" "b" "object int[3] external static";
  declares "enum { A }; typeof(A) b;" "b" "object int external static";
  declares "char *f(int); typeof(f) g;" "g" "function char *(int) external";
  declares
    "char *f(int); __attribute__((access(read_only, 1))) __typeof__(f) \
     g __asm__(\"f\");"
    "g" "function <the attribute 'access'> external";
  declares "void f(int n, typeof(n) *p);" "f"
    "function void (int, int *) external";
  rejects "typeof(y) x;" "'y' is not declared (C11 6.5.1p2)";
  (* An undeclared name may be a builtin of the backend (design 13.3). *)
  declares "__typeof__(__builtin_memcpy) *p;" "p"
    "object void *(*)(void *, const void *, unsigned long) external static";
  declares "typeof(__builtin_shuffle) g;" "g"
    "function <the builtin '__builtin_shuffle'> external";
  rejects "typeof(__builtin_foo) y;" "'__builtin_foo' is not declared";
  (* typeof of an expression is its type, unconverted. *)
  declares "int x; typeof(x + 1) *p;" "p" "object int * external static";
  declares "int a[2]; typedef typeof((0, a)) t;" "t" "typedef int *";
  declares "short s; typeof(-s) n;" "n" "object int external static";
  rejects "typeof(1 + (struct { int a; }){0}) y;" "6.5.6p2"

(* What typec does not type yet is an unknown type, never a guess, and an
   error only where a declaration needs what that type is (design 13.3). *)
let unknown_types () =
  declares "_Float16 h;" "h" "object <'_Float16'> external static";
  declares "_Float16 f(_Float16, const _Float16 *);" "f"
    "function <'_Float16'> (<'_Float16'>, const <'_Float16'> *) external";
  declares "_Complex _Float16 z;" "z"
    "object <'_Complex _Float16'> external static";
  rejects "int _Float16 i;" "6.7.2p2";
  (* GNU's complex integer types, which GCC and Clang both have. *)
  declares "_Complex int c;" "c" "object <'_Complex int'> external static";
  declares "char _Complex unsigned d;" "d"
    "object <'_Complex unsigned char'> external static";
  declares "_Complex long long e(_Complex short);" "e"
    "function <'_Complex long long'> (<'_Complex short'>) external";
  declares "_Complex _Float128 f(__float128);" "f"
    "function <'_Complex _Float128'> (<'__float128'>) external";
  rejects "__float128 _Float128 q;" "6.7.2p2";
  declares "void (^b)(void);" "b" "object <a block pointer> external static";
  declares "int q(void *, int (^)(const void *, const void *));" "q"
    "function int (void *, <a block pointer>) external";
  accepts "typedef struct { int (^e)(const char *, int); } glob_t;";
  declares "_Float16 h; typeof(h + 1) *p;" "p"
    "object <'_Float16'> * external static";
  declares "_Float16 h; typedef typeof(h * 2) t;" "t" "typedef <'_Float16'>";
  (* Whether the declaration declares a function depends on the type. *)
  rejects "typeof(*__builtin_shuffle(1)) y;"
    "whether 'y' is a function or an object depends on the builtin \
     '__builtin_shuffle' at in.c:1";
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
  rejects "enum e : int { A }; enum e { B };" "with and without a fixed type";
  rejects "enum e : int; enum e { A };" "with and without a fixed type";
  rejects "enum e { A = -1 }; enum e : int;" "with and without a fixed type";
  rejects "enum __attribute__((packed)) e { A }; enum e : int;"
    "with and without a fixed type";
  rejects "enum e : int { A }; enum e : int { B };" "defined twice";
  (* GCC takes a later [enum e;] for the tag, where Clang refuses it. *)
  accepts "enum e : int; enum e;";
  (* A fixed type leaves [packed] nothing to narrow: GCC and Clang ignore
     it there, wherever it stands. *)
  declares "enum __attribute__((packed)) e : int; enum e : int { A, B = -A };"
    "B" "enumerator enum e = 0";
  enum_integer_of "enum e : unsigned char { A } __attribute__((__packed__));"
    "e" "unsigned char";
  declares "enum __attribute__((packed)) e : short { A } x;" "x"
    "object enum e external static";
  (* The first fixed type decides the type of the enumerators and their
     values alike: Clang gives [e] the type [mode] makes, and GCC int. *)
  rejects "enum __attribute__((mode(QI))) e : int; enum e : int { A };"
    "the value of each enumerator depends on the attribute 'mode'";
  rejects "enum e : int; enum __attribute__((mode(QI))) e : int { A };"
    "the value of each enumerator depends on the attribute 'mode'";
  rejects "enum e { A }; enum e { A };" "defined twice";
  rejects "enum e : int { A }; enum e { B = sizeof(int[-1]) };"
    "with and without a fixed type";
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
    "object <the attribute 'mode'> external static";
  (* Those that choose the code of a function for a processor, and
     Clang's diagnose_if, leave its type alone. *)
  List.iter
    (fun attribute ->
      declares
        ("__attribute__((" ^ attribute ^ ")) int f(void);")
        "f" "function int (void) external")
    [ "target(\"avx2\")"; "target_clones(\"avx2\", \"default\")";
      "target_version(\"default\")"; "cpu_dispatch(generic)";
      "cpu_specific(generic)"; "diagnose_if(1, \"x\", \"warning\")" ]

(* In a C23 specifier, Clang's own spelling [clang::x], or [_Clang::x], of
   an attribute that has one is the GNU attribute [x]; Clang ignores it
   for any other [x], so typec does not know it. Apple Clang 21 gives
   none to noreturn. *)
let clang_spellings () =
  List.iter
    (fun prefix ->
      declares
        ("int f(int); [[" ^ prefix ^ "::overloadable]] int f(long);")
        "f" "function int (long) external overload")
    [ "clang"; "_Clang" ];
  declares "[[clang::availability(macos, introduced=10.0)]] int f(void);"
    "f" "function int (void) external";
  declares "[[clang::cpu_specific(generic)]] int f(void);" "f"
    "function int (void) external";
  declares "[[clang::noreturn]] void f(void);" "f"
    "function <the attribute 'clang::noreturn'> external";
  declares "[[clang::target(\"avx2\")]] int f(void);" "f"
    "function <the attribute 'clang::target'> external"

(* Clang's [overloadable] makes a function one of an overload set of its
   name: an entity of its own, which redeclares nothing, is not linked and
   is checked against no other declaration (design 13.3). *)
let overloads () =
  (* musl's fortify-headers, as Clang reads them with -O. *)
  let fortified =
    "char *fgets(char *, int); \
     __typeof__(fgets) __orig_fgets __asm__(\"fgets\"); \
     static __inline__ __attribute__((__overloadable__)) char *fgets(\
     char *const __attribute__((pass_object_size(0))) s, int n) \
     { return __orig_fgets(s, n); }"
  in
  declares fortified "__orig_fgets" "function char *(char *, int) external";
  links_to fortified "fgets" "function char *(char *, int) external";
  declares "int f(int); __attribute__((overloadable)) int f(long);" "f"
    "function int (long) external overload";
  links_to "int f(int); __attribute__((overloadable)) int f(long);" "f"
    "function int (int) external";
  declares "int f(int); static __attribute__((overloadable)) int f(long);" "f"
    "function int (long) internal overload";
  (* Its linkage is its own, as nothing visible is redeclared (6.2.2p5). *)
  declares "static int f(int); __attribute__((overloadable)) int f(long);" "f"
    "function int (long) external overload";
  declares
    "static int f(int); extern __attribute__((overloadable)) int f(long);" "f"
    "function int (long) external overload";
  declares "int f(int); int f(long) __attribute__((overloadable));" "f"
    "function int (long) external overload";
  links_to "__attribute__((overloadable)) int f(long);" "f" "";
  (* A declaration without it redeclares the one before the overloads. *)
  links_to
    "int f(int); __attribute__((overloadable)) int f(long); \
     __attribute__((overloadable)) int f(char); int f();"
    "f" "function int (int) external";
  declares
    "static int f(int); __attribute__((overloadable)) int f(long); \
     int f(int);"
    "f" "function int (int) internal";
  declares "__attribute__((overloadable)) int f(long); int f(int);" "f"
    "function int (int) external";
  rejects
    "int f(int); __attribute__((overloadable)) int f(long); long f(int);"
    "6.7p4";
  rejects
    "int f(); __attribute__((overloadable)) int f(long); int f(int); \
     __attribute__((overloadable)) int f(char); int f(long);"
    "6.7p4";
  (* Nor is an overload checked against the others, which Clang does. *)
  accepts "int x; __attribute__((overloadable)) int x(void);";
  (* Clang takes two with the same type as one function; typec gives each
     an entity of its own, and leaves a conflict among them to Clang. *)
  accepts
    "__attribute__((overloadable)) int f(int); \
     __attribute__((overloadable)) int f(int);";
  declares
    "__attribute__((overloadable)) float t(float); \
     __attribute__((overloadable)) double t(double);"
    "t" "function double (double) external overload";
  accepts
    "__attribute__((overloadable)) int f(int); \
     __attribute__((overloadable)) long f(int);";
  (* Which overload a use denotes is for overload resolution (0.9b), even
     where the declaration it resolves to has no attribute. *)
  declares "__attribute__((overloadable)) int f(long); typeof(f) g;" "g"
    "function <the overloaded 'f'> external";
  declares
    "__attribute__((overloadable)) int f(long); int f(int); int f(int); \
     typeof(f) g;"
    "g" "function <the overloaded 'f'> external";
  declares "int f(int); typeof(f) g; __attribute__((overloadable)) int f(long);"
    "g" "function int (int) external";
  (* Elsewhere the attribute is not recorded, as noreturn is not. *)
  declares "__attribute__((overloadable)) int x;" "x"
    "object <the attribute 'overloadable'> external static";
  declares "typedef __attribute__((overloadable)) int F(int);" "F"
    "typedef <the attribute 'overloadable'>";
  rejects "int (__attribute__((overloadable)) f)(int);"
    "the declaration of the function 'f' depends on the attribute \
     'overloadable'";
  rejects "int * __attribute__((overloadable)) f(int);"
    "the declaration of the function 'f' depends on the attribute \
     'overloadable'"

(* The Arm vector types that GCC and Clang declare on AArch64, as glibc's
   bits/math-vector.h names them: GCC declares Neon's and SVE's, Clang
   SVE's only, and other targets neither. Their types are unknown. *)
let arm_vector_typedefs () =
  declares ~target:aarch64_gcc "typedef __Float32x4_t __f32x4_t;" "__f32x4_t"
    "typedef <the Arm vector type '__Float32x4_t'>";
  declares ~target:aarch64_gcc "typedef __Float64x2_t __f64x2_t;" "__f64x2_t"
    "typedef <the Arm vector type '__Float64x2_t'>";
  declares ~target:aarch64_gcc
    "typedef __Float32x4_t v; __attribute__((__aarch64_vector_pcs__)) v \
     _ZGVnN4v_acosf(v);"
    "_ZGVnN4v_acosf" "function <the attribute 'aarch64_vector_pcs'> \
     external";
  List.iter
    (fun target ->
      declares ~target "typedef __SVFloat32_t f; typedef __SVFloat64_t d; \
                        typedef __SVBool_t __sv_bool_t;"
        "__sv_bool_t" "typedef <the Arm vector type '__SVBool_t'>")
    [ aarch64_gcc; aarch64_clang ];
  declares ~target:aarch64_gcc
    "typedef __SVFloat32_t __sv_f32_t; typedef __SVBool_t __sv_bool_t; \
     __sv_f32_t _ZGVsMxv_acosf(__sv_f32_t, __sv_bool_t);"
    "_ZGVsMxv_acosf"
    "function <the Arm vector type '__SVFloat32_t'> (<the Arm vector type \
     '__SVFloat32_t'>, <the Arm vector type '__SVBool_t'>) external";
  rejects ~target:aarch64_gcc "int __SVBool_t;" "6.7p3";
  declares ~target:aarch64_clang "int __Float32x4_t;" "__Float32x4_t"
    "object int external static";
  declares "int __SVBool_t;" "__SVBool_t" "object int external static";
  (* SVE types have no size: the backend refuses one, as for any unknown
     type whose size typec leaves to it. *)
  declares ~target:aarch64_gcc "char c[sizeof(__SVBool_t)];" "c"
    "object char[<constant>] external static";
  rejects ~target:aarch64_gcc "char c[(__SVBool_t)2];"
    "the value of a cast depends on the Arm vector type '__SVBool_t' at \
     <built-in>:0"

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
  declares "typedef __signed__ __int128 s128;" "s128" "typedef __int128";
  declares "__int128 unsigned u;" "u"
    "object unsigned __int128 external static";
  rejects "long __int128 l;" "6.7.2p2";
  (* A target without __int128 has no names for it, as in GCC and Clang. *)
  declares ~target:ilp32 "int __int128_t;" "__int128_t"
    "object int external static";
  declares ~target:ilp32 "long __uint128_t;" "__uint128_t"
    "object long external static";
  declares ~target:ilp32 "int __int128;" "__int128"
    "object int external static";
  declares ~target:ilp32 "__builtin_va_list ap;" "ap"
    "object __builtin_va_list external static"

(* Initialisers (C11 6.7.9) and the lengths they give arrays of unknown
   size (p22). *)
let initialisers () =
  let length source name expected =
    declares source name ("object " ^ expected ^ " external static")
  in
  length "int a[] = { 1, 2, 3 };" "a" "int[3]";
  length "int a[] = {};" "a" "int[0]";
  length "char s[] = \"abc\";" "s" "char[4]";
  length "char s[] = { \"abc\" };" "s" "char[4]";
  length "char s[] = (\"ab\");" "s" "char[3]";
  length "unsigned char s[] = u8\"ab\";" "s" "unsigned char[3]";
  length "int w[] = L\"ab\";" "w" "int[3]";
  length "char s[][4] = { \"ab\", \"cd\", \"e\" };" "s" "char[3][4]";
  length "int a[] = { [5] = 1, 2, [1] = 3 };" "a" "int[7]";
  length "int a[] = { [2 ... 4] = 1 };" "a" "int[5]";
  length "int m[][2] = { 1, 2, 3 };" "m" "int[2][2]";
  length "int m[][2] = { { 1 }, 2, 3, { 4 } };" "m" "int[3][2]";
  length "struct p { int a, b; } p[] = { 1, 2, 3 };" "p" "struct p[2]";
  length "struct p { int a, b; } p[] = { { 1 }, { .b = 2 }, 3 };" "p"
    "struct p[3]";
  length "union u { int i; char c[8]; } u[] = { 1, 2 };" "u" "union u[2]";
  length "union u { int i; float f; } u[] = { { .f = 1 }, 2 };" "u"
    "union u[2]";
  length
    "struct n { int a; union { int b; float c; }; int d; } n[] = { 1, 2, 3, \
     4 };"
    "n" "struct n[2]";
  length "struct n { int a; struct { int b, c; }; } n[] = { [0].c = 1, 2 };"
    "n" "struct n[2]";
  length "struct q { int a[3]; int b; } q[] = { [0].a[1] = 5, 6, 7, 8 };"
    "q" "struct q[2]";
  length "struct t { char n[8]; int v; } t[] = { \"abc\", 1, \"def\", 2 };"
    "t" "struct t[2]";
  length "struct b { int : 3; int x; int : 0; int y; } b[] = { 1, 2, 3 };"
    "b" "struct b[2]";
  accepts "struct f { int n; int d[]; } f = { 1, 2, 3 }, g = { 1, { 2 } };";
  length "int *p[] = { 0, \"x\" == 0 };" "p" "int *[2]";
  length "extern int e[]; int e[] = { 1, 2 };" "e" "int[2]";
  length "typedef int T[]; T a = { 1 }; T b = { 1, 2, 3 };" "b" "int[3]";
  length "int a[] = (int[]){ 1, 2 };" "a" "int[2]";
  declares "int a[] = { 1, 2 }; int n = sizeof a / sizeof a[0];" "n"
    "object int external static";
  (* Where the length depends on what typec does not compute, it is
     opaque (design P16, P21). *)
  length "struct s { int x; }; int a[] = { [sizeof (struct s)] = 1 };" "a"
    "int[<constant>]";
  length "int a[][sizeof (struct { int x; })] = { 1, 2, 3 };" "a"
    "int[<constant>][<constant>]";
  length "int a[][sizeof (struct { int x; })] = { { 1 }, { 2 } };" "a"
    "int[2][<constant>]";
  length "struct h { _Float16 h; int x; } h[] = { 1, 2 };" "h"
    "struct h[<constant>]";
  length "struct h { _Float16 h; int x; } h[] = { { 1, 2 }, { 3 } };" "h"
    "struct h[2]";
  (* What an initialiser must be (6.7.9p3, p5, p6, p7, p14, p16). *)
  rejects "int a[] = { [sizeof a] = 1 };" "6.5.3.4p1";
  rejects "int a[] = { .x = 1 };" "6.7.9p7";
  rejects "struct s { int x; } v = { [0] = 1 };" "6.7.9p6";
  rejects "struct s { int x; } v = { .y = 1 };" "6.7.9p7";
  rejects "int a[2] = { [2] = 1 };" "6.7.9p6";
  rejects "int a[] = { [-1] = 1 };" "negative";
  rejects "int x; int a[] = { [x] = 1 };" "integer constant expression";
  rejects "int a[] = { [3 ... 1] = 1 };" "empty";
  rejects "int a[] = { [4611686018427387903] = 1 };" "too large";
  rejects "char s[] = L\"ab\";" "6.7.9p14";
  rejects "int w[] = \"ab\";" "6.7.9p14";
  rejects "int a[] = 5;" "6.7.9p16";
  rejects "int b[2]; int a[] = b;" "6.7.9p16";
  rejects "struct u; struct u v = { 0 };" "6.7.9p3";
  rejects "typedef int T = 1;" "6.7.9p3";
  rejects "int x = { .a = 1 };" "scalar";
  rejects "void f(void) { extern int x = 1; }" "6.7.9p5";
  (* GCC and Clang fold the length of a variable length array in places,
     and refuse the initialiser of one they do not fold. *)
  accepts "void f(int n) { int a[n] = {}; }";
  accepts "static const int N = 4; void f(void) { int a[N] = { 0 }; }";
  (* A string literal that a generic selection chooses (6.5.1.1p4), and
     one for an array of unknown type (design P21). *)
  length "char s[] = _Generic(0, int: \"abc\");" "s" "char[4]";
  length
    "struct n { char name[4]; int v; } n[] = { _Generic(0, int: \"ab\"), 1, \
     2 };"
    "n" "struct n[2]";
  accepts "typedef int q __attribute__((mode(QI))); q s[] = \"abc\";";
  (* GCC takes a compound literal for a subarray, Clang refuses it. *)
  length "struct c { int a[2]; int b; } c[] = { (int[2]){ 1, 2 }, 3, 4 };"
    "c" "struct c[<constant>]";
  accepts "int x = { 1, 2 }; int a[1] = { 1, 2 }; int y = { { 1 } };";
  let deep =
    "struct d0 { int x; };"
    ^ String.concat ""
        (List.init 300 (fun i ->
             Printf.sprintf "struct d%d { struct d%d m; };" (i + 1) i))
  in
  rejects (deep ^ "struct d300 v = { 0 };") "levels";
  accepts (deep ^ "void f(void) { struct d300 v; struct d300 w = v; }")

(* 6.7.9p4: the initialiser of an object of static or thread storage
   duration is constant; typec reports what GCC and Clang both refuse. *)
let static_initialisers () =
  let refused source = rejects source "6.7.9p4" in
  refused "int g; int h = g;";
  refused "int g; int h = g + 1;";
  refused "int g; int h = (g = 1);";
  refused "int g; int h = g++;";
  refused "struct t { int v; } x; struct t y[] = { x };";
  refused "_Thread_local int t; int *p = &t;";
  refused "void f(void) { int x; static int *p = &x; }";
  refused "void f(void) { int a[2]; static int *p = a; }";
  refused "void f(void) { static int *p = (int[]){ 1 }; }";
  refused "int g; int *p = (int[]){ g };";
  refused "int g, *p; int *q = &p[g];";
  accepts "int g; int *p = &g; int a[3]; int *q = &a[1]; int *r = a + 1;";
  accepts "struct s { int m; } s; int *p = &s.m; int (*f)(void); int \
           (*g)(void) = 0;";
  accepts "int f(void); int (*p)(void) = f; int (*q)(void) = &f;";
  accepts "int f(void); int x = f(); int y = 0 && f(); int z = (1, 2);";
  accepts "const int c = 1; int d = c; double e = 1.0 / 3;";
  accepts "void f(void) { const int c = 1; static int d = c; }";
  accepts "char *s = \"abc\" + 1; int c = \"abc\"[1]; int *p = (int *)16;";
  accepts "int *p = (int[]){ 1, 2 }; int n = (int){ 3 };";
  accepts "int g; long n = sizeof g; int *p = 0 ? &g : 0;";
  accepts "void f(void) { l: ; static void *p = &&l; int x = 1; int y = x; }";
  accepts "struct s { int m; } s; struct s t = (struct s){ 1 };";
  (* Excess initialisers are not checked: GCC and Clang drop them. *)
  accepts
    "int x; static int a[1] = { 1, x }; static int s = { 1, x }; union u { \
     int i; int j; } u = { 1, x };";
  accepts "void f(void) { static int a[] = (int[]){ 1, 2 }; }"

(* Type declarations (design 3.1) in Type-C text. *)
let type_declarations () =
  let file = "in.tc" in
  declares ~file "type id = unsigned int;" "id" "typedef unsigned int";
  declares ~file "type handler = void (*)(int);" "handler"
    "typedef void (*)(int)";
  declares ~file "type node;" "node" "typedef struct node";
  declares ~file "type node; node *p;" "p"
    "object struct node * external static";
  declares ~file "type pair = struct { int a; pair *next; };" "pair"
    "typedef struct pair";
  declares ~file "type list = struct node { list *next; };" "list"
    "typedef struct node";
  declares ~file "type u = union { int i; u *p; }; u v;" "v"
    "object union u external static";
  (* An alias is the type it names, not a new one. *)
  accepts ~file
    "type id = unsigned int; \
     _Static_assert(__builtin_types_compatible_p(id, unsigned int), \"\");";
  accepts ~file
    "type pair = struct { int a; pair *next; }; \
     _Static_assert(sizeof(pair) == 16, \"\"); pair p; int n = sizeof p.a;";
  (* The structure is incomplete in its own body. *)
  rejects ~file "type t = struct { t inner; };" "incomplete";
  rejects ~file "type node; int a[sizeof(node)];" "incomplete";
  (* A type declaration in a block is read there. *)
  accepts ~file "void f(int n) { type row = int[n]; row r; r[0] = 1; }";
  rejects ~file "int n = 3; type row = int[n];" "6.7.6.2p2";
  declares ~file "type t = int; void f(void) { type t = long; t x; } t y;" "y"
    "object int external static"

(* Structures n0 to n[depth], each holding two of the one below, and a
   variant whose field is a structure holding n[depth] and then the
   members [last]. *)
let doubling_structures depth last =
  "struct n0 { int a; };"
  ^ String.concat ""
      (List.init depth (fun n ->
           Printf.sprintf " struct n%d { struct n%d a; struct n%d b; };"
             (n + 1) n n))
  ^ Printf.sprintf " struct top { struct n%d n;%s };" depth last
  ^ " type v = | C(struct top f) | D;"

(* Variants (design 3.2) are the structures they lower to (10.1). *)
let variants () =
  let file = "in.tc" in
  declares ~file "type e = | A | B;" "e" "typedef struct e";
  declares ~file "type e = | A | B;" "e_B" "enumerator int = 1";
  declares ~file "type e; type e = | A(int x); e v;" "v"
    "object struct e external static";
  accepts ~file
    "type expr = | Number(long value) | Add(expr *left, expr *right); \
     expr x = {0};";
  (* A variant is a value type, so it may be a field. *)
  accepts ~file "type a = | X(int v); type b = | Y(a inner, a *next);";
  accepts ~file "struct s { int a[2]; }; type e = | A(struct s v);";
  (* A field type is a value type (rule 4); a variant holds itself only
     through a pointer (rule 5). *)
  rejects ~file "type e = | A(e inner);"
    "the field 'inner' of 'A' is not a complete object type, so it is not \
     a value type (design 3.2 rule 4) [TC0006]";
  rejects ~file "type e; type e = | A(e inner);" "not a complete object";
  rejects ~file "type e = | A(struct { e x; } s);" "incomplete";
  rejects ~file "struct s; type e = | A(struct s v);" "not a complete object";
  rejects ~file "type e = | A(void f(void));" "not a complete object";
  rejects ~file "type e = | A(int a[2]);" "is an array, which a struct";
  rejects ~file "type e = | A(const int x);" "'x' of 'A' is qualified";
  rejects ~file "type e = | A(int *restrict p);" "is qualified";
  rejects ~file "type e = | A(_Atomic int x);" "is atomic";
  rejects ~file "void f(int n) { type e = | A(int (*p)[n]); }"
    "is variably modified";
  rejects ~file "struct s { const int c; }; type e = | A(struct s v);"
    "has a const-qualified member";
  rejects ~file
    "struct in { const int c[2]; }; struct out { int i; struct in n; }; \
     type e = | A(struct out v);"
    "has a const-qualified member";
  rejects ~file "union u { int i; const long c; }; type e = | A(union u v);"
    "has a const-qualified member";
  rejects ~file "struct f { int n; int a[]; }; type e = | A(struct f v);"
    "has a flexible array member";
  accepts ~file "struct s { const int *p; }; type e = | A(struct s v);";
  rejects ~file
    "struct s { const int c; }; struct a { struct s e[2]; };\
    \ type e = | A(struct a v);"
    "has a const-qualified member";
  rejects ~file "struct s { int i; const int : 2; }; type e = | A(struct s v);"
    "has a const-qualified member";
  rejects ~file
    "struct s { const int c; int a[]; }; type e = | A(struct s v);"
    "has a const-qualified member";
  rejects ~file "type e = | A(int x, long x);" "duplicate member";
  (* Whether a record holds a const member is found once per record, so
     the time is linear in the text, not in the size of the value. *)
  let started = Sys.time () in
  accepts ~file (doubling_structures 30 "");
  rejects ~file (doubling_structures 30 " const int c;") "const-qualified";
  if Sys.time () -. started > 2.0 then
    fail_case "doubling_structures 30" "took over 2 s"

(* Type-C text takes a variant only whole (design 3.2 rule 6): it may
   initialise, assign, pass, return, size and address one; C text may use
   the structure it lowers to (10.6). *)
(* Design 4: the scrutinee, patterns, bindings and exhaustiveness. *)
let matching () =
  let file = "in.tc" in
  let variant = "type e = | A | B(int i, e *next) | C(long l); " in
  let in_function body =
    variant ^ "long f(e v, const e *p, int n) { " ^ body ^ " return 0; }"
  in
  let match_error body text = rejects ~file (in_function body) text in
  accepts ~file
    (in_function
       "long r = 0; match (*p) { case A: break; case B(i, next): \
        r = i + (next != 0); break; case C(l): r = l; break; } \
        while (n--) match (v) { case B(_, _): continue; default: \
        match (*p) { case C(x): r += x; break; case A: case B(_, _): \
        break; } break; } \
        match (v) { case A: case C(_): int fresh = 1; r = fresh; break; \
        default: switch (n) { case 1: break; } break; } (void)r;");
  (* A binding is a copy that is not modifiable, of its field's type. *)
  match_error "match (v) { case C(l): l = 1; break; default: break; }"
    "the operand is not a modifiable lvalue (C11 6.5.16p2)";
  accepts ~file
    (in_function
       "match (v) { case B(i, next): { const int *q = &i; e *m = next; \
        (void)q; (void)m; } break; default: break; }");
  match_error "match (v) { case C(l): break; default: (void)l; break; }"
    "'l' is not declared";
  match_error "match (v) { case B(x, x): break; default: break; }"
    "'x'";
  match_error "match (n) { default: break; }"
    "the scrutinee of a match is not of a variant type; a pointer is not \
     dereferenced implicitly (design 4.1 rule 1) [TC0014]";
  match_error "match (p) { default: break; }"
    "the scrutinee of a match is not of a variant type";
  rejects ~file
    "type t; void g(t *q) { match (*q) { default: break; } }"
    "the scrutinee of a match is of the incomplete variant 't', whose \
     constructors are unknown here (design 4.1 rule 1) [TC0014]";
  match_error "match (v) { case D: break; default: break; }"
    "'D' names no constructor of the variant 'e' (design 4.1 rule 3) [TC0016]";
  match_error "match (v) { case C: break; default: break; }"
    "the case label 'C' omits the field list of a constructor with 1 \
     field(s), which only a single-pattern test may (design 4.1 rule 3) \
     [TC0016]";
  match_error "match (v) { case A: break; case C: case B: break; }"
    "the case label 'C' omits the field list";
  match_error "match (v) { case A: break; case B(_, _): case C: break; }"
    "the case label 'C' omits the field list";
  match_error "match (v) { case A(x): break; default: break; }"
    "the pattern 'A' has 1 sub-pattern(s), and the constructor has 0 \
     field(s)";
  (* The match is a block: what its scrutinee declares ends with it. *)
  match_error
    "match (*(sizeof(enum K { KA }) ? p : p)) { default: break; } \
     return KA;"
    "'KA' is not declared";
  match_error "match (v) { case A: break; case C(x): case B(_, _): break; }"
    "the binding 'x' is in an arm of several labels, which none of them may \
     bind (design 4.1 rule 6) [TC0017]";
  match_error "match (v) { case A: break; default: case C(x): break; }"
    "(design 4.1 rule 6) [TC0017]";
  match_error "match (v) { case A: break; case B(_, _): break; }"
    "the match does not cover the constructor 'C' of the variant 'e' \
     (design 4.2 rule 1) [TC0018]";
  match_error "match (v) { case B(_, _): break; }"
    "the match does not cover the constructors 'A' and 'C' of the variant \
     'e' (design 4.2 rule 1) [TC0018]";
  match_error "match (v) { case A: break; case A: break; default: break; }"
    "the constructor 'A' is covered twice (design 4.2 rule 1) [TC0018]";
  match_error "match (v) { case A: case A: break; default: break; }"
    "the constructor 'A' is covered twice";
  match_error "match (v) { case A: break; default: break; default: break; }"
    "a match has a second `default` (design 4.2 rule 2) [TC0019]";
  match_error
    "match (v) { case A: break; case B(_, _): break; case C(_): break; \
     default: break; }"
    "the `default` of a match covers no constructor (design 4.2 rule 2) \
     [TC0019]";
  match_error
    "switch (n) { case 1: match (v) { default: { case 2: break; } } }"
    "a case or default label inside a match arm, which is not one of its \
     own and belongs to no switch inside it (design 4.3 rule 3) [TC0020]";
  match_error "match (v) { default: if (n) { default: ; } break; }"
    "(design 4.3 rule 3) [TC0020]";
  (* A variant reaches no constructor through an enumeration. *)
  rejects ~file "enum k { K }; void g(enum k x) { match (x) { default: ; } }"
    "(design 4.1 rule 1) [TC0014]"

(* Design 4.3 rule 1 and 4.4: the end of every arm is unreachable, by the
   syntactic rules of 4.4, which evaluate no condition but a constant. *)
let arm_termination () =
  let file = "in.tc" in
  let variant =
    "type e = | A | B(int i); void g(void); _Noreturn void die(void); \
     __attribute__((noreturn)) void halt(void); \
     void stop(int) __attribute__((noreturn)); enum { ON = 1 }; "
  in
  let in_function body =
    variant ^ "long f(e v, int n) { while (n) { " ^ body
    ^ " } out: return 0; }"
  in
  (* [ends arm] puts [arm] as the last arm of a match. *)
  let ends arm =
    in_function ("match (v) { case A: break; default: " ^ arm ^ " }")
  in
  let open_end =
    "the end of the match arm can be reached (design 4.3 rule 1) [TC0021]"
  in
  let refused arm = rejects ~file (ends arm) open_end in
  let accepted arm = accepts ~file (ends arm) in
  accepted "break;";
  accepted "return 1;";
  accepted "continue;";
  accepted "goto out;";
  accepted "die();";
  accepted "halt();";
  accepted "(stop)(1);";
  accepted "__builtin_trap();";
  accepted "__builtin_unreachable();";
  accepted "__builtin_abort();";
  accepted "__builtin_exit(1);";
  accepted "do { continue; } while (1);";
  accepted "switch (n) { case 1: while (1) { default: return 1; } }";
  accepted "if (n) return 1; else break;";
  accepted "for (;;) ;";
  accepted "for (;1;) { if (n) continue; }";
  accepted "while (1) { switch (n) { case 1: break; } }";
  accepted "while (ON) { match (v) { default: break; } }";
  accepted "do { } while (2);";
  accepted "do { return 1; } while (n);";
  accepted "for (;;) { return 1; break; }";
  accepted "switch (n) { default: return 1; }";
  accepted "switch (n) { case 1: n++; default: return 1; }";
  accepted "{ n++; { break; } }";
  accepted "L: return 1;";
  accepted "({ return 1; });";
  accepted "(({ n++; continue; }));";
  accepted "match (v) { case A: return 1; default: die(); }";
  accepted "match (v) { case A: break; default: return 1; } return 2;";
  refused "n++;";
  refused "g();";
  refused "(void)die();";
  refused "{ }";
  refused "if (n) break;";
  refused "if (1) break;";
  refused "if (n) break; else n++;";
  refused "while (n) return 1;";
  refused "while (1, 1) ;";
  refused "for (;;) { if (n) break; }";
  refused "for (;;) { n += ({ if (n) break; 1; }); }";
  refused "for (;;) { int x = ({ break; 0; }); (void)x; }";
  refused "while (1) ({ break; });";
  refused "do { break; } while (1);";
  refused "do { continue; } while (n);";
  refused "do { if (n) continue; return 1; } while (0);";
  refused "do ; while (n);";
  refused "switch (n) { case 1: return 1; }";
  refused "switch (n) { default: break; }";
  refused "switch (n) { default: return 1; case 2: ; }";
  refused "return 1; L: n++;";
  refused "({ n++; });";
  refused "match (v) { default: break; }";
  refused "asm goto (\"\" : : : : out);";
  refused "switch (n) { case 1: switch (n) { default: return 1; } }";
  (* The jumps and labels in a type count, though it completes. *)
  refused "for (;;) { int w[n + ({ break; 1; })]; (void)w; }";
  refused "for (;;) { (void)sizeof (int [({ break; 1; })]); }";
  refused "for (;;) { __typeof__ (({ if (n) break; 1; })) w = 0; (void)w; }";
  refused "return 1; int w[n + ({ in: 1; })]; (void)w;";
  (* Which function of an overload set a call names is unknown. *)
  rejects ~file
    (variant
     ^ "__attribute__((overloadable)) void quit(double); \
        __attribute__((overloadable, noreturn)) void quit(int); \
        void h(e v) { match (v) { case A: quit(1); default: break; } }")
    open_end;
  (* A match in a type name is checked as any other. *)
  rejects ~file
    (variant
     ^ "void h(e v) { int a[({ int k = 1; match (v) { case A: k = 2; \
        default: break; } k; })]; (void)a; }")
    open_end;
  (* An arm before the last one, and the location of the refusal. *)
  rejects ~file (in_function "match (v) { case A: n++; default: break; }")
    open_end;
  (match read ~file lp64
           (variant ^ "void h(e v) {\n match (v) {\n case A:\n break;\n \
                       default:\n v = A;\n }\n}") with
   | Error { location; _ } when location.line = 5 -> ()
   | Error { location; _ } ->
       fail_case "arm location" (Printf.sprintf "line %d" location.line)
   | Ok _ -> fail_case "arm location" "accepted");
  (* C code gains no refusal: a switch section may fall into the next. *)
  accepts ~file
    "int c(int n) { switch (n) { case 1: n++; case 2: n--; } \
     for (;;) { if (n) break; } return n; }";
  (* The analysis recurses as deep as the tree, which the parser
     bounds, chains of statements included. *)
  let repeat depth text =
    String.concat "" (List.init depth (fun _ -> text))
  in
  accepts ~file
    (in_function
       (repeat 120 "match (v) { default: " ^ "return 1;" ^ repeat 120 " }"));
  accepted (repeat 4000 "if (n) return 1; else " ^ "return 0;");
  refused (repeat 4000 "if (n) " ^ "return 0;")

(* Design 4.3 rule 3: a label inside an arm is the target only of a goto
   in the same arm. *)
let arm_jumps () =
  let file = "in.tc" in
  let variant = "type e = | A | B(int i); " in
  let in_function body =
    variant ^ "int f(e v, e w, int n) { " ^ body ^ " out: return 0; }"
  in
  let into =
    "a jump into a match arm from outside it (design 4.3 rule 3) [TC0022]"
  in
  let refused body = rejects ~file (in_function body) into in
  let accepted body = accepts ~file (in_function body) in
  accepted
    "match (v) { case A: again: if (n--) goto again; break; \
     default: goto out; }";
  accepted
    "match (v) { case A: inner: match (w) { case A: goto inner; \
     default: goto out; } default: break; }";
  accepted "void *q = &&out; (void)q; match (v) { default: goto *q; }";
  accepted
    "{ __label__ in; match (v) { case A: in: if (n--) goto in; break; \
     default: break; } } goto in; in: ;";
  accepted "goto in; switch (n) { case 1: in: break; }";
  refused "goto in; match (v) { case A: in: return 1; default: break; }";
  refused "match (v) { case A: in: return 1; default: break; } goto in;";
  refused "match (v) { case A: goto in; default: in: return 1; }";
  refused
    "match (v) { case A: match (w) { case A: in: return 1; \
     default: break; } goto in; default: break; }";
  refused
    "match (v) { case A: n += ({ goto in; 0; }); break; \
     default: in: break; }";
  refused
    "match (v) { case A: break; default: in: break; } \
     asm goto (\"\" : : : : in);";
  rejects ~file
    (in_function
       "match (v) { case A: in: { void *q = &&in; (void)q; } return 1; \
        default: break; }")
    "the address of a label inside a match arm, which a computed goto \
     could jump to from outside the arm (design 4.3 rule 3) [TC0022]";
  (* The labels of the arms are those of the function, as in the C that
     the match lowers to. *)
  rejects ~file
    (in_function
       "match (v) { case A: in: break; default: in: break; }")
    "a second definition of a label in its scope (C11 6.8.1p3)"

(* Design 3.3: qualified constructors everywhere, unqualified ones where
   the target type of the position is the variant. *)
let constructors () =
  let file = "in.tc" in
  let variant = "type e = | A | B(int i, e *next); type s = | S(e v); " in
  let in_function body =
    variant ^ "void take(e); e f(e v, int n) { " ^ body ^ " }"
  in
  let constructor_error body text =
    rejects ~file (in_function body) (text ^ " (design 3.3) [TC0009]")
  in
  accepts ~file
    (in_function
       "e x = A, y = e.B(n, &x); x = B(1, 0); take(A); take(e.A); \
        x = n ? A : B(2, &y); x = (n, A); s w = S(B(3, 0)); \
        e a[2] = { A, B(1, 0) }; (void)w; (void)sizeof e.A; return (A);");
  accepts ~file (variant ^ "static e x = A, y = e.B(1, &x);");
  (* Under elided braces the subobject that an element reaches is its
     target, with no object of the constructor's name to fall back on. *)
  accepts ~file
    (variant
   ^ "e m[2][2] = { A, A, A, A }; struct w { struct t { e v; int n; } t; } \
      q = { A, 1 };");
  (* Under elided braces an anonymous member and the first element of an
     array are first subobjects, an unnamed bit-field none (6.7.9p9). *)
  accepts ~file
    (variant
   ^ "struct a { struct { e v; }; int n; } q[1] = { A, 1 }; \
      struct b { int : 3; e v; } r[1] = { A }; \
      struct c { struct d { e v; int n; } d[2]; int n; } u[1] = { A };");
  (* The first variant along the first members of a record is found once
     per record, so the time is linear in the text, not the nesting depth
     times the length of the list. *)
  let depth = 8000 in
  let nested =
    "struct n0 { e v; };"
    ^ String.concat ""
        (List.init depth (fun n ->
             Printf.sprintf " struct n%d { struct n%d a; };" (n + 1) n))
    ^ Printf.sprintf
        " void g(struct n%d y) { struct n%d x[] = { %s }; (void)x; }" depth
        depth
        (String.concat ", " (List.init depth (fun _ -> "y")))
  in
  let started = Sys.time () in
  accepts ~file (variant ^ nested);
  if Sys.time () -. started > 2.0 then
    fail_case "nested structures 8000" "took over 2 s";
  accepts ~file (variant ^ "typedef e alias; e x = alias.A;");
  (* A qualified constructor is an expression wherever one may stand,
     also after a parenthesis that could open a type name. *)
  accepts ~file
    (in_function
       "e x; x = (e.A); (void)sizeof(e.A); e.A; \
        __typeof__(e.A) y = x; return y;");
  (* An ordinary identifier of the name does not stand in the way
     (design 3.3). *)
  accepts ~file (variant ^ "int A; e x = A; int *p = &A;");
  (* Without a target type, the name is looked up as in C. *)
  rejects ~file (in_function "(void)A; return v;") "is not declared";
  rejects ~file (in_function "int i = B(1, 0); return v;")
    "is not declared";
  constructor_error "return e.C;"
    "the variant 'e' has no constructor 'C'";
  constructor_error "return e.B;" "the constructor 'B' takes arguments";
  constructor_error "return (e.B)(1, 0);"
    "a constructor is not a function, so it cannot be called through \
     parentheses";
  constructor_error "return A();"
    "the constructor 'A' has no fields, so it is written without parentheses";
  constructor_error "return B(1);"
    "the constructor 'B' takes one argument for each of its 2 fields";
  constructor_error "s w = S(1); return v;"
    "the argument for the field 'v' of 'S' does not have its type";
  constructor_error "return B(v, 0);"
    "the argument for the field 'i' of 'B' does not have its type";
  rejects ~file (variant ^ "type t; void g(void) { (void)t.A; }")
    "the variant 't' is incomplete here";
  rejects ~file (variant ^ "typedef int i; int x = i.A;")
    "'i' is not a variant, so it has no constructors";
  (* A constant initialiser needs constant arguments. *)
  rejects ~file (in_function "static e x; static e y = B(n, &x); return v;")
    "not a constant expression"

(* Design 3.2 rule 7: [{0}] and [{}] are the only braced initialisers of
   a variant. *)
let zero_values () =
  let file = "in.tc" in
  let variant = "type e = | A | B(int i); struct s { e v; int n; }; " in
  let refused source =
    rejects ~file (variant ^ source)
      "the only braced initialisers of a variant are {0} and {} (design \
       3.2 rule 7) [TC0008]"
  in
  accepts ~file
    (variant
   ^ "e x = {0}; e y = { 0 }; e a[2] = {0}; struct s z = {0}; \
      struct s w = { {0}, 1 }; struct s u = { A, 1 }; \
      struct s t = { .v = B(1), .n = 2 }; e c = (e){0};");
  accepts ~file
    (variant
   ^ "e x = {}; e a[2] = { {}, {0} }; struct s z = {}; \
      struct s w = { {}, 1 }; struct s v = { .v = {} }; \
      union u { e v; int n; } q = { {} }; e c = (e){};");
  refused "e x = {1};";
  refused "e x = { 0, 0 };";
  refused "e x = { .tag = 0 };";
  refused "e x = { {} };";
  refused "struct s z = { 0, 1 };";
  refused "struct s z = { .v.tag = 1 };";
  refused "struct s z = { .v = { 1 } };";
  refused "e c = (e){ 1 };";
  (* Where the subobject that an initialiser reaches is unknown, the
     backend could open the variant. *)
  rejects ~file
    (variant ^ "struct s z = { (_Complex int)2, 1234 };")
    "depends on what typec does not know, in an object that holds a variant";
  (* Whether a record holds a variant is found once per record, so the
     time is linear in the text, not in the size of the value. *)
  let lost_walk last =
    variant ^ doubling_structures 30 last
    ^ " struct top z = { (_Complex int)2, 1 };"
  in
  let started = Sys.time () in
  accepts ~file (lost_walk " int k;");
  rejects ~file (lost_walk " e k;") "in an object that holds a variant";
  if Sys.time () -. started > 2.0 then
    fail_case "lost_walk 30" "took over 2 s";
  (* A variant held through a member record, an array member or an
     anonymous member; a pointed-to variant is not held. The walk is lost
     where the complex value meets the first member, a structure. *)
  let lost source =
    variant ^ source ^ " struct w z = { (_Complex int)2, 1 };"
  in
  let held = "in an object that holds a variant" in
  rejects ~file (lost "struct w { struct s in; int n; };") held;
  rejects ~file
    (lost "struct t { int n; e a[2]; }; struct w { struct t t[1]; };")
    held;
  rejects ~file (lost "struct w { struct { int m; e v; }; int n; };") held;
  accepts ~file (lost "struct w { struct { int m; e *p; }; int n; };");
  (* C text initialises the representation (design 10.6). *)
  accepts ~file
    (variant ^ "\n# 1 \"v.h\" 1\ne x = { .tag = e_B, .u.B = { 1 } };\n\
                # 3 \"in.tc\" 2\n")

(* Design 3.4: the table of operations on a distinct type, in Type-C
   text; C text sees the representation (design 10.2). *)
let distinct_types () =
  let file = "in.tc" in
  let types =
    "type id = distinct unsigned int; type other = distinct unsigned int; \
     type ref = distinct int *; struct bits { id f : 3; int g; }; "
  in
  let in_function body =
    types ^ "id f(id a, id b, other o, ref r, unsigned u, int c) { " ^ body
    ^ " }"
  in
  let refused body =
    rejects ~file (in_function body)
      "a value of the distinct type 'id' takes no such operation; a cast to \
       its underlying type crosses to it (design 3.4) [TC0011]"
  in
  let mixed body =
    rejects ~file (in_function body)
      "the operands are not both of the distinct type 'id' (design 3.4) \
       [TC0011]"
  in
  let converts body =
    rejects ~file (in_function body) "without a cast (design 3.4) [TC0012]"
  in
  accepts ~file
    (in_function
       "id x = a; x = b; id *p = &x; void *v = p; (void)v; \
        (void)sizeof a; (void)_Alignof(id); f(x, a, o, r, u, c); (a, b); \
        if (a && !b || r) return c ? a : *p; while (a) break; \
        unsigned n = (unsigned)a + 1; x = (id)n; x = (id)o; \
        struct bits s = {0}; s.f = a; id z = {0}; (void)z; \
        return a == b ? (id)(a != b) : s.f;");
  accepts ~file (types ^ "static id k = (id)3; static id *q = &k;");
  List.iter refused
    [ "return a + b;"; "return -a;"; "a++; return a;"; "a += 1; return a;";
      "return (id)(a < b);"; "switch (a) { default: ; } return a;";
      "int t[2]; return (id)t[a];"; "struct bits s = {0}; return s.f + 1;" ];
  mixed "return (id)(a == u);";
  mixed "return (id)(a == 0);";
  mixed "(void)(c ? a : u); return a;";
  List.iter converts
    [ "id x = 1; return x;"; "unsigned n = a; return (id)n;";
      "a = u; return a;"; "return u;"; "f(u, a, o, r, u, c); return a;";
      "id x = o; return x;"; "unsigned *n = &a; return (id)*n;";
      "_Bool t = a; return (id)t;" ];
  rejects ~file
    (in_function "return a; } int g(id a) { return __builtin_printf(\"\", a);")
    "takes no such operation";
  rejects ~file (in_function "return (id)*r;") "'ref' takes no such operation";
  rejects ~file "type d = distinct struct s *[2];"
    "is not over an unqualified arithmetic or pointer type (design 3.4) \
     [TC0010]";
  rejects ~file "type d = distinct const int;"
    "is not over an unqualified arithmetic or pointer type (design 3.4) \
     [TC0010]";
  accepts ~file
    (types ^ "int g(id a) { return _Generic(a, unsigned: 1, id: 2); }");
  (* C text in a Type-C file sees the representation. *)
  accepts ~file
    (types
   ^ "\n# 1 \"m.h\" 1\n\
      static unsigned plus(id a) { return a + 1 + (a < 2); }\n\
      enum { three = (id)3 }; static int t[(id)2];\n\
      # 3 \"in.tc\" 2\n");
  rejects ~file "enum e; type d = distinct enum e;"
    "is not over an unqualified arithmetic or pointer type (design 3.4) \
     [TC0010]"

(* Design 3.4: every operand that typing reads refuses a distinct value
   in Type-C text, whichever path types it; a pointer to a distinct type
   meets no other pointer but one to void; a scalar that an initialiser
   reaches through elided braces converts as any other. *)
let distinct_operands () =
  let file = "in.tc" in
  let types =
    "type id = distinct unsigned int; type ref = distinct int *; \
     struct w { int v[4]; }; struct inner { id x; }; \
     struct outer { struct inner i; int n; }; struct pair { id t[2]; }; "
  in
  let in_function body =
    types ^ "id f(id a, ref r, unsigned u, int c) { " ^ body ^ " }"
  in
  let refused body =
    rejects ~file (in_function body)
      "a value of the distinct type 'id' takes no such operation"
  in
  let mixed body =
    rejects ~file (in_function body)
      "the pointers 'id *' and 'unsigned int *' are not compatible"
  in
  List.iter refused
    [ "int t[a]; (void)t; return a;";
      "(void)__builtin_offsetof(struct w, v[a]); return a;";
      "int t[4] = { [a] = 1 }; (void)t; return a;";
      "id x = a; (void)__atomic_fetch_add(&x, 1, 5); return a;";
      "id x = a; return __sync_add_and_fetch(&x, a);";
      "id x = a; __atomic_store_n(&x, a, a); return a;" ];
  rejects ~file (types ^ "static int t[(id)2];")
    "a value of the distinct type 'id' takes no such operation";
  rejects ~file (in_function "goto *r;") "'ref' takes no such operation";
  List.iter mixed
    [ "id x = a; unsigned *q = &u; return (id)(&x == q);";
      "id x = a; unsigned *q = &u; return (id)(&x < q);";
      "id x = a; unsigned *q = &u; return (id)(&x - q);";
      "id x = a; unsigned *q = &u; (void)(c ? &x : q); return a;" ];
  accepts ~file
    (in_function
       "id x = a; __atomic_store_n(&x, a, 5); \
        __asm__(\"\" : \"=r\"(x) : \"0\"(a)); \
        return __atomic_load_n(&x, 5);");
  (* GCC has no __c11 builtins, so these take a Clang target. *)
  rejects ~file ~target:lp64_clang
    (in_function "_Atomic id x; return __c11_atomic_fetch_add(&x, 1, 5);")
    "a value of the distinct type 'id' takes no such operation";
  rejects ~file ~target:lp64_clang
    (in_function "_Atomic id x; __c11_atomic_store(&x, u, 5); return a;")
    "a value of type 'unsigned int' does not convert to 'id' without a cast";
  rejects ~file ~target:lp64_clang
    (in_function
       "_Atomic id x; (void)__c11_atomic_exchange(&x, u, 5); return a;")
    "a value of type 'unsigned int' does not convert to 'id' without a cast";
  rejects ~file ~target:lp64_clang
    (in_function
       "volatile _Atomic id x; u = __c11_atomic_load(&x, 5); return a;")
    "a value of type 'id' does not convert to 'unsigned int' without";
  rejects ~file ~target:lp64_clang
    (in_function
       "_Atomic id x; \
        return (id)__c11_atomic_compare_exchange_weak(&x, &u, a, 5, 5);")
    "a value of type 'unsigned int *' does not convert to 'id *' without";
  accepts ~file ~target:lp64_clang
    (in_function
       "_Atomic id x; id e = a; __c11_atomic_init(&x, a); \
        __c11_atomic_store(&x, a, 5); (void)__c11_atomic_exchange(&x, a, 5); \
        (void)__c11_atomic_compare_exchange_strong(&x, &e, a, 5, 5); \
        (void)__c11_atomic_compare_exchange_weak(&x, &e, a, 5, 5); \
        return __c11_atomic_load(&x, 5);");
  (* Clang's max, min and nand fetch operations compute on the value;
     the operand is an int, so that the object is what is refused. *)
  List.iter
    (fun call ->
      rejects ~file ~target:lp64_clang
        (in_function ("_Atomic id x; id y = a; (void)" ^ call ^ "; return a;"))
        "a value of the distinct type 'id' takes no such operation")
    [ "__c11_atomic_fetch_max(&x, 1, 5)"; "__c11_atomic_fetch_min(&x, 1, 5)";
      "__c11_atomic_fetch_nand(&x, 1, 5)"; "__atomic_fetch_max(&y, 1, 5)";
      "__atomic_fetch_min(&y, 1, 5)"; "__atomic_max_fetch(&y, 1, 5)";
      "__atomic_min_fetch(&y, 1, 5)" ];
  rejects ~file ~target:lp64_clang
    (in_function "id y = a; (void)__sync_fetch_and_umax(&y, 1u); return a;")
    "'id *' does not convert to 'volatile unsigned int *' without a cast";
  accepts ~file ~target:lp64_clang
    (in_function
       "_Atomic int n = 0; int m = c; unsigned v = u; \
        (void)__c11_atomic_fetch_max(&n, c, 5); \
        (void)__c11_atomic_fetch_min(&n, c, 5); \
        (void)__c11_atomic_fetch_nand(&n, c, 5); \
        (void)__atomic_fetch_max(&m, c, 5); \
        (void)__atomic_fetch_min(&m, c, 5); \
        (void)__atomic_max_fetch(&m, c, 5); \
        (void)__atomic_min_fetch(&m, c, 5); \
        (void)__sync_fetch_and_max(&m, c); (void)__sync_fetch_and_min(&m, c); \
        (void)__sync_fetch_and_umax(&v, u); \
        (void)__sync_fetch_and_umin(&v, u); \
        return a;");
  accepts ~file
    (in_function
       "id x = a; id *p = &x; void *v = &u; (void)(p == v); \
        (void)(p == 0); (void)(p - p); (void)(c ? p : v); return *p;");
  List.iter
    (fun source ->
      rejects ~file (types ^ source) "without a cast (design 3.4) [TC0012]")
    [ "struct outer o = {5};"; "struct pair y = {5};";
      "struct outer o = { {5} };" ];
  accepts ~file
    (types
   ^ "struct outer o = {0}; struct outer p = { (id)5, 1 }; \
      struct pair y = { (id)1, (id)2 }; struct outer q = { { (id)5 } };");
  (* C text sees the representation at every level of a type. *)
  accepts ~file
    (types
   ^ "\n# 1 \"m.h\" 1\n\
      static unsigned *g(id *p, unsigned *q, int c) {\n\
      unsigned *s = p; (void)(p == q); (void)(p < q); (void)(p - q);\n\
      (void)s; return c ? p : q; }\n\
      static int h(id *p) { return _Generic(p, unsigned *: 1); }\n\
      # 3 \"in.tc\" 2\n")

let variant_operations () =
  let file = "in.tc" in
  let variant = "type e = | A | B(int i); " in
  let in_function body = variant ^ "e f(e v, e w, e *p) { " ^ body ^ " }" in
  let refused body =
    rejects ~file (in_function body)
      "the variant 'e' takes no such operation; Type-C text reaches its tag \
       and fields only through constructors and matching (design 3.2 rule 6) \
       [TC0007]"
  in
  accepts ~file
    (in_function
       "e x = v; x = w; e *q = &x; (void)sizeof v; (void)_Alignof(e); \
        (void)sizeof(*p); f(x, v, q); (v, w); return 1 ? v : *p;");
  accepts ~file (in_function "return ({ v; });");
  accepts ~file (in_function "return (v);");
  accepts ~file (in_function "v; return v;");
  refused "(void)v.tag; return v;";
  refused "(void)p->tag; return v;";
  refused "(void)(*p).u; return v;";
  refused "(void)f(v, w, p).tag; return v;";
  refused "(void)sizeof(v.tag); return v;";
  refused "(void)(v == w); return v;";
  refused "(void)(v != w); return v;";
  refused "(void)!v; return v;";
  refused "v += w; return v;";
  refused "(void)(int)v; return v;";
  accepts ~file (in_function "(void)v; (void)*p; return v;");
  accepts ~file
    (in_function "return _Generic(v, e: v, default: w);");
  refused "return (e)v;";
  refused "return (e)1;";
  refused "return (const e)v;";
  refused "(void)__builtin_offsetof(e, tag); return v;";
  (* C text, here a header that the Type-C file includes, reads the
     representation. *)
  accepts ~file
    (variant
   ^ "\n# 1 \"v.h\" 1\nint tag_of(e v) { return v.tag == e_B; }\n\
      int tag_at(e *p) { return (int)p->tag + (int)(e){0}.tag; }\n\
      # 3 \"in.tc\" 2\nint g(e v) { return tag_of(v); }")

(* Design 4.6: a single-pattern test is the selection step of a match
   as the condition of an [if] or [while]; its statement is no arm. *)
let single_pattern_test () =
  let file = "in.tc" in
  let variant = "type e = | A | B(int i) | C(long l, e *next); " in
  let in_function body =
    variant ^ "long f(e v, const e *p, int n) { " ^ body ^ " out: return 0; }"
  in
  let accepted body = accepts ~file (in_function body) in
  let refused body text = rejects ~file (in_function body) text in
  accepted "if (case B(i) = v) return i;";
  accepted "if (case A = *p) n = 1; else n = 2;";
  accepted
    "while (case C(l, next) = *p) { n += (int)l; p = next; } return n;";
  (* The statement may complete, and break and continue are C's. *)
  accepted "while (n--) if (case A = v) break; else continue;";
  accepted "while (case B(i) = v) { if (i) break; continue; }";
  accepted "match (v) { case B(i): if (case B(j) = v) return i + j; break; \
            default: break; }";
  (* A binding is not visible in the operand, the else branch or after;
     a nested block hides one. *)
  accepted
    "e x = v; if (case B(x) = x) return x; match (x) { default: break; }";
  refused "if (case B(j) = v) return j; else return j;"
    "'j' is not declared";
  refused "if (case B(j) = v) return j; return j;" "'j' is not declared";
  accepted "if (case B(i) = v) { { long i = 2; n = (int)i; } return i; }";
  refused "if (case B(i) = v) { long i = 2; return i; }" "'i'";
  refused "if (case B(i) = v) i = 2;" "not a modifiable lvalue";
  refused "while (case B(i) = v) { i++; }" "modifiable lvalue";
  (* 4.1 rules 1 and 3 hold for the operand and the pattern. *)
  refused "if (case A = p) return 1;"
    "the operand of a single-pattern test is not of a variant type; a \
     pointer is not dereferenced implicitly (design 4.1 rule 1) [TC0014]";
  refused "if (case A = n && n) return 1;" "[TC0014]";
  refused "if (case A = v && n) return 1;" "(design 3.2 rule 6) [TC0007]";
  refused "while (case D = v) break;"
    "'D' names no constructor of the variant 'e' (design 4.1 rule 3) \
     [TC0016]";
  refused "if (case B(i, j) = v) return 1;"
    "the pattern 'B' has 2 sub-pattern(s), and the constructor has 1 \
     field(s) (design 4.1 rule 3) [TC0016]";
  refused "if (case A(i) = v) return 1;" "[TC0016]";
  (* 4.6 rule 2: a test may omit the field list of a constructor with
     fields, and then binds nothing. *)
  accepted "if (case B = v) return 1; else n = 2;";
  accepted "while (case C = *p) break;";
  refused "if (case B = v) return i;" "'i' is not declared";
  accepted "if (case B = v) { long i = 2; return i; }";
  (* 4.3 rule 3 holds for the statement, whether or not it binds. *)
  let into =
    "a jump into the statement of a single-pattern test from outside it \
     (design 4.3 rule 3) [TC0022]"
  in
  refused "goto in; if (case A = v) { in: return 1; }" into;
  refused "if (case A = v) n = 1; else goto in; if (case B(i) = v) in: \
           return i;" into;
  refused "while (case A = v) { in: break; } goto in;" into;
  refused "void *q = &&in; (void)q; if (case A = v) in: return 1;"
    "the address of a label inside the statement of a single-pattern \
     test";
  accepted "if (case A = v) { in: if (n--) goto in; } else goto out;";
  accepted "if (case A = v) n = 1; else { in: if (n--) goto in; }";
  refused "switch (n) { case 1: if (case A = v) { case 2: ; } }"
    "a case or default label inside the statement of a single-pattern \
     test, which only a successful test enters (design 4.3 rule 3) \
     [TC0020]";
  (* Reachability: the test is no constant, and its statement's labels
     enter only from inside it. *)
  accepts ~file
    (variant
   ^ "int g(e v) { match (v) { case A: while (case B(i) = v) return i; \
      return 0; default: if (case A = v) return 1; else return 2; } }");
  rejects ~file
    (variant
   ^ "int g(e v) { match (v) { case A: return 1; default: if (case A = v) \
      return 1; } }")
    "[TC0021]";
  accepts ~file
    (variant
   ^ "int g(e v) { match (v) { case A: return 1; default: return 2; \
      if (case A = v) { in: return 3; } } }")

(* Generic types (design 3.5): identity, substitution, the definition
   check and the nesting limit. *)
let same a b = Printf.sprintf "__builtin_types_compatible_p(%s, %s)" a b

let asserts ?(holds = true) declarations condition =
  let condition = if holds then condition else "!" ^ condition in
  declarations ^ " _Static_assert(" ^ condition ^ ", \"\");"

let vector = "type vector(T) = struct { T *data; unsigned long len; };"
let box = "type box(T) = struct { T value; };"
let id = "type id(T) = distinct unsigned int;"

(* [depth] boxes around [int]. *)
let boxed depth =
  String.concat "" (List.init depth (fun _ -> "box("))
  ^ "int"
  ^ String.make depth ')'

let generic_identity () =
  let file = "in.tc" in
  (* Rule 3: one type for equal encodings, after typedef expansion. *)
  accepts ~file
    (asserts (vector ^ " typedef int myint;")
       (same "vector(int)" "vector(myint)"));
  accepts ~file
    (asserts ~holds:false vector (same "vector(int)" "vector(long)"));
  accepts ~file
    (vector ^ " extern vector(int) v; typedef int myint;"
    ^ " extern vector(myint) v;");
  accepts ~file
    (vector ^ " vector(int) a; void f(void) { vector(int) b = a; b.len = 1; }");
  (* A distinct instance equals only itself. *)
  let ids =
    id ^ " type expr = struct { int k; }; type stmt = struct { int k; };"
  in
  accepts ~file (asserts ids (same "id(expr)" "id(expr)"));
  accepts ~file (asserts ~holds:false ids (same "id(expr)" "id(stmt)"));
  accepts ~file (asserts ~holds:false ids (same "id(expr)" "unsigned int"));
  rejects ~file (ids ^ " id(expr) e; id(stmt) s; void f(void) { e = s; }")
    "'id__4stmt' does not convert to 'id__4expr'";
  accepts ~file (ids ^ " id(expr) e; id(expr) e2; void f(void) { e = e2; }");
  (* A transparent alias is the type it stands for: fp(const int) is
     fp(int), and fr(const int) is not fr(int). *)
  let fp = "type fp(T) = void (*)(T);" and fr = "type fr(T) = T (*)(void);" in
  accepts ~file (asserts fp (same "fp(const int)" "fp(int)"));
  accepts ~file (fp ^ " extern fp(int) p; extern fp(const int) p;");
  accepts ~file (asserts ~holds:false fr (same "fr(const int)" "fr(int)"));
  rejects ~file ~target:lp64_clang
    (fr ^ " extern fr(int) q; extern fr(const int) q;")
    "";
  accepts ~file
    (asserts "type ptr(T) = T *;" (same "ptr(int)" "int *"));
  accepts ~file (asserts "type ptr(T) = T *;" (same "ptr(void)" "void *"));
  accepts ~file (asserts (vector ^ " type ptr(T) = T *;")
    (same "vector(ptr(int))" "vector(int *)"))

let generic_instances () =
  let file = "in.tc" in
  (* Rule 7: an application under a pointer defines no instance, and a
     generic refers to itself through one. *)
  accepts ~file
    "type list(T) = | Nil | Cons(T head, list(T) *tail); list(int) l;";
  accepts ~file "type tree(T) = struct { tree(T) *left; T v; }; tree(int) t;";
  accepts ~file "type lst(T); lst(int) *p; \
                 type lst(T) = | Nil | Cons(T h, lst(T) *t); lst(int) l;";
  rejects ~file "type s(T) = struct { s(T) inner; };" "incomplete";
  rejects ~file "type s(T) = struct { s(T *) inner; };" "after a chain of 64";
  (* Rule 5: an argument that is not a value type is checked where the
     instance is needed complete, and the error is at the application. *)
  accepts ~file (box ^ " struct s; box(struct s) *p;");
  rejects ~file (box ^ " struct s; struct w { box(struct s) b; };")
    "in the instance 'box__T1s'";
  accepts ~file (box ^ " box(const int) c = { 1 };");
  (* The nesting limit is exact: 64 instances that each need the next. *)
  let member depth = box ^ " struct w { " ^ boxed depth ^ " deep; };" in
  accepts ~file (member 64);
  rejects ~file (member 65) "after a chain of 64";
  accepts ~file (box ^ " " ^ boxed 65 ^ " *deep;");
  accepts ~file "type ptr(T) = T *; ptr(void) v;"

(* Design 3.5 rule 6: a field whose type becomes void in an instance,
   by whatever route, does not exist there, so its constructor takes no
   argument for it. *)
let void_fields () =
  let file = "in.tc" in
  let opt = "type opt(T) = | No | Yes(T v); " in
  let two = "type two(A, B) = | Two(A a, B b) | One(A only); " in
  accepts ~file (opt ^ "struct w { opt(void) o; } w = { Yes };");
  accepts ~file (opt ^ "opt(const void) c = opt(const void).Yes;");
  accepts ~file (opt ^ "typedef void V; opt(V) o = Yes;");
  accepts ~file (opt ^ "opt(volatile void) o = Yes;");
  accepts ~file
    (opt ^ "type w(T) = | W(opt(T) o, T t); w(void) v = W(Yes);");
  accepts ~file
    "type l(T) = | Nil | Cons(T head, l(T) *tail); l(void) n = Nil, \
     c = Cons(&n);";
  accepts ~file
    (opt ^ "type h(T) = | H(opt(void) x, T t); h(int) a = H(Yes, 1); \
            opt(void) b = Yes;");
  accepts ~file (opt ^ "type id(T) = T; opt(id(void)) o = Yes;");
  accepts ~file (two ^ "two(void, int) t = Two(1), u = One;");
  accepts ~file (two ^ "two(int, void) t = Two(1), u = One(2);");
  accepts ~file (two ^ "two(void, void) t = Two, u = One;");
  rejects ~file (opt ^ "opt(void) o = Yes(1);") "the type void";
  rejects ~file (two ^ "two(void, int) t = Two(1, 2);") "the type void";
  rejects ~file (two ^ "two(void, int) t = Two;") "the type void";
  rejects ~file
    (two ^ "int f(two(void, int) t) { match (t) { case Two: return 0; \
            case One: return 1; } }")
    "the type void";
  accepts ~file
    (opt ^ "int f(opt(void) o) { match (o) { case No: return 0; \
            case Yes: return 1; } }");
  rejects ~file
    (opt ^ "int f(opt(void) o) { match (o) { case No: return 0; \
            case Yes(x): return 1; } }")
    "the type void";
  accepts ~file
    (opt ^ "int f(opt(void) o) { if (case Yes = o) return 1; return 0; }");
  (* Only the field's own type is removed: a pointer to void stays, an
     array of void is an error, and void written in the definition is
     refused when the definition is checked. *)
  accepts ~file
    "type p(T) = | P(T *p); p(void) v = P(0);";
  rejects ~file "type a(T) = | A(T a[2]); a(void) v;" "array";
  rejects ~file "type d(T) = | D(void x, T y);" "complete object type"

(* An instance of a generic variant is a variant (design 3.5 rule 3):
   its constructors build it, qualified or against a target type, and
   matching opens it, as for a variant that is not generic (3.2, 3.3,
   4). The names it derives come from its instance name (10.3). *)
let generic_variants () =
  let file = "in.tc" in
  let list = "type list(T) = | Nil | Cons(T head, list(T) *tail); " in
  let in_function body =
    list
    ^ "void take(list(int)); long f(list(int) v, list(int) *p) { " ^ body
    ^ " return 0; }"
  in
  accepts ~file
    (in_function
       "list(int) x = Nil, y = list(int).Cons(1, &x); x = Cons(2, &y); \
        take(Nil); take(list(int).Nil); x = (1 ? Nil : Cons(3, p)); \
        (void)sizeof list(int).Nil; list(int) z = {0}; (void)z;");
  accepts ~file (list ^ "list(int) n = Nil, c = list(int).Cons(1, &n);");
  accepts ~file
    (list ^ "struct w { list(int) l; int k; } q = { Cons(1, 0), 2 };");
  accepts ~file
    (in_function
       "long r = 0; match (v) { case Nil: break; case Cons(h, t): \
        { int *q = &h; list(int) *m = t; r = *q + (m != 0); } break; } \
        match (*p) { case Cons(_, _): break; default: break; } \
        if (case Cons(h, _) = v) { r += h; } (void)r;");
  (* Each instance has the field types of its own arguments. *)
  accepts ~file
    (in_function
       "list(char *) s = Cons(\"a\", 0); match (s) { case Cons(h, _): \
        { char **q = &h; (void)q; } break; default: break; }");
  let field_type instance field_type =
    in_function
      (Printf.sprintf
         "%s w = Cons(1, 0); match (w) { case Cons(h, _): \
          _Static_assert(__builtin_types_compatible_p(__typeof__(h), %s), \
          \"\"); break; default: break; }"
         instance field_type)
  in
  accepts ~file (field_type "list(long)" "long");
  rejects ~file (field_type "list(long)" "int") "static assertion";
  (* Exhaustiveness (4.2 rule 1). *)
  rejects ~file (in_function "match (v) { case Nil: break; }")
    "the match does not cover the constructor 'Cons' of the variant \
     'list__i' (design 4.2 rule 1) [TC0018]";
  rejects ~file
    (in_function
       "match (v) { case Nil: break; case Cons(_, _): break; \
        default: break; }")
    "the `default` of a match covers no constructor (design 4.2 rule 2)";
  rejects ~file (in_function "list(int) x = list(int).None; (void)x;")
    "has no constructor 'None' (design 3.3) [TC0009]";
  (* An unqualified constructor needs a variant target type. *)
  rejects ~file (in_function "int k = Nil; (void)k;") "'Nil'";
  (* A definition check that needs an instance leaves it to later uses;
     an instance of a variant completed after its application has the
     constructors of the completion. *)
  accepts ~file
    (list
   ^ "type box(T) = struct { list(T) l; }; list(int) a = Nil; \
      box(int) b = { Cons(1, &a) };");
  accepts ~file
    "type lst(T); lst(int) *p; type lst(T) = | No | Cons(T h, lst(T) *t); \
     int g(lst(int) x) { x = Cons(1, p); match (x) { case No: return 0; \
     case Cons(h, _): return h; } }";
  (* Design 3.2 rule 6: only constructors and matching open it. *)
  let refused = "the variant 'list__i' takes no such operation" in
  rejects ~file (in_function "(void)v.tag;") refused;
  rejects ~file (in_function "(void)p->u;") refused;
  rejects ~file (in_function "(void)(v == v);") refused;
  rejects ~file (in_function "list(int) x = { 1 }; (void)x;")
    "an initialiser reaches into the variant 'list__i'";
  (* An instance of a variant not complete yet has no constructors. *)
  rejects ~file
    "type lst(T); void g(lst(int) *p) { match (*p) { default: break; } }"
    "the scrutinee of a match is of the incomplete variant 'lst__i'"

let generic_arguments () =
  let file = "in.tc" in
  (* Rule 2. *)
  rejects ~file (box ^ " box(int[2]) b;") "is an array";
  rejects ~file (box ^ " box(int (*)[]) *b; box(void (int)) *f;")
    "function type";
  rejects ~file (box ^ " box(__int128) *b;") "no instance name encodes";
  rejects ~file
    (box ^ " void f(void) { struct s { int x; }; box(struct s *) b; }")
    "declared in a block";
  rejects ~file (box ^ " typedef struct { int x; } a, b; box(a) *x;")
    "more than one declaration names";
  rejects ~file (box ^ " typedef struct { int x; } *anon; box(anon) *x;")
    "which no declaration names";
  (* The encoding of an instance is bounded: each typedef doubles it. *)
  let pairs =
    "type pair(A, B) = struct { A a; B b; }; typedef pair(int, int) p0;"
    ^ String.concat ""
        (List.init 12 (fun n ->
             Printf.sprintf " typedef pair(p%d, p%d) p%d;" n n (n + 1)))
  in
  rejects ~file pairs "longer than 4096 bytes"

(* [source] is refused at [line] with a message that holds [expected]. *)
let rejects_at ~line source expected =
  match read ~file:"in.tc" lp64 source with
  | Ok _ -> fail_case source "accepted"
  | Error { location; message } ->
      if location.line <> line || not (contains message expected) then
        fail_case source
          (Printf.sprintf "error at line %d: %S, not at %d with %S"
             location.line message line expected)

(* [count] aliases, the nth of 2^n nested applications of the first,
   which only a reading per instance types in time. *)
let doubling_aliases count =
  "type b0(T) = T;"
  ^ String.concat ""
      (List.init count (fun n ->
           Printf.sprintf " type b%d(T) = b%d(b%d(T));" (n + 1) n n))
  ^ Printf.sprintf " b%d(int) x;" count

(* [count] generics, the nth of which needs two instances of the one
   before it, so that its definition check and [g<count>(int)] each need
   2^n instances of distinct arguments; [g0] has [members] members. *)
let doubling_instances ?(members = 1) count =
  let member index = Printf.sprintf " T v%d;" index in
  "type l(T) = struct { T x; }; type r(T) = struct { T y; };\
  \ type g0(T) = struct {"
  ^ String.concat "" (List.init members member)
  ^ " };"
  ^ String.concat ""
      (List.init count (fun n ->
           Printf.sprintf " type g%d(T) = struct { g%d(l(T)) a; g%d(r(T)) b; };"
             (n + 1) n n))
  ^ Printf.sprintf " g%d(int) x;" count

let generic_checks () =
  let file = "in.tc" in
  (* Rule 4: an application over a type parameter is an instance, so the
     check finds the generic's own instance incomplete within it. *)
  rejects ~file (box ^ " type g(T) = struct { box(g(T)) b; };") "incomplete";
  rejects ~file (box ^ " type g(T) = struct { box(g(T *)) b; };")
    "after a chain of 64";
  rejects ~file "type a(T) = struct { _Atomic T x; };"
    "`_Atomic` depends on a type parameter";
  accepts ~file
    (box ^ " type two(A, B) = struct { box(A) a; box(B) b; };"
    ^ " two(int, char) t;");
  (* Rule 7: a check defines no instance, so a real application counts
     the instances that the generic's definition needs. *)
  let holding depth =
    box ^ " type g(T) = struct { T x; " ^ boxed depth ^ " y; };"
  in
  accepts ~file (holding 63 ^ " struct w { g(int) z; };");
  (* Nor does it declare one: id(int) is one type after h's check. *)
  accepts ~file
    "type id(T) = distinct int; type g(T) = struct { T m; };\
    \ type h(T) = struct { T a; g(id(int)) *p; };\
    \ id(int) x; g(id(int)) v; void f(void) { x = v.m; }";
  rejects ~file (holding 64 ^ " struct w { g(int) z; };") "after a chain of 64";
  (* A check counts its own chains, which begin at the instances that
     the definition needs, and no later application can shorten them. *)
  accepts ~file (holding 64);
  rejects ~file (holding 65) "after a chain of 64";
  (* An instance defined before the check ends a chain. *)
  accepts ~file
    (box ^ " struct p { " ^ boxed 60 ^ " q; };"
    ^ " type g(T) = struct { T x; " ^ boxed 65 ^ " y; };");
  (* Nor does a check make a distinct type for any later point. *)
  accepts ~file
    "type d(T) = distinct int; int n;\
    \ int f(void) { return _Generic(__builtin_choose_expr(\
    __builtin_constant_p(n), n, n), int: 1, default: 2); }";
  (* A translation limit bounds the tokens that a unit reads for its
     instances, which can grow exponentially with the text, and so the
     time of the refusal, which is about a second. *)
  let started = Sys.time () in
  rejects ~file (doubling_instances 30) "tokens of definitions";
  if Sys.time () -. started > 10.0 then
    fail_case "doubling_instances 30" "took over 10 s";
  (* A definition of many members reaches the limit after fewer
     readings. *)
  rejects ~file (doubling_instances ~members:1000 30) "tokens of definitions";
  (* A transparent alias instance is a link of its chain, which causes
     the instance that it needs complete. *)
  let aliased depth =
    box ^ " type ab(T) = box(T)[1]; struct w { ab(" ^ boxed depth
    ^ ") deep; };"
  in
  accepts ~file (aliased 62);
  rejects ~file (aliased 63) "after a chain of 64";
  (* Each instance of a transparent alias is read once. *)
  let started = Sys.time () in
  accepts ~file (doubling_aliases 40);
  if Sys.time () -. started > 2.0 then
    fail_case "doubling_aliases 40" "took over 2 s";
  (* An error of a nested instance is reported at the outermost
     application. *)
  rejects_at ~line:4
    "type box(T) = struct { T value; };\n\
     type wrap(T) = struct { box(T) b; };\n\
     struct s;\n\
     struct w { wrap(struct s) x; };"
    "in the instance 'wrap__T1s'"

(* Design 10.3: every point that needs a type complete defines the
   instances that it needs, and where an instance's texts would stand
   before an external declaration that cannot hold them, the
   application is an error. *)
let generic_placement () =
  let file = "in.tc" in
  (* A block object (C11 6.7p7) and a tentative definition need their
     instances complete; a declaration with [extern] does not. *)
  rejects ~file (box ^ " struct s; void f(void) { box(struct s) b; }")
    "in the instance 'box__T1s'";
  rejects ~file (box ^ " struct s; box(struct s) b;")
    "in the instance 'box__T1s'";
  rejects ~file (box ^ " struct s; static box(struct s) b;")
    "in the instance 'box__T1s'";
  accepts ~file (box ^ " struct s; extern box(struct s) b;");
  accepts ~file (box ^ " struct s; extern box(struct s) b; \
                        struct s { int a; }; box(struct s) b;");
  accepts ~file "struct s x; struct s { int a; };";
  (* Each point of design 10.3 that typing reads is a need. *)
  let needs point =
    box ^ " struct s; box(struct s) *p; " ^ point
  in
  List.iter
    (fun point -> rejects ~file (needs point) "in the instance 'box__T1s'")
    [ "int n = sizeof(box(struct s));";
      "int n = _Alignof(box(struct s));";
      "_Alignas(box(struct s)) char c;";
      "void f(void) { *p = *p; }";
      "void g(); void f(void) { g(*p); }";
      "void g(box(struct s)); void f(void) { g(*p); }";
      "void f(int c) { (void)(c ? *p : *p); }";
      "void f(void) { (void)(0, *p); }";
      "void f(void) { *p; }";
      "void f(void) { (void)*p; }";
      "void f(void) { (void)(p + 1); }";
      "void f(void) { (void)p[1]; }";
      "void f(void) { p++; }";
      "void f(void) { (void)p->value; }";
      "void f(box(struct s) b) { }";
      "box(struct s) g(void) { return *p; }";
      "box(struct s) h(void); void f(void) { h(); }";
      "void f(void) { (void)(box(struct s)){ 0 }; }";
      "void f(void) { (void)__builtin_offsetof(box(struct s), value); }";
      "void f(__builtin_va_list a) \
       { (void)__builtin_va_arg(a, box(struct s)); }";
      "_Atomic(box(struct s)) *a;";
      "_Atomic box(struct s) *a;";
      "box(struct s) (*a)[2];" ];
  (* Rule 5: a typedef instance needs what its definition needs complete
     before the external declaration of its first use. *)
  let a2 = "type a2(T) = T[2];" in
  rejects ~file (a2 ^ " struct s { int a; } *f(a2(struct s) *p);")
    "needs 'struct s' complete";
  accepts ~file (a2 ^ " struct s { int a; }; struct s *f(a2(struct s) *p);");
  rejects ~file (box ^ " struct s { int a; } x = { sizeof(box(struct s)) };")
    "needs 'struct s' complete";
  rejects ~file
    (box ^ " enum e; struct t { enum e { A } k; box(enum e) b; };")
    "needs 'enum e' complete";
  (* The constructors of a variant instance are known once it is needed
     complete, as a constructor or a scrutinee needs it. *)
  let list = "type list(T) = | Nil | Cons(T head, list(T) *tail);" in
  List.iter
    (fun use -> accepts ~file (list ^ " " ^ use))
    [ "list(int) *p; int f(void) { return sizeof(list(int).Nil); }";
      "void g(list(int)); void f(void) { g(Nil); }";
      "void f(list(int) *p) { *p = Nil; }";
      "int f(list(int) *p) { match (*p) { case Nil: return 0; \
       case Cons(h, t): return h; } }" ];
  (* An enumeration, and an untagged type that a typedef names, are
     declared by the source before the declaration of the first use. *)
  rejects ~file (box ^ " enum e { A } f(box(enum e) *p);")
    "is declared in the external declaration";
  accepts ~file (box ^ " enum e { A }; enum e f(box(enum e) *p);");
  rejects ~file (box ^ " typedef struct { int x; } n, g(box(n) *p);")
    "is declared in the external declaration";
  accepts ~file (box ^ " typedef struct { int x; } n; n g(box(n) *p);");
  (* C11 6.7.2.3p8: the forward declaration of a tag that an argument
     names would change an earlier mention that declares it in a nested
     scope. *)
  let vec = "type vec(T) = struct { T *data; };" in
  let h =
    "struct H { int (*call)(struct X *); \
     struct X { vec(struct X *) v; } x; };"
  in
  rejects ~file (vec ^ " " ^ h) "declares the tag in a nested scope";
  rejects ~file
    (vec ^ " struct H { int (*call)(enum X *); vec(struct X *) v; };")
    "declares the tag in a nested scope";
  accepts ~file (vec ^ " struct X; " ^ h);
  accepts ~file
    (vec ^ " struct H { struct X *p; int (*call)(struct X *); \
            struct X { vec(struct X *) v; } x; };");
  accepts ~file
    "type opt(T) = | No | Yes(T v); struct node { opt(struct node *) next; };";
  (* A block literal before the application hides such mentions. *)
  let ptr = "type ptr(T) = T *;" in
  let probe =
    "int (^probe)(void) = ^{ return 0; }, size = sizeof(ptr(struct X *));"
  in
  let in_c text = ptr ^ "\n# 1 \"b.h\" 1\n" ^ text in
  rejects ~file (in_c probe) "a block literal";
  accepts ~file (in_c ("struct X; " ^ probe))

(* [source]'s texts of instances in the order they stand: each instance
   name, whether the text is the typedefs of its arguments, with the tag
   lines before each, its declaration or its definition, and the index
   of the external declaration whose anchor it stands at. *)
let placements source =
  let file = "in.tc" in
  let text =
    match Reader.read ~name:file (Preprocessed.text ~name:file source) with
    | Ok text -> text
    | Error error -> failwith (Reader.error_message error)
  in
  let keywords = Target.keywords lp64 Gnu in
  let scopes =
    match Parser.parse_with_scopes ~keywords text with
    | Ok (_, scopes) -> scopes
    | Error error -> failwith (Parser.error_message error)
  in
  let items = List.map fst scopes.declarations in
  let declaration_at (anchor : Tree.anchor) =
    let starts_before item = (Tree.anchor item).before <= anchor.before in
    List.length (List.filter starts_before items) - 1
  in
  match Declarations.read lp64 text scopes with
  | Error error ->
      fail_case source ("error: " ^ Reader.error_message error);
      []
  | Ok result ->
      let shown (placement : Declarations.placement) =
        let typedef (typedef : Declarations.argument_typedef) =
          List.map (fun (line : Type_name.tag_line) -> line.line)
            typedef.tag_lines
          @ [ typedef.name ]
        in
        let step =
          match placement.step with
          | Typedefs typedefs ->
              String.concat " " (List.concat_map typedef typedefs)
          | Declared _ -> "declared"
          | Defined -> "defined"
        in
        (Encoding.instance_name placement.instance, step,
         declaration_at placement.at)
      in
      List.map shown (Declarations.placements result)

let placement_indexes () =
  let expect source expected =
    if placements source <> expected then fail_case source "placements"
  in
  (* A use under a pointer defines nothing; the block object does. *)
  expect
    (box ^ " struct s { int a; }; box(struct s) *p; \
            void f(void) { box(struct s) b; }")
    [ ("box__T1s", "struct s; __tc_arg__T1s", 2); ("box__T1s", "declared", 2);
      ("box__T1s", "defined", 3) ];
  (* A nested use and need count where the definition that causes them
     stands, which follows the texts it needs. *)
  expect
    (box ^ " type wrap(T) = struct { box(T) b; }; int x; wrap(int) w;")
    [ ("wrap__i", "__tc_arg__i", 3); ("wrap__i", "declared", 3);
      ("box__i", "declared", 3); ("box__i", "defined", 3);
      ("wrap__i", "defined", 3) ];
  (* The definition of an alias instance is its declaration, which
     follows the texts of the instances that it uses. *)
  expect
    (box ^ " type ref(T) = box(T) *; ref(int) r; box(int) b;")
    [ ("ref__i", "__tc_arg__i", 2); ("box__i", "declared", 2);
      ("ref__i", "declared", 2); ("box__i", "defined", 3) ];
  (* Texts stand after the forward declaration of a variant that is no
     generic, in its own external declaration. *)
  expect
    (box ^ " type e = | A(box(int) b);")
    [ ("box__i", "__tc_arg__i", 1); ("box__i", "declared", 1);
      ("box__i", "defined", 1) ];
  (* A definition check places nothing. *)
  expect (box ^ " type wrap(T) = struct { box(T) b; };") [];
  (* An argument's typedef stands once, at the first use of an instance
     that takes it, before the texts that reading the definition puts
     there; a tag line stands before it for every structure or union
     tag that it names, that of a variant, an alias or an instance
     included. *)
  expect
    (box ^ " type pair(T, U) = struct { box(T) t; U u; }; \
            pair(struct s *, int) p;")
    [ ("pair__PT1si", "struct s; __tc_arg__PT1s __tc_arg__i", 2);
      ("pair__PT1si", "declared", 2); ("box__PT1s", "declared", 2);
      ("box__PT1s", "defined", 2); ("pair__PT1si", "defined", 2) ];
  expect
    (box ^ " type e = | A; type a = struct { int x; }; \
            box(e *) v; box(a *) r; box(box(int) *) i; box(e *) again;")
    [ ("box__P1e", "struct e; __tc_arg__P1e", 3);
      ("box__P1e", "declared", 3); ("box__P1e", "defined", 3);
      ("box__P1a", "struct a; __tc_arg__P1a", 4);
      ("box__P1a", "declared", 4); ("box__P1a", "defined", 4);
      ("box__i", "__tc_arg__i", 5); ("box__i", "declared", 5);
      ("box__PI3boxiE", "struct box__i; __tc_arg__PI3boxiE", 5);
      ("box__PI3boxiE", "declared", 5); ("box__PI3boxiE", "defined", 5) ]

let generic_definitions () =
  let file = "in.tc" in
  (* Rule 4 on the expanded type, and 7.1 rule 4. *)
  rejects ~file "type same(U) = U; type d(T) = distinct same(T);"
    "the representation after `distinct` depends on a type parameter";
  rejects ~file "type same(U) = U; type b(T) = struct { same(T) x : 3; };"
    "the type of a bit-field depends on a type parameter";
  rejects ~file "type a(T) = struct { _Atomic(T) x; };"
    "`_Atomic( )` depends on a type parameter";
  rejects ~file "type a(T) = struct { typeof(T) x; };"
    "`typeof( )` depends on a type parameter";
  rejects ~file "type a(T) = struct { char b[sizeof(T)]; T v; };"
    "in the definition of a generic type depends on a type parameter";
  rejects ~file
    (box ^ " type a(T) = struct { char b[sizeof(box(T))]; T v; };")
    "in the definition of a generic type depends on a type parameter";
  accepts ~file "type a(T) = struct { char b[sizeof(int)]; T v; }; a(int) x;";
  accepts ~file
    (box ^ " type pair(T) = struct { box(T) b; box(T *) p; };"
    ^ " pair(int) x;")

(* Design 13.5 and 3.5 rule 8: the definition of a generic reads where
   an instance's text stands as at the definition. *)
let generic_resolution () =
  let file = "in.tc" in
  (* A tag of a prototype's own scope, and a parameter's name, that
     file scope declares between the definition and the instance. *)
  rejects ~file
    "type handler(T) = struct { void (*call)(struct ctx *c, T value); }; \
     struct ctx { int depth; }; handler(int) h;"
    "in the instance 'handler__i' that this application names";
  rejects ~file
    "type handler(T) = struct { void (*call)(struct ctx *c, T value); }; \
     struct ctx { int depth; }; handler(int) h;"
    "the tag 'ctx' in a scope of its own";
  rejects ~file
    "type slot(T) = struct { void (*call)(int (foo), T value); }; \
     typedef char foo; slot(int) s;"
    "the text declares 'foo' for itself";
  accepts ~file
    "type slot(T) = struct { void (*call)(int (foo), T value); }; \
     int foo; slot(int) s;";
  accepts ~file
    "type slot(T) = struct { void (*call)(int (foo), T value); }; \
     slot(int) s; typedef char foo; slot(int) t;";
  (* What the text uses: an array type completed, a function type
     changed, and a type that depends on an unknown one, are refused;
     a structure completed and a declaration with the same type are
     not. *)
  let uses = "type g(T) = struct { T v; typeof(a) *p; };" in
  rejects ~file ("extern int a[]; " ^ uses ^ " int a[3]; g(int) x;")
    "changes the type that the text uses";
  rejects ~file ("int a(); " ^ uses ^ " int a(int); g(int) x;")
    "changes the type that the text uses (design 13.5) [TC0044]";
  accepts ~file ("extern int a[2]; " ^ uses ^ " extern int a[2]; g(int) x;");
  accepts ~file ("int a(int); " ^ uses ^ " int a(int); g(int) x;");
  accepts ~file ("extern int a[]; " ^ uses ^ " g(int) x; int a[3];");
  accepts ~file
    "struct s; type g(T) = struct { T v; struct s *p; }; \
     struct s { int a; }; g(int) x;";
  rejects ~file
    ("static _Float16 a(_Float16); " ^ uses
   ^ " static _Float16 a(_Float16 x) { return x; } g(int) x;")
    "[TC0045]";
  accepts ~file ("static _Float16 a(_Float16); " ^ uses ^ " g(int) x;");
  (* Unread text: an attribute's identifier that denotes a type
     parameter is refused at the definition, and one that denotes a
     declaration is a use of it. *)
  let aligned =
    "type g(T) = struct { T v __attribute__((aligned(sizeof(T)))); };"
  in
  rejects ~file ("typedef char T; " ^ aligned ^ " g(int) x;") "[TC0038]";
  rejects ~file aligned "[TC0038]";
  accepts ~file
    "enum { N = 8 }; \
     type g(T) = struct { T v __attribute__((aligned(N))); }; g(int) x;";
  rejects ~file
    "extern int a[]; \
     type g(T) = struct { T v __attribute__((aligned(sizeof(a)))); }; \
     int a[4]; g(int) x;"
    "changes the type that the text uses";
  rejects ~file
    "type g(T) = struct { T v __attribute__((aligned(sizeof(option)))); }; \
     int option; g(int) x;"
    "denotes a universe name, which lowering writes under a name";
  accepts ~file
    "type named(T) = struct { int name; T value; }; int name; \
     named(int) n;";
  (* A definition check writes no text: the check of [b] reads [a] over
     an opaque type after the typedef, but [a(int)] stands before it. *)
  accepts ~file
    "type a(T) = struct { T v; void (*f)(int (foo)); }; a(int) early; \
     typedef char foo; type b(T) = struct { a(T) inner; }; b(int) y;";
  (* The place of writing holds what lowering declares there: the
     forward declaration of a variant or a record alias whose body uses
     the instance (design 10.3), and the tag line of each tag that an
     instance's argument names, at a nested instance too. *)
  let slot =
    "type slot(T) = struct { void (*call)(int (expr), T value); };"
  in
  rejects ~file (slot ^ " type expr = | Call(slot(int) s) | Nil;")
    "the text declares 'expr' for itself";
  rejects ~file (slot ^ " type expr = struct { slot(int) s; };")
    "the text declares 'expr' for itself";
  rejects ~file
    "type handler(T) = struct { void (*call)(struct expr *c, T value); }; \
     type expr = | Call(handler(int) h) | Nil;"
    "the tag 'expr' in a scope of its own";
  let handler =
    "type handler(T) = struct { void (*call)(struct ctx *c, T value); };"
  in
  rejects ~file (handler ^ " handler(struct ctx *) h;")
    "the tag 'ctx' in a scope of its own";
  rejects ~file
    (handler ^ " type alias(T) = handler(T); alias(struct ctx *) h;")
    "the tag 'ctx' in a scope of its own";
  rejects ~file
    (handler
   ^ " type outer(T) = struct { handler(T) inner; }; \
      outer(struct ctx *) o;")
    "the tag 'ctx' in a scope of its own";
  accepts ~file (handler ^ " handler(struct other *) h;");
  (* A tag in unread text is a use of the tag. *)
  accepts ~file
    "struct s { int a; }; \
     type g(T) = struct { T v __attribute__((aligned(sizeof(struct s)))); }; \
     struct s; g(int) x;";
  (* The instance of a generic variant that a later declaration
     completes is defined, and checked, where a point first needs it
     complete after that. *)
  let deferred =
    "type g(T); g(int) *p; type g(T) = | A(void (*f)(int (foo))) | B(T v);"
  in
  rejects ~file (deferred ^ " typedef char foo; g(int) q;")
    "the text declares 'foo' for itself";
  accepts ~file (deferred ^ " g(int) q; typedef char foo;");
  (* A nested instance is checked where it stands, before the external
     declaration of the outer instance's first use. *)
  rejects ~file
    "type inner(T) = struct { void (*f)(int (y)); T v; }; \
     type outer(T) = struct { inner(T) i; }; typedef int y; outer(int) o;"
    "the text declares 'y' for itself";
  (* Moved text declares no name that is in scope after it, even where
     no instance is written (design 13.5, 3.5 rule 8). *)
  rejects ~file "type link(T) = struct { struct node *next; T v; };"
    "the tag 'node' is declared in the scope around the text"

let () =
  type_declarations ();
  variants ();
  variant_operations ();
  distinct_types ();
  distinct_operands ();
  constructors ();
  matching ();
  arm_termination ();
  arm_jumps ();
  single_pattern_test ();
  zero_values ();
  builtin_typedefs ();
  arm_vector_typedefs ();
  gnu_profile ();
  unknown_types ();
  fixed_enumerations ();
  attributes ();
  clang_spellings ();
  overloads ();
  specifier_combinations ();
  storage_classes ();
  declarators ();
  typedefs ();
  tags ();
  links ();
  linkage_table ();
  linkage ();
  composites ();
  enum_integer_composites ();
  return_qualifiers ();
  constant_expressions ();
  enumerations ();
  deep_expression ();
  huge_constants ();
  errors_are_located ();
  initialisers ();
  static_initialisers ();
  generic_identity ();
  generic_instances ();
  void_fields ();
  generic_placement ();
  placement_indexes ();
  generic_variants ();
  generic_arguments ();
  generic_definitions ();
  generic_checks ();
  generic_resolution ();
  if !failures > 0 then exit 1
