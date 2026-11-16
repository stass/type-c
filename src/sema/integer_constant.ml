(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
module Tree = Typec_syntax.Tree

type value = Known of Exact_integer.t | Opaque
type t = { integer_type : Integer.t; value : value }

type error =
  | Overflow
  | Division_by_zero
  | Shift_out_of_range
  | Too_large
  | Imaginary
  | Invalid_character of Escape.error
  | Character_too_large
  | Multiple_characters
  | Empty_character

let opaque integer_type = { integer_type; value = Opaque }
let width = Target.integer_width

let minimum target integer =
  if Target.is_signed target integer then
    Exact_integer.neg (Exact_integer.power_of_two (width target integer - 1))
  else Exact_integer.zero

let maximum target integer =
  let value_bits =
    if Target.is_signed target integer then width target integer - 1
    else width target integer
  in
  Exact_integer.sub (Exact_integer.power_of_two value_bits) Exact_integer.one

let fits target integer x =
  Exact_integer.compare x (minimum target integer) >= 0
  && Exact_integer.compare x (maximum target integer) <= 0

(* Modulo 2^N, then the upper half of a signed type's range wraps to its
   negative values. *)
let wrap target integer x =
  let bits = width target integer in
  let low_bits = Exact_integer.modulo_power_of_two x bits in
  if fits target integer low_bits then low_bits
  else Exact_integer.sub low_bits (Exact_integer.power_of_two bits)

let known target integer x =
  match integer with
  | Integer.Bool ->
      let truth = not (Exact_integer.equal x Exact_integer.zero) in
      let value = Exact_integer.of_int (Bool.to_int truth) in
      { integer_type = Bool; value = Known value }
  | _ -> { integer_type = integer; value = Known (wrap target integer x) }

let convert target integer constant =
  match constant.value with
  | Known x -> known target integer x
  | Opaque -> opaque integer

let truth constant =
  match constant.value with
  | Known x -> Some (not (Exact_integer.equal x Exact_integer.zero))
  | Opaque -> None

(* The result of an arithmetic operation, computed exactly in [integer]. *)
let arithmetic_result target integer x =
  if Target.is_signed target integer && not (fits target integer x) then
    Error Overflow
  else Ok (known target integer x)

let of_truth target integer truth =
  known target integer (Exact_integer.of_int (Bool.to_int truth))

(* 6.5.8p3, 6.5.9p4: the operands of a comparison are compared in their
   common type, which is no type of the comparison's value. *)
let compared_type target a b =
  match
    Arithmetic.usual_arithmetic_conversions target
      (Arithmetic.promote target (Integer a.integer_type))
      (Arithmetic.promote target (Integer b.integer_type))
  with
  | Integer integer -> integer
  | Real _ | Complex _ ->
      invalid_arg "Integer_constant: integer operands convert to an integer"

(* Applies [operation] to the values of the operands, or gives an opaque
   [integer] when one is opaque. *)
let with_value integer operation operand =
  match operand.value with
  | Known x -> operation x
  | Opaque -> Ok (opaque integer)

let with_values integer operation left right =
  match (left.value, right.value) with
  | Known x, Known y -> operation x y
  | Opaque, _ | _, Opaque -> Ok (opaque integer)

(* A failed operation has an opaque value: what it has where it is not
   evaluated, and its undefined behaviour no error (6.6p3, p11). *)
let settle integer = function
  | Ok value -> (value, None)
  | Error error -> (opaque integer, Some error)

(* Unary operators *)

(* The operators below compute a value of the result type [integer] that
   typing decides. *)
let unary_value target integer operator operand =
  match (operator : Tree.unary_operator) with
  | Unary_plus ->
      with_value integer (fun x -> Ok (known target integer x)) operand
  | Unary_minus ->
      with_value integer
        (fun x -> arithmetic_result target integer (Exact_integer.neg x))
        operand
  (* In two's complement ~x is -x - 1, which is always in range. *)
  | Bitwise_not ->
      with_value integer
        (fun x ->
          let complement =
            Exact_integer.sub (Exact_integer.neg x) Exact_integer.one
          in
          Ok (known target integer complement))
        operand
  | Logical_not -> (
      match truth operand with
      | Some truth -> Ok (of_truth target integer (not truth))
      | None -> Ok (opaque integer))
  | Address | Indirection | Pre_increment | Pre_decrement | Real_part
  | Imaginary_part ->
      invalid_arg "Integer_constant.unary"

(* Binary operators *)

let divide target integer ~remainder x y =
  if Exact_integer.equal y Exact_integer.zero then Error Division_by_zero
  else
    (* 6.5.5p6: a remainder is undefined where its quotient overflows. *)
    let quotient = arithmetic_result target integer (Exact_integer.div x y) in
    if remainder then
      Result.map
        (fun _ -> known target integer (Exact_integer.rem x y))
        quotient
    else quotient

(* The bits of the operands in [integer], combined and read back. *)
let bitwise target integer operation x y =
  let bits = width target integer in
  let representative v = Exact_integer.modulo_power_of_two v bits in
  Ok (known target integer (operation (representative x) (representative y)))

(* 6.5.7: [integer] is the type of the promoted left operand, whatever the
   type of the count. *)
let shift target integer ~left_shift left right =
  let shifted x count =
    if left_shift then Exact_integer.mul x (Exact_integer.power_of_two count)
    else Exact_integer.floor_shift_right x count
  in
  with_values integer
    (fun x count ->
      match Exact_integer.to_int count with
      | Some count when count >= 0 && count < width target integer ->
          Ok (known target integer (shifted x count))
      | Some _ | None -> Error Shift_out_of_range)
    left right

let compare_with operator order =
  match (operator : Tree.binary_operator) with
  | Less_than -> order < 0
  | Greater_than -> order > 0
  | Less_or_equal -> order <= 0
  | Greater_or_equal -> order >= 0
  | Equal_to -> order = 0
  | Not_equal_to -> order <> 0
  | _ -> invalid_arg "Integer_constant.compare_with"

(* A decisive left operand gives the value without the right one. *)
let logical target integer ~decisive left right =
  match (truth left, truth right) with
  | Some l, _ when l = decisive -> Ok (of_truth target integer decisive)
  | Some _, Some r -> Ok (of_truth target integer r)
  | Some _, None | None, _ -> Ok (opaque integer)

(* An operator of the usual arithmetic conversions on the values of its
   operands converted to their common type [integer], its result type. *)
let arithmetic_operation target integer operator x y =
  match (operator : Tree.binary_operator) with
  | Multiply -> arithmetic_result target integer (Exact_integer.mul x y)
  | Divide -> divide target integer ~remainder:false x y
  | Remainder -> divide target integer ~remainder:true x y
  | Add -> arithmetic_result target integer (Exact_integer.add x y)
  | Subtract -> arithmetic_result target integer (Exact_integer.sub x y)
  | Bitwise_and -> bitwise target integer Exact_integer.logand x y
  | Bitwise_xor -> bitwise target integer Exact_integer.logxor x y
  | Bitwise_or -> bitwise target integer Exact_integer.logor x y
  | _ -> invalid_arg "Integer_constant.arithmetic_operation"

let binary_value target integer operator left right =
  match (operator : Tree.binary_operator) with
  | Shift_left -> shift target integer ~left_shift:true left right
  | Shift_right -> shift target integer ~left_shift:false left right
  | Logical_and -> logical target integer ~decisive:false left right
  | Logical_or -> logical target integer ~decisive:true left right
  | Less_than | Greater_than | Less_or_equal | Greater_or_equal | Equal_to
  | Not_equal_to ->
      let compared = compared_type target left right in
      let order x y = compare_with operator (Exact_integer.compare x y) in
      with_values integer
        (fun x y -> Ok (of_truth target integer (order x y)))
        (convert target compared left) (convert target compared right)
  | Multiply | Divide | Remainder | Add | Subtract | Bitwise_and | Bitwise_xor
  | Bitwise_or ->
      with_values integer
        (arithmetic_operation target integer operator)
        (convert target integer left) (convert target integer right)

let conditional target ~result condition if_true if_false =
  match truth condition with
  | Some true -> convert target result if_true
  | Some false -> convert target result if_false
  | None -> opaque result

let unary target ~result operator operand =
  settle result (unary_value target result operator operand)

let binary target ~result operator left right =
  settle result (binary_value target result operator left right)

(* Integer constants (6.4.4.1) *)

(* The types that a constant may have, in order (6.4.4.1p5). A decimal
   constant without [u] has only signed types. *)
let candidate_types base (suffix : Number.integer_suffix) =
  let decimal = base = Number.Decimal in
  let open Integer in
  match (suffix.unsigned, suffix.length) with
  | false, Not_long when decimal -> [ Int; Long; Long_long ]
  | false, Not_long ->
      [ Int; Unsigned_int; Long; Unsigned_long; Long_long; Unsigned_long_long ]
  | false, Long when decimal -> [ Long; Long_long ]
  | false, Long -> [ Long; Unsigned_long; Long_long; Unsigned_long_long ]
  | false, Long_long when decimal -> [ Long_long ]
  | false, Long_long -> [ Long_long; Unsigned_long_long ]
  | true, Not_long -> [ Unsigned_int; Unsigned_long; Unsigned_long_long ]
  | true, Long -> [ Unsigned_long; Unsigned_long_long ]
  | true, Long_long -> [ Unsigned_long_long ]

let radix = function
  | Number.Binary -> 2
  | Number.Octal -> 8
  | Number.Decimal -> 10
  | Number.Hexadecimal -> 16

(* No type of a list is wider than the widest of the target, whose value
   has at most as many digits as bits in any base, which bounds the work
   on a huge constant. *)
let max_significant_digits = Target.max_integer_width

let without_leading_zeros digits =
  let length = String.length digits in
  let rec first_nonzero index =
    if index < length && digits.[index] = '0' then first_nonzero (index + 1)
    else index
  in
  let start = first_nonzero 0 in
  String.sub digits start (length - start)

let of_integer_constant target base digits (suffix : Number.integer_suffix) =
  let significant = without_leading_zeros digits in
  if suffix.imaginary then Error Imaginary
  else if String.length significant > max_significant_digits then
    Error Too_large
  else
    let value = Exact_integer.of_digits ~base:(radix base) significant in
    match
      List.find_opt
        (fun integer -> fits target integer value)
        (candidate_types base suffix)
    with
    | Some integer -> Ok { integer_type = integer; value = Known value }
    | None -> Error Too_large

(* Character constants (6.4.4.4) *)

(* The type of a constant with [encoding] and the type of its code
   unit. *)
let character_types target (encoding : Token.encoding) =
  match encoding with
  | Plain -> (Integer.Int, Integer.Unsigned_char)
  | Wide -> (target.Target.wchar_type, Integer.to_unsigned target.wchar_type)
  | Char16 -> (target.char16_type, Integer.to_unsigned target.char16_type)
  | Char32 -> (target.char32_type, Integer.to_unsigned target.char32_type)
  | Utf8 -> invalid_arg "Integer_constant: a character constant has no u8"

(* The code unit of one element, in a type whose largest unit is
   [max_unit]. A plain constant takes only the basic character set, as
   Clang does. *)
let code_unit (encoding : Token.encoding) max_unit = function
  | Escape.Code_unit unit -> Ok unit
  | Escape.Code_point point when encoding = Plain && point >= 0x80 ->
      Error Character_too_large
  | Escape.Code_point point when point > max_unit -> Error Character_too_large
  | Escape.Code_point point -> Ok point

(* The bytes of a multicharacter constant, first most significant. Only
   the low bits of int stay, which bounds the work on a long constant. *)
let multicharacter target units =
  let byte_value = Exact_integer.power_of_two target.Target.char_bit in
  let int_bits = width target Int in
  let append value unit =
    let shifted = Exact_integer.mul value byte_value in
    Exact_integer.modulo_power_of_two
      (Exact_integer.add shifted (Exact_integer.of_int unit))
      int_bits
  in
  known target Int (List.fold_left append Exact_integer.zero units)

let character_value target encoding units =
  let constant_type, unit_type = character_types target encoding in
  match units with
  | [] -> Error Empty_character
  | [ unit ] when encoding = Token.Plain ->
      (* The value of the char, then converted to int. *)
      let char_value = known target Char (Exact_integer.of_int unit) in
      Ok (convert target constant_type char_value)
  | [ unit ] ->
      let unit_value = known target unit_type (Exact_integer.of_int unit) in
      Ok (convert target constant_type unit_value)
  | _ :: _ :: _ when encoding = Token.Plain -> Ok (multicharacter target units)
  | _ :: _ :: _ -> Error Multiple_characters

let of_character_constant target encoding spelling =
  let _, unit_type = character_types target encoding in
  let max_unit =
    match Exact_integer.to_int (maximum target unit_type) with
    | Some max_unit -> max_unit
    | None -> invalid_arg "Integer_constant: a code unit wider than int"
  in
  let open_quote = String.index spelling '\'' in
  let text =
    String.sub spelling (open_quote + 1)
      (String.length spelling - open_quote - 2)
  in
  let add_unit units element =
    Result.bind units (fun units ->
        Result.map
          (fun unit -> unit :: units)
          (code_unit encoding max_unit element))
  in
  match Escape.decode ~max_code_unit:max_unit text with
  | Error error -> Error (Invalid_character error)
  | Ok elements ->
      Result.bind
        (List.fold_left add_unit (Ok []) elements)
        (fun units -> character_value target encoding (List.rev units))

let error_message = function
  | Overflow ->
      "the value of a constant expression is outside the range of its type \
       (C11 6.6p4)"
  | Division_by_zero ->
      "division by zero in a constant expression (C11 6.5.5p5)"
  | Shift_out_of_range ->
      "shift count is negative or not less than the width of the type \
       (C11 6.5.7p3)"
  | Too_large -> "integer constant is too large for its type (C11 6.4.4.1p6)"
  | Imaginary -> "an imaginary constant is not an integer constant"
  | Invalid_character error -> Escape.error_message error
  | Character_too_large ->
      "character does not fit the code unit of its character constant"
  | Multiple_characters ->
      "a character constant with an encoding prefix holds one character"
  | Empty_character -> "empty character constant (C11 6.4.4.4p1)"
