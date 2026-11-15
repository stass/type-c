(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type field = {
  width : int;
  integer : Integer.t Unknown.answer;
  location : Typec_cpp.Location.t;
}

type bit_field = Not_bit_field | Bit_field of field | Bit_field_value of field

type typed = { expression_type : Ctype.t; lvalue : bool; bit_field : bit_field }

type flaw =
  | Comma_operator of Tree.span
  | Invalid of { span : Tree.span; message : string }

type designation = { static_storage : bool; named : bool }

type kind =
  | Arithmetic_constant
  | Address_constant
  | Designator of designation
  | Backend_constant
  | Not_constant

type constant =
  | Integer_expression of { value : Integer_constant.t; flaw : flaw option }
  | Not_integer of { kind : kind; first : Tree.span }
  | Unevaluable of { span : Tree.span; message : string }

(* What a case or default label in the statement being typed belongs
   to: no switch, the innermost switch, or a match arm, where it belongs
   to no switch of its own (design 4.3 rule 3). A break leaves either. *)
type label_owner = No_switch | Switch_body | Match_arm

(* What encloses the statement being typed: the function, for __func__,
   and the loop, switch or match that break, continue and case need. *)
type enclosing = {
  function_name : string option;
  return_type : Ctype.t option;
  in_loop : bool;
  case_labels : label_owner;
}

type construction = {
  span : Tree.span;
  variant : string;
  constructor : string;
  callee : Tree.span option;
  arguments : Tree.expression list;
  braced : bool;
}

type access = Through_pointer | Through_copy
type binding = { name : string; constructor : string; field : string }

type matched_arm = {
  arm : Tree.span;
  labels : Tree.span;
  cases : string list;
  bindings : binding list;
}

type 'arms matching_of = {
  statement : Tree.span;
  scrutinee : Tree.span;
  variant : string;
  access : access;
  arms : 'arms;
}

type matching = matched_arm list matching_of

type answer =
  | Selected of {
      controlling : Tree.expression;
      associations : Tree.generic_association list;
      result : Tree.expression;
    }
  | Compatible of bool
type answered = { construct : Tree.span; answer : answer }

let max_quoted = 64

let quote text =
  if String.length text <= max_quoted then "'" ^ text ^ "'"
  else "'" ^ String.sub text 0 max_quoted ^ "...'"

(* The sites that lowering replaces with the names that their variant
   derives (design 3.3, 4.1 rule 1). Those names denote the variant only
   within the scope of its declaration (10.1 rule 6), and [record] is the
   one way to hand a site to lowering, so none lies outside the scope. *)
module Sites : sig
  type t
  (* A match comes with the typing of its arms, which [record] runs only
     once the match is in scope, so that the scope is the first thing
     that a match is checked for. *)
  type site =
    | Construction of construction
    | Matching of (unit -> matched_arm list) matching_of

  val create : unit -> t

  val record :
    t ->
    Ctype.tags ->
    fail:(Tree.span -> string -> unit) ->
    variant_type:Ctype.t ->
    site ->
    unit
  (** Records [site], of a variant of [variant_type], or calls [fail]
      where the site lies outside the scope of its declaration. *)

  val construction : t -> Tree.span -> construction option
  val brace : t -> construction -> unit
  (** Lowers a recorded construction to its braced list alone (design
      13.5). *)

  val constructions : t -> construction list
  val matchings : t -> matching list
end = struct
  type t = {
    constructions : (Tree.span, construction) Hashtbl.t;
    matchings : (Tree.span, matching) Hashtbl.t;
  }

  type site =
    | Construction of construction
    | Matching of (unit -> matched_arm list) matching_of

  let create () =
    { constructions = Hashtbl.create 64; matchings = Hashtbl.create 16 }

  let within_scope tags variant_type (use : Tree.span) =
    match Ctype.variant_scope tags variant_type with
    | Some scope -> scope.first <= use.first && use.last <= scope.last
    | None -> true

  (* The diagnostic for a site that [what] names, which [rule] codes. *)
  let outside_scope rule ~what ~variant =
    Rule.message rule
      (Printf.sprintf
         "%s is outside the scope of the declaration of the variant %s, \
          where the names that it lowers to do not denote the variant"
         what (quote variant))

  let record sites tags ~fail ~variant_type = function
    | Construction construction ->
        if within_scope tags variant_type construction.span then
          Hashtbl.replace sites.constructions construction.span construction
        else
          fail construction.span
            (outside_scope Variant_scope ~what:"the constructor expression"
               ~variant:construction.variant)
    | Matching matching ->
        if within_scope tags variant_type matching.statement then
          Hashtbl.replace sites.matchings matching.statement
            { matching with arms = matching.arms () }
        else
          fail matching.scrutinee
            (outside_scope Match_scrutinee ~what:"the match"
               ~variant:matching.variant)

  let construction sites span = Hashtbl.find_opt sites.constructions span

  let brace sites construction =
    Hashtbl.replace sites.constructions construction.span
      { construction with braced = true }

  let constructions sites =
    Hashtbl.to_seq_values sites.constructions
    |> List.of_seq
    |> List.sort (fun a b -> compare a.span.first b.span.first)

  let matchings sites =
    Hashtbl.to_seq_values sites.matchings
    |> List.of_seq
    |> List.sort (fun a b -> compare a.statement.first b.statement.first)
end

(* The target type of an expression's position, which selects an
   unqualified constructor (design 3.3), or none. *)
type position = Untargeted | Targeted of Ctype.t

(* [depth] and [enclosing] belong to the walk in progress. Only the
   reader's failure leaves a walk early, and it ends the read, so neither
   is restored on it. [selections] and [compatibilities] hold the answers
   to the constructs that ask whether types are compatible, by the span
   of the construct, and [answered] those that lowering replaces with
   their answer. [types] keeps the position that each expression is
   typed in, its one position. *)
type t = {
  types : (Tree.span, position * typed) Hashtbl.t;
  constants : (Tree.span, constant) Hashtbl.t;
  selections : (Tree.span, Tree.expression Unknown.answer) Hashtbl.t;
  compatibilities : (Tree.span, bool Unknown.answer) Hashtbl.t;
  answered : (Tree.span, answered) Hashtbl.t;
  sites : Sites.t;
  mutable depth : int;
  mutable enclosing : enclosing;
}

let outside_functions =
  { function_name = None; return_type = None; in_loop = false;
    case_labels = No_switch }

let create () =
  { types = Hashtbl.create 4096;
    constants = Hashtbl.create 4096;
    selections = Hashtbl.create 16;
    compatibilities = Hashtbl.create 16;
    answered = Hashtbl.create 16;
    sites = Sites.create ();
    depth = 0;
    enclosing = outside_functions }

let find view (expression : Tree.expression) =
  Option.map snd (Hashtbl.find_opt view.types expression.span)

let constant view (expression : Tree.expression) =
  Hashtbl.find_opt view.constants expression.span

let selection view (expression : Tree.expression) =
  Hashtbl.find_opt view.selections expression.span

let constructions view = Sites.constructions view.sites
let matchings view = Sites.matchings view.sites

let answered view =
  Hashtbl.to_seq_values view.answered
  |> List.of_seq
  |> List.sort (fun a b -> compare a.construct.first b.construct.first)

let types_compatible view (expression : Tree.expression) =
  Hashtbl.find_opt view.compatibilities expression.span

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
  type_declaration : Tree.type_declaration -> unit;
  binding : Tree.identifier -> Tree.declared -> Ctype.t -> unit;
}

(* Far above the nesting of real code, it bounds the recursion on the
   chains that the parser reads in loops (operators, else-if), whose
   trees are as deep as they are long. *)
let max_depth = 10_000

let needing need (unknown : Unknown.t) =
  let why =
    match unknown.cause with
    | Not_typed -> "which typec does not type yet"
    | Typed_differently -> "which GCC types otherwise than Clang"
  in
  Printf.sprintf "%s depends on %s at %s:%d, %s (design 13.3)" need
    unknown.construct unknown.location.file unknown.location.line why

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

(* What the value of an expression of [bit_field] is: Clang promotes the
   value of an assignment to a bit-field, of a prefix [++] of one and of a
   comma whose right operand is one by its width. *)
let value_of = function
  | Bit_field field | Bit_field_value field -> Bit_field_value field
  | Not_bit_field -> Not_bit_field

let is_bit_field typed =
  match typed.bit_field with
  | Bit_field _ | Bit_field_value _ -> true
  | Not_bit_field -> false

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

let location_of context (span : Tree.span) =
  context.text.tokens.(span.first).location

let unknown_at context span construct kind : Unknown.t =
  { construct; location = location_of context span; kind; cause = Not_typed }

let unknown context span construct kind =
  Ctype.unknown (unknown_at context span construct kind)

(* The value of an operation on an operand of unknown type: unknown in
   turn, and an object, as no operator gives a function. *)
let unknown_value (unknown : Unknown.t) =
  Ctype.unknown { unknown with kind = Unknown_object }

(* An unknown type in place of [t] keeps whether it is a function type
   (P21). *)
let unknown_in_place_of (t : Ctype.t) (unknown : Unknown.t) =
  match t.shape with
  | Function _ -> Ctype.unknown { unknown with kind = Unknown_function }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Unknown_type _ ->
      Ctype.unknown unknown

(* [t], Clang's type for [difference], or an unknown type where the
   backend types the construct otherwise (design 13.3). A type that is
   unknown already stays so, for the reason that it has. *)
let backend_type context location difference (t : Ctype.t) =
  match t.shape with
  | Unknown_type _ -> t
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Function _ -> (
      match Backend_difference.answer context.target difference location t with
      | Answer t -> t
      | Depends_on unknown -> unknown_in_place_of t unknown)

let fail_operands context span clause =
  context.fail span
    ("the operands have types that the operator does not take (C11 " ^ clause
   ^ ")")

(* Design 3.2 rule 6: Type-C text reaches the tag and fields of a
   variant only through constructors and match, so an operation at [span]
   whose operand, or the type it converts to or reaches into, is the
   variant [t] is refused there. C text may use the structure that a
   variant lowers to (design 10.6). *)
let is_type_c_text context (span : Tree.span) =
  File.is_type_c_text context.text.tokens.(span.first).owner

let refuse_variant context (span : Tree.span) (t : Ctype.t) =
  match Ctype.as_variant t with
  | Some name when is_type_c_text context span ->
      context.fail span
        (Rule.message Variant_operation
           (Printf.sprintf
              "the variant %s takes no such operation; Type-C text reaches \
               its tag and fields only through constructors and match"
              (quote name)))
  | Some _ | None -> ()

(* Distinct types (design 3.4, 10.2) *)

(* C text sees a distinct type as the typedef of its representation that
   it lowers to (design 10.2); only Type-C text sees the distinct type. *)
let type_as_seen context (span : Tree.span) (t : Ctype.t) =
  if is_type_c_text context span then t else Ctype.representation t

let as_seen context span (typed : typed) =
  { typed with
    expression_type = type_as_seen context span typed.expression_type }

let distinct_name (distinct : Ctype.distinct) = quote distinct.distinct_name

(* Design 9.2: Type-C text creates a value of a private type, through
   a constructor expression or a cast at [span], only where it owns the
   type; tokens of a macro expansion belong to the file of the expansion.
   C text is bound by no Type-C rule (rule 4). [described] names the
   type in the diagnostic. *)
let refuse_private_creation context (span : Tree.span) ~described
    (t : Ctype.t) =
  let file = context.text.tokens.(span.first).owner in
  match Ctype.privacy context.tags t with
  | Private declaring
    when File.is_type_c_text file && not (File.owns ~declaring file) ->
      context.fail span
        (Rule.message Private_creation
           (Printf.sprintf
              "%s is private to %s, so only the text of its owner creates \
               its values"
              described (quote declaring.name)))
  | Private _ | Public -> ()

(* Hands [site], of a variant of [variant_type], to lowering. *)
let record_site context ~variant_type site =
  Sites.record context.typed.sites context.tags ~fail:context.fail
    ~variant_type site

