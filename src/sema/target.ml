(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type byte_order = Little_endian | Big_endian
type compiler = Gcc | Clang
type backend = { compiler : compiler; major_version : int }

type t = {
  backend : backend;
  char_bit : int;
  char_signed : bool;
  sizeof_short : int;
  sizeof_int : int;
  sizeof_long : int;
  sizeof_long_long : int;
  sizeof_pointer : int;
  sizeof_float : int;
  sizeof_double : int;
  sizeof_long_double : int;
  sizeof_int128 : int option;
  optional_floats : Typec_syntax.Optional_float.t list;
  size_type : Integer.t;
  ptrdiff_type : Integer.t;
  wchar_type : Integer.t;
  intmax_type : Integer.t;
  uintmax_type : Integer.t;
  intptr_type : Integer.t;
  char16_type : Integer.t;
  char32_type : Integer.t;
  byte_order : byte_order;
  stdc_version : int;
}

type error =
  | Malformed_line of string
  | Duplicate_macro of string
  | Missing_macro of string
  | Malformed_macro of { name : string; value : string }
  | Unsupported_model of string
  | Unsupported_backend of backend

(* The reasons for each release are in the interface. *)
let minimum_major_version = function
  | Clang -> 20
  | Gcc -> 14

(* The widest integer type of a model, which bounds the work of constant
   evaluation. *)
let max_integer_width = 128
let max_character_width = 32

(* Raised at the first defect of a dump and caught in of_predefined_macros. *)
exception Invalid of error

module Macros = Map.Make (String)

let define_prefix = "#define "

let suffix_from text start =
  String.sub text start (String.length text - start)

(* The name ends at the first space, so a function-like macro gives a
   name with part of its parameter list; no macro the model reads is
   function-like, and the part still tells macros apart. *)
let name_and_value line =
  if not (String.starts_with ~prefix:define_prefix line) then
    raise (Invalid (Malformed_line line));
  let definition = suffix_from line (String.length define_prefix) in
  let name, value =
    match String.index_opt definition ' ' with
    | Some space ->
        (String.sub definition 0 space, suffix_from definition (space + 1))
    | None -> (definition, "")
  in
  if name = "" then raise (Invalid (Malformed_line line));
  (name, value)

let add_line macros line =
  if line = "" then macros
  else
    let name, value = name_and_value line in
    if Macros.mem name macros then raise (Invalid (Duplicate_macro name));
    Macros.add name value macros

let macros_of_dump dump =
  List.fold_left add_line Macros.empty (String.split_on_char '\n' dump)

let find macros name =
  match Macros.find_opt name macros with
  | Some value -> value
  | None -> raise (Invalid (Missing_macro name))

let malformed name value = raise (Invalid (Malformed_macro { name; value }))

let is_digit c = '0' <= c && c <= '9'

(* Only plain decimal digits: int_of_string alone would also take a sign,
   a base prefix and underscores. It returns None on overflow. *)
let decimal text =
  if text <> "" && String.for_all is_digit text then int_of_string_opt text
  else None

(* A size or a width: a positive decimal number. *)
(* Far above the size of any type, it keeps a width in bits, a size times
   CHAR_BIT, from overflowing. *)
let max_count = 1 lsl 16

let count_of_value name value =
  match decimal value with
  | Some count when count > 0 && count <= max_count -> count
  | Some _ | None -> malformed name value

let read_count macros name = count_of_value name (find macros name)

(* A size the target defines only when it has the type. *)
let read_optional_count macros name =
  Option.map (count_of_value name) (Macros.find_opt name macros)

(* The macro that GCC and Clang define exactly where they have the type,
   as each backend of a test host does (design 13.3). *)
let optional_float_macro : Typec_syntax.Optional_float.t -> string =
  function
  | Float16 -> "__FLT16_MANT_DIG__"
  | Float32 -> "__FLT32_MANT_DIG__"
  | Float64 -> "__FLT64_MANT_DIG__"
  | Float128 -> "__FLT128_MANT_DIG__"
  | Float32x -> "__FLT32X_MANT_DIG__"
  | Float64x -> "__FLT64X_MANT_DIG__"
  | Gnu_float128 -> "__SIZEOF_FLOAT128__"

let read_optional_floats macros =
  List.filter
    (fun optional -> Macros.mem (optional_float_macro optional) macros)
    Typec_syntax.Optional_float.all

(* A type is spelled as type specifiers (C11 6.7.2p2), such as
   [long unsigned int], in any order. *)
let specifier_of_word :
    string -> Typec_syntax.Tree.basic_type_specifier option = function
  | "char" -> Some Char
  | "short" -> Some Short
  | "int" -> Some Int
  | "long" -> Some Long
  | "signed" -> Some Signed
  | "unsigned" -> Some Unsigned
  | _ -> None

let integer_type_of_words words =
  let specifiers = List.filter_map specifier_of_word words in
  if List.length specifiers <> List.length words then None
  else Integer.of_specifiers specifiers

let read_integer_type macros name =
  let value = find macros name in
  let words = List.filter (( <> ) "") (String.split_on_char ' ' value) in
  match integer_type_of_words words with
  | Some integer_type -> integer_type
  | None -> malformed name value

(* The value names one of the __ORDER_*__ macros. A PDP-endian target is
   not supported. *)
let read_byte_order macros =
  let name = "__BYTE_ORDER__" in
  match find macros name with
  | "__ORDER_LITTLE_ENDIAN__" -> Little_endian
  | "__ORDER_BIG_ENDIAN__" -> Big_endian
  | value -> malformed name value

(* The version is a long constant such as 201710L. *)
let read_stdc_version macros =
  let name = "__STDC_VERSION__" in
  let value = find macros name in
  let digits =
    if String.ends_with ~suffix:"L" value then
      String.sub value 0 (String.length value - 1)
    else ""
  in
  match decimal digits with
  | Some version -> version
  | None -> malformed name value

let read_major_version macros name =
  let value = find macros name in
  match decimal value with
  | Some version -> version
  | None -> malformed name value

let read_backend macros =
  if Macros.mem "__clang__" macros then
    let major_version = read_major_version macros "__clang_major__" in
    { compiler = Clang; major_version }
  else
    let major_version = read_major_version macros "__GNUC__" in
    { compiler = Gcc; major_version }

let check_backend backend =
  if backend.major_version < minimum_major_version backend.compiler then
    raise (Invalid (Unsupported_backend backend))

let model_of_macros macros backend =
  let count = read_count macros in
  let integer_type = read_integer_type macros in
  {
    backend;
    char_bit = count "__CHAR_BIT__";
    char_signed = not (Macros.mem "__CHAR_UNSIGNED__" macros);
    sizeof_short = count "__SIZEOF_SHORT__";
    sizeof_int = count "__SIZEOF_INT__";
    sizeof_long = count "__SIZEOF_LONG__";
    sizeof_long_long = count "__SIZEOF_LONG_LONG__";
    sizeof_pointer = count "__SIZEOF_POINTER__";
    sizeof_float = count "__SIZEOF_FLOAT__";
    sizeof_double = count "__SIZEOF_DOUBLE__";
    sizeof_long_double = count "__SIZEOF_LONG_DOUBLE__";
    sizeof_int128 = read_optional_count macros "__SIZEOF_INT128__";
    optional_floats = read_optional_floats macros;
    size_type = integer_type "__SIZE_TYPE__";
    ptrdiff_type = integer_type "__PTRDIFF_TYPE__";
    wchar_type = integer_type "__WCHAR_TYPE__";
    intmax_type = integer_type "__INTMAX_TYPE__";
    uintmax_type = integer_type "__UINTMAX_TYPE__";
    intptr_type = integer_type "__INTPTR_TYPE__";
    char16_type = integer_type "__CHAR16_TYPE__";
    char32_type = integer_type "__CHAR32_TYPE__";
    byte_order = read_byte_order macros;
    stdc_version = read_stdc_version macros;
  }


let keywords target dialect : Typec_syntax.Keyword_set.t =
  { dialect; optional_floats = target.optional_floats }

(* GCC and Clang give no integer type padding bits, so a width is the
   size in bits. *)
let integer_width target (integer : Integer.t) =
  let bits size = size * target.char_bit in
  match integer with
  | Bool -> 1
  | Char | Signed_char | Unsigned_char -> target.char_bit
  | Short | Unsigned_short -> bits target.sizeof_short
  | Int | Unsigned_int -> bits target.sizeof_int
  | Long | Unsigned_long -> bits target.sizeof_long
  | Long_long | Unsigned_long_long -> bits target.sizeof_long_long
  | Int128 | Unsigned_int128 -> (
      match target.sizeof_int128 with
      | Some size -> bits size
      | None -> invalid_arg "Target.integer_width: no __int128")

let is_signed target (integer : Integer.t) =
  match integer with
  | Char -> target.char_signed
  | Signed_char | Short | Int | Long | Long_long | Int128 -> true
  | Bool | Unsigned_char | Unsigned_short | Unsigned_int | Unsigned_long
  | Unsigned_long_long | Unsigned_int128 ->
      false

let unsupported guarantee = raise (Invalid (Unsupported_model guarantee))

(* The widths of the standard integer types: CHAR_BIT and the minimum
   magnitudes of 5.2.4.2.1, the order of 6.2.5p8, and at most
   [max_integer_width] bits. *)
let check_widths model =
  let bits size = size * model.char_bit in
  let widths =
    [ model.char_bit; bits model.sizeof_short; bits model.sizeof_int;
      bits model.sizeof_long; bits model.sizeof_long_long ]
  in
  let minimums = [ 8; 16; 16; 32; 64 ] in
  if List.exists2 ( < ) widths minimums then
    unsupported "an integer type narrower than C allows";
  if List.sort compare widths <> widths then
    unsupported "an integer type narrower than one of lower rank";
  let widest = bits (Option.value model.sizeof_int128 ~default:0) in
  if List.exists (fun width -> width > max_integer_width) (widest :: widths)
  then unsupported "an integer type wider than 128 bits"

(* The signedness of the typedefs (7.19, 7.20.1.4, 7.20.1.5, 7.28). *)
let check_typedefs model =
  let signed integer = is_signed model integer in
  let unsigned_types =
    [ model.size_type; model.uintmax_type; model.char16_type;
      model.char32_type ]
  in
  let signed_types =
    [ model.ptrdiff_type; model.intmax_type; model.intptr_type ]
  in
  let wrong =
    List.exists signed unsigned_types
    || not (List.for_all signed signed_types)
  in
  if wrong then unsupported "a typedef of the wrong signedness";
  (* A code unit is an OCaml int when constants are evaluated. *)
  let character_types =
    [ model.wchar_type; model.char16_type; model.char32_type ]
  in
  let too_wide integer = integer_width model integer > max_character_width in
  if List.exists too_wide character_types then
    unsupported "a character type wider than 32 bits"

(* The backend is checked first, so that an unsupported one is reported
   as such rather than by a macro of the model that it lacks. *)
let checked_model dump =
  let macros = macros_of_dump dump in
  let backend = read_backend macros in
  check_backend backend;
  let model = model_of_macros macros backend in
  check_widths model;
  check_typedefs model;
  model

let of_predefined_macros dump =
  match checked_model dump with
  | model -> Ok model
  | exception Invalid error -> Error error

let optional_count_name = function
  | Some count -> string_of_int count
  | None -> "none"

let optional_floats_name = function
  | [] -> "none"
  | optional_floats ->
      String.concat " "
        (List.map Typec_syntax.Optional_float.spelling optional_floats)

let byte_order_name = function
  | Little_endian -> "little-endian"
  | Big_endian -> "big-endian"

let compiler_name = function
  | Gcc -> "GCC"
  | Clang -> "Clang"

let backend_name { compiler; major_version } =
  Printf.sprintf "%s %d" (compiler_name compiler) major_version

let to_string target =
  let fields =
    [
      ("backend", backend_name target.backend);
      ("char_bit", string_of_int target.char_bit);
      ("char_signed", string_of_bool target.char_signed);
      ("sizeof_short", string_of_int target.sizeof_short);
      ("sizeof_int", string_of_int target.sizeof_int);
      ("sizeof_long", string_of_int target.sizeof_long);
      ("sizeof_long_long", string_of_int target.sizeof_long_long);
      ("sizeof_pointer", string_of_int target.sizeof_pointer);
      ("sizeof_float", string_of_int target.sizeof_float);
      ("sizeof_double", string_of_int target.sizeof_double);
      ("sizeof_long_double", string_of_int target.sizeof_long_double);
      ("sizeof_int128", optional_count_name target.sizeof_int128);
      ("optional_floats", optional_floats_name target.optional_floats);
      ("size_type", Integer.name target.size_type);
      ("ptrdiff_type", Integer.name target.ptrdiff_type);
      ("wchar_type", Integer.name target.wchar_type);
      ("intmax_type", Integer.name target.intmax_type);
      ("uintmax_type", Integer.name target.uintmax_type);
      ("intptr_type", Integer.name target.intptr_type);
      ("char16_type", Integer.name target.char16_type);
      ("char32_type", Integer.name target.char32_type);
      ("byte_order", byte_order_name target.byte_order);
      ("stdc_version", string_of_int target.stdc_version);
    ]
  in
  String.concat ""
    (List.map (fun (field, value) -> field ^ ": " ^ value ^ "\n") fields)

let supported_backends =
  let oldest compiler =
    let major_version = minimum_major_version compiler in
    backend_name { compiler; major_version } ^ " or later"
  in
  oldest Clang ^ " and " ^ oldest Gcc

(* Values come from the backend, so %S escapes any control character. *)
let error_message = function
  | Malformed_line line ->
      Printf.sprintf "unexpected line %S among the predefined macros" line
  | Duplicate_macro name ->
      Printf.sprintf "the C compiler defines %S twice" name
  | Missing_macro name ->
      Printf.sprintf "the C compiler does not define %s" name
  | Unsupported_model guarantee ->
      "the predefined macros describe " ^ guarantee
  | Malformed_macro { name; value } ->
      Printf.sprintf "the C compiler defines %s as %S, which typec cannot read"
        name value
  | Unsupported_backend backend ->
      Printf.sprintf "the C compiler is %s; typec supports %s"
        (backend_name backend) supported_backends
