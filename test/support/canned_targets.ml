(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Predefined macro dumps of two targets, shared by the unit tests and
   the fuzz harness. *)

(* The macros of a GCC 14 dump for an LP64 target that the model reads,
   with a few it ignores: a function-like macro and one without a
   value. *)
let lp64_macros =
  [
    ("__GNUC__", "14");
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
    ("__CHAR16_TYPE__", "short unsigned int");
    ("__CHAR32_TYPE__", "unsigned int");
    ("__ORDER_LITTLE_ENDIAN__", "1234");
    ("__BYTE_ORDER__", "__ORDER_LITTLE_ENDIAN__");
    ("__STDC_VERSION__", "201112L");
    ("__has_include(STR)", "__has_include__(STR)");
    ("__GCC_ASM_FLAG_OUTPUTS__", "");
  ]

(* An ILP32 target with unsigned char, no __int128 and big-endian bytes,
   as for 32-bit ARM, with Clang 20's spellings of the types. *)
let ilp32_macros =
  [
    ("__clang__", "1");
    ("__clang_major__", "20");
    ("__GNUC__", "4");
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
    ("__CHAR16_TYPE__", "unsigned short");
    ("__CHAR32_TYPE__", "unsigned int");
    ("__BYTE_ORDER__", "__ORDER_BIG_ENDIAN__");
    ("__STDC_VERSION__", "201710L");
  ]

let dump_of macros =
  String.concat ""
    (List.map (fun (name, value) -> "#define " ^ name ^ " " ^ value ^ "\n")
       macros)

(* The model of a canned dump, which must be valid. *)
let target macros =
  match Typec_sema.Target.of_predefined_macros (dump_of macros) with
  | Ok target -> target
  | Error error -> failwith (Typec_sema.Target.error_message error)