(* The table of design 3.4: the operations that read a value of a
   distinct type in Type-C text. The other uses that it allows take the
   value whole and never read it as an operand: =, initialisation,
   arguments and return, sizeof, _Alignof, unary &, the comma and the
   branches of ?:. Every other operation refuses it, a new one too. *)
let reads_distinct : Tree.expression_node -> bool = function
  | Binary ((Equal_to | Not_equal_to | Logical_and | Logical_or), _, _)
  | Unary (Logical_not, _)
  | Cast _ ->
      true
  | _ -> false

let refuse_distinct context span (distinct : Ctype.distinct) =
  context.fail span
    (Rule.message Distinct_operation
       (Printf.sprintf
          "a value of the distinct type %s takes no such operation; a cast \
           to its underlying type crosses to it"
          (distinct_name distinct)))

(* An operand of an operation at [span], as the operation sees it;
   [reads] says whether the table lets the operation read a value of a
   distinct type. *)
let read_operand context span ~reads (typed : typed) =
  let typed = as_seen context span typed in
  match Ctype.as_distinct typed.expression_type with
  | Some distinct when not reads -> refuse_distinct context span distinct
  | Some _ | None -> typed

(* Design 3.4: [==], [!=] and [?:] take two values of one distinct type,
   [t], where they take one; [one_distinct] says whether they are. *)
let one_distinct context (t : Ctype.t) other =
  Ctype.compatible context.target context.tags t other = Answer true

let refuse_mixed context span (t : Ctype.t) =
  let name =
    match Ctype.as_distinct t with
    | Some distinct -> distinct_name distinct
    | None -> invalid_arg "Expressions: a mixed operand that is not distinct"
  in
  context.fail span
    (Rule.message Distinct_operation
       ("the operands are not both of the distinct type " ^ name))

let differs context a b =
  Ctype.compatible context.target context.tags a b = Answer false

(* Design 3.4: [D *] and [U *] are incompatible. GNU C only warns where
   two pointers to incompatible types meet, and the backend, which sees
   U for D, does not even warn, so typec decides: in Type-C text two
   pointers whose referenced types [a] and [b] mention a distinct type
   meet only where those are compatible or one is void. This is the one
   rule for conversions and for the operations on two pointers. *)
let pointers_differ context (a : Ctype.t) (b : Ctype.t) =
  let a = Ctype.unqualified a and b = Ctype.unqualified b in
  Ctype.is_void a = Answer false
  && Ctype.is_void b = Answer false
  && (Ctype.mentions_distinct a || Ctype.mentions_distinct b)
  && differs context a b

(* Design 3.4: Type-C text converts no value implicitly to or from a
   distinct type, nor a pointer to a type with one in it to another
   pointer but by [pointers_differ]. The backend sees a distinct type as
   its representation (design 10.2), so it cannot refuse these
   conversions; the others are its own. A value converts only to a
   scalar: towards a structure or an array it initialises a member
   through elided braces, which the initialiser checks where it places
   the value, or the backend refuses it. *)
let refuse_distinct_conversion context span target (typed : typed) =
  let target = Ctype.unqualified target in
  let source = Ctype.lvalue_conversion typed.expression_type in
  let crosses =
    match (target.shape, source.shape) with
    | Pointer t, Pointer s -> pointers_differ context t s
    | (Record _ | Array _), _ -> false
    | _ ->
        (Ctype.as_distinct target <> None || Ctype.as_distinct source <> None)
        && differs context target source
  in
  if crosses && is_type_c_text context span then
    context.fail span
      (Rule.message Distinct_conversion
         (Printf.sprintf
            "a value of type %s does not convert to %s without a cast"
            (quote (Type_name.of_ctype source))
            (quote (Type_name.of_ctype target))))

(* Design 13.5: typec answers a construct whose [types], as its text sees
   them, have a distinct type in them, which only Type-C text sees, and
   refuses one in Type-C text whose answer it does not know where an
   unknown type may hide one; [lowered] makes what replaces the construct
   from its answer. *)
let record_answer context span types ~lowered answer =
  let compares_distinct = List.exists Ctype.mentions_distinct types in
  match (answer : _ Unknown.answer) with
  | Answer answer when compares_distinct ->
      Hashtbl.replace context.typed.answered span
        { construct = span; answer = lowered answer }
  | Depends_on unknown
    when is_type_c_text context span && Ctype.has_distinct context.tags ->
      context.fail span
        (needing "the answer to a comparison of types, which may have a \
                  distinct type in them,"
           unknown)
  | Answer _ | Depends_on _ -> ()

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
  | Unknown_operand of Unknown.t
  | Distinct_operand of Ctype.t
      (** A scalar that takes only the operations of design 3.4. *)
  | Other_operand of Ctype.t
      (** void, a structure or union, [va_list], an incomplete enumeration *)

let value_operand context (t : Ctype.t) =
  match t.shape with
  | Pointer referenced -> Pointer_operand { pointer = t; referenced }
  | Unknown_type unknown -> Unknown_operand unknown
  | Distinct _ -> Distinct_operand t
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list | Array _ | Function _
    -> (
      match Ctype.as_arithmetic context.tags t with
      | Answer (Some arithmetic) ->
          let promoted = Arithmetic.promote context.target arithmetic in
          Arithmetic_operand { arithmetic; promoted }
      | Answer None -> Other_operand t
      | Depends_on unknown -> Unknown_operand unknown)

(* A bit-field promotes by its width and declared type, whatever type the
   backend gives its value. *)
let bit_field_operand context field =
  match field.integer with
  | Depends_on unknown -> Unknown_operand unknown
  | Answer integer -> (
      let width = field.width in
      let arithmetic = Arithmetic.Integer integer in
      let clang =
        Arithmetic.promote context.target ~bit_field_width:width arithmetic
      in
      match
        Backend_difference.answer context.target
          (Bit_field_promotion { integer; width })
          field.location clang
      with
      | Answer promoted -> Arithmetic_operand { arithmetic; promoted }
      | Depends_on unknown -> Unknown_operand unknown)

let operand context (typed : typed) =
  match (Ctype.as_distinct typed.expression_type, typed.bit_field) with
  | Some _, _ -> Distinct_operand (Ctype.unqualified typed.expression_type)
  | None, (Bit_field field | Bit_field_value field) ->
      bit_field_operand context field
  | None, Not_bit_field ->
      value_operand context (Ctype.lvalue_conversion typed.expression_type)

(* Refuses an operation at [span] in Type-C text on two pointers that
   [pointers_differ] keeps apart. *)
let refuse_mixed_pointers context span left right =
  match (left, right) with
  | Pointer_operand a, Pointer_operand b
    when is_type_c_text context span
         && pointers_differ context a.referenced b.referenced ->
      context.fail span
        (Rule.message Distinct_operation
           (Printf.sprintf
              "the pointers %s and %s are not compatible; a cast crosses \
               between them"
              (quote (Type_name.of_ctype a.pointer))
              (quote (Type_name.of_ctype b.pointer))))
  | _ -> ()

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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Function _ ->
      if not typed.lvalue then
        context.fail span ("the operand is not an lvalue (C11 " ^ clause ^ ")");
      if t.qualifiers.const || Ctype.is_array t = Answer true then
        context.fail span
          ("the operand is not a modifiable lvalue (C11 " ^ clause ^ ")")

let require_scalar context span ~clause typed =
  match operand context typed with
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Unknown_operand _ ->
      ()
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

(* An undeclared identifier may name a builtin function of the backend
   (design 13.3). One with a prototype has its function type; one that a
   rule types has a type only where it is called, and one whose type
   typec does not state has none (P21), so the name of either alone has
   an unknown function type. *)
let builtin context span name =
  let target = context.target in
  match Builtin_function.find target name with
  | Builtin (Prototype prototype) ->
      value (checked context span (Builtin_function.function_type target
                                     prototype))
  | Builtin (Rule _ | Unknown) ->
      value (unknown context span ("the builtin " ^ quote name)
               Unknown_function)
  | Of_other_compiler ->
      context.fail span
        (quote name ^ " is not a builtin of "
        ^ Target.compiler_name target.backend.compiler
        ^ ", the backend (design 13.3)")
  | Of_other_architectures ->
      context.fail span
        (quote name ^ " is not a builtin of "
        ^ Target.compiler_name target.backend.compiler
        ^ ", the backend, on this target's architecture ("
        ^ Target.architecture_name target.architecture
        ^ ") (design 13.3)")
  | Not_builtin ->
      context.fail span (quote name ^ " is not declared (C11 6.5.1p2)")

let const_char context span =
  let const = { Qualifiers.none with const = true } in
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
  | _ -> builtin context span name

(* The parameters that Clang gives a use of a function whose composite
   type has [parameters], by the rule of
   [Backend_difference.Old_style_function]. *)
let clang_parameters context ~old_style_definition
    (parameters : Ctype.parameters) : Ctype.parameters =
  let promoted t =
    match Ctype.promoted context.target context.tags t with
    | Answer promoted -> promoted
    | Depends_on unknown -> Ctype.unknown unknown
  in
  match (old_style_definition, parameters) with
  | true, _ | false, Old_style [] -> Unspecified
  | false, Old_style types ->
      Prototype { types = List.map promoted types; variadic = false }
  | false, (Prototype _ | Unspecified) -> parameters

let has_prototype : Ctype.parameters -> bool = function
  | Prototype _ -> true
  | Old_style _ | Unspecified -> false

(* The type of a use of a function whose composite type is [t], where
   [old_style_definition] says whether the declaration that the use
   reaches is a definition with a non-empty identifier list. *)
let function_designator context span ~old_style_definition (t : Ctype.t) =
  match t.shape with
  | Function { return; parameters } ->
      let clang = clang_parameters context ~old_style_definition parameters in
      let difference =
        Backend_difference.Old_style_function
          { clang_prototype = has_prototype clang;
            composite_prototype = has_prototype parameters }
      in
      backend_type context (location_of context span) difference
        (checked context span (Ctype.function_returning return clang))
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Unknown_type _ ->
      t

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
      | Function { function_type; old_style_definition; _ } ->
          value
            (function_designator context span ~old_style_definition
               function_type)
      | Enumerator { enumerator_type; _ } -> value enumerator_type
      | Typedef _ -> invalid_arg "Expressions: a typedef name as an operand")

(* Members (6.5.2.3) *)

(* The integer type of a bit-field member, of which define_record allows
   no other type. *)
let bit_field_integer context (member : Ctype.member) : Integer.t Unknown.answer
    =
  let declared = Ctype.representation member.member_type in
  match Ctype.as_arithmetic context.tags declared with
  | Answer (Some (Integer integer)) -> Answer integer
  | Depends_on unknown -> Depends_on unknown
  | Answer (Some (Real _ | Complex _) | None) ->
      invalid_arg "Expressions: a bit-field of no integer type"

(* 6.5.2.3p3, p4: the member, qualified as the structure is but for
   _Atomic, whose members are not accessed (p5). *)
let member_of context tag (qualifiers : Qualifiers.t)
    (name : Tree.identifier) ~lvalue =
  if Ctype.record_members context.tags tag = None then
    context.fail name.span
      "a member of an incomplete structure or union (C11 6.5.2.3p1)";
  match Ctype.find_member context.tags tag name.node with
  | None ->
      context.fail name.span
        (quote name.node ^ " is not a member of the structure or union (C11 \
                            6.5.2.3p1)")
  | Some { member; anonymous_qualifiers; _ } -> (
      let location = location_of context name.span in
      let qualifiers = { qualifiers with atomic = false; restrict = false } in
      let qualified =
        checked context name.span (Ctype.qualify qualifiers member.member_type)
      in
      let expression_type =
        backend_type context location
          (Anonymous_member
             { member_qualifiers = Ctype.top_qualifiers qualified;
               anonymous = anonymous_qualifiers })
          qualified
      in
      match member.bit_field_width with
      | None -> { expression_type; lvalue; bit_field = Not_bit_field }
      | Some width ->
          let integer = bit_field_integer context member in
          let narrow = Backend_difference.Narrow_bit_field { integer; width } in
          (* A distinct type is no integer type to narrow (design 3.4). *)
          let value_type =
            if Ctype.mentions_distinct expression_type then expression_type
            else backend_type context location narrow expression_type
          in
          { expression_type = value_type;
            lvalue;
            bit_field = Bit_field { width; integer; location } })

