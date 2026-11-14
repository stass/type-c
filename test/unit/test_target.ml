(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_sema

(* The macros of a GCC dump for an LP64 target that the model reads, with
   a few it ignores: a function-like macro and one without a value. *)
let lp64_macros =
  [
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

let lp64 : Target.t =
  {
    char_bit = 8;
    char_signed = true;
    sizeof_short = 2;
    sizeof_int = 4;
    sizeof_long = 8;
    sizeof_long_long = 8;
    sizeof_pointer = 8;
    sizeof_float = 4;
    sizeof_double = 8;
    sizeof_long_double = 16;
    has_int128 = true;
    size_type = Unsigned_long;
    ptrdiff_type = Long;
    wchar_type = Int;
    intmax_type = Long;
    uintmax_type = Unsigned_long;
    intptr_type = Long;
    char16_type = Unsigned_short;
    char32_type = Unsigned_int;
    byte_order = Little_endian;
    stdc_version = 201112;
  }

(* An ILP32 target with unsigned char, no __int128 and big-endian bytes,
   as for 32-bit ARM, with Clang's spellings of the types. *)
let ilp32_macros =
  [
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

let ilp32 : Target.t =
  {
    char_bit = 8;
    char_signed = false;
    sizeof_short = 2;
    sizeof_int = 4;
    sizeof_long = 4;
    sizeof_long_long = 8;
    sizeof_pointer = 4;
    sizeof_float = 4;
    sizeof_double = 8;
    sizeof_long_double = 8;
    has_int128 = false;
    size_type = Unsigned_int;
    ptrdiff_type = Int;
    wchar_type = Unsigned_int;
    intmax_type = Long_long;
    uintmax_type = Unsigned_long_long;
    intptr_type = Int;
    char16_type = Unsigned_short;
    char32_type = Unsigned_int;
    byte_order = Big_endian;
    stdc_version = 201710;
  }

let dump_of macros =
  String.concat ""
    (List.map (fun (name, value) -> "#define " ^ name ^ " " ^ value ^ "\n")
       macros)

let lp64_dump = dump_of lp64_macros
let without name = List.filter (fun (other, _) -> other <> name) lp64_macros

(* The LP64 dump with one macro defined as [value]. *)
let lp64_dump_with name value = dump_of (without name @ [ (name, value) ])

let malformed name value = Error (Target.Malformed_macro { name; value })

(* A dump and the model or the error it must yield. *)
type case = {
  name : string;
  dump : string;
  expected : (Target.t, Target.error) result;
}

let model_cases =
  [
    { name = "LP64"; dump = lp64_dump; expected = Ok lp64 };
    {
      name = "ILP32, unsigned char";
      dump = dump_of ilp32_macros;
      expected = Ok ilp32;
    };
    {
      name = "no final newline, empty lines";
      dump = "\n" ^ String.sub lp64_dump 0 (String.length lp64_dump - 1);
      expected = Ok lp64;
    };
    {
      name = "type specifiers in any order and spacing";
      dump = lp64_dump_with "__SIZE_TYPE__" " int  long unsigned ";
      expected = Ok lp64;
    };
    {
      name = "signed long is long";
      dump = lp64_dump_with "__PTRDIFF_TYPE__" "signed long";
      expected = Ok lp64;
    };
  ]

let error_cases =
  [
    {
      name = "missing size";
      dump = dump_of (without "__SIZEOF_INT__");
      expected = Error (Target.Missing_macro "__SIZEOF_INT__");
    };
    {
      name = "missing type";
      dump = dump_of (without "__WCHAR_TYPE__");
      expected = Error (Target.Missing_macro "__WCHAR_TYPE__");
    };
    {
      name = "missing version";
      dump = dump_of (without "__STDC_VERSION__");
      expected = Error (Target.Missing_macro "__STDC_VERSION__");
    };
    {
      name = "size with a suffix";
      dump = lp64_dump_with "__SIZEOF_INT__" "4L";
      expected = malformed "__SIZEOF_INT__" "4L";
    };
    {
      name = "size in hexadecimal";
      dump = lp64_dump_with "__SIZEOF_INT__" "0x4";
      expected = malformed "__SIZEOF_INT__" "0x4";
    };
    {
      name = "negative size";
      dump = lp64_dump_with "__SIZEOF_LONG__" "-8";
      expected = malformed "__SIZEOF_LONG__" "-8";
    };
    {
      name = "zero size";
      dump = lp64_dump_with "__SIZEOF_POINTER__" "0";
      expected = malformed "__SIZEOF_POINTER__" "0";
    };
    {
      name = "size that overflows";
      dump = lp64_dump_with "__CHAR_BIT__" "99999999999999999999";
      expected = malformed "__CHAR_BIT__" "99999999999999999999";
    };
    {
      name = "empty size";
      dump = lp64_dump_with "__SIZEOF_SHORT__" "";
      expected = malformed "__SIZEOF_SHORT__" "";
    };
    {
      name = "type that is not an integer type";
      dump = lp64_dump_with "__SIZE_TYPE__" "long double";
      expected = malformed "__SIZE_TYPE__" "long double";
    };
    {
      name = "signed and unsigned";
      dump = lp64_dump_with "__SIZE_TYPE__" "signed unsigned int";
      expected = malformed "__SIZE_TYPE__" "signed unsigned int";
    };
    {
      name = "long long long";
      dump = lp64_dump_with "__INTMAX_TYPE__" "long long long";
      expected = malformed "__INTMAX_TYPE__" "long long long";
    };
    {
      name = "a typedef name";
      dump = lp64_dump_with "__CHAR16_TYPE__" "__uint16_t";
      expected = malformed "__CHAR16_TYPE__" "__uint16_t";
    };
    {
      name = "PDP byte order";
      dump = lp64_dump_with "__BYTE_ORDER__" "__ORDER_PDP_ENDIAN__";
      expected = malformed "__BYTE_ORDER__" "__ORDER_PDP_ENDIAN__";
    };
    {
      name = "version without its suffix";
      dump = lp64_dump_with "__STDC_VERSION__" "201112";
      expected = malformed "__STDC_VERSION__" "201112";
    };
    {
      name = "version that is only a suffix";
      dump = lp64_dump_with "__STDC_VERSION__" "L";
      expected = malformed "__STDC_VERSION__" "L";
    };
    {
      name = "a name defined twice";
      dump = lp64_dump ^ "#define __SIZEOF_INT__ 4\n";
      expected = Error (Target.Duplicate_macro "__SIZEOF_INT__");
    };
    {
      name = "a line that is not a definition";
      dump = lp64_dump ^ "#undef __SIZEOF_INT__\n";
      expected = Error (Target.Malformed_line "#undef __SIZEOF_INT__");
    };
    {
      name = "a definition without a name";
      dump = lp64_dump ^ "#define  1\n";
      expected = Error (Target.Malformed_line "#define  1");
    };
  ]

let check_case case =
  let outcome = Target.of_predefined_macros case.dump in
  if outcome = case.expected then true
  else (
    Printf.eprintf "FAIL: %s\n" case.name;
    false)

(* An integer type and its size on a target. *)
let sizes =
  [
    ("char on LP64", lp64, Target.Unsigned_char, 1);
    ("size_t on LP64", lp64, lp64.size_type, 8);
    ("size_t on ILP32", ilp32, ilp32.size_type, 4);
    ("intmax_t on ILP32", ilp32, ilp32.intmax_type, 8);
  ]

let check_size (name, target, integer_type, expected) =
  if Target.sizeof_integer target integer_type = expected then true
  else (
    Printf.eprintf "FAIL: %s\n" name;
    false)

let () =
  let results =
    List.map check_case (model_cases @ error_cases)
    @ List.map check_size sizes
  in
  if List.mem false results then exit 1
