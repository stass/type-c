(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_sema
open Typec_test_support

let lp64 = Canned_targets.target Canned_targets.lp64_macros
let lp64_clang = Canned_targets.(target (as_clang lp64_macros))
let ilp32 = Canned_targets.target Canned_targets.ilp32_macros

(* A target whose int is as wide as its short, as on 16-bit machines,
   where uint32_t is unsigned long. *)
let int16 =
  let int16_macros =
    [
      ("__SIZEOF_INT__", "2");
      ("__SIZEOF_LONG__", "4");
      ("__UINT32_TYPE__", "long unsigned int");
      ("__UINT64_TYPE__", "long long unsigned int");
    ]
  in
  let int16_value (name, value) =
    (name, Option.value (List.assoc_opt name int16_macros) ~default:value)
  in
  Canned_targets.target (List.map int16_value Canned_targets.lp64_macros)

let check name actual expected =
  if actual = expected then true
  else (
    Printf.eprintf "FAIL: %s\n" name;
    false)

let get = function
  | Ok t -> t
  | Error error -> failwith (Ctype.error_message error)

let error_of = function Ok _ -> None | Error error -> Some error
let integer i = get (Ctype.integer lp64 i)
let int_type = integer Int
let char_type = integer Char
let unsigned_type = integer Unsigned_int
let long_type = integer Long
let float_type = get (Ctype.arithmetic lp64 (Real Float))
let double_type = get (Ctype.arithmetic lp64 (Real Double))
let pointer t = get (Ctype.pointer_to t)
let tags = Ctype.create_tags ()
let location =
  { Typec_cpp.Location.file = "in.c"; line = 1; flags = No_flags }
let array t length = get (Ctype.array_of tags t length)
let func return parameters = get (Ctype.function_returning return parameters)
let prototype types = Ctype.Prototype { types; variadic = false }
let variadic types = Ctype.Prototype { types; variadic = true }
let qualify qualifiers t = get (Ctype.qualify qualifiers t)
let const = { Qualifiers.none with const = true }
let volatile = { Qualifiers.none with volatile = true }
let restrict = { Qualifiers.none with restrict = true }
let atomic = { Qualifiers.none with atomic = true }

(* Ranks and promotions *)

let rank_order =
  let open Integer in
  [ [ Bool ]; [ Char; Signed_char; Unsigned_char ]; [ Short; Unsigned_short ];
    [ Int; Unsigned_int ]; [ Long; Unsigned_long ];
    [ Long_long; Unsigned_long_long ]; [ Int128; Unsigned_int128 ] ]

let check_ranks () =
  let ranks group = List.sort_uniq compare (List.map Integer.rank group) in
  let firsts = List.map (fun group -> List.hd (ranks group)) rank_order in
  check "each rank group has one rank"
    (List.for_all (fun group -> List.length (ranks group) = 1) rank_order)
    true
  && check "rank groups ascend" (List.sort compare firsts) firsts
  && check "rank groups are distinct"
       (List.length (List.sort_uniq compare firsts))
       (List.length firsts)

let promoted target ?bit_field_width integer =
  (Arithmetic.promote target ?bit_field_width (Integer integer)
    :> Arithmetic.t)

(* A target, an integer type, a bit-field width and the promoted type. *)
let promotion_cases : (string * Target.t * Integer.t * int option * Integer.t)
    list =
  [
    ("_Bool", lp64, Bool, None, Int);
    ("char", lp64, Char, None, Int);
    ("unsigned char, ILP32", ilp32, Unsigned_char, None, Int);
    ("plain unsigned char, ILP32", ilp32, Char, None, Int);
    ("unsigned short", lp64, Unsigned_short, None, Int);
    ("unsigned short, 16-bit int", int16, Unsigned_short, None, Unsigned_int);
    ("short, 16-bit int", int16, Short, None, Int);
    ("int", lp64, Int, None, Int);
    ("unsigned int", lp64, Unsigned_int, None, Unsigned_int);
    ("long", lp64, Long, None, Long);
    ("unsigned long, ILP32", ilp32, Unsigned_long, None, Unsigned_long);
    ("unsigned __int128", lp64, Unsigned_int128, None, Unsigned_int128);
    ("unsigned int : 31", lp64, Unsigned_int, Some 31, Int);
    ("unsigned int : 32", lp64, Unsigned_int, Some 32, Unsigned_int);
    ("int : 32", lp64, Int, Some 32, Int);
    ("_Bool : 1", lp64, Bool, Some 1, Int);
    ("unsigned char : 3", lp64, Unsigned_char, Some 3, Int);
    ("long : 20", lp64, Long, Some 20, Int);
    ("unsigned long : 32", lp64, Unsigned_long, Some 32, Unsigned_int);
    ("unsigned long : 33", lp64, Unsigned_long, Some 33, Unsigned_long);
    ("long long : 64, ILP32", ilp32, Long_long, Some 64, Long_long);
  ]

let check_promotion (name, target, integer, bit_field_width, expected) =
  check ("promotion of " ^ name)
    (promoted target ?bit_field_width integer)
    (Integer expected)

let floating_promotions () =
  check "float is not promoted"
    (Arithmetic.promote lp64 (Real Float) :> Arithmetic.t)
    (Real Float)
  && check "float argument"
       (Arithmetic.default_argument_promotion lp64 (Real Float))
       (Real Double)
  && check "complex float argument"
       (Arithmetic.default_argument_promotion lp64 (Complex Float))
       (Complex Float)
  && check "char argument"
       (Arithmetic.default_argument_promotion ilp32 (Integer Char))
       (Integer Int)
  && check "bit-field argument"
       (Arithmetic.default_argument_promotion lp64 ~bit_field_width:32
          (Integer Unsigned_long))
       (Integer Unsigned_int)

(* A target, two operand types and their common type. *)
let conversion_cases : (string * Target.t * Arithmetic.t * Arithmetic.t
                       * Arithmetic.t) list =
  [
    ("char + unsigned char", lp64, Integer Char, Integer Unsigned_char,
     Integer Int);
    ("unsigned int + int", lp64, Integer Unsigned_int, Integer Int,
     Integer Unsigned_int);
    ("unsigned int + long, LP64", lp64, Integer Unsigned_int, Integer Long,
     Integer Long);
    ("unsigned int + long, ILP32", ilp32, Integer Unsigned_int, Integer Long,
     Integer Unsigned_long);
    ("long + unsigned long", lp64, Integer Long, Integer Unsigned_long,
     Integer Unsigned_long);
    ("unsigned long + long long, LP64", lp64, Integer Unsigned_long,
     Integer Long_long, Integer Unsigned_long_long);
    ("unsigned long + long long, ILP32", ilp32, Integer Unsigned_long,
     Integer Long_long, Integer Long_long);
    ("long + long long", lp64, Integer Long, Integer Long_long,
     Integer Long_long);
    ("__int128 + unsigned long long", lp64, Integer Int128,
     Integer Unsigned_long_long, Integer Int128);
    ("long long + unsigned __int128", lp64, Integer Long_long,
     Integer Unsigned_int128, Integer Unsigned_int128);
    ("unsigned short + int, 16-bit int", int16, Integer Unsigned_short,
     Integer Int, Integer Unsigned_int);
    ("_Bool + _Bool", lp64, Integer Bool, Integer Bool, Integer Int);
    ("float + int", lp64, Real Float, Integer Int, Real Float);
    ("unsigned long long + float", lp64, Integer Unsigned_long_long,
     Real Float, Real Float);
    ("float + double", lp64, Real Float, Real Double, Real Double);
    ("long double + double", lp64, Real Long_double, Real Double,
     Real Long_double);
    ("_Complex float + double", lp64, Complex Float, Real Double,
     Complex Double);
    ("long double + _Complex float", lp64, Real Long_double, Complex Float,
     Complex Long_double);
    ("_Complex double + int", lp64, Integer Int, Complex Double,
     Complex Double);
    ("_Complex float + _Complex float", lp64, Complex Float, Complex Float,
     Complex Float);
  ]

let check_conversion (name, target, a, b, expected) =
  let a = Arithmetic.promote target a and b = Arithmetic.promote target b in
  check name (Arithmetic.usual_arithmetic_conversions target a b) expected
  && check (name ^ ", swapped")
       (Arithmetic.usual_arithmetic_conversions target b a)
       expected

(* A target, a range of enumerator values and the compatible type under
   int-sized enumerations. *)
let int_sized_enum_cases : (string * Target.t * Arithmetic.enumerator_range
                 * Integer.t option) list =
  [
    ("zero", lp64, { negative = false; width = 0 }, Some Unsigned_int);
    ("minus one", lp64, { negative = true; width = 1 }, Some Int);
    ("32 bits", lp64, { negative = false; width = 32 }, Some Unsigned_int);
    ("signed 32 bits", lp64, { negative = true; width = 32 }, Some Int);
    ("signed 33 bits, LP64", lp64, { negative = true; width = 33 },
     Some Long);
    ("signed 33 bits, ILP32", ilp32, { negative = true; width = 33 },
     Some Long_long);
    ("33 bits, LP64", lp64, { negative = false; width = 33 },
     Some Unsigned_long);
    ("64 bits, ILP32", ilp32, { negative = false; width = 64 },
     Some Unsigned_long_long);
    ("65 bits, LP64", lp64, { negative = false; width = 65 }, None);
    ("65 bits, ILP32", ilp32, { negative = false; width = 65 }, None);
    ("signed 65 bits, LP64", lp64, { negative = true; width = 65 }, None);
  ]

let short_enums (target : Target.t) =
  { target with enum_representation = Short }

let lp64_short = short_enums lp64
let ilp32_short = short_enums ilp32
let int16_short = short_enums int16

(* A target, whether the enumeration is packed, a range of enumerator
   values and the compatible type. *)
let short_enum_cases : (string * Target.t * bool * Arithmetic.enumerator_range
                       * Integer.t option) list =
  [
    ("short zero", lp64_short, false, { negative = false; width = 0 },
     Some Unsigned_char);
    ("packed zero", lp64, true, { negative = false; width = 0 },
     Some Unsigned_char);
    ("packed fixed width", ilp32, true, { negative = false; width = 8 },
     Some Unsigned_char);
    ("short 9 bits", ilp32_short, false, { negative = false; width = 9 },
     Some Unsigned_short);
    ("short minus one", lp64_short, false, { negative = true; width = 1 },
     Some Signed_char);
    ("short signed 9 bits", lp64_short, false, { negative = true; width = 9 },
     Some Short);
    ("short signed 17 bits", lp64_short, false,
     { negative = true; width = 17 }, Some Int);
    ("short 33 bits", lp64_short, false, { negative = false; width = 33 },
     Some Unsigned_long);
    (* By rank and not by size: where int has 16 bits, 256 is unsigned
       short under short enumerations and unsigned int without. *)
    ("16-bit int, short 9 bits", int16_short, false,
     { negative = false; width = 9 }, Some Unsigned_short);
    ("16-bit int, 9 bits", int16, false, { negative = false; width = 9 },
     Some Unsigned_int);
    ("16-bit int, packed 16 bits", int16, true,
     { negative = false; width = 16 }, Some Unsigned_short);
    ("16-bit int, packed 17 bits", int16, true,
     { negative = false; width = 17 }, Some Unsigned_long);
  ]

let enum_cases =
  short_enum_cases
  @ List.map
      (fun (name, target, range, expected) ->
        (name, target, false, range, expected))
      int_sized_enum_cases

let check_enum (name, target, packed, range, expected) =
  check ("enum, " ^ name)
    (Arithmetic.enum_compatible_type target ~packed range)
    expected

(* An object of an enumeration below int promotes to int, also where int
   does not hold its values, as Clang for msp430 gives it. *)
let enum_promotion_cases =
  [
    ("unsigned char", lp64_short, Integer.Unsigned_char,
     Arithmetic.Integer Int);
    ("16-bit int, unsigned short", int16_short, Unsigned_short, Integer Int);
    ("unsigned int", lp64, Unsigned_int, Integer Unsigned_int);
    ("unsigned long", lp64_short, Unsigned_long, Integer Unsigned_long);
  ]

let check_enum_promotion (name, target, integer, expected) =
  check ("enum promotion, " ^ name)
    (Arithmetic.promote_enumeration target integer :> Arithmetic.t)
    expected

(* Building types *)

let struct_s = Ctype.declare_record tags Struct (Some "s") ~at_file_scope:true
let other_struct_s =
  Ctype.declare_record tags Struct (Some "s") ~at_file_scope:true
let incomplete_struct =
  Ctype.declare_record tags Struct (Some "incomplete") ~at_file_scope:true
let enum_u = Ctype.declare_enum tags (Some "u") ~at_file_scope:true
let other_enum_u = Ctype.declare_enum tags (Some "v") ~at_file_scope:true
let incomplete_enum = Ctype.declare_enum tags (Some "later") ~at_file_scope:true

let member ?bit_field_width name member_type =
  { Ctype.member_name = name; member_type; bit_field_width }

let () =
  get (Ctype.define_record lp64 tags struct_s [ member (Some "x") int_type ]);
  get (Ctype.define_enum tags enum_u (Answer Unsigned_int));
  get (Ctype.define_enum tags other_enum_u (Answer Unsigned_int))

let function_type = func int_type (prototype [])

(* A pointer chain of [count] derivations over int. *)
let rec pointers count t =
  if count = 0 then t else pointers (count - 1) (pointer t)

let construction_errors : (string * (Ctype.t, Ctype.error) result
                          * Ctype.error option) list =
  [
    ("__int128 without it", Ctype.integer ilp32 Int128,
     Some Int128_unavailable);
    ("unsigned __int128 with it", Ctype.integer lp64 Unsigned_int128, None);
    ("const function", Ctype.qualify const function_type,
     Some Qualified_function);
    ("unqualified function", Ctype.qualify Qualifiers.none function_type,
     None);
    ("_Atomic array", Ctype.qualify atomic (array int_type (Constant 3)),
     Some Atomic_array);
    ("restrict int", Ctype.qualify restrict int_type,
     Some Restrict_without_object_pointer);
    ("restrict function pointer",
     Ctype.qualify restrict (pointer function_type),
     Some Restrict_without_object_pointer);
    ("restrict void pointer", Ctype.qualify restrict (pointer Ctype.void),
     None);
    ("restrict array of pointers",
     Ctype.qualify restrict (array (pointer int_type) (Constant 2)), None);
    ("_Atomic(const int)", Ctype.atomic (qualify const int_type),
     Some Atomic_of_unsuitable_type);
    ("_Atomic(int[3])", Ctype.atomic (array int_type (Constant 3)),
     Some Atomic_of_unsuitable_type);
    ("array of functions", Ctype.array_of tags function_type (Constant 1),
     Some Array_of_function);
    ("array of void", Ctype.array_of tags Ctype.void Unknown,
     Some Array_of_incomplete);
    ("array of an incomplete structure",
     Ctype.array_of tags (Ctype.record incomplete_struct) (Constant 2),
     Some Array_of_incomplete);
    ("array of int[]", Ctype.array_of tags (array int_type Unknown) Unknown,
     Some Array_of_incomplete);
    ("array of int[n]", Ctype.array_of tags (array int_type Variable) Unknown,
     None);
    ("negative length", Ctype.array_of tags int_type (Constant (-1)),
     Some Negative_length);
    ("zero length", Ctype.array_of tags int_type (Constant 0), None);
    ("function returning an array",
     Ctype.function_returning (array int_type (Constant 1)) (prototype []),
     Some Function_returning_array);
    ("function returning a function",
     Ctype.function_returning function_type Unspecified,
     Some Function_returning_function);
    ("largest pointer",
     Ctype.pointer_to (pointers (Ctype.max_size - 2) int_type), None);
    ("too large a pointer",
     Ctype.pointer_to (pointers (Ctype.max_size - 1) int_type),
     Some Too_large);
    ("too large a function",
     Ctype.function_returning (pointers (Ctype.max_size - 2) int_type)
       Unspecified,
     Some Too_large);
    ("void parameter",
     Ctype.function_returning int_type (prototype [ int_type; Ctype.void ]),
     Some Void_parameter);
  ]

let check_construction (name, outcome, expected) =
  check name (error_of outcome) expected

let largest_function =
  func (pointers (Ctype.max_size - 3) int_type) Unspecified

(* A chain of typedefs in which each is a pointer to a function taking
   two of the previous: each step doubles the tree, which the size limit
   stops after a few. *)
let doubling_typedefs () =
  let rec grow steps t =
    let doubled =
      Result.bind
        (Ctype.function_returning int_type (prototype [ t; t ]))
        Ctype.pointer_to
    in
    match doubled with
    | Ok t -> grow (steps + 1) t
    | Error error -> (steps, error)
  in
  let steps, error = grow 0 int_type in
  check "doubling typedefs stop at the limit" (steps < 16, error)
    (true, Ctype.Too_large)

(* Each of two compatible types gives the parameter types the other lacks,
   so their composite is about twice as large as either. *)
let oversized_composite () =
  let large = pointers 2060 int_type in
  let without_prototype = pointer (func int_type Unspecified) in
  let with_prototype = pointer (func int_type (prototype [ large ])) in
  let a = pointer (func int_type (prototype [ with_prototype;
                                              without_prototype ])) in
  let b = pointer (func int_type (prototype [ without_prototype;
                                              with_prototype ])) in
  check "oversized composite"
    (error_of (Ctype.composite lp64 tags location a b))
    (Some Too_large)
  && check "oversized composite, compatible"
       (Ctype.compatible lp64 tags location a b)
       (Answer true)

let construction_facts () =
  check "const array qualifies the element"
    (qualify const (array int_type (Constant 3)))
    (array (qualify const int_type) (Constant 3))
  && check "the largest function decays within the limit"
       ((Ctype.decay largest_function).size <= Ctype.max_size) true
  && check "parameters are adjusted and unqualified"
       (func int_type (prototype [ qualify const int_type;
                                   array char_type (Constant 4);
                                   function_type ]))
       (func int_type (prototype [ int_type; pointer char_type;
                                   pointer function_type ]))
  && check "the return type keeps its qualifiers"
       (Type_name.of_ctype (func (qualify const int_type) (prototype [])))
       "const int (void)"
  && check "lvalue conversion drops qualifiers"
       (Ctype.lvalue_conversion (qualify { const with atomic = true } int_type))
       int_type
  && check "lvalue conversion keeps element qualifiers"
       (Ctype.lvalue_conversion (array (qualify const int_type) (Constant 2)))
       (pointer (qualify const int_type))
  && check "a function decays to a pointer"
       (Ctype.lvalue_conversion function_type) (pointer function_type)
  && check "pointer to VLA is variably modified"
       (Ctype.is_variably_modified (pointer (array int_type Variable)))
       (Answer true)
  && check "array of known length is complete"
       (Ctype.is_complete tags (array int_type (Constant 2))) (Answer true)
  && check "array of unknown length is incomplete"
       (Ctype.is_complete tags (array int_type Unknown)) (Answer false)
  && check "a declared enumeration is incomplete"
       (Ctype.is_complete tags (Ctype.enum incomplete_enum)) (Answer false)
  && check "an enumeration is an integer type"
       (Ctype.is_integer (Ctype.enum incomplete_enum)) (Answer true)
  && check "an enumeration's arithmetic type"
       (Ctype.as_arithmetic tags (qualify const (Ctype.enum enum_u)))
       (Answer (Some (Integer Unsigned_int)))
  && check "an incomplete enumeration has no arithmetic type"
       (Ctype.as_arithmetic tags (Ctype.enum incomplete_enum))
       (Answer None)
  && check "a pointer is scalar" (Ctype.is_scalar (pointer Ctype.void))
       (Answer true)
  && check "void is an object type" (Ctype.is_object Ctype.void)
       (Answer true)
  && check "void is incomplete" (Ctype.is_complete tags Ctype.void)
       (Answer false)

(* Tags and members *)

let anonymous_inner = Ctype.declare_record tags Union None ~at_file_scope:true
let with_anonymous =
  Ctype.declare_record tags Struct (Some "outer") ~at_file_scope:true

let () =
  get
    (Ctype.define_record lp64 tags anonymous_inner
       [ member (Some "a") int_type; member (Some "b") float_type ]);
  get
    (Ctype.define_record lp64 tags with_anonymous
       [
         member (Some "first") char_type;
         member None (qualify const (Ctype.record anonymous_inner));
         member ~bit_field_width:3 None unsigned_type;
         member ~bit_field_width:5 (Some "bits") unsigned_type;
       ])

let anonymous_with_array =
  Ctype.declare_record tags Struct None ~at_file_scope:true

let () =
  get
    (Ctype.define_record lp64 tags anonymous_with_array
       [ member (Some "y") (array int_type (Constant 3)) ])

let definition_outcome kind members =
  let tag = Ctype.declare_record tags kind None ~at_file_scope:true in
  error_of (Ctype.define_record lp64 tags tag members)

let flexible = array int_type Unknown
let self_referential =
  Ctype.declare_record tags Struct (Some "node") ~at_file_scope:true

let definition_cases : (string * Ctype.error option * Ctype.error option)
    list =
  [
    ("redefinition",
     error_of
       (Ctype.define_record lp64 tags struct_s [ member (Some "y") int_type ]),
     Some Redefinition);
    ("self-referential",
     error_of
       (Ctype.define_record lp64 tags self_referential
          [ member (Some "next") (pointer (Ctype.record self_referential)) ]),
     None);
    ("duplicate member",
     definition_outcome Struct
       [ member (Some "x") int_type; member (Some "x") long_type ],
     Some (Duplicate_member "x"));
    ("duplicate through an anonymous member",
     definition_outcome Struct
       [ member (Some "a") int_type;
         member None (Ctype.record anonymous_inner) ],
     Some (Duplicate_member "a"));
    ("flexible array member",
     definition_outcome Struct
       [ member (Some "count") int_type; member (Some "items") flexible ],
     None);
    ("flexible array alone, as GCC and Clang accept",
     definition_outcome Struct [ member (Some "items") flexible ], None);
    ("flexible array first",
     definition_outcome Struct
       [ member (Some "items") flexible; member (Some "count") int_type ],
     Some Misplaced_flexible_array);
    ("flexible array in a union, as GCC and Clang accept",
     definition_outcome Union
       [ member (Some "count") int_type; member (Some "items") flexible ],
     None);
    ("bit-field as wide as int",
     definition_outcome Struct
       [ member ~bit_field_width:32 (Some "b") unsigned_type ], None);
    ("bit-field wider than int",
     definition_outcome Struct
       [ member ~bit_field_width:33 (Some "b") int_type ],
     Some Invalid_bit_field);
    ("_Bool : 2",
     definition_outcome Struct
       [ member ~bit_field_width:2 (Some "b") (integer Bool) ],
     Some Invalid_bit_field);
    ("enumerated bit-field",
     definition_outcome Struct
       [ member ~bit_field_width:3 (Some "e") (Ctype.enum enum_u) ], None);
    ("floating bit-field",
     definition_outcome Struct
       [ member ~bit_field_width:3 (Some "f") float_type ],
     Some Invalid_bit_field);
    ("named bit-field of width 0",
     definition_outcome Struct
       [ member ~bit_field_width:0 (Some "z") int_type ],
     Some Invalid_bit_field);
    ("unnamed bit-field of width 0",
     definition_outcome Struct
       [ member (Some "x") int_type; member ~bit_field_width:0 None int_type ],
     None);
    ("_Atomic anonymous member with an array",
     definition_outcome Struct
       [ member None
           (get (Ctype.atomic (Ctype.record anonymous_with_array))) ],
     None);
    ("incomplete member",
     definition_outcome Struct
       [ member (Some "inner") (Ctype.record incomplete_struct) ],
     Some Incomplete_member);
    ("function member",
     definition_outcome Struct [ member (Some "f") function_type ],
     Some Incomplete_member);
    ("variably modified member",
     definition_outcome Struct
       [ member (Some "p") (pointer (array int_type Variable)) ],
     Some Variably_modified_member);
  ]

let check_definition (name, outcome, expected) = check name outcome expected

let found name = Ctype.find_member tags with_anonymous name

let member_type name =
  Option.map
    (fun (found : Ctype.found_member) -> found.member.member_type)
    (found name)

let anonymous_qualifiers name =
  Option.map
    (fun (found : Ctype.found_member) -> found.anonymous_qualifiers)
    (found name)

(* The qualifiers of an anonymous member stay apart from the type of the
   members found through it, which Clang does not give them. *)
let member_facts () =
  check "named member" (member_type "first") (Some char_type)
  && check "named member, no anonymous qualifiers"
       (anonymous_qualifiers "first") (Some Qualifiers.none)
  && check "member of a const anonymous member" (member_type "b")
       (Some float_type)
  && check "qualifiers of a const anonymous member"
       (anonymous_qualifiers "b") (Some const)
  && check "bit-field width"
       (Option.map
          (fun (found : Ctype.found_member) -> found.member.bit_field_width)
          (found "bits"))
       (Some (Some 5))
  && check "no such member" (member_type "c") None
  && check "members in order"
       (Option.map List.length (Ctype.record_members tags with_anonymous))
       (Some 4)
  && check "members of an incomplete structure"
       (Ctype.record_members tags incomplete_struct) None

(* Compatibility and composite types *)

let old_style types = Ctype.Old_style types

(* Two types and their composite type, or None when not compatible. *)
let composite_cases : (string * Ctype.t * Ctype.t * Ctype.t option) list =
  [
    ("int, int", int_type, int_type, Some int_type);
    ("int, long", int_type, long_type, None);
    ("char, signed char", char_type, integer Signed_char, None);
    ("const int, int", qualify const int_type, int_type, None);
    ("_Atomic int, int", qualify atomic int_type, int_type, None);
    ("volatile int, volatile int", qualify volatile int_type,
     qualify volatile int_type, Some (qualify volatile int_type));
    ("int *, const int *", pointer int_type, pointer (qualify const int_type),
     None);
    ("int[], int[3]", array int_type Unknown, array int_type (Constant 3),
     Some (array int_type (Constant 3)));
    ("int[3], int[4]", array int_type (Constant 3),
     array int_type (Constant 4), None);
    ("int[n], int[3]", array int_type Variable, array int_type (Constant 3),
     Some (array int_type (Constant 3)));
    ("int[], int[n]", array int_type Unknown, array int_type Variable,
     Some (array int_type Variable));
    ("int (*)[], int (*)[3]", pointer (array int_type Unknown),
     pointer (array int_type (Constant 3)),
     Some (pointer (array int_type (Constant 3))));
    ("int(void), int()", func int_type (prototype []),
     func int_type Unspecified, Some (func int_type (prototype [])));
    ("int(char), int()", func int_type (prototype [ char_type ]),
     func int_type Unspecified, None);
    ("int(float), int()", func int_type (prototype [ float_type ]),
     func int_type Unspecified, None);
    ("int(double), int()", func int_type (prototype [ double_type ]),
     func int_type Unspecified,
     Some (func int_type (prototype [ double_type ])));
    ("int(int, ...), int()", func int_type (variadic [ int_type ]),
     func int_type Unspecified, None);
    ("int(enum u), int()", func int_type (prototype [ Ctype.enum enum_u ]),
     func int_type Unspecified,
     Some (func int_type (prototype [ Ctype.enum enum_u ])));
    ("int(int), int(int, int)", func int_type (prototype [ int_type ]),
     func int_type (prototype [ int_type; int_type ]), None);
    ("int(int, ...), int(int)", func int_type (variadic [ int_type ]),
     func int_type (prototype [ int_type ]), None);
    ("int(const int), int(int)",
     func int_type (prototype [ qualify const int_type ]),
     func int_type (prototype [ int_type ]),
     Some (func int_type (prototype [ int_type ])));
    ("int(int[3]), int(int *)",
     func int_type (prototype [ array int_type (Constant 3) ]),
     func int_type (prototype [ pointer int_type ]),
     Some (func int_type (prototype [ pointer int_type ])));
    ("int(int (*)[]), int(int (*)[2])",
     func int_type (prototype [ pointer (array int_type Unknown) ]),
     func int_type (prototype [ pointer (array int_type (Constant 2)) ]),
     Some
       (func int_type (prototype [ pointer (array int_type (Constant 2)) ])));
    ("int(void), long(void)", func int_type (prototype []),
     func long_type (prototype []), None);
    ("old-style f(c) char c; against int(int)",
     func int_type (old_style [ char_type ]),
     func int_type (prototype [ int_type ]),
     Some (func int_type (prototype [ int_type ])));
    ("old-style f(c) char c; against int(char)",
     func int_type (old_style [ char_type ]),
     func int_type (prototype [ char_type ]), None);
    ("old-style f(x) float x; against int(double)",
     func int_type (old_style [ float_type ]),
     func int_type (prototype [ double_type ]),
     Some (func int_type (prototype [ double_type ])));
    ("old-style f(i) int i; against int(int, int)",
     func int_type (old_style [ int_type ]),
     func int_type (prototype [ int_type; int_type ]), None);
    ("old-style f() against int(void)", func int_type (old_style []),
     func int_type (prototype []), Some (func int_type (prototype [])));
    ("old-style f(i) int i; against int()",
     func int_type (old_style [ int_type ]), func int_type Unspecified,
     Some (func int_type (old_style [ int_type ])));
    ("int(), old-style f(i) int i;", func int_type Unspecified,
     func int_type (old_style [ int_type ]),
     Some (func int_type (old_style [ int_type ])));
    ("int (*)(), int (*)(long)", pointer (func int_type Unspecified),
     pointer (func int_type (prototype [ long_type ])),
     Some (pointer (func int_type (prototype [ long_type ]))));
    ("enum u, unsigned int", Ctype.enum enum_u, unsigned_type,
     Some unsigned_type);
    ("unsigned int, enum u", unsigned_type, Ctype.enum enum_u,
     Some unsigned_type);
    ("const enum u *, const unsigned int *",
     pointer (qualify const (Ctype.enum enum_u)),
     pointer (qualify const unsigned_type),
     Some (pointer (qualify const unsigned_type)));
    ("enum u, int", Ctype.enum enum_u, int_type, None);
    ("enum u, enum v", Ctype.enum enum_u, Ctype.enum other_enum_u, None);
    ("enum u, enum u", Ctype.enum enum_u, Ctype.enum enum_u,
     Some (Ctype.enum enum_u));
    ("incomplete enum, unsigned int", Ctype.enum incomplete_enum,
     unsigned_type, None);
    ("struct s, struct s", Ctype.record struct_s, Ctype.record struct_s,
     Some (Ctype.record struct_s));
    ("two tags named s", Ctype.record struct_s, Ctype.record other_struct_s,
     None);
    ("struct s *, void *", pointer (Ctype.record struct_s),
     pointer Ctype.void, None);
  ]

let check_composite (name, a, b, expected) =
  let expected_composite =
    match expected with
    | Some t -> Ok t
    | None -> Error Ctype.Incompatible
  in
  check name (Ctype.composite lp64_clang tags location a b) expected_composite
  && check (name ^ ", compatible") (Ctype.compatible lp64 tags location b a)
       (Answer (Option.is_some expected))

(* GCC gives an enumerated type and its compatible integer type the
   enumerated type as their composite, so with GCC it is unknown, qualified
   as both types are. *)
let enum_integer_composite_with_gcc () =
  let composite =
    Ctype.unknown
      { construct = "the composite of an enumerated type and its integer type";
        location;
        kind = Unknown_object;
        cause = Typed_differently }
  in
  let enum = Ctype.enum enum_u in
  let composite_with_gcc a b = Ctype.composite lp64 tags location a b in
  check "enum u, unsigned int with GCC"
    (composite_with_gcc enum unsigned_type) (Ok composite)
  && check "const unsigned int, const enum u with GCC"
       (composite_with_gcc (qualify const unsigned_type) (qualify const enum))
       (Ok (qualify const composite))
  && check "enum u, enum u with GCC" (composite_with_gcc enum enum) (Ok enum)

(* Clang keeps the qualifiers of a return type and GCC drops all but
   _Atomic of them, so with GCC a comparison that turns on them depends on
   an unknown type, and the composite is an unknown function type. *)
let return_qualifiers () =
  let unknown kind =
    { Unknown.construct = "the qualifiers of a function's return type";
      location;
      kind;
      cause = Typed_differently }
  in
  let returning return = func return (prototype []) in
  let const_int = returning (qualify const int_type)
  and plain_int = returning int_type
  and plain_long = returning long_type
  and atomic_int = returning (qualify atomic int_type) in
  let compatible target a b = Ctype.compatible target tags location a b
  and composite target a b = Ctype.composite target tags location a b
  and same_type target a b = Ctype.same_type target tags location a b in
  let unknown_return = returning (Ctype.unknown (unknown Unknown_object)) in
  check "const int (void), int (void) with Clang"
    (compatible lp64_clang const_int plain_int) (Answer false)
  && check "const int (void), int (void) with GCC"
       (compatible lp64 const_int plain_int)
       (Depends_on (unknown Unknown_object))
  && check "const int (*)(void), int (*)(void) with GCC"
       (compatible lp64 (pointer const_int) (pointer plain_int))
       (Depends_on (unknown Unknown_object))
  && check "const int (void), long (void) with GCC"
       (compatible lp64 const_int plain_long) (Answer false)
  && check "_Atomic int (void), int (void) with GCC"
       (compatible lp64 atomic_int plain_int) (Answer false)
  && check "const int (void) with itself with GCC"
       (compatible lp64 const_int const_int) (Answer true)
  && check "composite of const int (void), int (void) with Clang"
       (composite lp64_clang const_int plain_int) (Error Incompatible)
  && check "composite of const int (void), int (void) with GCC"
       (composite lp64 const_int plain_int) (Ok unknown_return)
  && check "composite of const int (*)(void), int (*)(void) with GCC"
       (composite lp64 (pointer const_int) (pointer plain_int))
       (Ok (pointer unknown_return))
  && check "composite of const int (void), long (void) with GCC"
       (composite lp64 const_int plain_long) (Error Incompatible)
  && check "same type const int (void), int (void) with Clang"
       (same_type lp64_clang const_int plain_int) (Answer false)
  && check "same type const int (void), int (void) with GCC"
       (same_type lp64 const_int plain_int)
       (Depends_on (unknown Unknown_object))
  && check "same type const int (void), long (void) with GCC"
       (same_type lp64 const_int plain_long) (Answer false)

let unsigned_short_parameter () =
  check "int(unsigned short), int() on a 16-bit int target"
    (Ctype.compatible int16 tags location
       (func int_type (prototype [ integer Unsigned_short ]))
       (func int_type Unspecified))
    (Answer false)

(* Printing *)

let printing_cases : (Ctype.t * string) list =
  [
    (int_type, "int");
    (integer Unsigned_long, "unsigned long");
    (integer Unsigned_int128, "unsigned __int128");
    (get (Ctype.arithmetic lp64 (Complex Double)), "_Complex double");
    (qualify { const with volatile = true } int_type, "const volatile int");
    (qualify atomic int_type, "_Atomic int");
    (pointer int_type, "int *");
    (qualify const (pointer char_type), "char *const");
    (pointer (qualify const char_type), "const char *");
    (pointer (qualify const (pointer char_type)), "char *const *");
    (qualify restrict (pointer int_type), "int *restrict");
    (array int_type (Constant 3), "int[3]");
    (array int_type Unknown, "int[]");
    (array int_type Variable, "int[*]");
    (array (array int_type (Constant 3)) (Constant 2), "int[2][3]");
    (array (pointer int_type) (Constant 3), "int *[3]");
    (pointer (array int_type (Constant 3)), "int (*)[3]");
    (function_type, "int (void)");
    (pointer function_type, "int (*)(void)");
    (qualify const (pointer function_type), "int (*const)(void)");
    (pointer (func Ctype.void Unspecified), "void (*)()");
    (func int_type (variadic [ pointer (qualify const char_type) ]),
     "int (const char *, ...)");
    (pointer
       (func
          (pointer (func Ctype.void (prototype [])))
          (prototype [ int_type ])),
     "void (*(*)(int))(void)");
    (func (pointer (func Ctype.void (prototype [ int_type ])))
       (prototype
          [ int_type; pointer (func Ctype.void (prototype [ int_type ])) ]),
     "void (*(int, void (*)(int)))(int)");
    (Ctype.record struct_s, "struct s");
    (Ctype.record anonymous_inner, "union <anonymous>");
    (qualify const (Ctype.enum enum_u), "const enum u");
  ]

let check_printing (t, expected) =
  let printed = Type_name.of_ctype t in
  if printed = expected then true
  else (
    Printf.eprintf "FAIL: printed %S, expected %S\n" printed expected;
    false)

let declaration_facts () =
  check "declaration of a pointer to an array"
    (Type_name.declaration (pointer (array int_type (Constant 3))) "p")
    "int (*p)[3]"
  && check "declaration of an array"
       (Type_name.declaration (array int_type (Constant 3)) "a")
       "int a[3]"

(* An instance of the generic [g] at [arguments], a structure, which
   [level] tells apart from the other instances of a test. *)
let instance_type level arguments =
  let generic =
    match Typec_syntax.Spelling.type_name ~at_file_scope:true "g" with
    | Ok name -> name
    | Error _ -> failwith "instance_type: no generic name"
  in
  let instance : Ctype.instance =
    { generic; arguments = [ string_of_int level ];
      argument_types = arguments; mentions_parameter = false }
  in
  Ctype.record (Ctype.declare_instance tags Struct instance ~define:ignore)

(* A type whose spelling grows [width] times at each of [depth] levels,
   as each level names the one below it [width] times. *)
let rec crafted_type ~width depth =
  if depth = 0 then int_type
  else
    let below = crafted_type ~width (depth - 1) in
    instance_type depth (List.init width (fun _ -> below))

(* Its whole spelling is millions of bytes; naming it may cost no more
   than this many bytes, whatever its depth. *)
let naming_allocation = 100_000.

(* Every name that a diagnostic shows costs a bounded text, and a small
   type is named whole. *)
let bounded_names () =
  let crafted = crafted_type ~width:4 10 in
  let before = Gc.allocated_bytes () in
  let name = Type_name.of_ctype crafted in
  let allocated = Gc.allocated_bytes () -. before in
  let small = instance_type 0 [ int_type; pointer char_type ] in
  let accented = String.concat "" (List.init 150 (fun _ -> "\xc3\xa9")) in
  let cut = Shown.cut accented in
  check "a crafted type is named within a small allocation"
    (allocated <= naming_allocation) true
  && check "a crafted type's name is cut"
       (String.length name <= Shown.max_length
       && String.ends_with ~suffix:"..." name)
       true
  && check "a small instance is named whole" (Type_name.of_ctype small)
       "g(int, char *)"
  && check "a cut name ends at a character"
       (String.length cut <= Shown.max_length
       && String.is_valid_utf_8 cut
       && String.ends_with ~suffix:"..." cut)
       true

(* Types that typec does not compute: each question that depends on one
   answers so, and the known parts still decide what they can. *)
let unknown_facts () =
  let unknown_of kind =
    { Unknown.construct = "x"; location; kind; cause = Not_typed }
  in
  let object_unknown = unknown_of Unknown_object in
  let function_unknown = unknown_of Unknown_function in
  let u = Ctype.unknown object_unknown in
  let f = Ctype.unknown function_unknown in
  let packed_enum =
    Ctype.declare_enum tags (Some "packed") ~at_file_scope:true
  in
  get (Ctype.define_enum tags packed_enum (Depends_on object_unknown));
  let packed = Ctype.enum packed_enum in
  check "an unknown type may be an integer" (Ctype.is_integer u)
    (Depends_on object_unknown)
  && check "an unknown function is no integer" (Ctype.is_integer f)
       (Answer false)
  && check "an unknown function is incomplete" (Ctype.is_complete tags f)
       (Answer false)
  && check "an array of unknown elements may be complete"
       (Ctype.is_complete tags (array u (Constant 2)))
       (Depends_on object_unknown)
  && check "an unknown function decays" (Ctype.decay f) (pointer f)
  && check "an unknown function is not qualified"
       (error_of (Ctype.qualify const f))
       (Some Qualified_function)
  && check "compatible with an unknown type"
       (Ctype.compatible lp64 tags location (pointer u) (pointer int_type))
       (Depends_on object_unknown)
  && check "known parts decide incompatibility"
       (Ctype.compatible lp64 tags location (pointer u) (array u (Constant 1)))
       (Answer false)
  && check "an object is not a function, unknown or not"
       (Ctype.compatible lp64 tags location u function_type)
       (Answer false)
  && check "the composite is the unknown side"
       (Ctype.composite lp64 tags location (array int_type Unknown) u)
       (Ok u)
  && check "an enumeration of unknown integer type and int"
       (Ctype.compatible lp64 tags location packed int_type)
       (Depends_on object_unknown)
  && check "the composite of such an enumeration and int is int"
       (Ctype.composite lp64_clang tags location packed int_type)
       (Ok int_type)
  && check "promotion of an enumeration of unknown integer type"
       (Ctype.compatible lp64 tags location
          (func int_type (prototype [ packed ]))
          (func int_type Unspecified))
       (Depends_on object_unknown)
  && check "the same type as an unknown one"
       (Ctype.same_type lp64 tags location (pointer u) (pointer int_type))
       (Depends_on object_unknown)
  && check "not the same type, whatever the unknown one is"
       (Ctype.same_type lp64 tags location (pointer u)
          (array int_type (Constant 1)))
       (Answer false)

let () =
  let results =
    [ unknown_facts (); check_ranks (); floating_promotions ();
      construction_facts ();
      member_facts (); doubling_typedefs (); oversized_composite ();
      enum_integer_composite_with_gcc (); return_qualifiers ();
      unsigned_short_parameter ();
      declaration_facts (); bounded_names () ]
    @ List.map check_promotion promotion_cases
    @ List.map check_conversion conversion_cases
    @ List.map check_enum enum_cases
    @ List.map check_enum_promotion enum_promotion_cases
    @ List.map check_construction construction_errors
    @ List.map check_definition definition_cases
    @ List.map check_composite composite_cases
    @ List.map check_printing printing_cases
  in
  if List.mem false results then exit 1
