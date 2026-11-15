(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type c_type =
  | Void
  | Integer of Integer.t
  | Size
  | Uint16
  | Uint32
  | Uint64
  | Real of Arithmetic.floating
  | Complex of Arithmetic.floating
  | Va_list
  | Pointer of c_type
  | Const of c_type
  | Volatile of c_type

type prototype = { return : c_type; parameters : c_type list; variadic : bool }

type rule =
  | Type_generic of c_type
  | Pointee_of_first
  | Complex_of_first

type signature = Prototype of prototype | Rule of rule | Unknown

type architectures = Every | Only of Target.architecture list
type offer = { signature : signature; architectures : architectures }
type entry = { name : string; gcc : offer option; clang : offer option }

type lookup =
  | Builtin of signature
  | Of_other_compiler
  | Of_other_architectures
  | Not_builtin

(* The table's vocabulary *)

let bool = Integer Bool
let int = Integer Int
let unsigned = Integer Unsigned_int
let long = Integer Long
let void_pointer = Pointer Void
let const_void_pointer = Pointer (Const Void)
let volatile_void_pointer = Pointer (Volatile Void)
let string = Pointer (Integer Char)
let const_string = Pointer (Const (Integer Char))

let everywhere signature = Some { signature; architectures = Every }

let both name signature =
  { name; gcc = everywhere signature; clang = everywhere signature }

let gcc name signature = { name; gcc = everywhere signature; clang = None }
let clang name signature = { name; gcc = None; clang = everywhere signature }

let each name ~gcc ~clang =
  { name; gcc = everywhere gcc; clang = everywhere clang }

(* Clang lowers __builtin_setjmp and __builtin_longjmp on the
   architectures of hasSjLjLowering in its TargetInfo only, as Clang 21
   to 23 show with --target. GCC lowers them on every architecture, which
   is inferred: x86-64 and AArch64 are checked. *)
let setjmp_family name ~gcc ~clang =
  let clang_architectures = Only [ X86; Arm; Powerpc; Systemz; Ve ] in
  {
    name;
    gcc = everywhere gcc;
    clang = Some { signature = clang; architectures = clang_architectures };
  }

let prototype return parameters =
  Prototype { return; parameters; variadic = false }

let variadic return parameters =
  Prototype { return; parameters; variadic = true }

let type_generic result = Rule (Type_generic result)

(* The double, float and long double functions of a name, as C names
   them: [name], [name]f and [name]l. *)
let floating_family name signature_of =
  List.map
    (fun (suffix, floating) ->
      both (name ^ suffix) (signature_of (Real floating)))
    [ ("", Arithmetic.Double); ("f", Float); ("l", Long_double) ]

(* The int, long and long long functions of a name, signed or unsigned:
   [name], [name]l and [name]ll. *)
let integer_family name ~unsigned =
  let types : Integer.t list =
    if unsigned then [ Unsigned_int; Unsigned_long; Unsigned_long_long ]
    else [ Int; Long; Long_long ]
  in
  List.map2
    (fun suffix integer ->
      both (name ^ suffix) (prototype int [ Integer integer ]))
    [ ""; "l"; "ll" ] types

(* The constants of an optional floating type, whose name has the
   type's suffix, as in [__builtin_inff32]; typec does not compute the
   optional floating types (P21). *)
let optional_float_constants entry suffix =
  List.map
    (fun name -> entry (name ^ suffix) Unknown)
    [ "__builtin_huge_val"; "__builtin_inf"; "__builtin_nan"; "__builtin_nans" ]

(* The entries. The prototypes are those of the GCC manual ("Other
   Builtins", "Object Size Checking", "__atomic Builtins", "__sync
   Builtins", "Integer Overflow Builtins") and of Clang's Builtins.td,
   which agree but for __builtin_setjmp and __builtin_longjmp;
   test/run/expressions.t checks their return types and pointer
   parameters against both backends. *)

let memory_and_strings =
  [
    both "__builtin_memcpy"
      (prototype void_pointer [ void_pointer; const_void_pointer; Size ]);
    both "__builtin_memset"
      (prototype void_pointer [ void_pointer; int; Size ]);
    both "__builtin_memmove"
      (prototype void_pointer [ void_pointer; const_void_pointer; Size ]);
    both "__builtin_memcmp"
      (prototype int [ const_void_pointer; const_void_pointer; Size ]);
    both "__builtin_bzero" (prototype Void [ void_pointer; Size ]);
    both "__builtin_strcmp" (prototype int [ const_string; const_string ]);
    both "__builtin_strlen" (prototype Size [ const_string ]);
    both "__builtin_strcpy" (prototype string [ string; const_string ]);
    both "__builtin_strncpy" (prototype string [ string; const_string; Size ]);
    both "__builtin_strchr" (prototype string [ const_string; int ]);
    both "__builtin_printf" (variadic int [ const_string ]);
    both "__builtin_sprintf" (variadic int [ string; const_string ]);
    both "__builtin_snprintf" (variadic int [ string; Size; const_string ]);
    gcc "__builtin_puts" (prototype int [ const_string ]);
    both "__builtin_malloc" (prototype void_pointer [ Size ]);
    both "__builtin_free" (prototype Void [ void_pointer ]);
    both "__builtin_alloca" (prototype void_pointer [ Size ]);
  ]

(* The checking functions that the fortified string.h and stdio.h of
   macOS call, with the object size after the arguments of the function
   they check. *)
let object_size_checking =
  [
    both "__builtin_object_size" (prototype Size [ const_void_pointer; int ]);
    both "__builtin___memcpy_chk"
      (prototype void_pointer [ void_pointer; const_void_pointer; Size; Size ]);
    both "__builtin___memmove_chk"
      (prototype void_pointer [ void_pointer; const_void_pointer; Size; Size ]);
    both "__builtin___memset_chk"
      (prototype void_pointer [ void_pointer; int; Size; Size ]);
    clang "__builtin___memccpy_chk"
      (prototype void_pointer
         [ void_pointer; const_void_pointer; int; Size; Size ]);
    both "__builtin___strcpy_chk"
      (prototype string [ string; const_string; Size ]);
    both "__builtin___stpcpy_chk"
      (prototype string [ string; const_string; Size ]);
    both "__builtin___strcat_chk"
      (prototype string [ string; const_string; Size ]);
    both "__builtin___strncpy_chk"
      (prototype string [ string; const_string; Size; Size ]);
    both "__builtin___stpncpy_chk"
      (prototype string [ string; const_string; Size; Size ]);
    both "__builtin___strncat_chk"
      (prototype string [ string; const_string; Size; Size ]);
    clang "__builtin___strlcpy_chk"
      (prototype Size [ string; const_string; Size; Size ]);
    clang "__builtin___strlcat_chk"
      (prototype Size [ string; const_string; Size; Size ]);
    both "__builtin___sprintf_chk"
      (variadic int [ string; int; Size; const_string ]);
    both "__builtin___snprintf_chk"
      (variadic int [ string; Size; int; Size; const_string ]);
    both "__builtin___vsprintf_chk"
      (prototype int [ string; int; Size; const_string; Va_list ]);
    both "__builtin___vsnprintf_chk"
      (prototype int [ string; Size; int; Size; const_string; Va_list ]);
  ]

let floating =
  List.concat
    [
      floating_family "__builtin_fabs" (fun t -> prototype t [ t ]);
      floating_family "__builtin_copysign" (fun t -> prototype t [ t; t ]);
      floating_family "__builtin_fmax" (fun t -> prototype t [ t; t ]);
      floating_family "__builtin_huge_val" (fun t -> prototype t []);
      floating_family "__builtin_inf" (fun t -> prototype t []);
      floating_family "__builtin_nan" (fun t -> prototype t [ const_string ]);
      floating_family "__builtin_nans" (fun t -> prototype t [ const_string ]);
      [
        both "__builtin_conjf" (prototype (Complex Float) [ Complex Float ]);
        both "__builtin_complex" (Rule Complex_of_first);
        gcc "__builtin_isinff" (prototype int [ Real Float ]);
        gcc "__builtin_isinfl" (prototype int [ Real Long_double ]);
        clang "__builtin_flt_rounds" (prototype int []);
        gcc "__builtin_tgmath" Unknown;
      ];
      List.map
        (fun name -> both name (type_generic int))
        [ "__builtin_fpclassify"; "__builtin_isfinite"; "__builtin_isinf";
          "__builtin_isinf_sign"; "__builtin_isnan"; "__builtin_isnormal";
          "__builtin_signbit"; "__builtin_isgreater";
          "__builtin_isgreaterequal"; "__builtin_isless";
          "__builtin_islessequal"; "__builtin_islessgreater";
          "__builtin_isunordered" ];
      (* Clang has those of f128 (its __float128, GCC's _Float128) on
         every target, even one without the type. Provisional: GCC has
         each where it has the type, which every target of the test hosts
         does; a target without one would leave the call to the backend
         to refuse. *)
      optional_float_constants both "f128";
      List.concat_map (optional_float_constants gcc)
        [ "f32"; "f64"; "f32x"; "f64x" ];
    ]

let bits =
  List.concat
    [
      integer_family "__builtin_ffs" ~unsigned:false;
      integer_family "__builtin_clrsb" ~unsigned:false;
      integer_family "__builtin_clz" ~unsigned:true;
      integer_family "__builtin_ctz" ~unsigned:true;
      integer_family "__builtin_popcount" ~unsigned:true;
      integer_family "__builtin_parity" ~unsigned:true;
      [
        both "__builtin_abs" (prototype int [ int ]);
        (* Clang's is of unsigned short, which is not its uint16_t on
           AVR. *)
        each "__builtin_bswap16"
          ~gcc:(prototype Uint16 [ Uint16 ])
          ~clang:
            (prototype (Integer Unsigned_short) [ Integer Unsigned_short ]);
        both "__builtin_bswap32" (prototype Uint32 [ Uint32 ]);
        both "__builtin_bswap64" (prototype Uint64 [ Uint64 ]);
        both "__builtin_add_overflow" (type_generic bool);
        both "__builtin_sub_overflow" (type_generic bool);
        both "__builtin_mul_overflow" (type_generic bool);
        gcc "__builtin_mul_overflow_p" (type_generic bool);
      ];
    ]

(* The _n forms and the fetch operations give the value that the pointer
   points to; the generic forms take pointers to their values instead.
   Clang's __c11 builtins take a pointer to an _Atomic type. *)
let atomics =
  let pointee name = both name (Rule Pointee_of_first) in
  let generic_void name = both name (type_generic Void) in
  let fence name = both name (prototype Void [ int ]) in
  let c11 name rule = clang ("__c11_atomic_" ^ name) rule in
  List.concat
    [
      List.map pointee
        [ "__atomic_load_n"; "__atomic_exchange_n";
          "__sync_val_compare_and_swap"; "__sync_lock_test_and_set" ];
      List.concat_map
        (fun operation ->
          List.map pointee
            [ "__atomic_fetch_" ^ operation;
              "__atomic_" ^ operation ^ "_fetch";
              "__sync_fetch_and_" ^ operation;
              "__sync_" ^ operation ^ "_and_fetch" ])
        [ "add"; "sub"; "and"; "or"; "xor"; "nand" ];
      List.map generic_void
        [ "__atomic_store_n"; "__atomic_load"; "__atomic_store";
          "__atomic_exchange"; "__sync_lock_release" ];
      List.map fence [ "__atomic_thread_fence"; "__atomic_signal_fence" ];
      [
        both "__atomic_compare_exchange" (type_generic bool);
        both "__atomic_compare_exchange_n" (type_generic bool);
        both "__sync_bool_compare_and_swap" (type_generic bool);
        both "__atomic_test_and_set"
          (prototype bool [ volatile_void_pointer; int ]);
        both "__atomic_clear" (prototype Void [ volatile_void_pointer; int ]);
        both "__atomic_is_lock_free"
          (prototype bool [ Size; Pointer (Const (Volatile Void)) ]);
        both "__sync_synchronize" (prototype Void []);
      ];
      List.map
        (fun name -> c11 name (Rule Pointee_of_first))
        [ "load"; "exchange"; "fetch_add"; "fetch_sub"; "fetch_and";
          "fetch_or"; "fetch_xor" ];
      [
        c11 "init" (type_generic Void);
        c11 "store" (type_generic Void);
        c11 "compare_exchange_strong" (type_generic bool);
        c11 "compare_exchange_weak" (type_generic bool);
        c11 "is_lock_free" (prototype bool [ Size ]);
        c11 "thread_fence" (prototype Void [ int ]);
        c11 "signal_fence" (prototype Void [ int ]);
      ];
    ]

(* The va_list builtins take the list by reference, which no C type
   states, so a rule types them. GCC's __builtin_apply calls through a
   function type of no parameters and a variable argument list, which the
   table's types do not spell. *)
let control =
  [
    both "__builtin_va_start" (type_generic Void);
    (* C23's va_start, which takes the last parameter or nothing: GCC 15
       and Clang 21 have it in C23. *)
    both "__builtin_c23_va_start" (type_generic Void);
    both "__builtin_va_end" (type_generic Void);
    both "__builtin_va_copy" (type_generic Void);
    gcc "__builtin_va_arg_pack" Unknown;
    gcc "__builtin_va_arg_pack_len" (prototype int []);
    both "__builtin_expect" (prototype long [ long; long ]);
    clang "__builtin_assume" (prototype Void [ bool ]);
    (* The macOS SDK's os_log, whose format must be a string literal. *)
    clang "__builtin_os_log_format_buffer_size" (type_generic Size);
    clang "__builtin_os_log_format" (type_generic void_pointer);
    both "__builtin_constant_p" (type_generic int);
    both "__builtin_classify_type" (type_generic int);
    both "__builtin_prefetch" (variadic Void [ const_void_pointer ]);
    both "__builtin_return_address" (prototype void_pointer [ unsigned ]);
    both "__builtin_frame_address" (prototype void_pointer [ unsigned ]);
    (* GCC takes a void *, Clang a void ** to the buffer. *)
    setjmp_family "__builtin_setjmp"
      ~gcc:(prototype int [ void_pointer ])
      ~clang:(prototype int [ Pointer void_pointer ]);
    gcc "__builtin_apply_args" (variadic void_pointer []);
    gcc "__builtin_apply" Unknown;
    gcc "__builtin_shuffle" Unknown;
  ]

(* The builtins that GCC and Clang declare noreturn, whose call ends a
   match arm (design 4.4). *)
let not_returning =
  [
    both "__builtin_abort" (prototype Void []);
    both "__builtin_trap" (prototype Void []);
    both "__builtin_unreachable" (prototype Void []);
    gcc "__builtin_exit" (prototype Void [ int ]);
    setjmp_family "__builtin_longjmp"
      ~gcc:(prototype Void [ void_pointer; int ])
      ~clang:(prototype Void [ Pointer void_pointer; int ]);
  ]

let table =
  List.concat [ memory_and_strings; object_size_checking; floating; bits;
                atomics; control; not_returning ]

let noreturn name =
  List.exists (fun entry -> entry.name = name) not_returning

let offer (target : Target.t) entry =
  match target.backend.compiler with
  | Gcc -> entry.gcc
  | Clang -> entry.clang

let lookup (target : Target.t) entry =
  match offer target entry with
  | None -> Of_other_compiler
  | Some { signature; architectures = Every } -> Builtin signature
  | Some { signature; architectures = Only architectures } ->
      if List.mem target.architecture architectures then Builtin signature
      else Of_other_architectures

let find target name =
  match List.find_opt (fun entry -> entry.name = name) table with
  | None -> Not_builtin
  | Some entry -> lookup target entry

let rec c_type target t =
  let ( let* ) = Result.bind in
  match t with
  | Void -> Ok Ctype.void
  | Integer integer -> Ctype.integer target integer
  | Size -> Ctype.integer target target.Target.size_type
  | Uint16 -> Ctype.integer target target.uint16_type
  | Uint32 -> Ctype.integer target target.uint32_type
  | Uint64 -> Ctype.integer target target.uint64_type
  | Real floating -> Ctype.arithmetic target (Real floating)
  | Complex floating -> Ctype.arithmetic target (Complex floating)
  | Va_list -> Ok Ctype.va_list
  | Pointer referenced ->
      let* referenced = c_type target referenced in
      Ctype.pointer_to referenced
  | Const t -> qualified target { Qualifiers.none with const = true } t
  | Volatile t ->
      qualified target { Qualifiers.none with volatile = true } t

and qualified target qualifiers t =
  Result.bind (c_type target t) (Ctype.qualify qualifiers)

let function_type target { return; parameters; variadic } =
  let ( let* ) = Result.bind in
  let* return = c_type target return in
  let* types =
    List.fold_right
      (fun parameter types ->
        let* types = types in
        let* t = c_type target parameter in
        Ok (t :: types))
      parameters (Ok [])
  in
  Ctype.function_returning return (Prototype { types; variadic })
