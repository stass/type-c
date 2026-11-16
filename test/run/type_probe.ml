(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Writes a C file of static assertions about types, as typec computes them
   for the target model read from the macro dump named on the command
   line: the promotions, the usual arithmetic conversions, the integer type
   of enumerations and the compatibility of pairs of types. A backend that
   compiles the file agrees with typec on every one. *)

open Typec_sema

let get = function
  | Ok t -> t
  | Error error -> failwith (Ctype.error_message error)

let name = Type_name.of_ctype

(* An assertion that the expression has the type, which _Generic selects
   by compatibility after lvalue conversion. *)
let assert_type expression t =
  Printf.printf "_Static_assert(_Generic(%s, %s: 1, default: 0), \"%s: %s\");\n"
    expression (name t) expression (name t)

let integers target =
  let open Integer in
  let standard =
    [ Bool; Char; Signed_char; Unsigned_char; Short; Unsigned_short; Int;
      Unsigned_int; Long; Unsigned_long; Long_long; Unsigned_long_long ]
  in
  if Option.is_some target.Target.sizeof_int128 then
    standard @ [ Int128; Unsigned_int128 ]
  else standard

let arithmetic_types target =
  List.map (fun integer -> Arithmetic.Integer integer) (integers target)
  @ List.concat_map
      (fun floating -> [ Arithmetic.Real floating; Complex floating ])
      [ Float; Double; Long_double ]

(* Every type here exists on the target. *)
let arithmetic target a = Result.get_ok (Ctype.arithmetic target a)

let zero target a = Printf.sprintf "(%s)0" (name (arithmetic target a))

let print_conversions target =
  let types = arithmetic_types target in
  let promoted a = Arithmetic.promote target a in
  List.iter
    (fun a ->
      let promoted_a = (promoted a :> Arithmetic.t) in
      assert_type ("+" ^ zero target a) (arithmetic target promoted_a);
      List.iter
        (fun b ->
          let common =
            Arithmetic.usual_arithmetic_conversions target (promoted a)
              (promoted b)
          in
          assert_type
            (zero target a ^ " + " ^ zero target b)
            (arithmetic target common))
        types)
    types

(* GCC and Clang agree on the promotion of a bit-field of a type ranked
   above int only when it is narrower than its type and than int, or full
   width and wider than int; see Arithmetic.promote. *)
let backends_agree target integer bits =
  let int_width = Target.integer_width target Int in
  let width = Target.integer_width target integer in
  Integer.rank integer <= Integer.rank Int
  || (bits < width && bits <= int_width)
  || (bits = width && bits > int_width)

let bit_field_widths target integer =
  let int_width = Target.integer_width target Int in
  let width = Target.integer_width target integer in
  let tested bits =
    bits >= 1 && bits <= width && backends_agree target integer bits
  in
  List.sort_uniq compare
    (List.filter tested [ 1; int_width - 1; int_width; int_width + 1; width ])

let print_bit_fields target =
  let fields =
    List.concat_map
      (fun integer ->
        let widths = bit_field_widths target integer in
        List.map (fun bits -> (integer, bits)) widths)
      (integers target)
  in
  print_string "extern struct bit_fields {\n";
  List.iteri
    (fun index (integer, bits) ->
      Printf.printf "  %s field%d : %d;\n" (Integer.name integer) index bits)
    fields;
  print_string "} bit_fields;\n";
  List.iteri
    (fun index (integer, bit_field_width) ->
      let promoted =
        Arithmetic.promote target ~bit_field_width (Integer integer)
      in
      assert_type
        (Printf.sprintf "+bit_fields.field%d" index)
        (arithmetic target (promoted :> Arithmetic.t)))
    fields

(* The largest value of [bits] bits, in hexadecimal. *)
let all_ones bits =
  let leading = [| ""; "1"; "3"; "7" |].(bits mod 4) in
  if bits = 0 then "0" else "0x" ^ leading ^ String.make (bits / 4) 'f'

(* The enumerator values that need exactly [range]: the largest value of
   that width, and -1 when negative. *)
let enumerator_values { Arithmetic.negative; width } =
  if negative then [ "-1"; all_ones (width - 1) ] else [ all_ones width ]

