(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_sema

let lp64 = Canned_targets.target Canned_targets.lp64_macros
let ilp32 = Canned_targets.target Canned_targets.ilp32_macros

(* A target whose int is as wide as its short, as on 16-bit machines. *)
let int16 =
  Canned_targets.target
    (List.map
       (fun (name, value) ->
         if name = "__SIZEOF_INT__" then (name, "2") else (name, value))
       Canned_targets.lp64_macros)

let check name actual expected =
  if actual = expected then true
  else (
    Printf.eprintf "FAIL: %s\n" name;
    false)

let get = function
  | Ok t -> t
  | Error error -> failwith (Ctype.error_message error)

let error_of = function Ok _ -> None | Error error -> Some error
let int_type = Ctype.integer Int
let char_type = Ctype.integer Char
let unsigned_type = Ctype.integer Unsigned_int
let long_type = Ctype.integer Long
let float_type = Ctype.arithmetic (Real Float)
let double_type = Ctype.arithmetic (Real Double)
let pointer t = get (Ctype.pointer_to t)
let tags = Ctype.create_tags ()
let array t length = get (Ctype.array_of tags t length)
let func return parameters = get (Ctype.function_returning return parameters)
let prototype types = Ctype.Prototype { types; variadic = false }
let variadic types = Ctype.Prototype { types; variadic = true }
let qualify qualifiers t = get (Ctype.qualify qualifiers t)
let const = { Ctype.no_qualifiers with const = true }
let volatile = { Ctype.no_qualifiers with volatile = true }
let restrict = { Ctype.no_qualifiers with restrict = true }
let atomic = { Ctype.no_qualifiers with atomic = true }

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

(* A target, a range of enumerator values and the compatible type. *)
let enum_cases : (string * Target.t * Arithmetic.enumerator_range
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

let check_enum (name, target, range, expected) =
  check ("enum, " ^ name) (Arithmetic.enum_compatible_type target range)
    expected

(* Building types *)

let struct_s = Ctype.declare_record tags Struct (Some "s")
let other_struct_s = Ctype.declare_record tags Struct (Some "s")
let incomplete_struct = Ctype.declare_record tags Struct (Some "incomplete")
let enum_u = Ctype.declare_enum tags (Some "u")
let other_enum_u = Ctype.declare_enum tags (Some "v")
let incomplete_enum = Ctype.declare_enum tags (Some "later")

let member ?bit_field_width name member_type =
  { Ctype.member_name = name; member_type; bit_field_width }

let () =
  get (Ctype.define_record lp64 tags struct_s [ member (Some "x") int_type ]);
  get (Ctype.define_enum tags enum_u Unsigned_int);
  get (Ctype.define_enum tags other_enum_u Unsigned_int)

let function_type = func int_type (prototype [])

(* A pointer chain of [count] derivations over int. *)
let rec pointers count t =
  if count = 0 then t else pointers (count - 1) (pointer t)

let construction_errors : (string * (Ctype.t, Ctype.error) result
                          * Ctype.error option) list =
  [
    ("const function", Ctype.qualify const function_type,
     Some Qualified_function);
    ("unqualified function", Ctype.qualify Ctype.no_qualifiers function_type,
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
  check "oversized composite" (error_of (Ctype.composite lp64 tags a b))
    (Some Too_large)
  && check "oversized composite, compatible" (Ctype.compatible lp64 tags a b)
       true

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
  && check "the return type is unqualified"
       (func (qualify const int_type) Unspecified)
       (func int_type Unspecified)
  && check "lvalue conversion drops qualifiers"
       (Ctype.lvalue_conversion (qualify { const with atomic = true } int_type))
       int_type
  && check "lvalue conversion keeps element qualifiers"
       (Ctype.lvalue_conversion (array (qualify const int_type) (Constant 2)))
       (pointer (qualify const int_type))
  && check "a function decays to a pointer"
       (Ctype.lvalue_conversion function_type) (pointer function_type)
  && check "pointer to VLA is variably modified"
       (Ctype.is_variably_modified (pointer (array int_type Variable))) true
  && check "array of known length is complete"
       (Ctype.is_complete tags (array int_type (Constant 2))) true
  && check "array of unknown length is incomplete"
       (Ctype.is_complete tags (array int_type Unknown)) false
  && check "a declared enumeration is incomplete"
       (Ctype.is_complete tags (Ctype.enum incomplete_enum)) false
  && check "an enumeration is an integer type"
       (Ctype.is_integer (Ctype.enum incomplete_enum)) true
  && check "an enumeration's arithmetic type"
       (Ctype.as_arithmetic tags (qualify const (Ctype.enum enum_u)))
       (Some (Integer Unsigned_int))
  && check "an incomplete enumeration has no arithmetic type"
       (Ctype.as_arithmetic tags (Ctype.enum incomplete_enum)) None
  && check "a pointer is scalar" (Ctype.is_scalar (pointer Ctype.void)) true
  && check "void is an object type" (Ctype.is_object Ctype.void) true
  && check "void is incomplete" (Ctype.is_complete tags Ctype.void) false

(* Tags and members *)

let anonymous_inner = Ctype.declare_record tags Union None
let with_anonymous = Ctype.declare_record tags Struct (Some "outer")

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

let anonymous_with_array = Ctype.declare_record tags Struct None

let () =
  get
    (Ctype.define_record lp64 tags anonymous_with_array
       [ member (Some "y") (array int_type (Constant 3)) ])

let definition_outcome kind members =
  let tag = Ctype.declare_record tags kind None in
  error_of (Ctype.define_record lp64 tags tag members)

let flexible = array int_type Unknown
let self_referential = Ctype.declare_record tags Struct (Some "node")

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
       [ member ~bit_field_width:2 (Some "b") (Ctype.integer Bool) ],
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

let member_type name =
  Option.map
    (fun (member : Ctype.member) -> member.member_type)
    (Ctype.find_member tags with_anonymous name)

let member_facts () =
  check "named member" (member_type "first") (Some char_type)
  && check "member of a const anonymous member" (member_type "b")
       (Some (qualify const float_type))
  && check "bit-field width"
       (Option.map
          (fun (member : Ctype.member) -> member.bit_field_width)
          (Ctype.find_member tags with_anonymous "bits"))
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
    ("char, signed char", char_type, Ctype.integer Signed_char, None);
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
     Some (Ctype.enum enum_u));
    ("unsigned int, enum u", unsigned_type, Ctype.enum enum_u,
     Some (Ctype.enum enum_u));
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
  check name (Ctype.composite lp64 tags a b) expected_composite
  && check (name ^ ", compatible") (Ctype.compatible lp64 tags b a)
       (Option.is_some expected)

let unsigned_short_parameter () =
  check "int(unsigned short), int() on a 16-bit int target"
    (Ctype.compatible int16 tags
       (func int_type (prototype [ Ctype.integer Unsigned_short ]))
       (func int_type Unspecified))
    false

(* Printing *)

let printing_cases : (Ctype.t * string) list =
  [
    (int_type, "int");
    (Ctype.integer Unsigned_long, "unsigned long");
    (Ctype.integer Unsigned_int128, "unsigned __int128");
    (Ctype.arithmetic (Complex Double), "_Complex double");
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

let () =
  let results =
    [ check_ranks (); floating_promotions (); construction_facts ();
      member_facts (); doubling_typedefs (); oversized_composite ();
      unsigned_short_parameter (); declaration_facts () ]
    @ List.map check_promotion promotion_cases
    @ List.map check_conversion conversion_cases
    @ List.map check_enum enum_cases
    @ List.map check_construction construction_errors
    @ List.map check_definition definition_cases
    @ List.map check_composite composite_cases
    @ List.map check_printing printing_cases
  in
  if List.mem false results then exit 1
