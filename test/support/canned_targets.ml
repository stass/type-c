(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Predefined macro dumps of three targets, shared by the unit tests and
   the fuzz harness. *)

(* The macros of the optional floating types that GCC 14 defines on
   x86-64, in the order it prints them. *)
let gcc_optional_float_macros =
  [
    ("__FLT16_MANT_DIG__", "11");
    ("__FLT32_MANT_DIG__", "24");
    ("__FLT64_MANT_DIG__", "53");
    ("__FLT128_MANT_DIG__", "113");
    ("__FLT32X_MANT_DIG__", "53");
    ("__FLT64X_MANT_DIG__", "64");
    ("__SIZEOF_FLOAT128__", "16");
  ]

(* The macros of a GCC 14 dump for x86-64 that the model reads, with a
   few it ignores: a function-like macro and one without a value. *)
let lp64_macros =
  gcc_optional_float_macros
  @ [
    ("__GNUC__", "14");
    ("__x86_64__", "1");
    ("__CHAR_BIT__", "8");
    ("__SIZEOF_SHORT__", "2");
    ("__SIZEOF_INT__", "4");
    ("__SIZEOF_LONG__", "8");
    ("__SIZEOF_LONG_LONG__", "8");
    ("__SIZEOF_POINTER__", "8");
    ("__SIZEOF_FLOAT__", "4");
    ("__SIZEOF_DOUBLE__", "8");
    ("__SIZEOF_LONG_DOUBLE__", "16");
    ("__SIZEOF_INT128__", "16");
    ("__SIZE_TYPE__", "long unsigned int");
    ("__PTRDIFF_TYPE__", "long int");
    ("__WCHAR_TYPE__", "int");
    ("__INTMAX_TYPE__", "long int");
    ("__UINTMAX_TYPE__", "long unsigned int");
    ("__INTPTR_TYPE__", "long int");
    ("__UINT16_TYPE__", "short unsigned int");
    ("__UINT32_TYPE__", "unsigned int");
    ("__UINT64_TYPE__", "long unsigned int");
    ("__CHAR16_TYPE__", "short unsigned int");
    ("__CHAR32_TYPE__", "unsigned int");
    ("__ORDER_LITTLE_ENDIAN__", "1234");
    ("__BYTE_ORDER__", "__ORDER_LITTLE_ENDIAN__");
    ("__STDC_VERSION__", "201112L");
    ("__has_include(STR)", "__has_include__(STR)");
    ("__GCC_ASM_FLAG_OUTPUTS__", "");
  ]

(* An ILP32 target with unsigned char, no __int128 and big-endian bytes,
   as for 32-bit ARM, with Clang 21's spellings of the types. *)
let ilp32_macros =
  [
    ("__clang__", "1");
    ("__clang_major__", "21");
    ("__GNUC__", "4");
    ("__arm__", "1");
    ("__CHAR_BIT__", "8");
    ("__CHAR_UNSIGNED__", "1");
    ("__SIZEOF_SHORT__", "2");
    ("__SIZEOF_INT__", "4");
    ("__SIZEOF_LONG__", "4");
    ("__SIZEOF_LONG_LONG__", "8");
    ("__SIZEOF_POINTER__", "4");
    ("__SIZEOF_FLOAT__", "4");
    ("__SIZEOF_DOUBLE__", "8");
    ("__SIZEOF_LONG_DOUBLE__", "8");
    ("__SIZE_TYPE__", "unsigned int");
    ("__PTRDIFF_TYPE__", "int");
    ("__WCHAR_TYPE__", "unsigned int");
    ("__INTMAX_TYPE__", "long long int");
    ("__UINTMAX_TYPE__", "long long unsigned int");
    ("__INTPTR_TYPE__", "int");
    ("__UINT16_TYPE__", "unsigned short");
    ("__UINT32_TYPE__", "unsigned int");
    ("__UINT64_TYPE__", "long long unsigned int");
    ("__CHAR16_TYPE__", "unsigned short");
    ("__CHAR32_TYPE__", "unsigned int");
    ("__BYTE_ORDER__", "__ORDER_BIG_ENDIAN__");
    ("__STDC_VERSION__", "201710L");
  ]

(* The LP64 target with the architecture macro of AArch64 for that of
   x86-64, which is all that a test of the architecture needs. *)
let aarch64_macros =
  ("__aarch64__", "1") :: List.remove_assoc "__x86_64__" lp64_macros

let dump_of macros =
  String.concat ""
    (List.map (fun (name, value) -> "#define " ^ name ^ " " ^ value ^ "\n")
       macros)

(* The model of a canned dump, which must be valid, with the int-sized
   enumerations of the default of every host. *)
let target macros =
  match
    Typec_sema.Target.of_predefined_macros ~enum_representation:Int_sized
      (dump_of macros)
  with
  | Ok target -> target
  | Error error -> failwith (Typec_sema.Target.error_message error)

let names_backend (name, _) =
  List.mem name [ "__clang__"; "__clang_major__"; "__GNUC__" ]

let without_backend macros =
  List.filter (fun macro -> not (names_backend macro)) macros

(* [macros] as Clang 21 or GCC 14 would print them, for the typing that
   depends on the backend (Backend_difference). *)
let as_clang macros =
  ("__clang__", "1") :: ("__clang_major__", "21") :: ("__GNUC__", "4")
  :: without_backend macros

let as_gcc macros = ("__GNUC__", "14") :: without_backend macros