let enumerator_ranges target =
  let widths =
    List.sort_uniq compare
      (List.map (Target.integer_width target) [ Integer.Int; Long; Long_long ])
  in
  let widest = Target.integer_width target Unsigned_long_long in
  let ranges width =
    List.filter
      (fun { Arithmetic.width; _ } -> width <= widest)
      [ { Arithmetic.negative = false; width }; { negative = true; width };
        { negative = false; width = width + 1 };
        { negative = true; width = width + 1 } ]
  in
  { Arithmetic.negative = true; width = 1 } :: List.concat_map ranges widths

(* Declares each enumeration in C and in tags, and returns the types. *)
let print_enums target tags =
  List.mapi
    (fun index range ->
      let tag_name = Printf.sprintf "e%d" index in
      let tag = Ctype.declare_enum tags (Some tag_name) ~at_file_scope:true in
      let values =
        List.mapi
          (fun value_index value ->
            Printf.sprintf "%s_%d = %s" tag_name value_index value)
          (enumerator_values range)
      in
      Printf.printf "enum %s { %s };\n" tag_name (String.concat ", " values);
      (match Arithmetic.enum_compatible_type target range with
      | Some integer ->
          get (Ctype.define_enum tags tag (Answer integer));
          assert_type
            ("(enum " ^ tag_name ^ ")0")
            (arithmetic target (Integer integer))
      | None -> failwith "no integer type for an enumeration");
      Ctype.enum tag)
    (enumerator_ranges target)

let compatibility_types target tags enums =
  let int_type = arithmetic target (Integer Int) in
  let pointer t = get (Ctype.pointer_to t) in
  let array t length = get (Ctype.array_of tags t length) in
  let returning return parameters =
    get (Ctype.function_returning return parameters)
  in
  let func = returning int_type in
  let prototype types = Ctype.Prototype { types; variadic = false } in
  let const_qualifier = { Qualifiers.none with const = true } in
  let const t = get (Ctype.qualify const_qualifier t) in
  let struct_type name =
    Ctype.record
      (Ctype.declare_record tags Struct (Some name) ~at_file_scope:true)
  in
  print_string "struct a;\nstruct b;\n";
  let integer i = arithmetic target (Integer i) in
  [ int_type; integer Unsigned_int; integer Long; integer Long_long;
    integer Char; integer Signed_char;
    const int_type; array int_type Unknown; array int_type (Constant 3);
    array int_type (Constant 4); array (const int_type) (Constant 3);
    func (prototype []); func Unspecified;
    func (prototype [ integer Char ]);
    func (prototype [ arithmetic target (Real Double) ]);
    func (prototype [ arithmetic target (Real Float) ]);
    func (prototype [ int_type ]);
    func (Prototype { types = [ int_type ]; variadic = true });
    func (prototype [ const int_type; array int_type (Constant 2) ]);
    func (prototype [ int_type; pointer int_type ]);
    returning (const int_type) (prototype []);
    returning (get (Ctype.atomic int_type)) (prototype []);
    pointer Ctype.void; pointer int_type; pointer (const int_type);
    pointer (array int_type Unknown); pointer (array int_type (Constant 3));
    struct_type "a"; struct_type "b" ]
  @ enums

(* The comparisons have no source; an unknown answer would name this. *)
let probe_location =
  { Typec_cpp.Location.file = "type_probe"; line = 1; flags = No_flags }

(* A pair whose compatibility typec leaves to the backend, as GCC types
   some otherwise than Clang, has no assertion. *)
let print_compatibility target tags types =
  let pointer t = name (get (Ctype.pointer_to t)) in
  let print a b = function
    | Unknown.Depends_on _ -> ()
    | Answer compatible ->
        Printf.printf
          "_Static_assert(_Generic((%s)0, %s: 1, default: 0) == %d, \
           \"%s and %s\");\n"
          (pointer a) (pointer b) (Bool.to_int compatible) (name a) (name b)
  in
  List.iter
    (fun a ->
      List.iter
        (fun b -> print a b (Ctype.compatible target tags probe_location a b))
        types)
    types

let read_file path = In_channel.with_open_bin path In_channel.input_all

let () =
  match Sys.argv with
  | [| _; dump |] -> (
      match Target.of_predefined_macros (read_file dump) with
      | Ok target ->
          let tags = Ctype.create_tags () in
          print_conversions target;
          print_bit_fields target;
          let enums = print_enums target tags in
          print_compatibility target tags
            (compatibility_types target tags enums)
      | Error error ->
          prerr_endline (Target.error_message error);
          exit 1)
  | _ ->
      prerr_endline "usage: type_probe MACRO-DUMP";
      exit 2