let direct_member context span (record : typed) name =
  let t = record.expression_type in
  match t.shape with
  | Record tag -> member_of context tag t.qualifiers name ~lvalue:record.lvalue
  | Unknown_type unknown ->
      { (value (unknown_value unknown)) with lvalue = record.lvalue }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ ->
      context.fail span
        "the operand of '.' is not a structure or union (C11 6.5.2.3p1)"

(* [p->m] reaches into [*p], which may not be a variant (design 3.2 rule
   6). *)
let pointer_member context span (pointer : typed) name =
  match operand context pointer with
  | Pointer_operand
      { referenced = { shape = Record tag; qualifiers; _ } as referenced; _ }
    ->
      refuse_variant context span referenced;
      member_of context tag qualifiers name ~lvalue:true
  | Pointer_operand { referenced = { shape = Unknown_type unknown; _ }; _ }
  | Unknown_operand unknown ->
      lvalue (unknown_value unknown)
  | Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
  | Other_operand _ ->
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
  | ( ( Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
      | Other_operand _ ),
      _ ) ->
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
  | Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
  | Other_operand _ ->
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
  | Distinct_operand _ | Other_operand _ -> fail_operands context span clause

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
  | Arithmetic_operand _ | Distinct_operand _ | Other_operand _ ->
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
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      fail_operands context span "6.5.3.3p1"

(* Clang takes either part of a bit-field as its value; GCC's real part
   of one is the bit-field itself. *)
let bit_field_part context span ~imaginary (typed : typed) =
  let part = value (Ctype.lvalue_conversion typed.expression_type) in
  if imaginary then part
  else
    match
      Backend_difference.answer context.target Bit_field_real_part
        (location_of context span) part
    with
    | Answer part -> part
    | Depends_on unknown ->
        { typed with expression_type = Ctype.unknown unknown }

(* GNU [__real__] and [__imag__] of what is no bit-field: a part of a
   complex value, of the floating type of the parts, or a real operand's
   own type; an lvalue where the operand is one, but for the imaginary
   part of a real value, which is a zero. *)
let other_part context span ~imaginary (typed : typed) =
  let t = typed.expression_type in
  match operand context typed with
  | Arithmetic_operand { arithmetic = Complex floating; _ } ->
      let part = arithmetic_type context span (Real floating) in
      let part = checked context span (Ctype.qualify t.qualifiers part) in
      { typed with expression_type = part; bit_field = Not_bit_field }
  | Arithmetic_operand _ when imaginary -> value (Ctype.lvalue_conversion t)
  | Arithmetic_operand _ -> typed
  | Unknown_operand unknown ->
      { typed with expression_type = unknown_value unknown }
  | Pointer_operand _ | Distinct_operand _ | Other_operand _ ->
      context.fail span
        "the operand of __real__ or __imag__ is not arithmetic"

let complex_part context span ~imaginary typed =
  if is_bit_field typed then bit_field_part context span ~imaginary typed
  else other_part context span ~imaginary typed

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
  | ( ( Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
      | Other_operand _ ),
      _ ) ->
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
  | ( ( Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
      | Other_operand _ ),
      _ ) ->
      fail_operands context span "6.5.7p2"

(* 6.5.8p2, p6 and 6.5.9p2, p3: an int. GNU C compares a pointer with an
   integer too; relations take real operands only. *)
let ordinary_comparison context span ~relational ~clause left right =
  let takes = function
    | Arithmetic_operand { arithmetic; _ } ->
        (not relational) || is_real arithmetic
    | Pointer_operand _ | Unknown_operand _ -> true
    | Distinct_operand _ | Other_operand _ -> false
  in
  if not (takes left && takes right) then fail_operands context span clause;
  int_type context span

(* Design 3.4: == and != take two values of one distinct type. *)
let comparison context span ~relational ~clause left right =
  match (left, right) with
  | Distinct_operand a, Distinct_operand b
    when (not relational) && one_distinct context a b ->
      int_type context span
  | Distinct_operand t, _ | _, Distinct_operand t when not relational ->
      refuse_mixed context span t
  | _ -> ordinary_comparison context span ~relational ~clause left right

(* 6.5.13p2, p3 and 6.5.14p2, p3. *)
let logical context span ~clause left right =
  let takes = function
    | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
    | Unknown_operand _ ->
        true
    | Other_operand _ -> false
  in
  if not (takes left && takes right) then fail_operands context span clause;
  int_type context span

let binary_type context span (op : Tree.binary_operator) left right =
  let left = operand context left and right = operand context right in
  (* Every operator but a logical one, which takes each operand as a
     truth value on its own, relates two pointers that it takes. *)
  (match op with
  | Logical_and | Logical_or -> ()
  | _ -> refuse_mixed_pointers context span left right);
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

let is_plain_void_pointer (t : Ctype.t) =
  match t.shape with
  | Pointer { shape = Void; qualifiers; _ } -> qualifiers = Qualifiers.none
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Function _ | Unknown_type _ ->
      false

(* 6.5.15p6: a pointer to void, qualified as both referenced types are;
   restrict and _Atomic do not apply to void. *)
let qualified_void_pointer context span (a : Ctype.t) (b : Ctype.t) =
  let both = Qualifiers.union a.qualifiers b.qualifiers in
  let qualifiers = { both with restrict = false; atomic = false } in
  let void = checked context span (Ctype.qualify qualifiers Ctype.void) in
  checked context span (Ctype.pointer_to void)

(* 6.5.15p6: pointers to compatible types give a pointer to their
   composite, qualified as both are; GCC and Clang give others a pointer
   to unqualified void. *)
let composite_pointer context span (a : Ctype.t) (b : Ctype.t) =
  match
    Ctype.composite context.target context.tags (location_of context span)
      (Ctype.unqualified a) (Ctype.unqualified b)
  with
  | Ok composite ->
      let qualifiers = Qualifiers.union a.qualifiers b.qualifiers in
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

(* Generic selection (6.5.1.1) and __builtin_types_compatible_p *)

(* A generic association with its type name read; [default] has none.
   [result] is the expression that the selection is if it selects the
   association. *)
type association = {
  association_span : Tree.span;
  association_type : Ctype.t option;
  result : Tree.expression;
}

let compatible context a b = Ctype.compatible context.target context.tags a b

(* 6.5.1.1p2: no two associations name compatible types. Where that
   depends on an unknown type the backend checks it. *)
let check_distinct context associations =
  let check earlier association =
    match association.association_type with
    | None -> earlier
    | Some t ->
        if List.exists (fun u -> compatible context t u = Answer true) earlier
        then
          context.fail association.association_span
            "the type of a generic association is compatible with that of \
             another (C11 6.5.1.1p2)";
        t :: earlier
  in
  ignore (List.fold_left check [] associations)

(* 6.5.1.1p2: at most one default association. *)
let default_association context associations =
  let is_default association = Option.is_none association.association_type in
  match List.filter is_default associations with
  | [] -> None
  | [ default ] -> Some default.result
  | _ :: second :: _ ->
      context.fail second.association_span
        "a second default generic association (C11 6.5.1.1p2)"

(* 6.5.1.1p2, p3: the result of the one association whose type is
   compatible with the controlling type, else that of the default; the
   selection is unknown where the compatibility of any association is.
   C11 allows several compatible associations beside a default, which
   GCC and Clang refuse. *)
let select context span controlling_type associations default =
  let unknown = ref None and compatible_results = ref [] in
  let compare association =
    match association.association_type with
    | None -> ()
    | Some t -> (
        match compatible context controlling_type t with
        | Depends_on dependence -> unknown := Some dependence
        | Answer true ->
            compatible_results := association.result :: !compatible_results
        | Answer false -> ())
  in
  List.iter compare associations;
  match (!unknown, !compatible_results, default) with
  | Some dependence, _, _ -> Unknown.Depends_on dependence
  | None, [ result ], _ -> Answer result
  | None, [], Some default -> Answer default
  | None, [], None ->
      context.fail span
        "the controlling expression is compatible with no generic \
         association (C11 6.5.1.1p2)"
  | None, _ :: _ :: _, _ ->
      context.fail span
        "the controlling expression is compatible with more than one \
         generic association"

(* GCC and Clang compare the types without their top-level qualifiers,
   which for Clang do not include [_Atomic]. *)
let types_compatible_answer context span first second =
  match
    compatible context
      (Ctype.without_top_qualifiers first)
      (Ctype.without_top_qualifiers second)
  with
  | Depends_on unknown -> Unknown.Depends_on unknown
  | Answer clang ->
      Backend_difference.answer context.target
        (Atomic_comparison
           (Ctype.top_qualifiers first, Ctype.top_qualifiers second))
        (location_of context span) clang

(* Constant expressions (6.6) *)

(* An operand is typed, and so classed, before its operation. *)
let operand_constant context (operand : Tree.expression) =
  match Hashtbl.find_opt context.typed.constants operand.span with
  | Some constant -> constant
  | None -> invalid_arg "Expressions: an operand classed after its operation"

let operand_typed context (operand : Tree.expression) =
  match Hashtbl.find_opt context.typed.types operand.span with
  | Some (_, typed) -> typed
  | None -> invalid_arg "Expressions: an operand typed after its operation"

let is_integer_expression context operand =
  match operand_constant context operand with
  | Integer_expression _ -> true
  | Not_integer _ | Unevaluable _ -> false

(* What a designator gives as a value (6.3.2.1): its address where it is
   an array or a function, its value otherwise. *)
let designated_value (typed : typed) { static_storage; named } =
  let t = typed.expression_type in
  match t.shape with
  | Array _ | Function _ ->
      if static_storage then Address_constant else Not_constant
  | Unknown_type _ -> Backend_constant
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
    ->
      if named && not t.qualifiers.const then Not_constant
      else Backend_constant

(* The class of the value of an operand, which is never a designator; an
   integer constant expression is an arithmetic one too (6.6p8). *)
let operand_kind context operand =
  match operand_constant context operand with
  | Integer_expression _ -> Arithmetic_constant
  | Unevaluable _ -> Backend_constant
  | Not_integer { kind = Designator designation; _ } ->
      designated_value (operand_typed context operand) designation
  | Not_integer { kind; _ } -> kind

(* Whether an operand is evaluated where its operation is (6.6p3): what a
   constant expression does not allow is allowed in one that is not, and
   may be in one that an opaque value decides. *)
type role = Evaluated | Not_evaluated | Maybe_evaluated

let demoted role kind =
  match (role, kind) with
  | (Not_evaluated | Maybe_evaluated), Not_constant -> Backend_constant
  | (Evaluated | Not_evaluated | Maybe_evaluated), kind -> kind

(* The class of an operation on operands of these classes: what both GCC
   and Clang refuse where one is, an arithmetic constant where all are
   (6.6p8), else what the backend decides. *)
let combined kinds =
  if List.mem Not_constant kinds then Not_constant
  else if List.for_all (fun kind -> kind = Arithmetic_constant) kinds then
    Arithmetic_constant
  else Backend_constant

let refused_or_backend kinds =
  if List.mem Not_constant kinds then Not_constant else Backend_constant

(* How an operand takes part in an integer constant expression: its value
   and the flaw that counts where it is evaluated, or the constant of the
   operation where the operand is none. *)
type part = Part of Integer_constant.t * flaw option | Breaks of constant

let part context role operand =
  match operand_constant context operand with
  | Integer_expression { value; flaw } ->
      Part (value, if role = Evaluated then flaw else None)
  | (Not_integer _ | Unevaluable _) as broken -> Breaks broken

(* The constant of an operation of class [kind] whose operand [broken] is
   no integer constant expression. *)
let broken_by broken kind =
  match broken with
  | Not_integer { first; _ } -> Not_integer { kind; first }
  | Integer_expression _ | Unevaluable _ -> broken

