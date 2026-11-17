(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_sema
open Typec_test_support
module Target_query = Typec_driver.Target_query

let lp64 : Target.t =
  {
    backend = { compiler = Gcc; major_version = 14 };
    architecture = X86;
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
    sizeof_int128 = Some 16;
    optional_floats = Typec_syntax.Optional_float.all;
    size_type = Unsigned_long;
    ptrdiff_type = Long;
    wchar_type = Int;
    intmax_type = Long;
    uintmax_type = Unsigned_long;
    intptr_type = Long;
    uint16_type = Unsigned_short;
    uint32_type = Unsigned_int;
    uint64_type = Unsigned_long;
    char16_type = Unsigned_short;
    char32_type = Unsigned_int;
    byte_order = Little_endian;
    stdc_version = 201112;
    enum_representation = Int_sized;
  }

let ilp32 : Target.t =
  {
    backend = { compiler = Clang; major_version = 21 };
    architecture = Arm;
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
    sizeof_int128 = None;
    optional_floats = [];
    size_type = Unsigned_int;
    ptrdiff_type = Int;
    wchar_type = Unsigned_int;
    intmax_type = Long_long;
    uintmax_type = Unsigned_long_long;
    intptr_type = Int;
    uint16_type = Unsigned_short;
    uint32_type = Unsigned_int;
    uint64_type = Unsigned_long_long;
    char16_type = Unsigned_short;
    char32_type = Unsigned_int;
    byte_order = Big_endian;
    stdc_version = 201710;
    enum_representation = Int_sized;
  }

let dump_of = Canned_targets.dump_of
let lp64_dump = dump_of Canned_targets.lp64_macros

let without name =
  List.filter (fun (other, _) -> other <> name) Canned_targets.lp64_macros

(* The LP64 dump with one macro defined as [value]. *)
let lp64_dump_with name value = dump_of (without name @ [ (name, value) ])

(* The LP64 dump as a Clang of [major] would print it. *)
let lp64_clang_dump major =
  dump_of
    (without "__GNUC__"
    @ [ ("__clang__", "1"); ("__clang_major__", major); ("__GNUC__", "4") ])

(* The LP64 dump with these macros of the optional floating types in
   place of GCC's. *)
let lp64_dump_with_floats macros =
  let is_gcc_float (name, _) =
    List.mem_assoc name Canned_targets.gcc_optional_float_macros
  in
  dump_of
    (List.filter (fun macro -> not (is_gcc_float macro))
       Canned_targets.lp64_macros
    @ macros)

let unsupported_backend compiler major_version =
  Error (Target.Unsupported_backend { compiler; major_version })

let malformed name value = Error (Target.Malformed_macro { name; value })
let unsupported guarantee = Error (Target.Unsupported_model guarantee)

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
      dump = dump_of Canned_targets.ilp32_macros;
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
    {
      name = "GCC 16";
      dump = lp64_dump_with "__GNUC__" "16";
      expected =
        Ok { lp64 with backend = { compiler = Gcc; major_version = 16 } };
    };
    {
      name = "Clang that does not claim to be GCC";
      dump =
        dump_of
          (without "__GNUC__"
          @ [ ("__clang__", "1"); ("__clang_major__", "21") ]);
      expected =
        Ok { lp64 with backend = { compiler = Clang; major_version = 21 } };
    };
    {
      name = "Clang 22";
      dump = lp64_clang_dump "22";
      expected =
        Ok { lp64 with backend = { compiler = Clang; major_version = 22 } };
    };
    {
      name = "AArch64";
      dump = dump_of Canned_targets.aarch64_macros;
      expected = Ok { lp64 with architecture = Aarch64 };
    };
    {
      name = "arm64ec, which also defines __x86_64__, is AArch64";
      dump = dump_of (("__arm64ec__", "1") :: Canned_targets.lp64_macros);
      expected = Ok { lp64 with architecture = Aarch64 };
    };
    {
      name = "i386 is x86";
      dump = dump_of (("__i386__", "1") :: without "__x86_64__");
      expected = Ok lp64;
    };
    {
      name = "an architecture that typec does not tell apart";
      dump = dump_of (("__riscv", "1") :: without "__x86_64__");
      expected = Ok { lp64 with architecture = Other };
    };
    {
      name = "uint32_t of unsigned long, as on arm-none-eabi";
      dump =
        dump_of
          (("__UINT32_TYPE__", "long unsigned int")
          :: List.remove_assoc "__UINT32_TYPE__" Canned_targets.ilp32_macros);
      expected = Ok { ilp32 with uint32_type = Unsigned_long };
    };
  ]

(* The optional floating types follow their macros alone, as Clang 20 on
   x86-64 Linux, Apple clang 21 and GCC 14 define them. *)
let optional_float_cases =
  [
    {
      name = "Clang on x86-64 Linux: _Float16 and __float128";
      dump =
        lp64_dump_with_floats
          [
            ("__FLOAT128__", "1");
            ("__FLT16_MANT_DIG__", "11");
            ("__SIZEOF_FLOAT128__", "16");
          ];
      expected = Ok { lp64 with optional_floats = [ Float16; Gnu_float128 ] };
    };
    {
      name = "Apple clang: _Float16 alone";
      dump = lp64_dump_with_floats [ ("__FLT16_MANT_DIG__", "11") ];
      expected = Ok { lp64 with optional_floats = [ Float16 ] };
    };
    {
      name = "no optional floating type";
      dump = lp64_dump_with_floats [];
      expected = Ok { lp64 with optional_floats = [] };
    };
    {
      name = "the order of Optional_float.all";
      dump =
        lp64_dump_with_floats
          (List.rev Canned_targets.gcc_optional_float_macros);
      expected = Ok lp64;
    };
  ]

let error_cases =
  [
    {
      name = "Clang 20";
      dump = lp64_clang_dump "20";
      expected = unsupported_backend Clang 20;
    };
    {
      name = "GCC 13";
      dump = lp64_dump_with "__GNUC__" "13";
      expected = unsupported_backend Gcc 13;
    };
    {
      name = "an unsupported backend before a missing macro";
      dump =
        dump_of
          (("__GNUC__", "13")
          :: List.filter
               (fun (name, _) -> name <> "__GNUC__" && name <> "__SIZEOF_INT__")
               Canned_targets.lp64_macros);
      expected = unsupported_backend Gcc 13;
    };
    {
      name = "neither Clang nor GCC";
      dump = dump_of (without "__GNUC__");
      expected = Error (Target.Missing_macro "__GNUC__");
    };
    {
      name = "Clang without its version";
      dump = dump_of (("__clang__", "1") :: Canned_targets.lp64_macros);
      expected = Error (Target.Missing_macro "__clang_major__");
    };
    {
      name = "a version that is not a number";
      dump = lp64_dump_with "__GNUC__" "14.2";
      expected = malformed "__GNUC__" "14.2";
    };
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
      name = "CHAR_BIT below 8";
      dump = lp64_dump_with "__CHAR_BIT__" "7";
      expected = unsupported "an integer type narrower than C allows";
    };
    {
      name = "long narrower than int";
      dump = lp64_dump_with "__SIZEOF_LONG__" "2";
      expected = unsupported "an integer type narrower than C allows";
    };
    {
      name = "int wider than long";
      dump = lp64_dump_with "__SIZEOF_INT__" "16";
      expected = unsupported "an integer type narrower than one of lower rank";
    };
    {
      name = "long long of 256 bits";
      dump = lp64_dump_with "__SIZEOF_LONG_LONG__" "32";
      expected = unsupported "an integer type wider than 128 bits";
    };
    {
      name = "__int128 of 256 bits";
      dump = lp64_dump_with "__SIZEOF_INT128__" "32";
      expected = unsupported "an integer type wider than 128 bits";
    };
    {
      name = "signed size_t";
      dump = lp64_dump_with "__SIZE_TYPE__" "long int";
      expected = unsupported "a typedef of the wrong signedness";
    };
    {
      name = "32-bit uint64_t";
      dump = lp64_dump_with "__UINT64_TYPE__" "unsigned int";
      expected = unsupported "a uint64_t that is not 64 bits wide";
    };
    {
      name = "32-bit uint16_t";
      dump = lp64_dump_with "__UINT16_TYPE__" "unsigned int";
      expected = unsupported "a uint16_t that is not 16 bits wide";
    };
    {
      name = "signed uint32_t";
      dump = lp64_dump_with "__UINT32_TYPE__" "int";
      expected = unsupported "a typedef of the wrong signedness";
    };
    {
      name = "64-bit char32_t";
      dump = lp64_dump_with "__CHAR32_TYPE__" "long unsigned int";
      expected = unsupported "a character type wider than 32 bits";
    };
    {
      name = "64-bit wchar_t";
      dump = lp64_dump_with "__WCHAR_TYPE__" "long int";
      expected = unsupported "a character type wider than 32 bits";
    };
    {
      name = "huge size";
      dump = lp64_dump_with "__SIZEOF_INT__" "1152921504606846980";
      expected = malformed "__SIZEOF_INT__" "1152921504606846980";
    };
    {
      name = "unsigned ptrdiff_t";
      dump = lp64_dump_with "__PTRDIFF_TYPE__" "long unsigned int";
      expected = unsupported "a typedef of the wrong signedness";
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
  let outcome =
    Target.of_predefined_macros ~enum_representation:Int_sized case.dump
  in
  if outcome = case.expected then true
  else (
    Printf.eprintf "FAIL: %s\n" case.name;
    false)

(* An integer type and its width on a target. *)
let widths =
  [
    ("char on LP64", lp64, Integer.Unsigned_char, 8);
    ("_Bool on LP64", lp64, Integer.Bool, 1);
    ("size_t on LP64", lp64, lp64.size_type, 64);
    ("size_t on ILP32", ilp32, ilp32.size_type, 32);
    ("intmax_t on ILP32", ilp32, ilp32.intmax_type, 64);
    ("__int128 on LP64", lp64, Integer.Int128, 128);
  ]

let check_width (name, target, integer, expected) =
  if Target.integer_width target integer = expected then true
  else (
    Printf.eprintf "FAIL: %s\n" name;
    false)

let without_int128 () =
  match Target.integer_width ilp32 Integer.Unsigned_int128 with
  | _ ->
      prerr_endline "FAIL: unsigned __int128 has a width on ILP32";
      false
  | exception Invalid_argument _ -> true

let check_signed (name, target, integer, expected) =
  if Target.is_signed target integer = expected then true
  else (
    Printf.eprintf "FAIL: signedness of %s\n" name;
    false)

let signedness =
  [
    ("char on LP64", lp64, Integer.Char, true);
    ("char on ILP32", ilp32, Integer.Char, false);
    ("signed char on ILP32", ilp32, Integer.Signed_char, true);
    ("_Bool", lp64, Integer.Bool, false);
    ("__int128", lp64, Integer.Int128, true);
  ]

(* What a probe of the fake backend does: a shell command. *)
let compiles = "exit 0"
let fails = "exit 1"
let killed = "kill -KILL $$"

type query_case = {
  query_name : string;
  query_dump : string;
  short_probe : string;
  int_sized_probe : string;
  options : string list;
  answer : (Target.enum_representation, Target_query.error) result;
}

let write_file path text =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel text)

(* A backend that prints the case's dump for -dM and runs the command of
   the probe whose text it reads on stdin, told apart by its size; the
   paths of the dump and of the backend. *)
let fake_backend case =
  let dump = Filename.temp_file "dump" ".txt" in
  write_file dump case.query_dump;
  let backend = Filename.temp_file "backend" ".sh" in
  write_file backend
    (String.concat "\n"
       [
         "#!/bin/sh";
         "for argument in \"$@\"; do";
         "  if [ \"$argument\" = -dM ]; then exec cat " ^ Filename.quote dump
         ^ "; fi";
         "done";
         "case \"$(cat)\" in";
         "*'== 1 ?'*) " ^ case.short_probe ^ " ;;";
         "*'== sizeof(int) ?'*) " ^ case.int_sized_probe ^ " ;;";
         "esac";
         "exit 2";
         "";
       ]);
  Unix.chmod backend 0o755;
  (dump, backend)

let query_cases =
  let int_sized_alone =
    {
      query_name = "the int-sized probe alone compiles";
      query_dump = lp64_dump;
      short_probe = fails;
      int_sized_probe = compiles;
      options = [];
      answer = Ok Target.Int_sized;
    }
  in
  [
    int_sized_alone;
    {
      int_sized_alone with
      query_name = "the short probe alone compiles";
      short_probe = compiles;
      int_sized_probe = fails;
      answer = Ok Target.Short;
    };
    {
      int_sized_alone with
      query_name = "the model does not read __ARM_SIZEOF_MINIMAL_ENUM";
      query_dump = lp64_dump_with "__ARM_SIZEOF_MINIMAL_ENUM" "1";
    };
    {
      int_sized_alone with
      query_name = "neither probe compiles";
      short_probe = fails;
      int_sized_probe = fails;
      options = [ "-fshort-enums" ];
      answer =
        Error (Target_query.Neither_enumeration_probe [ "-fshort-enums" ]);
    };
    {
      int_sized_alone with
      query_name = "both probes compile";
      short_probe = compiles;
      int_sized_probe = compiles;
      answer = Error (Target_query.Both_enumeration_probes []);
    };
    {
      int_sized_alone with
      query_name = "a signal ends a probe";
      short_probe = killed;
      answer = Error (Target_query.Probe_ended_by_signal []);
    };
  ]

let check_query case =
  let dump, backend = fake_backend case in
  let outcome =
    Fun.protect
      ~finally:(fun () -> List.iter Sys.remove [ dump; backend ])
      (fun () -> Target_query.query ~program:backend case.options)
    |> Result.map (fun (target : Target.t) -> target.enum_representation)
  in
  if outcome = case.answer then true
  else (
    Printf.eprintf "FAIL: %s\n" case.query_name;
    false)

let () =
  let results =
    List.map check_case (model_cases @ optional_float_cases @ error_cases)
    @ List.map check_width widths
    @ List.map check_signed signedness
    @ [ without_int128 () ]
    @ List.map check_query query_cases
  in
  if List.mem false results then exit 1
