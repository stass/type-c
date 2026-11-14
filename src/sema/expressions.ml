(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type bit_field = Not_bit_field | Bit_field of int | Bit_field_value of int

type typed = { expression_type : Ctype.t; lvalue : bool; bit_field : bit_field }

(* What encloses the statement being typed: the function, for __func__,
   and the loop or switch that break, continue and case need. *)
type enclosing = {
  function_name : string option;
  in_loop : bool;
  in_switch : bool;
}

(* [depth] and [enclosing] belong to the walk in progress. Only the
   reader's failure leaves a walk early, and it ends the read, so neither
   is restored on it. *)
type t = {
  types : (Tree.span, typed) Hashtbl.t;
  mutable depth : int;
  mutable enclosing : enclosing;
}

let outside_functions =
  { function_name = None; in_loop = false; in_switch = false }

let create () =
  { types = Hashtbl.create 4096; depth = 0; enclosing = outside_functions }

let find view (expression : Tree.expression) =
  Hashtbl.find_opt view.types expression.span

type context = {
  typed : t;
  target : Target.t;
  text : Reader.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> string -> 'a;
  entity : Tree.span -> string -> Tree.reference -> Entity.t;
  overloaded : Tree.reference -> bool;
  type_name : Tree.type_name -> Ctype.t;
  declaration : Tree.declaration -> unit;
  constant : evaluated:bool -> Tree.expression -> Integer_constant.t option;
}

(* Far above the nesting of real code, it bounds the recursion on the
   chains that the parser reads in loops (operators, else-if), whose
   trees are as deep as they are long. *)
let max_depth = 10_000

let max_quoted = 64

let quote text =
  if String.length text <= max_quoted then "'" ^ text ^ "'"
  else "'" ^ String.sub text 0 max_quoted ^ "...'"

(* [walk] one level deeper. *)
let nested context span walk =
  let view = context.typed in
  if view.depth >= max_depth then
    context.fail span "an expression or statement is nested too deeply";
  view.depth <- view.depth + 1;
  let result = walk () in
  view.depth <- view.depth - 1;
  result

let within context enclosing walk =
  let view = context.typed in
  let saved = view.enclosing in
  view.enclosing <- enclosing;
  walk ();
  view.enclosing <- saved

(* Building results *)

let checked context span = function
  | Ok t -> t
  | Error error -> context.fail span (Ctype.error_message error)

let value expression_type =
  { expression_type; lvalue = false; bit_field = Not_bit_field }

let lvalue expression_type =
  { expression_type; lvalue = true; bit_field = Not_bit_field }

(* The width that the integer promotions of the value use (6.3.1.1p2). *)
let promotion_width = function
  | Bit_field width | Bit_field_value width -> Some width
  | Not_bit_field -> None

(* What the value of an expression of [bit_field] is: GCC and Clang
   promote the value of an assignment to a bit-field, of a prefix [++] of
   one and of a comma whose right operand is one by its width. *)
let value_of = function
  | Bit_field width | Bit_field_value width -> Bit_field_value width
  | Not_bit_field -> Not_bit_field

let designates_bit_field typed =
  match typed.bit_field with
  | Bit_field _ -> true
  | Bit_field_value _ | Not_bit_field -> false

let arithmetic_type context span arithmetic =
  checked context span (Ctype.arithmetic context.target arithmetic)

let integer_type context span integer =
  checked context span (Ctype.integer context.target integer)

let int_type context span = integer_type context span Integer.Int

(* 6.5.3.4p5. *)
let size_type context span =
  integer_type context span context.target.size_type

let void_pointer context span =
  checked context span (Ctype.pointer_to Ctype.void)

let unknown context (span : Tree.span) construct kind =
  let location = context.text.tokens.(span.first).location in
  Ctype.unknown { construct; location; kind }

(* The value of an operation on an operand of unknown type: unknown in
   turn, and an object, as no operator gives a function. *)
let unknown_value (unknown : Ctype.unknown) =
  Ctype.unknown { unknown with kind = Unknown_object }

let fail_operands context span clause =
  context.fail span
    ("the operands have types that the operator does not take (C11 " ^ clause
   ^ ")")

(* Operands (6.3.2.1, 6.3.1.1) *)

(* The value of an operand, after lvalue conversion, by what the
   operators ask of it. An arithmetic operand keeps its type and its
   promoted type; an enumerated type is its compatible integer type. *)
type operand =
  | Arithmetic_operand of {
      arithmetic : Arithmetic.t;
      promoted : Arithmetic.promoted;
    }
  | Pointer_operand of { pointer : Ctype.t; referenced : Ctype.t }
  | Unknown_operand of Ctype.unknown
  | Other_operand of Ctype.t
      (** void, a structure or union, [va_list], an incomplete enumeration *)

let operand context (typed : typed) =
  let t = Ctype.lvalue_conversion typed.expression_type in
  match t.shape with
  | Pointer referenced -> Pointer_operand { pointer = t; referenced }
  | Unknown_type unknown -> Unknown_operand unknown
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list | Array _ | Function _
    -> (
      match Ctype.as_arithmetic context.tags t with
      | Answer (Some arithmetic) ->
          let promoted =
            Arithmetic.promote context.target
              ?bit_field_width:(promotion_width typed.bit_field) arithmetic
          in
          Arithmetic_operand { arithmetic; promoted }
      | Answer None -> Other_operand t
      | Depends_on unknown -> Unknown_operand unknown)

let is_integer : Arithmetic.t -> bool = function
  | Integer _ -> true
  | Real _ | Complex _ -> false

let is_real : Arithmetic.t -> bool = function
  | Integer _ | Real _ -> true
  | Complex _ -> false

let promoted_type context span (promoted : Arithmetic.promoted) =
  arithmetic_type context span (promoted :> Arithmetic.t)

(* 6.3.1.8. *)
let converted context span (left : Arithmetic.promoted) right =
  arithmetic_type context span
    (Arithmetic.usual_arithmetic_conversions context.target left right)

(* 6.3.2.1p1: an lvalue that may be assigned. That of a structure with a
   const member is the backend's to refuse, as is an incomplete one. *)
let require_modifiable context span ~clause (typed : typed) =
  let t = typed.expression_type in
  match t.shape with
  | Unknown_type _ -> ()
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
  | Function _ ->
      if not typed.lvalue then
        context.fail span ("the operand is not an lvalue (C11 " ^ clause ^ ")");
      if t.qualifiers.const || Ctype.is_array t = Answer true then
        context.fail span
          ("the operand is not a modifiable lvalue (C11 " ^ clause ^ ")")

let require_scalar context span ~clause typed =
  match operand context typed with
  | Arithmetic_operand _ | Pointer_operand _ | Unknown_operand _ -> ()
  | Other_operand _ ->
      context.fail span
        ("the operand is not of scalar type (C11 " ^ clause ^ ")")

(* Constants (6.4.4, 6.4.5) *)

let spelling context (span : Tree.span) =
  Reader.spelling context.text context.text.tokens.(span.first)

let constant_type context span (number : Number.t) =
  match number with
  | Integer { base; digits; suffix } -> (
      match
        Integer_constant.of_integer_constant context.target base digits suffix
      with
      | Ok constant -> integer_type context span constant.integer_type
      (* GNU [_Complex int], which typec does not model. *)
      | Error Imaginary ->
          unknown context span "an imaginary integer constant" Unknown_object
      | Error error ->
          context.fail span (Integer_constant.error_message error))
  | Floating { suffix = { floating_type; imaginary } } ->
      let floating : Arithmetic.floating =
        match floating_type with
        | Float -> Float
        | Double -> Double
        | Long_double -> Long_double
      in
      if imaginary then arithmetic_type context span (Complex floating)
      else arithmetic_type context span (Real floating)
  | Not_a_constant -> invalid_arg "Expressions: a constant that is not one"

let character_type context span encoding =
  match
    Integer_constant.of_character_constant context.target encoding
      (spelling context span)
  with
  | Ok constant -> integer_type context span constant.integer_type
  | Error error -> context.fail span (Integer_constant.error_message error)

(* 6.4.5p5, p2: joined literals have the prefix that one of them has. *)
let joined_encoding context (literal : Tree.string_literal) =
  let prefixed =
    List.filter_map
      (fun (piece : Token.encoding Tree.spanned) ->
        if piece.node = Plain then None else Some piece.node)
      literal
  in
  match List.sort_uniq compare prefixed with
  | [] -> Token.Plain
  | [ encoding ] -> encoding
  | _ :: _ :: _ ->
      context.fail (List.hd literal).span
        "string literals with different encoding prefixes are joined (C11 \
         6.4.5p2)"

(* 6.4.5p6: the code unit of a string literal of [encoding]; that of [u8]
   is [char8_t] from C23 on. *)
let code_unit_type context (encoding : Token.encoding) : Integer.t =
  let target = context.target in
  match encoding with
  | Plain -> Char
  | Utf8 when target.stdc_version > 201710 -> Unsigned_char
  | Utf8 -> Char
  | Char16 -> target.char16_type
  | Char32 -> target.char32_type
  | Wide -> target.wchar_type

let utf8_length code_point =
  if code_point < 0x80 then 1
  else if code_point < 0x800 then 2
  else if code_point < 0x10000 then 3
  else 4

(* The code units of one string literal token: a character takes those of
   UTF-8, UTF-16 or UTF-32 by the width of the unit, an octal or
   hexadecimal escape one. *)
let code_units context unit_width (piece : Token.encoding Tree.spanned) =
  let spelled = spelling context piece.span in
  let open_quote = String.index spelled '"' in
  let text =
    String.sub spelled (open_quote + 1) (String.length spelled - open_quote - 2)
  in
  let units = function
    | Escape.Code_unit _ -> 1
    | Code_point _ when unit_width >= 21 -> 1
    | Code_point point when unit_width >= 16 -> if point > 0xFFFF then 2 else 1
    | Code_point point -> utf8_length point
  in
  let max_code_unit = (1 lsl unit_width) - 1 in
  match Escape.decode ~max_code_unit text with
  | Ok elements -> List.fold_left (fun total e -> total + units e) 0 elements
  | Error error -> context.fail piece.span (Escape.error_message error)

(* 6.4.5p6: an array of code units with room for the terminating null,
   an lvalue (6.5.1p4). *)
let string_type context (literal : Tree.string_literal) =
  let span = (List.hd literal).span in
  let unit = code_unit_type context (joined_encoding context literal) in
  let unit_width = Target.integer_width context.target unit in
  let length =
    List.fold_left
      (fun total piece -> total + code_units context unit_width piece)
      1 literal
  in
  checked context span
    (Ctype.array_of context.tags (integer_type context span unit)
       (Constant length))

(* Identifiers (6.5.1p2, 6.4.2.2) *)

(* An identifier that the implementation reserves (C11 7.1.3p1) may name
   one of the backend's builtins without a declaration, such as
   [__builtin_memcpy]; typec has no table of them yet (0.7b), so it takes
   every such name as one, of unknown type. *)
let may_be_builtin name = String.starts_with ~prefix:"__" name

let const_char context span =
  let const = { Ctype.no_qualifiers with const = true } in
  checked context span
    (Ctype.qualify const (integer_type context span Integer.Char))

(* 6.4.2.2p1: [__func__] is a [static const char] array that holds the
   name of the function, as [__FUNCTION__] is in GCC and Clang; Clang
   gives [__PRETTY_FUNCTION__] a signature, so its length is the
   backend's. *)
let predefined context span name =
  let name_array length =
    lvalue
      (checked context span
         (Ctype.array_of context.tags (const_char context span) length))
  in
  match (name, context.typed.enclosing.function_name) with
  | ("__func__" | "__FUNCTION__"), Some function_name ->
      name_array (Constant (String.length function_name + 1))
  | "__PRETTY_FUNCTION__", Some _ -> name_array Opaque
  | _ when may_be_builtin name ->
      value
        (unknown context span ("the builtin " ^ quote name) Object_or_function)
  | _ -> context.fail span (quote name ^ " is not declared (C11 6.5.1p2)")

let identifier context span name (resolution : Tree.resolution) =
  match resolution with
  | Undeclared -> predefined context span name
  | Resolved reference -> (
      match (context.entity span name reference).declared with
      (* typec does not resolve overloads, so the one a use names is
         unknown. *)
      | Function _ when context.overloaded reference ->
          value
            (unknown context span ("the overloaded " ^ quote name)
               Unknown_function)
      | Object { object_type; _ } -> lvalue object_type
      | Function { function_type; _ } -> value function_type
      | Enumerator { enumerator_type; _ } -> value enumerator_type
      | Typedef _ -> invalid_arg "Expressions: a typedef name as an operand")

(* Members (6.5.2.3) *)

(* 6.5.2.3p3, p4: the member, qualified as the structure is but for
   _Atomic, whose members are not accessed (p5). *)
let member_of context tag (qualifiers : Ctype.qualifiers)
    (name : Tree.identifier) ~lvalue =
  if Ctype.record_members context.tags tag = None then
    context.fail name.span
      "a member of an incomplete structure or union (C11 6.5.2.3p1)";
  match Ctype.find_member context.tags tag name.node with
  | None ->
      context.fail name.span
        (quote name.node ^ " is not a member of the structure or union (C11 \
                            6.5.2.3p1)")
  | Some member ->
      let qualifiers = { qualifiers with atomic = false; restrict = false } in
      let expression_type =
        checked context name.span (Ctype.qualify qualifiers member.member_type)
      in
      let bit_field =
        match member.bit_field_width with
        | Some width -> Bit_field width
        | None -> Not_bit_field
      in
      { expression_type; lvalue; bit_field }

let direct_member context span (record : typed) name =
  let t = record.expression_type in
  match t.shape with
  | Record tag -> member_of context tag t.qualifiers name ~lvalue:record.lvalue
  | Unknown_type unknown ->
      { (value (unknown_value unknown)) with lvalue = record.lvalue }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Va_list | Array _ | Function _
    ->
      context.fail span
        "the operand of '.' is not a structure or union (C11 6.5.2.3p1)"

let pointer_member context span (pointer : typed) name =
  match operand context pointer with
  | Pointer_operand { referenced = { shape = Record tag; qualifiers; _ }; _ } ->
      member_of context tag qualifiers name ~lvalue:true
  | Pointer_operand { referenced = { shape = Unknown_type unknown; _ }; _ }
  | Unknown_operand unknown ->
      lvalue (unknown_value unknown)
  | Pointer_operand _ | Arithmetic_operand _ | Other_operand _ ->
      context.fail span
        "the operand of '->' is not a pointer to a structure or union (C11 \
         6.5.2.3p2)"

(* Postfix and unary operators (6.5.2, 6.5.3) *)

(* 6.5.2.1: [a[i]] is [*(a + i)], an lvalue. *)
let subscript context span array index =
  match (operand context array, operand context index) with
  | ( Pointer_operand { referenced; _ },
      Arithmetic_operand { arithmetic = Integer _; _ } )
  | ( Arithmetic_operand { arithmetic = Integer _; _ },
      Pointer_operand { referenced; _ } ) ->
      lvalue referenced
  | Unknown_operand unknown, _ | _, Unknown_operand unknown ->
      lvalue (unknown_value unknown)
  | (Pointer_operand _ | Arithmetic_operand _ | Other_operand _), _ ->
      fail_operands context span "6.5.2.1p1"

(* 6.5.2.2p2: as many arguments as a prototype has parameters, or more
   where it is variadic. *)
let check_arity context span (parameters : Ctype.parameters) count =
  match parameters with
  | Prototype { types; variadic } ->
      let expected = List.length types in
      if count < expected || (count > expected && not variadic) then
        context.fail span
          "a call has a number of arguments that its prototype does not take \
           (C11 6.5.2.2p2)"
  | Unspecified | Old_style _ -> ()

(* 6.5.2.2p1, p5: the callee is a pointer to a function, after the
   conversion of a function designator; the call has its return type. *)
let call_type context span (callee : typed) count =
  match operand context callee with
  | Pointer_operand
      { referenced = { shape = Function { return; parameters }; _ }; _ } ->
      check_arity context span parameters count;
      return
  | Pointer_operand { referenced = { shape = Unknown_type unknown; _ }; _ }
  | Unknown_operand unknown ->
      unknown_value unknown
  | Pointer_operand _ | Arithmetic_operand _ | Other_operand _ ->
      context.fail span
        "the called expression is not a function or a pointer to one (C11 \
         6.5.2.2p1)"

(* 6.5.2.4p1, p2 and 6.5.3.1p1, p2: a modifiable lvalue of real or
   pointer type, whose value the result is; GNU C takes a complex one. *)
let increment context span ~clause (typed : typed) =
  require_modifiable context span ~clause typed;
  match operand context typed with
  | Arithmetic_operand _ | Pointer_operand _ ->
      value (Ctype.lvalue_conversion typed.expression_type)
  | Unknown_operand unknown -> value (unknown_value unknown)
  | Other_operand _ -> fail_operands context span clause

(* 6.5.3.2p1, p3: of a function designator, or of an lvalue other than a
   bit-field. *)
let address context span (typed : typed) =
  let t = typed.expression_type in
  if designates_bit_field typed then
    context.fail span "the address of a bit-field (C11 6.5.3.2p1)";
  if (not typed.lvalue) && Ctype.is_function t = Answer false then
    context.fail span "the address of what is not an lvalue (C11 6.5.3.2p1)";
  value (checked context span (Ctype.pointer_to t))

(* 6.5.3.2p2, p4: an lvalue, or a function designator. *)
let indirection context span typed =
  match operand context typed with
  | Pointer_operand { referenced; _ } ->
      { (value referenced) with
        lvalue = Ctype.is_function referenced <> Answer true }
  | Unknown_operand unknown ->
      lvalue (Ctype.unknown { unknown with kind = Object_or_function })
  | Arithmetic_operand _ | Other_operand _ ->
      context.fail span
        "the operand of unary '*' is not a pointer (C11 6.5.3.2p2)"

let is_real_floating (arithmetic : Arithmetic.t) =
  match arithmetic with
  | Real _ -> true
  | Integer _ | Complex _ -> false

(* 6.5.3.3p1, p2: [+] and [-] of an arithmetic operand, [~] of an integer,
   or in GNU C of a complex value, its conjugate. *)
let arithmetic_unary context span ~integer typed =
  match operand context typed with
  | Arithmetic_operand { arithmetic; promoted }
    when not (integer && is_real_floating arithmetic) ->
      value (promoted_type context span promoted)
  | Unknown_operand unknown -> value (unknown_value unknown)
  | Arithmetic_operand _ | Pointer_operand _ | Other_operand _ ->
      fail_operands context span "6.5.3.3p1"

(* GNU [__real__] and [__imag__]: a part of a complex value, of the
   floating type of the parts, or a real operand's own type; an lvalue
   where the operand is one, but for the imaginary part of a real value,
   which is a zero. *)
let complex_part context span ~imaginary (typed : typed) =
  let t = typed.expression_type in
  match operand context typed with
  | Arithmetic_operand { arithmetic = Complex floating; _ } ->
      let part = arithmetic_type context span (Real floating) in
      let part = checked context span (Ctype.qualify t.qualifiers part) in
      { typed with expression_type = part; bit_field = Not_bit_field }
  | Arithmetic_operand _ when imaginary ->
      value (Ctype.lvalue_conversion t)
  | Arithmetic_operand _ -> { typed with bit_field = Not_bit_field }
  | Unknown_operand unknown ->
      { typed with expression_type = unknown_value unknown }
  | Pointer_operand _ | Other_operand _ ->
      context.fail span
        "the operand of __real__ or __imag__ is not arithmetic"

(* Binary operators (6.5.5 to 6.5.14) *)

(* The usual arithmetic conversions of two arithmetic operands, each of
   an integer type where [integer] says so. *)
let arithmetic_binary context span ~integer ~clause left right =
  match (left, right) with
  | Arithmetic_operand a, Arithmetic_operand b
    when (not integer) || (is_integer a.arithmetic && is_integer b.arithmetic)
    ->
      converted context span a.promoted b.promoted
  | Unknown_operand unknown, _ | _, Unknown_operand unknown ->
      unknown_value unknown
  | (Arithmetic_operand _ | Pointer_operand _ | Other_operand _), _ ->
      fail_operands context span clause

(* 6.5.6p2, p8: GNU C takes a pointer to void or to a function too. *)
let addition context span left right =
  match (left, right) with
  | ( Pointer_operand { pointer; _ },
      Arithmetic_operand { arithmetic = Integer _; _ } )
  | ( Arithmetic_operand { arithmetic = Integer _; _ },
      Pointer_operand { pointer; _ } ) ->
      pointer
  | _ ->
      arithmetic_binary context span ~integer:false ~clause:"6.5.6p2" left
        right

(* 6.5.6p3, p8, p9. *)
let subtraction context span left right =
  match (left, right) with
  | Pointer_operand _, Pointer_operand _ ->
      integer_type context span context.target.ptrdiff_type
  | ( Pointer_operand { pointer; _ },
      Arithmetic_operand { arithmetic = Integer _; _ } ) ->
      pointer
  | _ ->
      arithmetic_binary context span ~integer:false ~clause:"6.5.6p3" left
        right

(* 6.5.7p2, p3: the type of the promoted left operand. *)
let shift context span left right =
  match (left, right) with
  | ( Arithmetic_operand { arithmetic = Integer _; promoted },
      Arithmetic_operand { arithmetic = Integer _; _ } ) ->
      promoted_type context span promoted
  | Unknown_operand unknown, _ | _, Unknown_operand unknown ->
      unknown_value unknown
  | (Arithmetic_operand _ | Pointer_operand _ | Other_operand _), _ ->
      fail_operands context span "6.5.7p2"

(* 6.5.8p2, p6 and 6.5.9p2, p3: an int. GNU C compares a pointer with an
   integer too; relations take real operands only. *)
let comparison context span ~relational ~clause left right =
  let takes = function
    | Arithmetic_operand { arithmetic; _ } ->
        (not relational) || is_real arithmetic
    | Pointer_operand _ | Unknown_operand _ -> true
    | Other_operand _ -> false
  in
  if not (takes left && takes right) then fail_operands context span clause;
  int_type context span

(* 6.5.13p2, p3 and 6.5.14p2, p3. *)
let logical context span ~clause left right =
  let takes = function
    | Arithmetic_operand _ | Pointer_operand _ | Unknown_operand _ -> true
    | Other_operand _ -> false
  in
  if not (takes left && takes right) then fail_operands context span clause;
  int_type context span

let binary_type context span (op : Tree.binary_operator) left right =
  let left = operand context left and right = operand context right in
  let arithmetic ~integer clause =
    arithmetic_binary context span ~integer ~clause left right
  in
  match op with
  | Multiply | Divide -> arithmetic ~integer:false "6.5.5p2"
  | Remainder -> arithmetic ~integer:true "6.5.5p2"
  | Add -> addition context span left right
  | Subtract -> subtraction context span left right
  | Shift_left | Shift_right -> shift context span left right
  | Less_than | Greater_than | Less_or_equal | Greater_or_equal ->
      comparison context span ~relational:true ~clause:"6.5.8p2" left right
  | Equal_to | Not_equal_to ->
      comparison context span ~relational:false ~clause:"6.5.9p2" left right
  | Bitwise_and -> arithmetic ~integer:true "6.5.10p2"
  | Bitwise_xor -> arithmetic ~integer:true "6.5.11p2"
  | Bitwise_or -> arithmetic ~integer:true "6.5.12p2"
  | Logical_and -> logical context span ~clause:"6.5.13p2" left right
  | Logical_or -> logical context span ~clause:"6.5.14p2" left right

(* The conditional operator (6.5.15) *)

let union_qualifiers (a : Ctype.qualifiers) (b : Ctype.qualifiers) :
    Ctype.qualifiers =
  {
    const = a.const || b.const;
    volatile = a.volatile || b.volatile;
    restrict = a.restrict || b.restrict;
    atomic = a.atomic || b.atomic;
  }

let is_plain_void_pointer (t : Ctype.t) =
  match t.shape with
  | Pointer { shape = Void; qualifiers; _ } -> qualifiers = Ctype.no_qualifiers
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      false

(* 6.5.15p6: a pointer to void, qualified as both referenced types are;
   restrict and _Atomic do not apply to void. *)
let qualified_void_pointer context span (a : Ctype.t) (b : Ctype.t) =
  let both = union_qualifiers a.qualifiers b.qualifiers in
  let qualifiers = { both with restrict = false; atomic = false } in
  let void = checked context span (Ctype.qualify qualifiers Ctype.void) in
  checked context span (Ctype.pointer_to void)

(* 6.5.15p6: pointers to compatible types give a pointer to their
   composite, qualified as both are; GCC and Clang give others a pointer
   to unqualified void. *)
let composite_pointer context span (a : Ctype.t) (b : Ctype.t) =
  match
    Ctype.composite context.target context.tags (Ctype.unqualified a)
      (Ctype.unqualified b)
  with
  | Ok composite ->
      let qualifiers = union_qualifiers a.qualifiers b.qualifiers in
      let referenced =
        checked context span (Ctype.qualify qualifiers composite)
      in
      checked context span (Ctype.pointer_to referenced)
  | Error Incompatible -> void_pointer context span
  | Error error -> context.fail span (Ctype.error_message error)

(* The second and third operands of a conditional: the expression, for
   whether it is a null pointer constant, with its type. *)
type branch = { branch : Tree.expression; branch_typed : typed }

(* Whether an operand is a null pointer constant (6.3.2.3p3); [Opaque]
   where it is one of a value that the backend computes. *)
type null_pointer = Null | Not_null | Opaque_constant

(* The conditional of two objects that are not scalars: void, or two
   structures, unions or va_lists of the same type; GNU C takes void with
   any other operand. *)
let other_conditional context span (a : Ctype.t) (b : Ctype.t) =
  if Ctype.is_void a = Answer true || Ctype.is_void b = Answer true then
    Ctype.void
  else
    match Ctype.compatible context.target context.tags a b with
    | Answer true -> a
    | Depends_on unknown -> unknown_value unknown
    | Answer false -> fail_operands context span "6.5.15p3"

(* Statements (6.8) and the expressions that hold them *)

let rec expression context (expression : Tree.expression) =
  match Hashtbl.find_opt context.typed.types expression.span with
  | Some typed -> typed
  | None ->
      let typed =
        nested context expression.span (fun () ->
            expression_node context expression)
      in
      Hashtbl.replace context.typed.types expression.span typed;
      typed

and expression_node context (whole : Tree.expression) =
  let span = whole.span in
  let typed = expression context in
  match whole.node with
  | Identifier { name; resolution } -> identifier context span name resolution
  | Constant number -> value (constant_type context span number)
  | Character encoding -> value (character_type context span encoding)
  | String literal -> lvalue (string_type context literal)
  | Parenthesized inner -> typed inner
  | Generic { controlling; associations } ->
      generic context span controlling associations
  | Compound_literal { type_name; values } ->
      compound_literal context span type_name values
  | Subscript { operand; index } ->
      let array = typed operand in
      subscript context span array (typed index)
  | Call { callee; arguments } ->
      let callee = typed callee in
      let arguments = List.map typed arguments in
      value (call_type context span callee (List.length arguments))
  | Member { operand; member } ->
      direct_member context span (typed operand) member
  | Pointer_member { operand; member } ->
      pointer_member context span (typed operand) member
  (* The value of a postfix operation is no bit-field in Clang. *)
  | Post_increment operand | Post_decrement operand ->
      increment context span ~clause:"6.5.2.4p1" (typed operand)
  | Unary (op, operand) -> unary context span op (typed operand)
  | Sizeof_expression operand ->
      if designates_bit_field (typed operand) then
        context.fail span "sizeof of a bit-field (C11 6.5.3.4p1)";
      value (size_type context span)
  | Sizeof_type type_name | Alignof type_name ->
      ignore (context.type_name type_name);
      value (size_type context span)
  | Alignof_expression operand ->
      ignore (typed operand);
      value (size_type context span)
  (* 6.5.4p5: the value of a cast has the unqualified type. *)
  | Cast { type_name; operand } ->
      let cast_type = context.type_name type_name in
      ignore (typed operand);
      value (Ctype.unqualified cast_type)
  | Binary (op, left, right) ->
      let left = typed left in
      value (binary_type context span op left (typed right))
  | Conditional { condition; if_true; if_false } ->
      value (conditional context span condition if_true if_false)
  | Assignment (op, left, right) ->
      let left_typed = typed left in
      assignment context span op left_typed (typed right)
  (* 6.5.17p2: the right operand's value. *)
  | Comma (left, right) ->
      ignore (typed left);
      let right = typed right in
      { expression_type = Ctype.lvalue_conversion right.expression_type;
        lvalue = false;
        bit_field = value_of right.bit_field }
  | Statement_expression block -> value (statement_expression context block)
  | Label_address _ -> value (void_pointer context span)
  | Va_arg { list; type_name } ->
      ignore (typed list);
      value (Ctype.unqualified (context.type_name type_name))
  | Offsetof { type_name; member = _; designators } ->
      ignore (context.type_name type_name);
      List.iter (designator context) designators;
      value (size_type context span)
  | Types_compatible (first, second) ->
      ignore (context.type_name first);
      ignore (context.type_name second);
      value (int_type context span)
  (* Clang's block, whose type typec does not model; its body is not
     typed. *)
  | Block_literal _ ->
      value (unknown context span "a block literal" Unknown_object)

(* GNU [__real__] and [__imag__] and the operators of 6.5.3. *)
and unary context span (op : Tree.unary_operator) typed =
  match op with
  | Address -> address context span typed
  | Indirection -> indirection context span typed
  | Unary_plus | Unary_minus ->
      arithmetic_unary context span ~integer:false typed
  | Bitwise_not -> arithmetic_unary context span ~integer:true typed
  | Logical_not ->
      require_scalar context span ~clause:"6.5.3.3p1" typed;
      value (int_type context span)
  | Pre_increment | Pre_decrement ->
      { (increment context span ~clause:"6.5.3.1p1" typed) with
        bit_field = value_of typed.bit_field }
  | Real_part -> complex_part context span ~imaginary:false typed
  | Imaginary_part -> complex_part context span ~imaginary:true typed

(* 0.9b-3 selects the association; until then the selection is of
   unknown type. *)
and generic context span controlling associations =
  ignore (expression context controlling);
  List.iter
    (fun (association : Tree.generic_association) ->
      match association.node with
      | Association (type_name, chosen) ->
          ignore (context.type_name type_name);
          ignore (expression context chosen)
      | Default_association chosen -> ignore (expression context chosen))
    associations;
  value (unknown context span "_Generic" Object_or_function)

(* 6.5.2.5p4: an lvalue of the type name's type. An array of unknown
   length takes it from the initialiser, which typec does not read yet
   (0.9b-2). *)
and compound_literal context span type_name values =
  let t = context.type_name type_name in
  initialiser_list context values;
  match t.shape with
  | Array { length = Unknown; _ } ->
      lvalue
        (unknown context span
           "a compound literal of an array of unknown length" Unknown_object)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      lvalue t

(* 6.5.15p3 to p6. A GNU [a ?: b] has [a] as its second operand. *)
and conditional context span condition if_true if_false =
  let condition_typed = expression context condition in
  require_scalar context condition.span ~clause:"6.5.15p2" condition_typed;
  let second =
    match if_true with
    | Some branch -> { branch; branch_typed = expression context branch }
    | None -> { branch = condition; branch_typed = condition_typed }
  in
  let third =
    { branch = if_false; branch_typed = expression context if_false }
  in
  let second_operand = operand context second.branch_typed in
  match (second_operand, operand context third.branch_typed) with
  | Arithmetic_operand a, Arithmetic_operand b ->
      converted context span a.promoted b.promoted
  | Pointer_operand a, Pointer_operand b ->
      pointer_conditional context span (second, a.referenced)
        (third, b.referenced)
  (* An integer is a null pointer constant, or in GNU C any integer. *)
  | ( Pointer_operand { pointer; _ },
      Arithmetic_operand { arithmetic = Integer _; _ } )
  | ( Arithmetic_operand { arithmetic = Integer _; _ },
      Pointer_operand { pointer; _ } ) ->
      pointer
  | Unknown_operand unknown, _ | _, Unknown_operand unknown ->
      unknown_value unknown
  | Other_operand a, Other_operand b -> other_conditional context span a b
  | Other_operand a, (Arithmetic_operand _ | Pointer_operand _)
    when Ctype.is_void a = Answer true ->
      Ctype.void
  | (Arithmetic_operand _ | Pointer_operand _), Other_operand b
    when Ctype.is_void b = Answer true ->
      Ctype.void
  | (Arithmetic_operand _ | Pointer_operand _ | Other_operand _), _ ->
      fail_operands context span "6.5.15p3"

(* 6.5.15p6: a null pointer constant takes the other operand's type, a
   pointer to void makes the result one. Whether an operand of a value
   that the backend computes is null is unknown, and so is the type. *)
and pointer_conditional context span (second, a) (third, b) =
  let pointer_type branch =
    Ctype.lvalue_conversion branch.branch_typed.expression_type
  in
  let is_void t = Ctype.is_void t = Answer true in
  let null branch referenced =
    if is_void referenced then null_pointer_constant context branch.branch
    else Not_null
  in
  match (null second a, null third b) with
  | Opaque_constant, _ | _, Opaque_constant ->
      unknown context span "a null pointer constant of an opaque value"
        Unknown_object
  | Null, _ -> pointer_type third
  | Not_null, Null -> pointer_type second
  | Not_null, Not_null when is_void a || is_void b ->
      qualified_void_pointer context span a b
  | Not_null, Not_null -> composite_pointer context span a b

(* 6.3.2.3p3: an integer constant expression of value 0, or one cast to
   void *. *)
and null_pointer_constant context (candidate : Tree.expression) =
  match candidate.node with
  | Parenthesized inner -> null_pointer_constant context inner
  | Cast { operand; _ }
    when is_plain_void_pointer (expression context candidate).expression_type
    ->
      zero_constant context operand
  | _ -> zero_constant context candidate

(* Evaluated as an operand that is not evaluated, an operation that would
   fail gives an opaque value rather than an error: this is no constant
   expression context. *)
and zero_constant context candidate =
  let integer =
    Ctype.is_integer (expression context candidate).expression_type
  in
  if integer <> Answer true then Not_null
  else
    match context.constant ~evaluated:false candidate with
    | Some { value = Known value; _ }
      when Exact_integer.equal value Exact_integer.zero ->
        Null
    | Some { value = Opaque; _ } -> Opaque_constant
    | Some { value = Known _; _ } | None -> Not_null

(* 6.5.16p2, p3: the left operand is a modifiable lvalue, whose type after
   lvalue conversion the result has; a compound assignment takes what its
   operator takes (6.5.16.2). *)
and assignment context span (op : Tree.assignment_operator) left right =
  require_modifiable context span ~clause:"6.5.16p2" left;
  (match op with
  | Assign -> ()
  | Compound_assign op -> ignore (binary_type context span op left right));
  { expression_type = Ctype.lvalue_conversion left.expression_type;
    lvalue = false;
    bit_field = value_of left.bit_field }

(* GNU: the value of the last expression statement of the block, or
   void. *)
and statement_expression context (block : Tree.block) =
  block_items context block;
  match List.rev block.node.items with
  | Block_statement { node = Expression_statement last; _ } :: _ ->
      Ctype.lvalue_conversion (expression context last).expression_type
  | (Block_statement _ | Block_declaration _) :: _ | [] -> Ctype.void

and designator context (designator : Tree.designator) =
  match designator.node with
  | Index index -> ignore (expression context index)
  | Index_range { low; high } ->
      ignore (expression context low);
      ignore (expression context high)
  | Member_designator _ -> ()

and initialiser context (initialiser : Tree.initialiser) =
  match initialiser with
  | Expression_initialiser value -> ignore (expression context value)
  | Braced list -> initialiser_list context list

and initialiser_list context (list : Tree.initialiser_list) =
  List.iter
    (fun (element : Tree.designated_initialiser) ->
      List.iter (designator context) element.node.designators;
      initialiser context element.node.initialiser)
    list.node

and block_items context (block : Tree.block) =
  List.iter
    (function
      | Tree.Block_declaration declaration -> context.declaration declaration
      | Block_statement statement -> typed_statement context statement)
    block.node.items

and typed_statement context (statement : Tree.statement) =
  nested context statement.span (fun () -> statement_node context statement)

and statement_node context (statement : Tree.statement) =
  let enclosing = context.typed.enclosing in
  let in_loop body =
    within context { enclosing with in_loop = true } (fun () ->
        typed_statement context body)
  in
  let scalar ~clause condition =
    require_scalar context condition.Tree.span ~clause
      (expression context condition)
  in
  match statement.node with
  | Labeled { label; statement = labeled } ->
      label_of context label;
      typed_statement context labeled
  | Compound block -> block_items context block
  | Expression_statement value | Computed_goto value ->
      ignore (expression context value)
  | Null_statement | Attribute_statement _ | Goto _ -> ()
  | If { condition; then_branch; else_branch } ->
      scalar ~clause:"6.8.4.1p1" condition;
      typed_statement context then_branch;
      Option.iter (typed_statement context) else_branch
  | Switch { controlling; body } ->
      switch_controlling context controlling;
      within context { enclosing with in_switch = true } (fun () ->
          typed_statement context body)
  | While { condition; body } ->
      scalar ~clause:"6.8.5p2" condition;
      in_loop body
  | Do { body; condition } ->
      in_loop body;
      scalar ~clause:"6.8.5p2" condition
  | For { clause; condition; step; body } ->
      Option.iter (for_clause context) clause;
      Option.iter (scalar ~clause:"6.8.5p2") condition;
      Option.iter (fun step -> ignore (expression context step)) step;
      in_loop body
  | Continue ->
      if not enclosing.in_loop then
        context.fail statement.span "continue outside a loop (C11 6.8.6.2p1)"
  | Break ->
      if not (enclosing.in_loop || enclosing.in_switch) then
        context.fail statement.span
          "break outside a loop or switch (C11 6.8.6.3p1)"
  | Return value ->
      Option.iter (fun value -> ignore (expression context value)) value
  | Asm { operands; qualifiers = _; template = _ } ->
      Option.iter
        (fun (operands : Tree.asm_operands) ->
          List.iter
            (fun (operand : Tree.asm_operand) ->
              ignore (expression context operand.node.value))
            (operands.outputs @ operands.inputs))
        operands

and for_clause context (clause : Tree.for_clause) =
  match clause with
  | Clause_declaration declaration -> context.declaration declaration
  | Clause_expression value -> ignore (expression context value)

(* 6.8.4.2p1. *)
and switch_controlling context controlling =
  match operand context (expression context controlling) with
  | Arithmetic_operand { arithmetic = Integer _; _ } | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Other_operand _ ->
      context.fail controlling.span
        "the controlling expression of a switch is not an integer (C11 \
         6.8.4.2p1)"

(* 6.8.1p2: case and default labels only in a switch. *)
and label_of context (label : Tree.label) =
  let in_switch () =
    if not context.typed.enclosing.in_switch then
      context.fail label.span
        "a case or default label outside a switch (C11 6.8.1p2)"
  in
  match label.node with
  | Named_label _ -> ()
  | Default_label -> in_switch ()
  | Case_label value ->
      in_switch ();
      case_value context value
  | Case_range { low; high } ->
      in_switch ();
      case_value context low;
      case_value context high

(* 6.8.4.2p3: an integer constant expression. *)
and case_value context value =
  match operand context (expression context value) with
  | Arithmetic_operand { arithmetic = Integer _; _ } ->
      if context.constant ~evaluated:true value = None then
        context.fail value.span
          "a case label is not an integer constant expression (C11 6.8.4.2p3)"
  | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Other_operand _ ->
      context.fail value.span "a case label is not an integer (C11 6.8.4.2p3)"

let function_body context ~name block =
  let enclosing = { outside_functions with function_name = Some name } in
  within context enclosing (fun () -> block_items context block)