let first_flaw first second =
  match first with Some _ -> first | None -> second

let invalid span (failure : Integer_constant.error option) =
  Option.map
    (fun error ->
      Invalid { span; message = Integer_constant.error_message error })
    failure

let integer value = Integer_expression { value; flaw = None }

(* The size of a type that the target model gives (6.5.3.4p2, p4); the
   front end knows no other (design P16). The size of an unknown object
   type is the backend's too, as a constant: an unknown type is a variable
   length array only in a prototype, through [typeof] or an attribute,
   where the backend checks it. *)
type size = Bytes of int | Backend_size | Variable_size | No_size

let rec size_of context (t : Ctype.t) =
  let target = context.target in
  let of_integer integer =
    Bytes (Target.integer_width target integer / target.char_bit)
  in
  let of_floating : Arithmetic.floating -> int = function
    | Float -> target.sizeof_float
    | Double -> target.sizeof_double
    | Long_double -> target.sizeof_long_double
  in
  if t.qualifiers.atomic then Backend_size
  else
    match t.shape with
    (* GNU C, which GCC and Clang follow. *)
    | Void | Function _ | Unknown_type { kind = Unknown_function; _ } ->
        Bytes 1
    | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
        Backend_size
    | Arithmetic (Integer Bool) -> Backend_size
    | Arithmetic (Integer integer) -> of_integer integer
    | Arithmetic (Real floating) -> Bytes (of_floating floating)
    (* 6.2.5p13: the real and imaginary parts of a complex type. *)
    | Arithmetic (Complex floating) -> Bytes (2 * of_floating floating)
    | Enum tag -> (
        match Ctype.enum_integer context.tags tag with
        | Some (Answer integer) -> of_integer integer
        | Some (Depends_on _) -> Backend_size
        | None -> No_size)
    | Pointer _ -> Bytes target.sizeof_pointer
    | Distinct { representation; _ } -> size_of context representation
    | Va_list -> Backend_size
    | Record _ | Array _ -> (
        match
          (Ctype.is_complete context.tags t, Ctype.is_variably_modified t)
        with
        | Answer false, _ -> No_size
        | _, Answer true -> Variable_size
        | (Answer true | Depends_on _), (Answer false | Depends_on _) ->
            Backend_size)

(* 6.5.3.4p2: an integer constant but for a variable length array. *)
let size_constant context span t =
  let size_type = context.target.size_type in
  match size_of context t with
  | Bytes bytes ->
      integer
        (Integer_constant.known context.target size_type
           (Exact_integer.of_int bytes))
  | Backend_size -> integer (Integer_constant.opaque size_type)
  | Variable_size -> Not_integer { kind = Backend_constant; first = span }
  | No_size ->
      Unevaluable
        {
          span;
          message =
            "sizeof is applied to an incomplete type (C11 6.5.3.4p1)";
        }

let identifier_constant context span name (resolution : Tree.resolution)
    (typed : typed) =
  let itself kind = Not_integer { kind; first = span } in
  match resolution with
  (* [__func__] and its kin are static arrays, a builtin the backend's. *)
  | Undeclared ->
      if typed.lvalue then
        itself (Designator { static_storage = true; named = false })
      else itself Backend_constant
  | Resolved reference -> (
      match (context.entity span name reference).declared with
      | Function _ when context.overloaded reference -> itself Backend_constant
      | Function _ ->
          itself (Designator { static_storage = true; named = false })
      | Object { storage; _ } ->
          let static_storage = storage = Static_storage in
          itself (Designator { static_storage; named = true })
      | Enumerator { value; _ } -> integer value
      | Typedef _ -> invalid_arg "Expressions: a typedef name as an operand")

(* 6.5.2.1p2: [e1[e2]] is [*(e1 + e2)]. An element of an array that a
   designator designates is part of that object. *)
let subscript_kind context operand index =
  let operand_type = (operand_typed context operand).expression_type in
  let pointer, offset =
    match (Ctype.lvalue_conversion operand_type).shape with
    | Pointer _ -> (operand, index)
    | _ -> (index, operand)
  in
  let pointer_type = (operand_typed context pointer).expression_type in
  let constant_offset = is_integer_expression context offset in
  match operand_constant context pointer with
  | Not_integer { kind = Designator designation; _ }
    when constant_offset && Ctype.is_array pointer_type = Answer true ->
      Designator designation
  | _ when constant_offset && operand_kind context pointer = Address_constant
    ->
      Designator { static_storage = true; named = false }
  | _ ->
      refused_or_backend
        [ operand_kind context pointer; operand_kind context offset ]

(* What [*] or [->] designates through the value of [operand]. *)
let through_pointer context operand =
  match operand_kind context operand with
  | Address_constant -> Designator { static_storage = true; named = false }
  | Not_constant -> Not_constant
  | Arithmetic_constant | Designator _ | Backend_constant -> Backend_constant

let member_kind context operand =
  match operand_constant context operand with
  | Not_integer { kind = Designator _ as designator; _ } -> designator
  | Integer_expression _ | Not_integer _ | Unevaluable _ ->
      operand_kind context operand

(* 6.6p9: the address of an object of static storage duration or of a
   function is an address constant. *)
let address_kind context operand =
  match operand_constant context operand with
  | Not_integer { kind = Designator { static_storage = true; _ }; _ } ->
      Address_constant
  | Not_integer
      { kind = Designator { static_storage = false; _ } | Not_constant; _ }
    ->
      Not_constant
  | Integer_expression _ | Unevaluable _ | Not_integer _ -> Backend_constant

let unary_constant context span op operand =
  match part context Evaluated operand with
  | Part (value, flaw) ->
      let value, failure = Integer_constant.unary context.target op value in
      let flaw = first_flaw flaw (invalid span failure) in
      Integer_expression { value; flaw }
  | Breaks broken ->
      broken_by broken (combined [ operand_kind context operand ])

(* 6.6p7, p8: an address constant plus or minus an integer constant
   expression, or an operation on arithmetic constants. *)
let binary_kind context (op : Tree.binary_operator) left right =
  match (op, operand_kind context left, operand_kind context right) with
  | _, Not_constant, _ | _, _, Not_constant -> Not_constant
  | (Add | Subtract), Address_constant, _
    when is_integer_expression context right ->
      Address_constant
  | Add, _, Address_constant when is_integer_expression context left ->
      Address_constant
  | _, Arithmetic_constant, Arithmetic_constant -> Arithmetic_constant
  | _, _, _ -> Backend_constant

let binary_constant context span op left right =
  match (part context Evaluated left, part context Evaluated right) with
  | Part (left_value, left_flaw), Part (right_value, right_flaw) ->
      let value, failure =
        Integer_constant.binary context.target op left_value right_value
      in
      let operand_flaw = first_flaw left_flaw right_flaw in
      Integer_expression
        { value; flaw = first_flaw operand_flaw (invalid span failure) }
  | Breaks broken, _ | Part _, Breaks broken ->
      broken_by broken (binary_kind context op left right)

(* 6.5.13p4, 6.5.14p4: the right operand is evaluated where the left one
   does not decide the value, which is true for [||] ([decisive]) and
   false for [&&]. Neither fails. *)
let logical_constant context ~decisive op left right =
  let kind right_role =
    combined
      [ operand_kind context left;
        demoted right_role (operand_kind context right) ]
  in
  match part context Evaluated left with
  | Breaks broken -> broken_by broken (kind Maybe_evaluated)
  | Part (left_value, left_flaw) -> (
      let right_role =
        match Integer_constant.truth left_value with
        | Some truth when truth = decisive -> Not_evaluated
        | Some _ -> Evaluated
        | None -> Maybe_evaluated
      in
      match part context right_role right with
      | Part (right_value, right_flaw) ->
          let value, _ =
            Integer_constant.binary context.target op left_value right_value
          in
          Integer_expression { value; flaw = first_flaw left_flaw right_flaw }
      | Breaks broken -> broken_by broken (kind right_role))

(* 6.5.15p4: the operand that the condition chooses is evaluated. *)
let conditional_constant context condition second third =
  let kind (second_role, third_role) =
    combined
      [ operand_kind context condition;
        demoted second_role (operand_kind context second);
        demoted third_role (operand_kind context third) ]
  in
  match part context Evaluated condition with
  | Breaks broken -> broken_by broken (kind (Maybe_evaluated, Maybe_evaluated))
  | Part (condition_value, condition_flaw) -> (
      let roles =
        match Integer_constant.truth condition_value with
        | Some true -> (Evaluated, Not_evaluated)
        | Some false -> (Not_evaluated, Evaluated)
        | None -> (Maybe_evaluated, Maybe_evaluated)
      in
      let second_role, third_role = roles in
      match
        (part context second_role second, part context third_role third)
      with
      | Part (if_true, true_flaw), Part (if_false, false_flaw) ->
          let value =
            Integer_constant.conditional context.target condition_value
              if_true if_false
          in
          let branch_flaw = first_flaw true_flaw false_flaw in
          Integer_expression
            { value; flaw = first_flaw condition_flaw branch_flaw }
      | Breaks broken, _ | Part _, Breaks broken ->
          broken_by broken (kind roles))

(* 6.6p3: a comma operator only where it is not evaluated. *)
let comma_constant context span left right =
  match (part context Not_evaluated left, part context Not_evaluated right) with
  | Part _, Part (value, _) ->
      Integer_expression { value; flaw = Some (Comma_operator span) }
  | Breaks _, _ | Part _, Breaks _ ->
      let kinds = [ operand_kind context left; operand_kind context right ] in
      Not_integer { kind = refused_or_backend kinds; first = span }

(* The expression whose value [expression] is, through parentheses and
   the selections of _Generic and __builtin_choose_expr (6.5.1p5,
   6.5.1.1p4) that [select] gives. *)
let rec source_through select (expression : Tree.expression) =
  match expression.node with
  | Parenthesized inner -> source_through select inner
  | Generic _ | Choose _ -> (
      match select expression with
      | Unknown.Answer chosen -> source_through select chosen
      | Depends_on unknown -> Unknown.Depends_on unknown)
  | _ -> Answer expression

(* The source of an expression that has been typed, through the
   selections that typing has made. *)
let value_source context =
  source_through (fun (selecting : Tree.expression) ->
      match Hashtbl.find_opt context.typed.selections selecting.span with
      | Some selection -> selection
      | None -> invalid_arg "Expressions: an untyped selection")

let is_floating_constant context expression =
  match value_source context expression with
  | Answer { node = Constant (Floating _); _ } -> true
  | Answer _ | Depends_on _ -> false

(* 6.6p6, p8, p9: a cast to an integer type of an integer constant
   expression, or of a floating constant, whose value the backend
   computes; a cast between arithmetic types; a cast to a pointer type of
   an integer constant expression or an address constant. *)
let representation_cast_constant context span (cast_type : Ctype.t) operand
    =
  let itself kind = Not_integer { kind; first = span } in
  let operand_kind = operand_kind context operand in
  match Ctype.as_arithmetic context.tags cast_type with
  | Answer (Some (Integer integer_type))
    when is_floating_constant context operand ->
      integer (Integer_constant.opaque integer_type)
  | Answer (Some (Integer integer_type)) -> (
      match part context Evaluated operand with
      | Part (value, flaw) ->
          let target = context.target in
          let value = Integer_constant.convert target integer_type value in
          Integer_expression { value; flaw }
      | Breaks broken -> broken_by broken (combined [ operand_kind ]))
  | Answer (Some (Real _ | Complex _)) -> itself (combined [ operand_kind ])
  | Answer None when Ctype.is_pointer cast_type = Answer true ->
      let integer = is_integer_expression context operand in
      if integer || operand_kind = Address_constant then
        itself Address_constant
      else itself (refused_or_backend [ operand_kind ])
  | Answer None -> itself (refused_or_backend [ operand_kind ])
  | Depends_on unknown ->
      Unevaluable { span; message = needing "the value of a cast" unknown }

(* Design 3.4: in Type-C text a cast to a distinct type is a constant
   where the cast to its representation is, but no integer constant
   expression, as a distinct type is no integer type. C text casts to the
   representation (design 10.2). *)
let cast_constant context span (cast_type : Ctype.t) operand =
  match Ctype.as_distinct cast_type with
  | Some { representation; _ } when not (is_type_c_text context span) ->
      representation_cast_constant context span representation operand
  | None -> representation_cast_constant context span cast_type operand
  | Some { representation; _ } -> (
      match representation_cast_constant context span representation operand
      with
      | Integer_expression _ ->
          let kind = combined [ operand_kind context operand ] in
          Not_integer { kind; first = span }
      | constant -> constant)

(* The constant of the selection at [span] of a [construct]. *)
let selected_constant context span construct =
  match Hashtbl.find_opt context.typed.selections span with
  | Some (Answer chosen) -> operand_constant context chosen
  | Some (Depends_on unknown) ->
      let message = needing ("the value of " ^ construct) unknown in
      Unevaluable { span; message }
  | None -> invalid_arg "Expressions: an untyped selection"

(* The class of an expression that has been typed, from those of its
   operands. *)
let classify_node context (whole : Tree.expression) typed =
  let span = whole.span and target = context.target in
  let itself kind = Not_integer { kind; first = span } in
  let unevaluable error =
    Unevaluable { span; message = Integer_constant.error_message error }
  in
  match whole.node with
  | Identifier { name; resolution } ->
      identifier_constant context span name resolution typed
  | Constant (Integer { base; digits; suffix }) -> (
      match Integer_constant.of_integer_constant target base digits suffix with
      | Ok value -> integer value
      | Error error -> unevaluable error)
  | Constant (Floating _) -> itself Arithmetic_constant
  | Constant Not_a_constant ->
      invalid_arg "Expressions: a constant that is not one"
  | Character encoding -> (
      match
        Integer_constant.of_character_constant target encoding
          (spelling context span)
      with
      | Ok value -> integer value
      | Error error -> unevaluable error)
  | String _ -> itself (Designator { static_storage = true; named = false })
  | Parenthesized inner -> operand_constant context inner
  (* 6.5.1.1p4: the class and value of the result expression, as of
     the chosen operand of __builtin_choose_expr. *)
  | Generic _ -> selected_constant context span "_Generic"
  | Choose _ -> selected_constant context span "__builtin_choose_expr"
  | Types_compatible _ -> (
      let int = Integer.Int in
      match Hashtbl.find_opt context.typed.compatibilities span with
      | Some (Answer compatible) ->
          integer
            (Integer_constant.known target int
               (Exact_integer.of_int (Bool.to_int compatible)))
      | Some (Depends_on _) -> integer (Integer_constant.opaque int)
      | None -> invalid_arg "Expressions: an untyped builtin")
  (* 6.5.2.5p5: of static storage duration outside the body of a
     function. *)
  | Compound_literal _ ->
      let static_storage = context.typed.enclosing.function_name = None in
      itself (Designator { static_storage; named = false })
  | Qualified_constructor _ ->
      invalid_arg "Expressions: a constructor that is no constructor expression"
  | Subscript { operand; index } ->
      itself (subscript_kind context operand index)
  | Member { operand; _ } -> itself (member_kind context operand)
  | Pointer_member { operand; _ } | Unary (Indirection, operand) ->
      itself (through_pointer context operand)
  | Unary (Address, operand) -> itself (address_kind context operand)
  | Unary
      (((Unary_plus | Unary_minus | Bitwise_not | Logical_not) as op), operand)
    ->
      unary_constant context span op operand
  | Unary ((Real_part | Imaginary_part), operand) ->
      itself (combined [ operand_kind context operand ])
  | Post_increment _ | Post_decrement _ | Assignment _
  | Unary ((Pre_increment | Pre_decrement), _) ->
      itself Not_constant
  | Sizeof_expression operand ->
      let operand_type = (operand_typed context operand).expression_type in
      size_constant context span operand_type
  | Sizeof_type type_name ->
      size_constant context span (context.type_name type_name)
  (* [offsetof] expands to [__builtin_offsetof], an integer constant
     (C11 7.19p3). *)
  | Alignof _ | Alignof_expression _ | Offsetof _ ->
      integer (Integer_constant.opaque target.size_type)
  | Cast { type_name; operand } ->
      cast_constant context span (context.type_name type_name) operand
  | Binary (Logical_and, left, right) ->
      logical_constant context ~decisive:false Logical_and left right
  | Binary (Logical_or, left, right) ->
      logical_constant context ~decisive:true Logical_or left right
  | Binary (op, left, right) -> binary_constant context span op left right
  | Conditional { condition; if_true; if_false } ->
      let second = Option.value if_true ~default:condition in
      conditional_constant context condition second if_false
  | Comma (left, right) -> comma_constant context span left right
  | Label_address _ -> itself Address_constant
  | Call _ | Statement_expression _ | Va_arg _ | Block_literal _ ->
      itself Backend_constant

(* The class of an expression that has been typed. A constructor makes a
   structure, constant where its arguments are. *)
let classify context (whole : Tree.expression) typed =
  match Sites.construction context.typed.sites whole.span with
  | Some { arguments; _ } ->
      let kinds = List.map (operand_kind context) arguments in
      Not_integer { kind = refused_or_backend kinds; first = whole.span }
  | None -> classify_node context whole typed

(* 6.7.9p4, 6.5.2.5p3: an initialiser that no backend takes as
   constant. *)
let require_constant context (expression : Tree.expression) =
  if operand_kind context expression = Not_constant then
    context.fail expression.span
      "an initialiser of an object with static or thread storage duration \
       is not a constant expression (C11 6.7.9p4)"

(* The rule that types a call of [callee], where it names a builtin that
   a rule types. *)
let rec builtin_rule context (callee : Tree.expression) =
  match callee.node with
  | Identifier { name; resolution = Undeclared } -> (
      match Builtin_function.find context.target name with
      | Builtin (Rule rule) -> Some (name, rule)
      | Builtin (Prototype _ | Unknown)
      | Of_other_compiler | Of_other_architectures | Not_builtin ->
          None)
  | Parenthesized inner -> builtin_rule context inner
  | _ -> None

let fail_builtin_argument context span name requirement =
  context.fail span
    (Printf.sprintf "the first argument of %s is not %s (design 13.3)"
       (quote name) requirement)

(* The type of the object that [first] points to, as the result of
   [name]. A distinct type gives itself whatever its qualifiers: the
   rules of design 3.4 need it, and only __typeof__ sees the qualifier.
   Clang keeps a qualifier of any other referenced type that a typedef
   gives it and drops one written in the pointer's declarator; Ctype does
   not tell them apart, so such a qualified type gives an unknown result.
   _Atomic, which Clang's __c11 builtins drop, does not count. *)
let object_of_first context span name first =
  let qualified (qualifiers : Qualifiers.t) =
    qualifiers.const || qualifiers.volatile || qualifiers.restrict
  in
  match operand context first with
  | Pointer_operand { referenced = { shape = Distinct _; _ } as referenced; _ }
    ->
      value (Ctype.unqualified referenced)
  | Pointer_operand { referenced; _ } when qualified referenced.qualifiers ->
      value
        (unknown context span ("the result of " ^ quote name)
           Unknown_object)
  | Pointer_operand { referenced; _ } -> value (Ctype.unqualified referenced)
  | Unknown_operand unknown -> value (unknown_value unknown)
  | Arithmetic_operand _ | Distinct_operand _ | Other_operand _ ->
      fail_builtin_argument context span name "a pointer"

(* A builtin of [Pointee_of_first] reads the object that [first] points
   to as its operand, so in Type-C text the object is not of a distinct
   type (design 3.4). *)
let pointee_of_first context span name first =
  match operand context first with
  | Pointer_operand { referenced = { shape = Distinct distinct; _ }; _ }
    when is_type_c_text context span ->
      refuse_distinct context span distinct
  | Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
  | Other_operand _ | Unknown_operand _ ->
      object_of_first context span name first

let complex_of_first context span name first =
  match operand context first with
  | Arithmetic_operand { arithmetic = Real floating; _ } ->
      value (arithmetic_type context span (Complex floating))
  | Unknown_operand unknown -> value (unknown_value unknown)
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      fail_builtin_argument context span name "of a real floating type"

(* The operand that the condition of __builtin_choose_expr chooses,
   unknown where typec leaves the condition's value to the backend, as
   for a call of __builtin_constant_p. *)
let choice context span condition first second =
  let undecided () =
    Unknown.Depends_on
      (unknown_at context span "the condition of __builtin_choose_expr"
         Object_or_function)
  in
  match operand_constant context condition with
  | Integer_expression { value = { value = Known value; _ }; flaw = None } ->
      if Exact_integer.equal value Exact_integer.zero then Unknown.Answer second
      else Answer first
  | Integer_expression { value = { value = Opaque; _ }; flaw = None }
  | Integer_expression { flaw = Some (Comma_operator _); _ }
  | Not_integer { kind = Backend_constant; _ } ->
      undecided ()
  | Integer_expression { flaw = Some (Invalid { span; message }); _ }
  | Unevaluable { span; message } ->
      context.fail span message
  | Not_integer
      { kind = Arithmetic_constant | Address_constant | Designator _
             | Not_constant;
        first } ->
      context.fail first
        "the condition of '__builtin_choose_expr' is not an integer \
         constant expression (design 13.3)"

(* A call of a builtin that a rule types, with the types of its
   arguments. *)
let rule_call context span name (rule : Builtin_function.rule) arguments =
  match (rule, arguments) with
  | Type_generic result, _ ->
      value
        (checked context span (Builtin_function.c_type context.target result))
  | Pointee_of_first, first :: _ -> pointee_of_first context span name first
  | Complex_of_first, first :: _ -> complex_of_first context span name first
  | Moves_object { result = Moved_object; _ }, first :: _ ->
      object_of_first context span name first
  | Moves_object { result = Fixed result; _ }, _ ->
      value
        (checked context span (Builtin_function.c_type context.target result))
  | ( (Pointee_of_first | Complex_of_first
      | Moves_object { result = Moved_object; _ }),
      [] ) ->
      context.fail span
        (quote name ^ " takes at least one argument (design 13.3)")

(* 6.5.2.2p5, or the rule of the builtin that [callee] names. *)
let call context span callee (callee_typed : typed) arguments =
  match builtin_rule context callee with
  | Some (name, rule) -> rule_call context span name rule arguments
  | None ->
      value (call_type context span callee_typed (List.length arguments))

(* A cast to [void] discards its operand, so it takes a variant whole
   (design 3.2 rule 6). This is the one place that decides it. *)
let discards cast_type = Ctype.is_void cast_type = Answer true

(* Constructor expressions (design 3.3) *)

(* A constructor that an expression names: the variant's unqualified
   type and name, and the constructor. *)
type chosen_constructor = {
  variant_type : Ctype.t;
  variant_name : string;
  chosen : Ctype.constructor;
}

let find_constructor constructors name =
  List.find_opt
    (fun (constructor : Ctype.constructor) ->
      constructor.constructor_name = name)
    constructors

let constructor_message text = Rule.message Constructor_expression text

(* The variant of [t] that names its constructors, unqualified. *)
let named_in t constructors name =
  match (Ctype.as_variant t, find_constructor constructors name) with
  | Some variant_name, Some chosen ->
      Some { variant_type = Ctype.unqualified t; variant_name; chosen }
  | None, _ | Some _, None -> None

(* An unqualified name in Type-C text is a constructor where the target
   type of its position is a variant with a constructor of that name,
   whatever else the name denotes there (design 3.3, P2). C text keeps
   C's meaning of every name. *)
let unqualified_constructor context position (span : Tree.span) name =
  match position with
  | Targeted t when is_type_c_text context span ->
      Option.bind (Ctype.constructors context.tags t) (fun constructors ->
          named_in t constructors name)
  | Targeted _ | Untargeted -> None

(* [T.C]: the type name denotes a complete variant with a constructor [C]. *)
let qualified_constructor context (variant : Tree.type_name)
    (constructor : Tree.identifier) =
  let t = context.type_name variant in
  let described = quote (spelling context variant.span) in
  match (Ctype.constructors context.tags t, Ctype.as_variant t) with
  | Some constructors, _ -> (
      match named_in t constructors constructor.node with
      | Some named -> named
      | None ->
          context.fail constructor.span
            (constructor_message
               (Printf.sprintf "the variant %s has no constructor %s"
                  described (quote constructor.node))))
  | None, Some _ ->
      context.fail variant.span
        (constructor_message
           (Printf.sprintf "the variant %s is incomplete here" described))
  | None, None ->
      context.fail variant.span
        (constructor_message
           (Printf.sprintf "%s is not a variant, so it has no constructors"
              described))

(* The constructor expression that [whole] is, if it is one: its
   constructor and its arguments, [None] where it is written without
   parentheses. A call of a name is a constructor expression where the
   name alone would be one. *)
let constructor_expression context position (whole : Tree.expression) =
  match whole.node with
  | Identifier { name; _ } ->
      Option.map
        (fun named -> (named, None))
        (unqualified_constructor context position whole.span name)
  | Qualified_constructor { variant; constructor } ->
      Some (qualified_constructor context variant constructor, None)
  | Call { callee = { node = Identifier { name; _ }; _ }; arguments } ->
      Option.map
        (fun named -> (named, Some arguments))
        (unqualified_constructor context position whole.span name)
  | Call
      { callee = { node = Qualified_constructor { variant; constructor }; _ };
        arguments } ->
      Some (qualified_constructor context variant constructor, Some arguments)
  | _ -> None

(* The first of [arguments] take [positions], those past them none. *)
let rec zip_positions positions arguments =
  match (positions, arguments) with
  | position :: positions, _ :: arguments ->
      position :: zip_positions positions arguments
  | [], arguments -> List.map (fun _ -> Untargeted) arguments
  | _ :: _, [] -> []

(* Statements (6.8) and the expressions that hold them *)

(* The value of an expression that an operation reads (design 3.4): the
   plain typing entry, which refuses a value of a distinct type in Type-C
   text and gives C text the representation. Only the uses that design
   3.4 lets take such a value whole call [whole_value] instead. *)
let rec expression context (expression : Tree.expression) =
  let typed = whole_value context expression in
  read_operand context expression.span ~reads:false typed

(* An expression without a target type, which its use takes whole: it
   discards, copies, sizes, addresses or tests it, or gives it to the
   expression around it, which reads it in turn. *)
and whole_value context (expression : Tree.expression) =
  positioned context Untargeted expression

(* An expression is typed once, in its one position: a second position
   would give it a second meaning, so asking in one is an internal
   error. *)
and positioned context position (expression : Tree.expression) =
  match Hashtbl.find_opt context.typed.types expression.span with
  | Some (typed_position, typed) when typed_position = position -> typed
  | Some _ -> invalid_arg "Expressions: an expression typed in two positions"
  | None ->
      let typed =
        nested context expression.span (fun () ->
            match constructor_expression context position expression with
            | Some (named, arguments) ->
                construct context expression named arguments
            | None -> expression_node context position expression)
      in
      (match position with
      | Targeted target ->
          refuse_distinct_conversion context expression.span target typed
      | Untargeted -> ());
      Hashtbl.replace context.typed.types expression.span (position, typed);
      Hashtbl.replace context.typed.constants expression.span
        (classify context expression typed);
      typed

and expression_node context position (whole : Tree.expression) =
  let span = whole.span in
  (* Parentheses, the branches of ?: and the right operand of a comma
     have the target type of the expression around them (design 3.3). *)
  let as_enclosing = positioned context position in
  (* An operand that the operation takes as a whole, as design 3.2 rule 6
     lets it take a variant: copies, sizes, addresses, passes on or
     discards. *)
  let as_whole = whole_value context in
  (* Any other operand, which the operation reaches into, so it may not
     be a variant; it reads a distinct value only where the table of
     design 3.4 says so. *)
  let typed operand =
    let operand_typed = whole_value context operand in
    refuse_variant context span operand_typed.expression_type;
    read_operand context span ~reads:(reads_distinct whole.node) operand_typed
  in
  match whole.node with
  | Identifier { name; resolution } -> identifier context span name resolution
  | Constant number -> value (constant_type context span number)
  | Character encoding -> value (character_type context span encoding)
  | String literal -> lvalue (string_type context literal)
  | Parenthesized inner -> as_enclosing inner
  | Generic _ -> selected context whole
  | Compound_literal { type_name; values } ->
      compound_literal context type_name values
  | Subscript { operand; index } ->
      let array = typed operand in
      subscript context span array (typed index)
  | Qualified_constructor _ ->
      invalid_arg "Expressions: a constructor that is no constructor expression"
  | Call { callee; arguments } ->
      refuse_parenthesized_constructor context callee;
      let callee_typed = typed callee in
      let positions =
        argument_positions context callee callee_typed arguments
      in
      let arguments = List.map2 (argument context) positions arguments in
      call context span callee callee_typed arguments
  | Member { operand; member } ->
      direct_member context span (typed operand) member
  | Pointer_member { operand; member } ->
      pointer_member context span (typed operand) member
  (* The value of a postfix operation is no bit-field in Clang. *)
  | Post_increment operand | Post_decrement operand ->
      increment context span ~clause:"6.5.2.4p1" (typed operand)
  | Unary ((Address as op), operand) -> unary context span op (as_whole operand)
  | Unary (op, operand) -> unary context span op (typed operand)
  | Sizeof_expression operand ->
      if designates_bit_field (as_whole operand) then
        context.fail span "sizeof of a bit-field (C11 6.5.3.4p1)";
      value (size_type context span)
  | Sizeof_type type_name | Alignof type_name ->
      ignore (context.type_name type_name);
      value (size_type context span)
  | Alignof_expression operand ->
      ignore (as_whole operand);
      value (size_type context span)
  (* 6.5.4p5: the value of a cast has the unqualified type. *)
  | Cast { type_name; operand } ->
      let cast_type = context.type_name type_name in
      refuse_variant context span cast_type;
      Option.iter
        (fun distinct ->
          refuse_private_creation context span cast_type
            ~described:("the distinct type " ^ distinct_name distinct))
        (Ctype.as_distinct cast_type);
      ignore (if discards cast_type then as_whole operand else typed operand);
      value (Ctype.unqualified cast_type)
  | Binary (op, left, right) ->
      let left = typed left in
      value (binary_type context span op left (typed right))
  | Conditional { condition; if_true; if_false } ->
      value (conditional context span position condition if_true if_false)
  | Assignment ((Assign as op), left, right) ->
      let left_typed = as_whole left in
      let right_position = Targeted left_typed.expression_type in
      assignment context span op left_typed
        (positioned context right_position right)
  | Assignment ((Compound_assign _ as op), left, right) ->
      let left_typed = typed left in
      assignment context span op left_typed (typed right)
  (* 6.5.17p2: the right operand's value. *)
  | Comma (left, right) ->
      ignore (as_whole left);
      let right = as_enclosing right in
      { expression_type = Ctype.lvalue_conversion right.expression_type;
        lvalue = false;
        bit_field = value_of right.bit_field }
  | Statement_expression block -> value (statement_expression context block)
  | Label_address _ -> value (void_pointer context span)
  | Va_arg { list; type_name } ->
      ignore (typed list);
      value (Ctype.unqualified (context.type_name type_name))
  | Offsetof { type_name; member = _; designators } ->
      refuse_variant context span (context.type_name type_name);
      List.iter (designator context) designators;
      value (size_type context span)
  | Choose _ -> selected context whole
  | Types_compatible (first, second) ->
      let first = type_as_seen context span (context.type_name first) in
      let second = type_as_seen context span (context.type_name second) in
      let answer = types_compatible_answer context span first second in
      record_answer context span [ first; second ]
        ~lowered:(fun compatible -> Compatible compatible)
        answer;
      Hashtbl.replace context.typed.compatibilities span answer;
      value (int_type context span)
  (* Clang's block, whose type typec does not model; its body is not
     typed. *)
  | Block_literal _ ->
      value (unknown context span "a block literal" Unknown_object)

(* Design 3.3: the value of the variant that the constructor makes from
   its arguments, one for each field, each converted to the type of its
   field as if by assignment. *)
and construct context (whole : Tree.expression) named arguments =
  record_site context ~variant_type:named.variant_type
    (Construction
       { span = whole.span;
         variant = named.variant_name;
         constructor = named.chosen.constructor_name;
         callee = called_name whole;
         arguments = Option.value arguments ~default:[];
         braced = false });
  let described = "the variant " ^ quote named.variant_name in
  refuse_private_creation context whole.span named.variant_type ~described;
  let name = quote named.chosen.constructor_name in
  let fields = named.chosen.fields in
  let refuse text = context.fail whole.span (constructor_message text) in
  (match (fields, arguments) with
  | [], None -> ()
  | [], Some _ ->
      refuse
        (Printf.sprintf
           "the constructor %s has no fields, so it is written without \
            parentheses"
           name)
  | _ :: _, None ->
      refuse (Printf.sprintf "the constructor %s takes arguments" name)
  | _ :: _, Some arguments ->
      if List.length arguments <> List.length fields then
        refuse
          (Printf.sprintf
             "the constructor %s takes one argument for each of its %d \
              fields"
             name (List.length fields));
      List.iter2 (constructor_argument context named) fields arguments);
  value named.variant_type

(* [(T.C)(args)]: constructor_expression takes only [T.C(args)] as a
   call, so a callee in parentheses would be a constructor without its
   arguments. *)
and refuse_parenthesized_constructor context (callee : Tree.expression) =
  let rec named (inner : Tree.expression) =
    match inner.node with
    | Parenthesized inner -> named inner
    | Qualified_constructor _ -> true
    | _ -> false
  in
  match callee.node with
  | Parenthesized inner when named inner ->
      context.fail callee.span
        (constructor_message
           "a constructor is not a function, so it cannot be called through \
            parentheses")
  | _ -> ()

(* The tokens that name a constructor that is called. *)
and called_name (whole : Tree.expression) =
  match whole.node with
  | Call { callee; _ } -> Some callee.span
  | _ -> None

(* The argument initialises its field in the braced list that the
   constructor lowers to. Where the field or the argument is a structure
   or union, a value of another type would initialise its first member
   through elided braces instead (C11 6.7.9p13), so the types must be
   compatible (6.5.16.1p1); the other conversions are the backend's, as
   for any assignment. *)
and constructor_argument context named (field : Ctype.member) argument =
  let field_type = field.member_type in
  let argument_type =
    Ctype.lvalue_conversion
      (positioned context (Targeted field_type) argument).expression_type
  in
  initialises_whole context field_type argument;
  let is_record t = Ctype.is_record t = Answer true in
  if is_record field_type || is_record argument_type then
    match
      Ctype.compatible context.target context.tags field_type argument_type
    with
    | Answer true | Depends_on _ -> ()
    | Answer false ->
        context.fail argument.span
          (constructor_message
             (Printf.sprintf
                "the argument for the field %s of %s does not have its type"
                (quote (Option.value field.member_name ~default:""))
                (quote named.chosen.constructor_name)))

(* The arguments of a call of a builtin that moves a value of the object
   that its first argument points to have the target types that the
   builtin states by that object; those of any other call have them by
   its prototype. The first argument is typed here, in the one position
   that [argument] gives it too. *)
and argument_positions context callee (callee_typed : typed) arguments =
  match (builtin_rule context callee, arguments) with
  | Some (_, Moves_object { operands; _ }), first :: rest ->
      let span = first.span in
      let first = expression context first in
      Untargeted :: moved_positions context span operands first rest
  | _ -> prototype_positions context callee_typed arguments

(* Design 3.4: a value moves into or out of the object that [first]
   points to as it is assigned, so a value of a distinct type moves only
   to and from an object of its type. The value has the unqualified type
   of the object, which drops the _Atomic of Clang's __c11 builtins. *)
and moved_positions context span operands (first : typed) arguments =
  match operand context first with
  | Pointer_operand { referenced; _ } ->
      let moved = Ctype.unqualified referenced in
      let position : Builtin_function.moved -> position = function
        | Object_type -> Targeted moved
        | Pointer_to_object ->
            Targeted (checked context span (Ctype.pointer_to moved))
      in
      zip_positions (List.map position operands) arguments
  | Arithmetic_operand _ | Distinct_operand _ | Other_operand _
  | Unknown_operand _ ->
      List.map (fun _ -> Untargeted) arguments

(* 6.5.2.2p7: the arguments of a call through a prototype are converted
   to the types of its parameters, which are their target types (design
   3.3); those past them, and those of other calls, have none. *)
and prototype_positions context (callee : typed) arguments =
  let parameters =
    match operand context callee with
    | Pointer_operand
        { referenced =
            { shape = Function { parameters = Prototype { types; _ }; _ }; _ };
          _ } ->
        types
    | Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
    | Other_operand _ | Unknown_operand _ ->
        []
  in
  zip_positions (List.map (fun t -> Targeted t) parameters) arguments

(* Design 3.4: a value of a distinct type passes only to a parameter of
   its type, not through [...] or to a function without a prototype,
   where the default argument promotions would convert it. *)
and argument context position argument =
  match position with
  | Targeted _ -> positioned context position argument
  | Untargeted -> expression context argument

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

(* A selection gives the chosen operand as it is, an lvalue or a
   bit-field where it is one, as GCC and Clang do. *)
and selected context (selecting : Tree.expression) =
  match selection_of context selecting with
  | Unknown.Answer chosen -> whole_value context chosen
  | Depends_on unknown ->
      value (Ctype.unknown { unknown with kind = Object_or_function })

(* The operand that a _Generic or __builtin_choose_expr selects, made
   once. Making it types the operands, in their own positions, but not
   the selection, so an initialiser can find a string literal that a
   selection gives before it types the selection in its position. *)
and selection_of context (selecting : Tree.expression) =
  let span = selecting.span in
  match Hashtbl.find_opt context.typed.selections span with
  | Some selection -> selection
  | None ->
      let selection =
        match selecting.node with
        | Generic { controlling; associations } ->
            generic context span controlling associations
        | Choose { condition; first; second } ->
            choose context span condition first second
        | _ -> invalid_arg "Expressions: a selection of no selection"
      in
      Hashtbl.replace context.typed.selections span selection;
      selection

(* 6.5.1.1p4: the selection is its result expression, an lvalue or a
   function designator if that is one. Every association is typed, as
   GCC and Clang check the ones they do not select. The type that
   selects is that of the controlling expression after lvalue conversion,
   as C17 says and GCC and Clang do in every mode. *)
and generic context span controlling associations =
  let controlling_typed = whole_value context controlling in
  let associations_typed =
    List.map (generic_association context span) associations
  in
  check_distinct context associations_typed;
  let default = default_association context associations_typed in
  let controlling_type =
    Ctype.lvalue_conversion
      (as_seen context span controlling_typed).expression_type
  in
  let types =
    controlling_type
    :: List.filter_map (fun a -> a.association_type) associations_typed
  in
  let selection =
    select context span controlling_type associations_typed default
  in
  record_answer context span types
    ~lowered:(fun result -> Selected { controlling; associations; result })
    selection;
  selection

(* Both operands are typed. *)
and choose context span condition first second =
  ignore (expression context condition);
  ignore (whole_value context first);
  ignore (whole_value context second);
  choice context span condition first second

(* The association of the selection at [span], with its type as the text
   of the selection sees it. *)
and generic_association context span
    (association : Tree.generic_association) =
  let association_type, result =
    match association.node with
    | Association (type_name, result) ->
        (Some (type_as_seen context span (context.type_name type_name)),
         result)
    | Default_association result -> (None, result)
  in
  ignore (whole_value context result);
  { association_span = association.span; association_type; result }

(* 6.5.2.5p4: an lvalue of the type name's type, which the initialiser
   completes where it is an array of unknown size; outside the body of a
   function its initialisers are constant (p3). *)
and compound_literal context type_name values =
  let t = context.type_name type_name in
  let constant = context.typed.enclosing.function_name = None in
  lvalue (initialiser context ~constant t (Tree.Braced values))

(* 6.5.15p3 to p6. A GNU [a ?: b] has [a] as its second operand. *)
and conditional context span position condition if_true if_false =
  let condition_typed = whole_value context condition in
  require_scalar context condition.span ~clause:"6.5.15p2" condition_typed;
  let branch_typed = positioned context position in
  let second =
    match if_true with
    | Some branch -> { branch; branch_typed = branch_typed branch }
    | None -> { branch = condition; branch_typed = condition_typed }
  in
  let third = { branch = if_false; branch_typed = branch_typed if_false } in
  let branch_operand branch =
    operand context (as_seen context span branch.branch_typed)
  in
  let second_operand = branch_operand second
  and third_operand = branch_operand third in
  refuse_mixed_pointers context span second_operand third_operand;
  match (second_operand, third_operand) with
  | Distinct_operand a, Distinct_operand b when one_distinct context a b -> a
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
  | Distinct_operand t, _ | _, Distinct_operand t -> refuse_mixed context span t
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
  match value_source context candidate with
  | Depends_on _ -> Opaque_constant
  | Answer source -> (
      match source.node with
      | Cast { operand; _ }
        when is_plain_void_pointer
               (operand_typed context source).expression_type
        ->
          zero_constant context operand
      | _ -> zero_constant context source)

(* An operation that fails gives an opaque value rather than an error:
   this is no constant expression context. Whether an operand of unknown
   type is one is unknown too. *)
and zero_constant context candidate =
  let typed = operand_typed context candidate in
  match
    (Ctype.is_integer typed.expression_type, operand_constant context candidate)
  with
  | Depends_on _, _ -> Opaque_constant
  | _, Integer_expression { value = { value = Known value; _ }; flaw = None }
    when Exact_integer.equal value Exact_integer.zero ->
      Null
  | _, (Integer_expression { value = { value = Opaque; _ }; _ } | Unevaluable _)
    ->
      Opaque_constant
  | _, (Integer_expression _ | Not_integer _) -> Not_null

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
   void, which is no bit-field in Clang. *)
and statement_expression context (block : Tree.block) =
  block_items context block;
  match List.rev block.node.items with
  | Block_statement { node = Expression_statement last; _ } :: _ ->
      Ctype.lvalue_conversion (whole_value context last).expression_type
  | (Block_statement _ | Block_declaration _ | Block_type_declaration _) :: _
  | [] ->
      Ctype.void

and designator context (designator : Tree.designator) =
  match designator.node with
  | Index index -> ignore (expression context index)
  | Index_range { low; high } ->
      ignore (expression context low);
      ignore (expression context high)
  | Member_designator _ -> ()

and integer_constant context candidate =
  ignore (expression context candidate);
  match operand_constant context candidate with
  | Integer_expression { value; flaw = None } -> Ok value
  | Integer_expression { flaw = Some (Comma_operator span); _ } -> Error span
  | Integer_expression { flaw = Some (Invalid { span; message }); _ }
  | Unevaluable { span; message } ->
      context.fail span message
  | Not_integer { first; _ } -> Error first

(* Design 13.5: a constructor that initialises a whole object of its
   variant, with no brace elided before it, lowers to its braced list
   alone, which keeps a static initialiser constant. An atomic object
   takes no braced list in Clang, so it keeps the compound literal. *)
and initialises_whole context t (initialising : Tree.expression) =
  let span = initialising.span in
  match Sites.construction context.typed.sites span with
  | Some construction ->
      let variant_type = (operand_typed context initialising).expression_type in
      if
        Ctype.compatible context.target context.tags
          (Ctype.without_top_qualifiers t) variant_type
        = Answer true
      then Sites.brace context.typed.sites construction
  | None -> ()

and initialiser context ~constant t initialiser =
  (* [value] types an expression, which classes it too; the other
     callbacks take one that it has typed, or type none. *)
  let value subobject initialising =
    let position =
      match subobject with
      | Some subobject_type -> Targeted subobject_type
      | None -> Untargeted
    in
    (positioned context position initialising).expression_type
  in
  let converts scalar initialising =
    refuse_distinct_conversion context initialising.Tree.span scalar
      (operand_typed context initialising)
  in
  let initialises initialising =
    if constant then require_constant context initialising
  in
  let typing : Initialiser.typing =
    {
      target = context.target;
      tags = context.tags;
      fail = context.fail;
      value;
      converts;
      initialises;
      source = source_through (selection_of context);
      initialises_whole = initialises_whole context;
      type_c_text = is_type_c_text context;
      index = integer_constant context;
    }
  in
  Initialiser.initialise typing t initialiser

and block_items context (block : Tree.block) = items context block.node.items

and items context =
  List.iter (function
    | Tree.Block_declaration declaration -> context.declaration declaration
    | Block_type_declaration declaration ->
        context.type_declaration declaration
    | Block_statement statement -> typed_statement context statement)

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
      (whole_value context condition)
  in
  match statement.node with
  | Labeled { label; statement = labeled } ->
      label_of context label;
      typed_statement context labeled
  | Compound block -> block_items context block
  | Expression_statement value -> ignore (whole_value context value)
  | Computed_goto value -> ignore (expression context value)
  | Null_statement | Attribute_statement _ | Goto _ -> ()
  | If { condition; then_branch; else_branch } ->
      scalar ~clause:"6.8.4.1p1" condition;
      typed_statement context then_branch;
      Option.iter (typed_statement context) else_branch
  | Switch { controlling; body } ->
      switch_controlling context controlling;
      within context { enclosing with case_labels = Switch_body } (fun () ->
          typed_statement context body)
  | Match { scrutinee; arms } ->
      match_statement context statement scrutinee arms
  | While { condition; body } ->
      scalar ~clause:"6.8.5p2" condition;
      in_loop body
  | Do { body; condition } ->
      in_loop body;
      scalar ~clause:"6.8.5p2" condition
  | For { clause; condition; step; body } ->
      Option.iter (for_clause context) clause;
      Option.iter (scalar ~clause:"6.8.5p2") condition;
      Option.iter (fun step -> ignore (whole_value context step)) step;
      in_loop body
  | Continue ->
      if not enclosing.in_loop then
        context.fail statement.span "continue outside a loop (C11 6.8.6.2p1)"
  | Break ->
      if (not enclosing.in_loop) && enclosing.case_labels = No_switch then
        context.fail statement.span
          "break outside a loop, switch or match (C11 6.8.6.3p1, design 4.3 \
           rule 2)"
  | Return value ->
      let position =
        match enclosing.return_type with
        | Some t -> Targeted t
        | None -> Untargeted
      in
      Option.iter
        (fun value -> ignore (positioned context position value))
        value
  (* Design 3.4: an asm operand takes a value whole, a distinct one too,
     since asm is unchecked and the backend sees the representation. *)
  | Asm { operands; qualifiers = _; template = _ } ->
      Option.iter
        (fun (operands : Tree.asm_operands) ->
          List.iter
            (fun (operand : Tree.asm_operand) ->
              ignore (whole_value context operand.node.value))
            (operands.outputs @ operands.inputs))
        operands

and for_clause context (clause : Tree.for_clause) =
  match clause with
  | Clause_declaration declaration -> context.declaration declaration
  | Clause_expression value -> ignore (whole_value context value)

(* 6.8.4.2p1. *)
and switch_controlling context controlling =
  match operand context (expression context controlling) with
  | Arithmetic_operand { arithmetic = Integer _; _ } | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail controlling.span
        "the controlling expression of a switch is not an integer (C11 \
         6.8.4.2p1)"

(* 6.8.1p2: case and default labels only in a switch. *)
and label_of context (label : Tree.label) =
  let in_switch () =
    match context.typed.enclosing.case_labels with
    | Switch_body -> ()
    | Match_arm ->
        context.fail label.span
          (Rule.message Enclosing_switch_label
             "a case or default label inside a match arm, which is not one \
              of its own and belongs to no switch inside it")
    | No_switch ->
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
  | Arithmetic_operand { arithmetic = Integer _; _ } -> (
      match integer_constant context value with
      | Ok _ -> ()
      | Error _ ->
          context.fail value.span
            "a case label is not an integer constant expression (C11 \
             6.8.4.2p3)")
  | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail value.span "a case label is not an integer (C11 6.8.4.2p3)"

(* Matching (design 4) *)

(* The constructors that no label names, in declaration order: what a
   [default] covers, or what a match without one misses (4.2 rule 1). *)
and uncovered (constructors : Ctype.constructor list) named =
  List.filter
    (fun (constructor : Ctype.constructor) ->
      not (List.mem constructor.constructor_name named))
    constructors

and match_statement context (statement : Tree.statement) scrutinee arms =
  let typed = expression context scrutinee in
  let t = typed.expression_type in
  let variant, constructors = scrutinee_variant context scrutinee.span t in
  record_site context ~variant_type:t
    (Matching
       { statement = statement.span; scrutinee = scrutinee.span; variant;
         access = access_of context scrutinee t;
         arms =
           (fun () ->
             typed_arms context ~statement variant constructors arms) })

(* The arms of a match of [variant]: their labels, the coverage of the
   constructors and the items of each arm. *)
and typed_arms context ~(statement : Tree.statement) variant constructors
    arms =
  let labelled =
    List.map (labelled_constructors context variant constructors) arms
  in
  let defaulted =
    coverage context ~statement:statement.span variant constructors
      (List.concat labelled)
  in
  let enclosing = { context.typed.enclosing with case_labels = Match_arm } in
  List.map2
    (fun (arm : Tree.arm) labels ->
      let matched = matched_arm context arm labels defaulted in
      within context enclosing (fun () -> arm_items context arm);
      refuse_open_arm context arm;
      matched)
    arms labelled

(* Design 4.4: a callee that designates a function declared [_Noreturn]
   or with the GNU [noreturn], or a builtin that is; an undeclared name
   that typing accepted is a builtin. Which function of an overload set
   a call names is unknown, so it may return. *)
and calls_noreturn context (callee : Tree.expression) =
  match callee.node with
  | Parenthesized inner -> calls_noreturn context inner
  | Identifier { name; resolution = Undeclared } ->
      Builtin_function.noreturn name
  | Identifier { resolution = Resolved reference; _ }
    when context.overloaded reference ->
      false
  | Identifier { name; resolution = Resolved reference } -> (
      match (context.entity callee.span name reference).declared with
      | Function { noreturn; _ } -> noreturn
      | Object _ | Typedef _ | Enumerator _ -> false)
  | _ -> false

(* Design 4.4: a condition that is an integer constant expression the
   front end evaluates (13.3), other than 0. *)
and non_zero_constant context condition =
  match constant context.typed condition with
  | Some (Integer_expression { value; flaw = None }) ->
      Integer_constant.truth value = Some true
  | Some (Integer_expression { flaw = Some _; _ } | Not_integer _
         | Unevaluable _)
  | None ->
      false

and reachability_facts context =
  { Reachability.noreturn = calls_noreturn context;
    non_zero = non_zero_constant context }

(* Design 4.3 rule 1, asked of each arm once typing has read it, so that
   every match that typing reads, and lowering emits, is checked. An arm
   is walked again for each arm around it, at most as many times as the
   parser's bound on nested brackets. *)
and refuse_open_arm context arm =
  match Reachability.arm_refusal (reachability_facts context) arm with
  | Some { span; message } -> context.fail span message
  | None -> ()

(* 4.1 rule 1, 4.2 rule 4: a variant, whose qualifiers are ignored, and
   complete here, so that its constructors are known. *)
and scrutinee_variant context span t =
  match (Ctype.as_variant t, Ctype.constructors context.tags t) with
  | Some variant, Some constructors -> (variant, constructors)
  | Some variant, None ->
      context.fail span
        (Rule.message Match_scrutinee
           (Printf.sprintf
              "the scrutinee of a match is of the incomplete variant %s, \
               whose constructors are unknown here"
              (quote variant)))
  | None, _ ->
      context.fail span
        (Rule.message Match_scrutinee
           "the scrutinee of a match is not of a variant type; a pointer \
            is not dereferenced implicitly")

(* The constructor that [pattern] names, with one sub-pattern per field
   (4.1 rule 3). *)
and pattern_constructor context variant constructors (label : Tree.arm_label)
    (pattern : Tree.pattern) =
  let name = pattern.constructor.node in
  let given = List.length (Option.value pattern.sub_patterns ~default:[]) in
  match
    List.find_opt
      (fun (constructor : Ctype.constructor) ->
        constructor.constructor_name = name)
      constructors
  with
  | None ->
      context.fail label.span
        (Rule.message Pattern
           (Printf.sprintf "%s names no constructor of the variant %s"
              (quote name) (quote variant)))
  | Some constructor when List.length constructor.fields <> given ->
      context.fail label.span
        (Rule.message Pattern
           (Printf.sprintf
              "the pattern %s has %d sub-pattern(s), and the constructor \
               has %d field(s)"
              (quote name) given (List.length constructor.fields)))
  | Some constructor -> constructor

(* Each label of [arm] with the constructor that its pattern names;
   [None] for a [default]. *)
and labelled_constructors context variant constructors (arm : Tree.arm) =
  List.map
    (fun (label : Tree.arm_label) ->
      match label.node with
      | Default_arm_label -> (label, None)
      | Pattern_label pattern ->
          let constructor =
            pattern_constructor context variant constructors label pattern
          in
          (label, Some constructor))
    arm.node.labels

(* 4.2 rules 1 and 2 over the labels of a match, in order: each
   constructor is covered once, by a label or by the one [default], which
   covers at least one. The result is what the [default] covers. *)
and coverage context ~statement variant constructors labelled =
  let rec named seen defaults = function
    | [] -> (seen, defaults)
    | ((label : Tree.arm_label), None) :: rest ->
        if defaults <> [] then
          context.fail label.span
            (Rule.message Default_arm "a match has a second `default`");
        named seen (label :: defaults) rest
    | (label, Some (constructor : Ctype.constructor)) :: rest ->
        let name = constructor.constructor_name in
        if List.mem name seen then
          context.fail label.span
            (Rule.message Exhaustiveness
               (Printf.sprintf "the constructor %s is covered twice"
                  (quote name)));
        named (name :: seen) defaults rest
  in
  let seen, defaults = named [] [] labelled in
  let missing = uncovered constructors seen in
  match (defaults, missing) with
  | [], [] -> []
  | [], _ :: _ ->
      context.fail statement
        (Rule.message Exhaustiveness
           (Printf.sprintf "the match does not cover %s of the variant %s"
              (constructor_list (List.map constructor_name missing))
              (quote variant)))
  | (default : Tree.arm_label) :: _, [] ->
      context.fail default.span
        (Rule.message Default_arm
           "the `default` of a match covers no constructor")
  | _ :: _, _ :: _ -> missing

and constructor_name (constructor : Ctype.constructor) =
  constructor.constructor_name

(* What a diagnostic calls the constructors [names]. *)
and constructor_list names =
  let quoted = List.map quote names in
  match List.rev quoted with
  | [ one ] -> "the constructor " ^ one
  | last :: before ->
      Printf.sprintf "the constructors %s and %s"
        (String.concat ", " (List.rev before))
        last
  | [] -> invalid_arg "Expressions.constructor_list: no constructor"

(* An arm and its bindings, which only an arm of one label may declare
   (4.1 rule 6). A binding is a non-modifiable object of its field's
   type in the arm's scope (rule 4). *)
and matched_arm context (arm : Tree.arm) labelled defaulted =
  let labels = arm.node.labels in
  let first = List.hd labels and last = List.hd (List.rev labels) in
  let bindings =
    match labelled with
    | [ ({ Tree.node = Pattern_label pattern; _ }, Some constructor) ] ->
        pattern_bindings context pattern constructor
    | _ ->
        List.iter (refuse_shared_binding context) labels;
        []
  in
  let cases =
    List.concat_map
      (function
        | _, Some constructor -> [ constructor ] | _, None -> defaulted)
      labelled
  in
  { arm = arm.span;
    labels = { first = first.span.first; last = last.span.last };
    cases = List.map constructor_name cases;
    bindings }

and refuse_shared_binding context (label : Tree.arm_label) =
  match label.node with
  | Pattern_label { sub_patterns = Some sub_patterns; _ } ->
      List.iter
        (function
          | Tree.Binding { name; _ } ->
              context.fail name.span
                (Rule.message Shared_arm
                   (Printf.sprintf
                      "the binding %s is in an arm of several labels, which \
                       none of them may bind"
                      (quote name.node)))
          | Wildcard _ -> ())
        sub_patterns
  | Pattern_label { sub_patterns = None; _ } | Default_arm_label -> ()

and pattern_bindings context (pattern : Tree.pattern)
    (constructor : Ctype.constructor) =
  let name = constructor.constructor_name in
  let sub_patterns = Option.value pattern.sub_patterns ~default:[] in
  List.concat
    (List.map2
       (fun (sub_pattern : Tree.sub_pattern) (field : Ctype.member) ->
         match (sub_pattern, field.member_name) with
         | Wildcard _, _ -> []
         | Binding { name = binding; declared }, Some field_name ->
             context.binding binding declared
               (non_modifiable field.member_type);
             [ { name = binding.node; constructor = name; field = field_name } ]
         | Binding _, None ->
             invalid_arg "Expressions.pattern_bindings: an unnamed field")
       sub_patterns constructor.fields)

(* A field type is unqualified and no array (design 3.2 rule 4), so it
   takes [const]. *)
and non_modifiable t =
  match Ctype.qualify { Qualifiers.none with const = true } t with
  | Ok qualified -> qualified
  | Error _ -> invalid_arg "Expressions.non_modifiable: no value type"

and arm_items context (arm : Tree.arm) = items context arm.node.items

(* Design 13.5: the lowered match reaches the scrutinee in place, through
   a pointer to it, unless it is volatile or atomic or may not be
   addressed. Any other scrutinee is copied, which only costs time. *)
and access_of context (scrutinee : Tree.expression) (t : Ctype.t) =
  if t.qualifiers.volatile || t.qualifiers.atomic then Through_copy
  else if addressable context scrutinee then Through_pointer
  else Through_copy

(* Whether [e] is an lvalue that C lets [&] take (C11 6.5.3.2p1): one that
   a pointer reaches, a compound literal, a named object not declared
   [register], or a member or element of one of those. Another lvalue is
   taken as not, which is safe. No bit-field has a variant type
   (6.7.2.1p5). *)
and addressable context (e : Tree.expression) =
  match e.node with
  | Unary (Indirection, _) | Pointer_member _ | Compound_literal _ -> true
  | Parenthesized inner | Member { operand = inner; _ } ->
      addressable context inner
  | Subscript { operand; index } ->
      subscripted_addressable context operand
      && subscripted_addressable context index
  | Identifier { name; resolution = Resolved reference } -> (
      match (context.entity e.span name reference).declared with
      | Object { register; _ } -> not register
      | Function _ | Typedef _ | Enumerator _ -> false)
  | _ -> false

(* An operand of [e1[e2]] is a pointer, which reaches an object, or an
   array, which converts to one only where C may take its address
   (6.5.2.1p2, 6.3.2.1p3). *)
and subscripted_addressable context (operand : Tree.expression) =
  match find context.typed operand with
  | Some { expression_type = { shape = Array _; _ }; _ } ->
      addressable context operand
  | Some _ -> true
  | None -> false

let function_body context ~name ~return_type block =
  let enclosing =
    { outside_functions with function_name = Some name; return_type }
  in
  within context enclosing (fun () -> block_items context block);
  match Reachability.jump_refusal (reachability_facts context) block with
  | Some { span; message } -> context.fail span message
  | None -> ()
