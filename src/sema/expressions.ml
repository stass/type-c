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

type category = Lvalue | Value | Atomic_value

type typed = {
  expression_type : Ctype.t;
  category : category;
  bit_field : bit_field;
}

type flaw =
  | Comma_operator of Tree.span
  | Invalid of { span : Tree.span; diagnostic : Rule.diagnostic }

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
  | Unevaluable of { span : Tree.span; diagnostic : Rule.diagnostic }

(* What a case or default label in the statement being typed belongs
   to: no switch, the innermost switch, or a match arm, the statement of
   a single-pattern test, the statement of a defer or the scope of one,
   where it belongs to no switch of its own (design 4.3 rule 3, 4.6 rule
   6, 6 rule 5). *)
type label_owner =
  | No_switch
  | Switch_body
  | Match_arm
  | Test_statement
  | Deferred_statement
  | Defer_scope

(* Where a statement stands: as a block item, or as the substatement of
   another statement. *)
type standing = Block_item | Substatement

type holder = {
  statement : Tree.span;
  labels : Tree.span option;
  standing : standing;
}

(* The positions of design 5.1 rule 3: the whole of an expression
   statement, the whole right operand of a simple assignment that is
   one, and the whole initialiser of the one declarator of a block-item
   declaration. *)
type try_form = Whole_statement | Assigned | Initialiser

type try_site = {
  try_span : Tree.span;
  operand : Tree.span;
  holder : holder;
  form : try_form;
  place : Parser.View.t;
  temporary : int;
  operand_instance : Ctype.instance;
  return_instance : Ctype.instance;
  ok_field : string option;
  err_field : string option;
}

(* Whether a function returns void, which decides the form of a return
   of a value in the scope of a defer (design 13.5). *)
type returns = Returns_void | Returns_value

type function_defers = {
  function_name : string;
  declarator : Tree.declarator;
  body : Tree.span;
  returns : returns;
  sites : Reachability.defer_site list;
}

(* The try at [held_span] that [holder], the statement or declaration
   being typed, holds in the position [form]. *)
type try_holder = { held_span : Tree.span; form : try_form; holder : holder }

(* The try that the statement being typed gives a position, if any. A
   declaration gives it only once the object it initialises is one that
   the position allows, which the initialiser alone sees. *)
type try_place =
  | No_place
  | Unchecked_declaration of try_holder
  | Placed of try_holder

(* Whether statements give a try the positions of design 5.1 rule 3,
   which those of a function body do outside any statement expression,
   and if so the try that the statement being typed gives one. *)
type try_positions = No_positions | Positions of try_place

(* What encloses the statement being typed: the function, for __func__,
   return and try, the switch or match that case labels need, and the
   positions of try. [return_type] is [None] outside functions. *)
type enclosing = {
  function_name : string option;
  return_type : Ctype.t Unknown.answer option;
  case_labels : label_owner;
  try_positions : try_positions;
}

type construction = {
  span : Tree.span;
  variant : Ctype.variant_name;
  constructor : Spelling.constructor;
  callee : Tree.span option;
  arguments : Tree.expression list;
  braced : bool;
}

type access = Through_pointer | Through_copy
type binding = {
  name : string;
  constructor : Spelling.constructor;
  field : string;
}

type matched_arm = {
  arm : Tree.span;
  labels : Tree.span;
  cases : Spelling.constructor list;
  bindings : binding list;
}

type test_form = If_test of { otherwise : Tree.span option } | While_test

type test = {
  form : test_form;
  constructor : Spelling.constructor;
  constructors : Spelling.constructor list;
  bindings : binding list;
  controlled : Tree.span;
}

type selection = Arms of matched_arm list | Test of test

type 'selects matching_of = {
  statement : Tree.span;
  scrutinee : Tree.span;
  variant : Ctype.variant_name;
  access : access;
  selects : 'selects;
}

type matching = selection matching_of

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

let quoted_variant name = quote (Encoding.variant_name name :> string)

(* The sites that lowering replaces with the names that their variant
   derives (design 3.3, 4.1 rule 1). Those names denote the variant only
   within the scope of its declaration (10.1 rule 6), and [record] is the
   one way to hand a site to lowering, so none lies outside the scope. *)
module Sites : sig
  type t
  (* A match comes with the typing of its arms, and a test with the
     typing of its pattern and statement, which [record] runs only once
     the matching is in scope, so that the scope is the first thing that
     it is checked for. *)
  type site =
    | Construction of construction
    | Matching of (unit -> matched_arm list) matching_of
    | Testing of (unit -> test) matching_of

  val create : unit -> t

  val record :
    t ->
    Ctype.tags ->
    fail:(Tree.span -> Rule.diagnostic -> unit) ->
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
    | Testing of (unit -> test) matching_of

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
         what (quoted_variant variant))

  (* A matching that [what] names, with what it selects typed by
     [selects] once it is known to be in scope. *)
  let record_matching sites tags ~fail ~variant_type ~what matching selects
      =
    if within_scope tags variant_type matching.statement then
      Hashtbl.replace sites.matchings matching.statement
        { matching with selects = selects () }
    else
      fail matching.scrutinee
        (outside_scope Match_scrutinee ~what ~variant:matching.variant)

  let record sites tags ~fail ~variant_type = function
    | Construction construction ->
        if within_scope tags variant_type construction.span then
          Hashtbl.replace sites.constructions construction.span construction
        else
          fail construction.span
            (outside_scope Variant_scope ~what:"the constructor expression"
               ~variant:construction.variant)
    | Matching matching ->
        record_matching sites tags ~fail ~variant_type ~what:"the match"
          matching (fun () -> Arms (matching.selects ()))
    | Testing testing ->
        record_matching sites tags ~fail ~variant_type
          ~what:"the single-pattern test" testing (fun () ->
            Test (testing.selects ()))

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
   unqualified constructor (design 3.3), or none. A [Discarded] position
   has none and discards the value (6.3.2.2p1), which a conditional of a
   type that typec does not know needs to tell (design 5.2). *)
type position = Untargeted | Targeted of Ctype.t | Discarded

(* The position of an operand whose value is that of the expression
   around it, which stands in [position]: the association that a
   selection selects and the last item of a statement expression. It is
   discarded where that expression is (design 5.2), but has no target
   type, as design 3.3 gives neither one. *)
let value_position = function
  | Discarded -> Discarded
  | Untargeted | Targeted _ -> Untargeted

(* Where a pattern stands, which decides whether it may omit the field
   list of a constructor with fields: only a test may (design 4.1 rule 3,
   4.6 rule 2). *)
type pattern_site = Match_label | Test_pattern

(* A pattern checked against the constructor it names: each sub-pattern
   with its field, none without a field list. Only [pattern_constructor]
   builds one, so that no binding pairs sub-patterns left unchecked. *)
type checked_pattern = {
  constructor : Ctype.constructor;
  sub_fields : (Tree.sub_pattern * Ctype.member) list;
}

(* The spans of the measurements of types that mention a type parameter
   (design 7.1 rule 4): the last token of each, by its first. Of two that
   begin at one token, the inner one is kept. *)
module Measurements = Map.Make (Int)

(* [enclosing] belongs to the walk in progress. Only the reader's failure
   leaves a walk early, and it ends the read, so it is not restored on
   it. [selections] and [compatibilities] hold the answers to the
   constructs that ask whether types are compatible, by the span of the
   construct, and [answered] those that lowering replaces with their
   answer. [types] holds the type of each expression, which [positioned]
   alone gives, once. *)
type t = {
  types : (Tree.span, typed) Hashtbl.t;
  constants : (Tree.span, constant) Hashtbl.t;
  mutable measurements : int Measurements.t;
  selections : (Tree.span, Tree.expression Unknown.answer) Hashtbl.t;
  compatibilities : (Tree.span, bool Unknown.answer) Hashtbl.t;
  answered : (Tree.span, answered) Hashtbl.t;
  sites : Sites.t;
  mutable enclosing : enclosing;
  mutable tries : try_site list;
  mutable function_tries : try_site list;
  mutable defers : function_defers list;
}

let outside_functions =
  { function_name = None; return_type = None; case_labels = No_switch;
    try_positions = No_positions }

let create () =
  { types = Hashtbl.create 16;
    constants = Hashtbl.create 16;
    measurements = Measurements.empty;
    selections = Hashtbl.create 16;
    compatibilities = Hashtbl.create 16;
    answered = Hashtbl.create 16;
    sites = Sites.create ();
    enclosing = outside_functions;
    tries = [];
    function_tries = [];
    defers = [] }

let find_at view span = Hashtbl.find_opt view.types span
let find view (expression : Tree.expression) = find_at view expression.span

let constant view (expression : Tree.expression) =
  Hashtbl.find_opt view.constants expression.span

let selection view (expression : Tree.expression) =
  Hashtbl.find_opt view.selections expression.span

let constructions view = Sites.constructions view.sites
let matchings view = Sites.matchings view.sites
let tries view = List.rev view.tries
let defers view = List.rev view.defers

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
  fail : 'a. Tree.span -> Rule.diagnostic -> 'a;
  entity : Tree.span -> string -> Tree.reference -> Entity.t;
  overloaded : Tree.reference -> bool;
  generic_function : Tree.reference -> bool;
  type_name : Tree.type_name -> Ctype.t;
  declaration : Tree.declaration -> unit;
  type_declaration : Tree.scoped_type_declaration -> unit;
  binding : Tree.identifier -> Tree.declared -> Ctype.t -> unit;
  needs_complete : Ctype.t -> unit;
  block_literal : unit -> unit;
  views : Parser.views;
  moved_operand :
    Parser.try_views -> scope:Tree.scope_depth -> Tree.span ->
    (unit -> typed) -> typed;
  read_moved : Tree.span -> (unit -> unit) -> unit;
  label_address : Tree.label_name -> unit;
}

let needing need (unknown : Unknown.t) =
  let why =
    match unknown.cause with
    | Not_typed -> "which typec does not type yet"
    | Typed_differently -> "which GCC types otherwise than Clang"
  in
  Rule.message Profile
    (Printf.sprintf "%s depends on %s at %s:%d, %s (design 13.3)" need
       unknown.construct unknown.location.file unknown.location.line why)

let returns_void enclosing =
  match enclosing.return_type with
  | Some (Answer t) -> Ctype.is_void t = Answer true
  | Some (Depends_on _) | None -> false

let within context enclosing walk =
  let view = context.typed in
  let saved = view.enclosing in
  view.enclosing <- enclosing;
  let walked = walk () in
  view.enclosing <- saved;
  walked

(* Building results *)

let checked context span = function
  | Ok t -> t
  | Error error -> context.fail span (Rule.c_text (Ctype.error_message error))

(* Clang gives a value an _Atomic type only where it converts none
   ([value_type]), so a value built with one is an [Atomic_value]; a
   member, which Clang converts, has its category from [member_category]
   instead. *)
let value (expression_type : Ctype.t) =
  let category =
    if expression_type.qualifiers.atomic then Atomic_value else Value
  in
  { expression_type; category; bit_field = Not_bit_field }

let lvalue expression_type =
  { expression_type; category = Lvalue; bit_field = Not_bit_field }

(* 6.3.2.1p2-4: the type of the value of a typed expression. Clang
   converts a value as it does an lvalue, but for an _Atomic one. *)
let value_type typed =
  match typed.category with
  | Atomic_value -> typed.expression_type
  | Lvalue | Value -> Ctype.lvalue_conversion typed.expression_type

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

(* Whether two types are compatible, asked by the construct at [span]. *)
let compatible context span a b =
  Ctype.compatible context.target context.tags (location_of context span) a b

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
    (Rule.c_text
       ("the operands have types that the operator does not take (C11 " ^ clause
      ^ ")"))

(* Design 3.2 rule 6: Type-C text reaches the tag and fields of a
   variant only through constructors and matching, so an operation at [span]
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
               its tag and fields only through constructors and matching"
              (quoted_variant name)))
  | Some _ | None -> ()

(* Design 7.1 rule 3: an instance of a generic function is its text with
   each type parameter naming its argument, so a use of a type parameter
   that C refuses of a structure, or types otherwise for another value
   type, is refused where the check reads it. *)
let refuse_type_parameter context (span : Tree.span) use =
  context.fail span
    (Rule.message Type_parameter_operation
       (use ^ ", which is not valid C of one meaning for every value type"))

let read_type_parameter context span =
  refuse_type_parameter context span
    "a value of a type parameter is the operand of an operation"

(* The operations that read a value as an operand: all but those that
   take it whole (design 7.1 rule 3). *)
let refuse_type_parameter_operand context span (t : Ctype.t) =
  if Ctype.is_opaque t then read_type_parameter context span

(* Design 7.1 rule 3: an asm constraint depends on the size and kind of
   its operand, which differ between arguments. *)
let refuse_type_parameter_asm context span (t : Ctype.t) =
  if Ctype.mentions_opaque context.tags t then
    refuse_type_parameter context span
      "an asm operand has a type that mentions a type parameter"

(* Provisional (design 7.1 rule 3): the conditional operator gives
   two values of a type parameter the type of the usual arithmetic
   conversions, which differs between arguments. *)
let refuse_type_parameter_branch context span (branch : typed) =
  if Ctype.is_opaque branch.expression_type then
    refuse_type_parameter context span
      "a value of a type parameter is a branch of the conditional operator"

(* Design 7.1 rule 3: a construct that asks whether two types are
   compatible gives the answer of the argument. *)
let refuse_type_parameter_comparison context span construct types =
  if List.exists (Ctype.mentions_opaque context.tags) types then
    refuse_type_parameter context span
      (construct ^ " compares a type that mentions a type parameter")

(* An assignment, which has stored the value that it gives. *)
let rec is_assignment (expression : Tree.expression) =
  match expression.node with
  | Assignment _ -> true
  | Parenthesized inner -> is_assignment inner
  | _ -> false

(* Design 5.2: whether discarding [discarded], typed as [typed], drops a
   value of a result type in Type-C text, judged by its first token;
   discarding an assignment drops nothing. *)
let drops_result context (discarded : Tree.expression) typed =
  Option.is_some (Ctype.as_result typed.expression_type)
  && is_type_c_text context discarded.span
  && not (is_assignment discarded)

let dropped_result =
  Rule.message Dropped_result
    "a value of a result type is discarded; handle it with try or match, \
     store it, or cast it to void"

(* Design 5.2: Type-C text discards no value of a result type. *)
let refuse_dropped_result context (discarded : Tree.expression) typed =
  if drops_result context discarded typed then
    context.fail discarded.span dropped_result

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
  context.needs_complete t;
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
  context.needs_complete typed.expression_type;
  let typed = as_seen context span typed in
  refuse_type_parameter_operand context span typed.expression_type;
  match Ctype.as_distinct typed.expression_type with
  | Some distinct when not reads -> refuse_distinct context span distinct
  | Some _ | None -> typed

(* Design 3.4: [==], [!=] and [?:] take two values of one distinct type,
   [t], where they take one; [one_distinct] says whether they are. *)
let one_distinct context span (t : Ctype.t) other =
  compatible context span t other = Answer true

let refuse_mixed context span (t : Ctype.t) =
  let name =
    match Ctype.as_distinct t with
    | Some distinct -> distinct_name distinct
    | None -> invalid_arg "Expressions: a mixed operand that is not distinct"
  in
  context.fail span
    (Rule.message Distinct_operation
       ("the operands are not both of the distinct type " ^ name))

let differs context span a b = compatible context span a b = Answer false

(* Why two pointers do not meet. *)
type pointer_gap =
  | Distinct_gap
      (** Design 3.4: [D *] and [U *] are incompatible. GNU C only warns
          where two pointers to incompatible types meet, and the backend,
          which sees U for D, does not even warn, so typec decides in
          Type-C text. *)
  | Parameter_gap of string
      (** Design 7.1 rule 3: pointers to incompatible types where one
          mentions a type parameter are compatible for some arguments
          alone, as pointers to [void (T)] and to [void ()] are where [T]
          is a structure; the use that is refused. *)

let pointer_parameter_gap =
  "pointers to incompatible types meet where one mentions a type parameter"

let unknown_parameter_gap (unknown : Unknown.t) =
  Printf.sprintf
    "pointers meet where one mentions a type parameter, and whether their \
     types are compatible depends on %s, whose type typec does not compute"
    unknown.construct

(* The one rule for conversions and for the operations on two pointers:
   two pointers whose referenced types [a] and [b] mention a distinct
   type or a type parameter meet only where those are compatible or one
   is void. *)
let pointers_differ context span (a : Ctype.t) (b : Ctype.t) =
  let a = Ctype.unqualified a and b = Ctype.unqualified b in
  let is_void t = Ctype.is_void t = Answer true in
  let may_be_void t = Ctype.is_void t <> Answer false in
  let mentions_parameter t = Ctype.mentions_opaque context.tags t in
  if is_void a || is_void b then None
  else if mentions_parameter a || mentions_parameter b then
    (* Rule 3 wants the pointers to meet for every argument, so an
       unknown answer is a gap too. *)
    match compatible context span a b with
    | Answer true -> None
    | Answer false -> Some (Parameter_gap pointer_parameter_gap)
    | Depends_on unknown -> Some (Parameter_gap (unknown_parameter_gap unknown))
  else if may_be_void a || may_be_void b then None
  else if
    (Ctype.mentions_distinct a || Ctype.mentions_distinct b)
    && differs context span a b
  then Some Distinct_gap
  else None

(* Design 7.1 rule 3: a value of a type parameter converts to no other
   type, as a structure does not, though a scalar argument would. *)
let refuse_type_parameter_conversion context span target (typed : typed) =
  let source = value_type typed in
  if
    (Ctype.is_opaque target || Ctype.is_opaque source)
    && differs context span target source
  then
    refuse_type_parameter context span
      "a value converts to or from a type parameter of another type"

(* Design 3.4: Type-C text converts no value implicitly to or from a
   distinct type, nor a pointer but as [pointers_differ] allows. The
   backend sees a distinct type as its representation (design 10.2), so
   it cannot refuse these conversions; the others are its own. A value
   converts only to a scalar: towards a structure or an array it
   initialises a member through elided braces, which the initialiser
   checks where it places the value, or the backend refuses it. *)
let refuse_conversion context span target (typed : typed) =
  let target = Ctype.unqualified target in
  let source = value_type typed in
  let crosses =
    match (target.shape, source.shape) with
    | Pointer t, Pointer s -> (
        match pointers_differ context span t s with
        | Some (Parameter_gap use) -> refuse_type_parameter context span use
        | Some Distinct_gap -> true
        | None -> false)
    | (Record _ | Array _), _ -> false
    | _ ->
        (Ctype.as_distinct target <> None || Ctype.as_distinct source <> None)
        && differs context span target source
  in
  if crosses && is_type_c_text context span then
    context.fail span
      (Rule.message Distinct_conversion
         (Printf.sprintf
            "a value of type %s does not convert to %s without a cast"
            (quote (Type_name.of_ctype source))
            (quote (Type_name.of_ctype target))));
  refuse_type_parameter_conversion context span target typed

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
        (needing
           "the answer to a comparison of types, which may have a distinct \
            type in them,"
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
      (** void, a structure or union, [va_list], an incomplete
          enumeration, an [Atomic_value] *)

let value_operand context (t : Ctype.t) =
  match t.shape with
  | Unknown_type unknown -> Unknown_operand unknown
  (* Only an [Atomic_value] has an _Atomic value type, and Clang takes
     it for no arithmetic or pointer value but in [arithmetic_binary]. *)
  | _ when t.qualifiers.atomic -> Other_operand t
  | Pointer referenced -> Pointer_operand { pointer = t; referenced }
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
      value_operand context (value_type typed)

(* Refuses an operation at [span] on two pointers that [pointers_differ]
   keeps apart, a distinct type in Type-C text only. *)
let refuse_mixed_pointers context span left right =
  match (left, right) with
  | Pointer_operand a, Pointer_operand b -> (
      match pointers_differ context span a.referenced b.referenced with
      | Some (Parameter_gap use) -> refuse_type_parameter context span use
      | Some Distinct_gap when is_type_c_text context span ->
          context.fail span
            (Rule.message Distinct_operation
               (Printf.sprintf
                  "the pointers %s and %s are not compatible; a cast \
                   crosses between them"
                  (quote (Type_name.of_ctype a.pointer))
                  (quote (Type_name.of_ctype b.pointer))))
      | Some Distinct_gap | None -> ())
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
      if typed.category <> Lvalue then
        context.fail span
          (Rule.c_text ("the operand is not an lvalue (C11 " ^ clause ^ ")"));
      if t.qualifiers.const || Ctype.is_array t = Answer true then
        context.fail span
          (Rule.c_text
             ("the operand is not a modifiable lvalue (C11 " ^ clause ^ ")"))

let require_scalar context span ~clause typed =
  refuse_type_parameter_operand context span typed.expression_type;
  match operand context typed with
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Unknown_operand _ ->
      ()
  | Other_operand _ ->
      context.fail span
        (Rule.c_text ("the operand is not of scalar type (C11 " ^ clause ^ ")"))

(* Constants (6.4.4, 6.4.5) *)

let spelling context (span : Tree.span) =
  Reader.spelling context.text context.text.tokens.(span.first)

let constant_type context span (number : Number.t) =
  match number with
  | Integer { base; digits; suffix } -> (
      match
        Integer_constant.of_integer_constant context.target base digits suffix
      with
      | Ok (integer, _) -> integer_type context span integer
      (* GNU [_Complex int], which typec does not model. *)
      | Error Imaginary ->
          unknown context span "an imaginary integer constant" Unknown_object
      | Error error ->
          context.fail span
            (Rule.c_text (Integer_constant.error_message error)))
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
  | Ok (integer, _) -> integer_type context span integer
  | Error error ->
      context.fail span
        (Rule.c_text (Integer_constant.error_message error))

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
        (Rule.c_text
           "string literals with different encoding prefixes are joined (C11 \
            6.4.5p2)")

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
  | Error error ->
      context.fail piece.span
        (Rule.c_text (Escape.error_message error))

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
        (Rule.message Profile
           (quote name ^ " is not a builtin of "
           ^ Target.compiler_name target.backend.compiler
           ^ ", the backend (design 13.3)"))
  | Of_other_architectures ->
      context.fail span
        (Rule.message Profile
           (quote name ^ " is not a builtin of "
           ^ Target.compiler_name target.backend.compiler
           ^ ", the backend, on this target's architecture ("
           ^ Target.architecture_name target.architecture
           ^ ") (design 13.3)"))
  | Not_builtin ->
      context.fail span
        (Rule.c_text (quote name ^ " is not declared (C11 6.5.1p2)"))

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
  | Resolved reference when context.generic_function reference ->
      context.fail span
        (Rule.message Not_implemented
           (quote name
          ^ " is a generic function, whose calls and instances typec does \
             not build yet (design 7.2; work package 3.2)"))
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
      (* The parser leaves a typedef name here only in Type-C text, where
         it may be an unqualified constructor (design 3.3); where it is
         none, it is no expression. *)
      | Typedef _ ->
          context.fail span
            (Rule.c_text
               ("expected an expression, found the type name " ^ quote name)))

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

(* 6.5.2.3p3, p4: a member of an lvalue is one, and Clang converts a
   member of a value as it does an lvalue. *)
let member_category = function
  | Lvalue -> Lvalue
  | Value | Atomic_value -> Value

(* 6.5.2.3p3, p4: the member, qualified as the structure is but for
   _Atomic, whose members are not accessed (p5). *)
let member_of context tag (qualifiers : Qualifiers.t)
    (name : Tree.identifier) ~category =
  context.needs_complete (Ctype.record tag);
  if Ctype.record_members context.tags tag = None then
    context.fail name.span
      (Rule.c_text
         "a member of an incomplete structure or union (C11 6.5.2.3p1)");
  match Ctype.find_member context.tags tag name.node with
  | None ->
      context.fail name.span
        (Rule.c_text
           (quote name.node ^ " is not a member of the structure or union (C11 \
                               6.5.2.3p1)"))
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
      | None -> { expression_type; category; bit_field = Not_bit_field }
      | Some width ->
          let integer = bit_field_integer context member in
          let narrow = Backend_difference.Narrow_bit_field { integer; width } in
          (* A distinct type is no integer type to narrow (design 3.4). *)
          let value_type =
            if Ctype.mentions_distinct expression_type then expression_type
            else backend_type context location narrow expression_type
          in
          { expression_type = value_type;
            category;
            bit_field = Bit_field { width; integer; location } })

let direct_member context span (record : typed) name =
  let t = record.expression_type in
  match t.shape with
  | Record tag ->
      member_of context tag t.qualifiers name
        ~category:(member_category record.category)
  | Unknown_type unknown ->
      { (value (unknown_value unknown)) with
        category = member_category record.category }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ ->
      context.fail span
        (Rule.c_text
           "the operand of '.' is not a structure or union (C11 6.5.2.3p1)")

(* [p->m] reaches into [*p], which may not be a variant (design 3.2 rule
   6). *)
let pointer_member context span (pointer : typed) name =
  match operand context pointer with
  | Pointer_operand
      { referenced = { shape = Record tag; qualifiers; _ } as referenced; _ }
    ->
      refuse_variant context span referenced;
      member_of context tag qualifiers name ~category:Lvalue
  | Pointer_operand { referenced = { shape = Unknown_type unknown; _ }; _ }
  | Unknown_operand unknown ->
      lvalue (unknown_value unknown)
  | Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail span
        (Rule.c_text
           "the operand of '->' is not a pointer to a structure or union (C11 \
            6.5.2.3p2)")

(* Postfix and unary operators (6.5.2, 6.5.3) *)

(* 6.5.2.1: [a[i]] is [*(a + i)], an lvalue. *)
let subscript context span array index =
  match (operand context array, operand context index) with
  | ( Pointer_operand { referenced; _ },
      Arithmetic_operand { arithmetic = Integer _; _ } )
  | ( Arithmetic_operand { arithmetic = Integer _; _ },
      Pointer_operand { referenced; _ } ) ->
      context.needs_complete referenced;
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
          (Rule.c_text
             "a call has a number of arguments that its prototype does not \
              take (C11 6.5.2.2p2)")
  | Unspecified | Old_style _ -> ()

(* 6.5.2.2p5 and 6.5.4p5: the value of a call or a cast has the type
   [t], unqualified as a value is but for _Atomic, which Clang keeps. *)
let call_or_cast_type context span (t : Ctype.t) =
  let kept = { Qualifiers.none with atomic = t.qualifiers.atomic } in
  let clang = checked context span (Ctype.qualify kept (Ctype.unqualified t)) in
  backend_type context (location_of context span)
    (Value_qualifiers t.qualifiers) clang

(* 6.5.2.2p1: the callee is a pointer to a function, after the
   conversion of a function designator. *)
let call_type context span (callee : typed) count =
  match operand context callee with
  | Pointer_operand
      { referenced = { shape = Function { return; parameters }; _ }; _ } ->
      check_arity context span parameters count;
      context.needs_complete return;
      call_or_cast_type context span return
  | Pointer_operand { referenced = { shape = Unknown_type unknown; _ }; _ }
  | Unknown_operand unknown ->
      unknown_value unknown
  | Pointer_operand _ | Arithmetic_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail span
        (Rule.c_text
           "the called expression is not a function or a pointer to one (C11 \
            6.5.2.2p1)")

(* 6.5.2.4p1, p2 and 6.5.3.1p1, p2: a modifiable lvalue of real or
   pointer type, whose value the result is; GNU C takes a complex one. *)
let increment context span ~clause (typed : typed) =
  require_modifiable context span ~clause typed;
  match operand context typed with
  | Pointer_operand { referenced; _ } ->
      context.needs_complete referenced;
      value (value_type typed)
  | Arithmetic_operand _ -> value (value_type typed)
  | Unknown_operand unknown -> value (unknown_value unknown)
  | Distinct_operand _ | Other_operand _ -> fail_operands context span clause

(* 6.5.3.2p1, p3: of a function designator, or of an lvalue other than a
   bit-field. *)
let address context span (typed : typed) =
  let t = typed.expression_type in
  if designates_bit_field typed then
    context.fail span
      (Rule.c_text "the address of a bit-field (C11 6.5.3.2p1)");
  if typed.category <> Lvalue && Ctype.is_function t = Answer false then
    context.fail span
      (Rule.c_text "the address of what is not an lvalue (C11 6.5.3.2p1)");
  value (checked context span (Ctype.pointer_to t))

(* 6.5.3.2p2, p4: an lvalue, or a function designator. *)
let indirection context span typed =
  match operand context typed with
  | Pointer_operand { referenced; _ } ->
      if Ctype.is_function referenced = Answer true then value referenced
      else lvalue referenced
  | Unknown_operand unknown ->
      lvalue (Ctype.unknown { unknown with kind = Object_or_function })
  | Arithmetic_operand _ | Distinct_operand _ | Other_operand _ ->
      context.fail span
        (Rule.c_text
           "the operand of unary '*' is not a pointer (C11 6.5.3.2p2)")

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
  let part = value (value_type typed) in
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
  | Arithmetic_operand _ when imaginary -> value (value_type typed)
  | Arithmetic_operand _ -> typed
  | Unknown_operand unknown ->
      { typed with expression_type = unknown_value unknown }
  | Pointer_operand _ | Distinct_operand _ | Other_operand _ ->
      context.fail span
        (Rule.c_text "the operand of __real__ or __imag__ is not arithmetic")

let complex_part context span ~imaginary typed =
  if is_bit_field typed then bit_field_part context span ~imaginary typed
  else other_part context span ~imaginary typed

(* Binary operators (6.5.5 to 6.5.14) *)

(* Clang's usual arithmetic conversions for [*], [/], [%], [+], [-],
   [&], [^] and [|] take the left operand without _Atomic, for a compound
   assignment, and so an [Atomic_value] there; those of a comparison or a
   conditional do not. *)
let without_atomic context = function
  | Other_operand t when t.qualifiers.atomic ->
      value_operand context (Ctype.unqualified t)
  | operand -> operand

(* The usual arithmetic conversions of two arithmetic operands, each of
   an integer type where [integer] says so. *)
let arithmetic_binary context span ~integer ~clause left right =
  match (without_atomic context left, right) with
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
  | ( Pointer_operand { pointer; referenced },
      Arithmetic_operand { arithmetic = Integer _; _ } )
  | ( Arithmetic_operand { arithmetic = Integer _; _ },
      Pointer_operand { pointer; referenced } ) ->
      context.needs_complete referenced;
      pointer
  | _ ->
      arithmetic_binary context span ~integer:false ~clause:"6.5.6p2" left
        right

(* 6.5.6p3, p8, p9. *)
let subtraction context span left right =
  match (left, right) with
  | Pointer_operand { referenced; _ }, Pointer_operand _ ->
      context.needs_complete referenced;
      integer_type context span context.target.ptrdiff_type
  | ( Pointer_operand { pointer; referenced },
      Arithmetic_operand { arithmetic = Integer _; _ } ) ->
      context.needs_complete referenced;
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
    when (not relational) && one_distinct context span a b ->
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
  | Error error -> context.fail span (Rule.c_text (Ctype.error_message error))

(* An operand whose value an expression may give, kept as the expression,
   for whether it is a null pointer constant, with its type. The second
   and third operands of a conditional are branches, and so are the
   associations of a selection that typec cannot decide. *)
type branch = { branch : Tree.expression; branch_typed : typed }

(* Design 5.2: refuses each of [branches] of a result type whose value
   the expression that holds them, standing in [position], discards.
   [discards] answers whether it discards them all, as a void conditional
   does, or depends on what the backend decides: whether a conditional is
   void, or which association a selection selects (design 13.3). Where it
   depends and the expression's own value is discarded, a branch of a
   result type may be dropped, so it is refused as needing [need]; where
   the value is used, it is not dropped. *)
let discard_branches context position ~need discards branches =
  let diagnostic =
    match (discards, position) with
    | Unknown.Answer true, _ -> Some dropped_result
    | Depends_on unknown, Discarded -> Some (needing need unknown)
    | Answer false, _ | Depends_on _, (Untargeted | Targeted _) -> None
  in
  let refuse diagnostic { branch; branch_typed } =
    if drops_result context branch branch_typed then
      context.fail branch.span diagnostic
  in
  Option.iter (fun diagnostic -> List.iter (refuse diagnostic) branches)
    diagnostic

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
    match compatible context span a b with
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

(* 6.5.1.1p2: no two associations name compatible types. Where that
   depends on an unknown type the backend checks it. *)
let check_distinct context associations =
  let check earlier association =
    match association.association_type with
    | None -> earlier
    | Some t ->
        let span = association.association_span in
        if List.exists (fun u -> compatible context span t u = Answer true)
             earlier
        then
          context.fail association.association_span
            (Rule.c_text
               "the type of a generic association is compatible with that of \
                another (C11 6.5.1.1p2)");
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
        (Rule.c_text "a second default generic association (C11 6.5.1.1p2)")

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
        match compatible context span controlling_type t with
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
        (Rule.c_text
           "the controlling expression is compatible with no generic \
            association (C11 6.5.1.1p2)")
  | None, _ :: _ :: _, _ ->
      context.fail span
        (Rule.c_text
           "the controlling expression is compatible with more than one \
            generic association")

(* GCC and Clang compare the types without their top-level qualifiers,
   which for Clang do not include [_Atomic]. *)
let types_compatible_answer context span first second =
  match
    compatible context span
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
  | Some typed -> typed
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
  | (Not_integer _ | Unevaluable _) as broken ->
      Breaks broken

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
      Invalid
        { span;
          diagnostic = Rule.c_text (Integer_constant.error_message error) })
    failure

let integer value = Integer_expression { value; flaw = None }

(* Design 7.1 rule 4: the size, alignment or offset of a type that
   mentions a type parameter differs between arguments, so no constant
   that C asks for may hold it. *)
let parameter_dependent =
  Rule.message Type_parameter_constant
    "the expression holds the size, alignment or offset of a type that \
     mentions a type parameter, so it is no constant expression"

(* The type whose size, alignment or member offset [whole] is, where it
   is a [sizeof], an [_Alignof] or an [offsetof]. *)
let measured_type context (whole : Tree.expression) =
  match whole.node with
  | Sizeof_expression operand | Alignof_expression operand ->
      Some (operand_typed context operand).expression_type
  | Sizeof_type type_name | Alignof type_name | Offsetof { type_name; _ } ->
      Some (context.type_name type_name)
  | _ -> None

let measures_parameter context whole =
  match measured_type context whole with
  | Some t -> Ctype.mentions_opaque context.tags t
  | None -> false

(* Design 7.1 rule 4: an expression depends on a type parameter where
   an expression in it, evaluated or not, measures a type that mentions
   one. Every expression in it lies within its span, so the fact is
   derived from the spans of such measurements, which [measurements]
   holds. *)
let record_measurement context (whole : Tree.expression) =
  let { Tree.first; last } = whole.span in
  let inner = function
    | Some other -> Some (min other last)
    | None -> Some last
  in
  if measures_parameter context whole then
    context.typed.measurements <-
      Measurements.update first inner context.typed.measurements

(* Refuses [expression] where C asks for a constant, if it depends on a
   type parameter: whatever its class, that of an instance can differ.
   Spans of expressions nest, and each measurement begins with its own
   keyword, which begins no expression inside it: so the first
   measurement that begins within [expression] lies within it, and the
   search costs a lookup and at most two entries however many the unit
   holds. *)
let refuse_dependent context (expression : Tree.expression) =
  let { Tree.first; last } = expression.span in
  let within (_, measured_last) = measured_last <= last in
  let measurements =
    Measurements.to_seq_from first context.typed.measurements
    |> Seq.take_while (fun (measured_first, _) -> measured_first <= last)
  in
  match Seq.find within measurements with
  | Some (measured_first, measured_last) ->
      context.fail
        { first = measured_first; last = measured_last }
        parameter_dependent
  | None -> ()

(* The constant of a [sizeof], [_Alignof] or [offsetof] at [span] of the
   type [t], which [known] gives where [t] mentions no type parameter;
   [refuse_dependent] refuses one that does where it would be read. *)
let measured context (t : Ctype.t) known =
  if Ctype.mentions_opaque context.tags t then integer Opaque else known ()

(* The integer type that typing gives an integer constant expression,
   the one source of its type, as C text sees a distinct type (design
   10.2). No integer constant has an unknown type, as the declarations
   give an enumerator one only with its value; were one to, the
   expression would be refused. *)
let integer_type_of context (typed : typed) =
  match
    Ctype.as_arithmetic context.tags
      (Ctype.representation typed.expression_type)
  with
  | Answer (Some (Integer integer)) -> Ok integer
  | Depends_on unknown ->
      Error (needing "the type of an integer constant expression" unknown)
  | Answer (Some (Real _ | Complex _) | None) ->
      invalid_arg "Expressions: integer constants typed as no integer"

(* Applies [compute] to the integer type that typing gives an integer
   constant expression; one of unknown type is unevaluable at [span]. *)
let with_integer_type context span (typed : typed) compute =
  match integer_type_of context typed with
  | Ok integer -> compute integer
  | Error diagnostic -> Unevaluable { span; diagnostic }

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
let size_constant context span typed t =
  match size_of context t with
  | Bytes bytes ->
      with_integer_type context span typed (fun size_type ->
          integer
            (Integer_constant.known context.target size_type
               (Exact_integer.of_int bytes)))
  | Backend_size -> integer Opaque
  | Variable_size -> Not_integer { kind = Backend_constant; first = span }
  | No_size ->
      Unevaluable
        {
          span;
          diagnostic =
            Rule.c_text
              "sizeof is applied to an incomplete type (C11 6.5.3.4p1)";
        }

let identifier_constant context span name (resolution : Tree.resolution)
    (typed : typed) =
  let itself kind = Not_integer { kind; first = span } in
  match resolution with
  (* [__func__] and its kin are static arrays, a builtin the backend's. *)
  | Undeclared ->
      if typed.category = Lvalue then
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
      | Typedef _ ->
          invalid_arg "Expressions: a typedef name that typing refused")

(* 6.5.2.1p2: [e1[e2]] is [*(e1 + e2)]. An element of an array that a
   designator designates is part of that object. *)
let subscript_kind context operand index =
  let pointer, offset =
    match (value_type (operand_typed context operand)).shape with
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

let unary_constant context span typed op operand =
  match part context Evaluated operand with
  | Part (value, flaw) ->
      with_integer_type context span typed (fun result ->
          let value, failure =
            Integer_constant.unary context.target ~result op value
          in
          let flaw = first_flaw flaw (invalid span failure) in
          Integer_expression { value; flaw })
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

let binary_constant context span typed op left right =
  match (part context Evaluated left, part context Evaluated right) with
  | Part (left_value, left_flaw), Part (right_value, right_flaw) ->
      with_integer_type context span typed (fun result ->
          let value, failure =
            Integer_constant.binary context.target ~result op left_value
              right_value
          in
          let operand_flaw = first_flaw left_flaw right_flaw in
          let flaw = first_flaw operand_flaw (invalid span failure) in
          Integer_expression { value; flaw })
  | Breaks broken, _ | Part _, Breaks broken ->
      broken_by broken (binary_kind context op left right)

(* A comparison takes the types of its operands, not of its result. *)
let comparison_constant context span op left right =
  let typed_left = operand_typed context left in
  let typed_right = operand_typed context right in
  match (part context Evaluated left, part context Evaluated right) with
  | Part (left_value, left_flaw), Part (right_value, right_flaw) ->
      with_integer_type context span typed_left (fun left_type ->
          with_integer_type context span typed_right (fun right_type ->
              let value =
                Integer_constant.comparison context.target ~left_type
                  ~right_type op left_value right_value
              in
              let flaw = first_flaw left_flaw right_flaw in
              Integer_expression { value; flaw }))
  | Breaks broken, _ | Part _, Breaks broken ->
      broken_by broken (binary_kind context op left right)

(* 6.5.13p4, 6.5.14p4: the right operand is evaluated where the left one
   does not decide the value, which is true for [||] ([decisive]) and
   false for [&&]. Neither fails. *)
let logical_constant context span typed ~decisive op left right =
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
          with_integer_type context span typed (fun result ->
              let value, _ =
                Integer_constant.binary context.target ~result op left_value
                  right_value
              in
              let flaw = first_flaw left_flaw right_flaw in
              Integer_expression { value; flaw })
      | Breaks broken -> broken_by broken (kind right_role))

(* 6.5.15p4: the operand that the condition chooses is evaluated. *)
let conditional_constant context span typed condition second third =
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
          with_integer_type context span typed (fun result ->
              let value =
                Integer_constant.conditional context.target ~result
                  condition_value if_true if_false
              in
              let branch_flaw = first_flaw true_flaw false_flaw in
              let flaw = first_flaw condition_flaw branch_flaw in
              Integer_expression { value; flaw })
      | Breaks broken, _ | Part _, Breaks broken ->
          broken_by broken (kind roles))

(* 7.19p3: an [offsetof] is an integer constant expression where each
   index of its member designator is one. *)
let offsetof_constant context designators =
  let index (designator : Tree.designator) =
    match designator.node with
    | Index index -> [ index ]
    | Index_range { low; high } -> [ low; high ]
    | Member_designator _ -> []
  in
  let indices = List.concat_map index designators in
  let parts = List.map (part context Evaluated) indices in
  let broken =
    List.find_map (function Breaks broken -> Some broken | Part _ -> None) parts
  in
  let flaw =
    List.fold_left
      (fun flaw -> function
        | Part (_, next) -> first_flaw flaw next
        | Breaks _ -> flaw)
      None parts
  in
  match broken with
  | Some broken ->
      broken_by broken (combined (List.map (operand_kind context) indices))
  | None -> Integer_expression { value = Opaque; flaw }

(* 6.6p3: a comma operator only where it is not evaluated. *)
let comma_constant context span left right =
  match (part context Not_evaluated left, part context Not_evaluated right) with
  | Part _, Part (value, _) ->
      Integer_expression { value; flaw = Some (Comma_operator span) }
  | Breaks _, _ | Part _, Breaks _ ->
      let kinds = [ operand_kind context left; operand_kind context right ] in
      Not_integer { kind = refused_or_backend kinds; first = span }

(* The expression that a _Generic is if it selects [association]. *)
let association_result (association : Tree.generic_association) =
  match association.node with
  | Association (_, result) | Default_association result -> result

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
   an integer constant expression or an address constant. The value
   converts to the type that typing gives the cast. *)
let representation_cast_constant context span typed (cast_type : Ctype.t)
    operand =
  let itself kind = Not_integer { kind; first = span } in
  let operand_kind = operand_kind context operand in
  match Ctype.as_arithmetic context.tags cast_type with
  | Answer (Some (Integer _)) when is_floating_constant context operand ->
      integer Opaque
  | Answer (Some (Integer _)) -> (
      match part context Evaluated operand with
      | Part (value, flaw) ->
          with_integer_type context span typed (fun integer_type ->
              let target = context.target in
              let value = Integer_constant.convert target integer_type value in
              Integer_expression { value; flaw })
      | Breaks broken -> broken_by broken (combined [ operand_kind ]))
  | Answer (Some (Real _ | Complex _)) -> itself (combined [ operand_kind ])
  | Answer None when Ctype.is_pointer cast_type = Answer true ->
      let integer = is_integer_expression context operand in
      if integer || operand_kind = Address_constant then
        itself Address_constant
      else itself (refused_or_backend [ operand_kind ])
  | Answer None -> itself (refused_or_backend [ operand_kind ])
  | Depends_on unknown ->
      Unevaluable
        { span; diagnostic = needing "the value of a cast" unknown }

(* Design 3.4: in Type-C text a cast to a distinct type is a constant
   where the cast to its representation is, but no integer constant
   expression, as a distinct type is no integer type. C text casts to the
   representation (design 10.2). *)
let cast_constant context span typed (cast_type : Ctype.t) operand =
  let of_representation =
    representation_cast_constant context span typed
  in
  match Ctype.as_distinct cast_type with
  | Some { representation; _ } when not (is_type_c_text context span) ->
      of_representation representation operand
  | None -> of_representation cast_type operand
  | Some { representation; _ } -> (
      match of_representation representation operand with
      | Integer_expression _ ->
          let kind = combined [ operand_kind context operand ] in
          Not_integer { kind; first = span }
      | constant -> constant)

(* The constant of the selection at [span] of a [construct]. *)
let selected_constant context span construct =
  match Hashtbl.find_opt context.typed.selections span with
  | Some (Answer chosen) -> operand_constant context chosen
  | Some (Depends_on unknown) ->
      let diagnostic = needing ("the value of " ^ construct) unknown in
      Unevaluable { span; diagnostic }
  | None -> invalid_arg "Expressions: an untyped selection"

(* The class of an expression that has been typed, from those of its
   operands. *)
let classify_node context (whole : Tree.expression) typed =
  let span = whole.span and target = context.target in
  let itself kind = Not_integer { kind; first = span } in
  let unevaluable error =
    Unevaluable
      { span; diagnostic = Rule.c_text (Integer_constant.error_message error) }
  in
  match whole.node with
  | Identifier { name; resolution } ->
      identifier_constant context span name resolution typed
  | Constant (Integer { base; digits; suffix }) -> (
      match Integer_constant.of_integer_constant target base digits suffix with
      | Ok (_, value) -> integer value
      | Error error -> unevaluable error)
  | Constant (Floating _) -> itself Arithmetic_constant
  | Constant Not_a_constant ->
      invalid_arg "Expressions: a constant that is not one"
  | Character encoding -> (
      match
        Integer_constant.of_character_constant target encoding
          (spelling context span)
      with
      | Ok (_, value) -> integer value
      | Error error -> unevaluable error)
  | String _ -> itself (Designator { static_storage = true; named = false })
  | Parenthesized inner -> operand_constant context inner
  (* 6.5.1.1p4: the class and value of the result expression, as of
     the chosen operand of __builtin_choose_expr. *)
  | Generic _ -> selected_constant context span "_Generic"
  | Choose _ -> selected_constant context span "__builtin_choose_expr"
  | Types_compatible _ -> (
      match Hashtbl.find_opt context.typed.compatibilities span with
      (* 0 or 1, which every integer type holds. *)
      | Some (Answer compatible) ->
          integer (Known (Exact_integer.of_int (Bool.to_int compatible)))
      | Some (Depends_on _) -> integer Opaque
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
      unary_constant context span typed op operand
  | Unary ((Real_part | Imaginary_part), operand) ->
      itself (combined [ operand_kind context operand ])
  | Post_increment _ | Post_decrement _ | Assignment _
  | Unary ((Pre_increment | Pre_decrement), _) ->
      itself Not_constant
  | Sizeof_expression operand ->
      let operand_type = (operand_typed context operand).expression_type in
      measured context operand_type (fun () ->
          size_constant context span typed operand_type)
  | Sizeof_type type_name ->
      let t = context.type_name type_name in
      measured context t (fun () -> size_constant context span typed t)
  (* [offsetof] expands to [__builtin_offsetof], an integer constant
     (C11 7.19p3). *)
  | Alignof type_name ->
      measured context (context.type_name type_name) (fun () ->
          integer Opaque)
  | Offsetof { type_name; designators; member = _ } ->
      measured context (context.type_name type_name) (fun () ->
          offsetof_constant context designators)
  | Alignof_expression operand ->
      let operand_type = (operand_typed context operand).expression_type in
      measured context operand_type (fun () -> integer Opaque)
  | Cast { type_name; operand } ->
      cast_constant context span typed (context.type_name type_name) operand
  | Binary (Logical_and, left, right) ->
      logical_constant context span typed ~decisive:false Logical_and left
        right
  | Binary (Logical_or, left, right) ->
      logical_constant context span typed ~decisive:true Logical_or left right
  | Binary
      ( (( Less_than | Greater_than | Less_or_equal | Greater_or_equal
         | Equal_to | Not_equal_to ) as op),
        left,
        right ) ->
      comparison_constant context span op left right
  | Binary (op, left, right) ->
      binary_constant context span typed op left right
  | Conditional { condition; if_true; if_false } ->
      let second = Option.value if_true ~default:condition in
      conditional_constant context span typed condition second if_false
  | Comma (left, right) -> comma_constant context span left right
  | Label_address _ -> itself Address_constant
  | Call _ | Statement_expression _ | Va_arg _ | Block_literal _ ->
      itself Backend_constant
  (* Lowering reads the value of a [try] from an automatic temporary
     (design 13.5). *)
  | Try _ -> itself Not_constant

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
  refuse_dependent context expression;
  if operand_kind context expression = Not_constant then
    context.fail expression.span
      (Rule.c_text
         "an initialiser of an object with static or thread storage duration \
          is not a constant expression (C11 6.7.9p4)")

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
    (Rule.message Profile
       (Printf.sprintf "the first argument of %s is not %s (design 13.3)"
          (quote name) requirement))

(* The type of the object that [first] points to, as the result of
   [name]. A distinct type gives itself whatever its qualifiers: the
   rules of design 3.4 need it, and only __typeof__ sees the qualifier.
   Clang keeps a qualifier of any other referenced type that a typedef
   gives it and drops one written in the pointer's declarator; Ctype does
   not tell them apart, so such a qualified type gives an unknown result.
   _Atomic, which Clang's __c11 builtins drop, does not count. Every such
   builtin reads the object as a scalar, which a type parameter is not
   (design 7.1 rule 3). *)
let object_of_first context span name first =
  let qualified (qualifiers : Qualifiers.t) =
    qualifiers.const || qualifiers.volatile || qualifiers.restrict
  in
  match operand context first with
  | Pointer_operand { referenced; _ } when Ctype.is_opaque referenced ->
      read_type_parameter context span
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
  refuse_dependent context condition;
  match operand_constant context condition with
  | Integer_expression { value = Known value; flaw = None } ->
      if Exact_integer.equal value Exact_integer.zero then Unknown.Answer second
      else Answer first
  | Integer_expression { value = Opaque; flaw = None }
  | Integer_expression { flaw = Some (Comma_operator _); _ }
  | Not_integer { kind = Backend_constant; _ } ->
      undecided ()
  | Integer_expression { flaw = Some (Invalid { span; diagnostic }); _ }
  | Unevaluable { span; diagnostic } ->
      context.fail span diagnostic
  | Not_integer
      { kind = Arithmetic_constant | Address_constant | Designator _
             | Not_constant;
        first } ->
      context.fail first
        (Rule.message Profile
           "the condition of '__builtin_choose_expr' is not an integer \
            constant expression (design 13.3)")

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
        (Rule.message Profile
           (quote name ^ " takes at least one argument (design 13.3)"))

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
  variant_name : Ctype.variant_name;
  chosen : Ctype.constructor;
}

let find_constructor constructors name =
  List.find_opt
    (fun (constructor : Ctype.constructor) ->
      (constructor.constructor_name :> string) = name)
    constructors

let constructor_message text = Rule.message Constructor_expression text

(* For each message about the fields of [constructor]: the fields that
   a void type argument removed from it (design 3.5 rule 6), which the
   source still spells. *)
let void_fields_note (constructor : Ctype.constructor) =
  match constructor.void_fields with
  | [] -> ""
  | names ->
      Printf.sprintf
        " (in this instance the type void removes the field(s) %s; design \
         3.5 rule 6)"
        (String.concat ", " (List.map quote names))

(* The variant of [t] that names its constructors, unqualified. *)
let named_in t constructors name =
  match (Ctype.as_variant t, find_constructor constructors name) with
  | Some variant_name, Some chosen ->
      Some { variant_type = Ctype.unqualified t; variant_name; chosen }
  | None, _ | Some _, None -> None

(* An unqualified name in Type-C text is a constructor where the target
   type of its position is a variant with a constructor of that name,
   whatever else the name denotes there (design 3.3). C text keeps
   C's meaning of every name. *)
let unqualified_constructor context position (span : Tree.span) name =
  match position with
  | Targeted t when is_type_c_text context span ->
      context.needs_complete t;
      Option.bind (Ctype.constructors context.tags t) (fun constructors ->
          named_in t constructors name)
  | Targeted _ | Untargeted | Discarded -> None

(* [T.C]: the type name denotes a complete variant with a constructor [C]. *)
let qualified_constructor context (variant : Tree.type_name)
    (constructor : Tree.identifier) =
  let t = context.type_name variant in
  let described = quote (spelling context variant.span) in
  context.needs_complete t;
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

(* Try (design 5.1) *)

(* Rule 3: the try that an expression statement holds in a position,
   with its form. Parentheses, a compound assignment and a chain of
   assignments each leave the try out of the positions. *)
let statement_try (value : Tree.expression) =
  match value.node with
  | Try _ -> Some (value.span, Whole_statement)
  | Assignment (Assign, _, ({ node = Try _; _ } as right)) ->
      Some (right.span, Assigned)
  | _ -> None

(* Rule 3: the try that a declaration holds as the whole initialiser of
   its one declarator. *)
let declaration_try (declaration : Tree.declaration) =
  match declaration.node with
  | Declaration
      { declarators =
          [ { node =
                { initialiser =
                    Some (Expression_initialiser ({ node = Try _; _ } as held));
                  _ };
              _ } ];
        _ } ->
      Some held.span
  | Declaration _ | Static_assert _ -> None

(* Types a statement or declaration that gives a try the position
   [place], where its statements give positions at all. *)
let holding context place type_holder =
  let enclosing = context.typed.enclosing in
  match enclosing.try_positions with
  | Positions _ ->
      within context
        { enclosing with try_positions = Positions place }
        type_holder
  | No_positions -> type_holder ()

(* Rule 3: the position that the statement being typed gives the try at
   [span], which it takes; a try in any other place is this one error. *)
let placed_try context span =
  let view = context.typed in
  match view.enclosing.try_positions with
  | Positions (Placed held) when held.held_span = span ->
      view.enclosing <-
        { view.enclosing with try_positions = Positions No_place };
      held
  | Positions (Placed _ | Unchecked_declaration _ | No_place) | No_positions
    ->
      context.fail span
        (Rule.message Try_position
           "try stands in none of its positions: a whole expression \
            statement, the whole right operand of a simple assignment that \
            is one, or the whole initialiser of a declaration in a block; \
            give it a statement or declaration of its own")

(* Rules 3 and 5: a declaration that holds a try declares an automatic
   object whose type is not variably modified, since C evaluates the
   size expressions of a declaration before its initialiser and lowering
   writes the operand before both. *)
let refuse_try_object context span ~constant (t : Ctype.t) =
  let refuse text = context.fail span (Rule.message Try_declaration text) in
  if constant then
    refuse
      "a declaration that holds try declares an object of static or \
       thread storage duration";
  match Ctype.is_variably_modified t with
  | Answer false -> ()
  | Answer true ->
      refuse
        "a declaration that holds try declares an object of a variably \
         modified type, whose size C evaluates before its initialiser"
  | Depends_on unknown ->
      context.fail span
        (needing
           "whether a declaration that holds try declares a variably \
            modified type"
           unknown)

(* A declaration gives the try of its initialiser its position once the
   object that it initialises, of type [t], is one that rule 3 allows. *)
let place_declared_try context ~constant t (initialiser : Tree.initialiser) =
  let view = context.typed in
  match (view.enclosing.try_positions, initialiser) with
  | Positions (Unchecked_declaration held), Expression_initialiser value
    when value.span = held.held_span ->
      refuse_try_object context held.held_span ~constant t;
      view.enclosing <-
        { view.enclosing with try_positions = Positions (Placed held) }
  | ( (Positions (No_place | Unchecked_declaration _ | Placed _)
      | No_positions),
      (Expression_initialiser _ | Braced _) ) ->
      ()

let is_pragma (token : Token.t) =
  match token.kind with
  | Pragma _ | Typec_pragma -> true
  | Identifier _ | Number | Character _ | String _ | Punctuator _ -> false

(* Rule 3: no pragma line stands from directly before the statement or
   declaration that holds a try, its C labels included, to its final
   [;]; the token before the first is a pragma exactly where one stands
   directly before it. *)
let refuse_try_pragma context span (holder : holder) =
  let first =
    match holder.labels with
    | Some labels -> labels.first
    | None -> holder.statement.first
  in
  let tokens = context.text.tokens in
  let rec pragma_from index =
    index <= holder.statement.last
    && (is_pragma tokens.(index) || pragma_from (index + 1))
  in
  if pragma_from (max 0 (first - 1)) then
    context.fail span
      (Rule.message Try_pragma
         "a pragma line stands in or directly before the statement or \
          declaration that holds try; give the pragma or the try a \
          statement of its own")

(* Rules 1 and 5: the instance of result that [t] is, if any, which no
   type that typec does not know answers. *)
let try_result context span ~need (t : Ctype.t) =
  match t.shape with
  | Unknown_type unknown -> context.fail span (needing need unknown)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
  | Va_list | Array _ | Function _ ->
      Ctype.as_result t

let operand_result context span operand_type =
  match
    try_result context span ~need:"whether the operand of try is a result"
      operand_type
  with
  | Some instance -> instance
  | None ->
      context.fail span
        (Rule.message Try_operand "the operand of try is of no result type")

let return_result context span =
  let need = "whether the function that holds try returns a result" in
  let returned =
    match context.typed.enclosing.return_type with
    | Some (Answer t) -> try_result context span ~need t
    | Some (Depends_on unknown) -> context.fail span (needing need unknown)
    | None -> invalid_arg "Expressions: a try placed outside a function"
  in
  match returned with
  | Some instance -> instance
  | None ->
      context.fail span
        (Rule.message Try_operand
           "try stands in a function that returns no result type")

(* The encoding of the error type of an instance of result, which says
   whether two error types are one, qualifiers at every level included
   (design 3.5 rule 3). *)
let error_encoding (instance : Ctype.instance) =
  match instance.arguments with
  | [ _value; error ] -> error
  | _ -> invalid_arg "Expressions: a result of other than two arguments"

(* The field of the constructor [name] of a complete result, or [None]
   where it has none, its type being void (design 3.5 rule 6). *)
let result_field context (result : Ctype.t) name =
  match
    Option.bind (Ctype.constructors context.tags result) (fun constructors ->
        find_constructor constructors name)
  with
  | Some { fields = [ field ]; _ } -> Some field
  | Some { fields = []; _ } -> None
  | Some { fields = _ :: _ :: _; _ } | None ->
      invalid_arg "Expressions: a result without its constructors"

(* The name of a field of result, which the universe declares (design
   3.6), so that lowering spells it as the instance does. *)
let field_name (field : Ctype.member) =
  match field.member_name with
  | Some name -> name
  | None -> invalid_arg "Expressions: a field of result without a name"

(* Rule 2: the type of the value of a try, that of the field of Ok, or
   void, which only the statement try e; holds. *)
let try_value context span (held : try_holder) ok_field =
  match (ok_field, held.form) with
  | Some (field : Ctype.member), _ -> Ctype.unqualified field.member_type
  | None, Whole_statement -> Ctype.void
  | None, (Assigned | Initialiser) ->
      context.fail span
        (Rule.message Try_void
           "the value of try is void, which only the statement try e; \
            discards")

(* The tries of a function are numbered from 0 in the order they are
   typed, so the next number is one past that of the newest of [tries]. *)
let next_temporary (tries : try_site list) =
  match tries with [] -> 0 | newest :: _ -> newest.temporary + 1

(* The views that the parser took at the try at [span]. *)
let try_views context (span : Tree.span) =
  match Parser.try_views context.views span.first with
  | Some views -> views
  | None -> invalid_arg "Expressions: a try without views"

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

(* An expression is typed once, in its one position: a second typing
   could give it a second meaning, so it is an internal error, and a use
   of an expression typed before reads it through [operand_typed]. *)
and positioned context position (expression : Tree.expression) =
  if Hashtbl.mem context.typed.types expression.span then
    invalid_arg "Expressions: an expression typed twice";
  let typed =
    match constructor_expression context position expression with
    | Some (named, arguments) -> construct context expression named arguments
    | None -> expression_node context position expression
  in
  (match position with
  | Targeted target ->
      (* 6.5.16.1p2, 6.5.2.2p7: converted as if by assignment. *)
      context.needs_complete typed.expression_type;
      refuse_conversion context expression.span target typed
  | Untargeted | Discarded -> ());
  Hashtbl.replace context.typed.types expression.span typed;
  Hashtbl.replace context.typed.constants expression.span
    (classify context expression typed);
  record_measurement context expression;
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
  | Generic { associations; _ } ->
      selected context position whole
        (List.map association_result associations)
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
      let arguments = call_arguments context callee callee_typed arguments in
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
      let whole = as_whole operand in
      if designates_bit_field whole then
        context.fail span (Rule.c_text "sizeof of a bit-field (C11 6.5.3.4p1)");
      context.needs_complete whole.expression_type;
      value (size_type context span)
  | Sizeof_type type_name | Alignof type_name ->
      context.needs_complete (context.type_name type_name);
      value (size_type context span)
  | Alignof_expression operand ->
      context.needs_complete (as_whole operand).expression_type;
      value (size_type context span)
  | Cast { type_name; operand } ->
      let cast_type = context.type_name type_name in
      refuse_variant context span cast_type;
      if Ctype.is_opaque cast_type then
        refuse_type_parameter context span "a cast to a type parameter";
      Option.iter
        (fun distinct ->
          refuse_private_creation context span cast_type
            ~described:("the distinct type " ^ distinct_name distinct))
        (Ctype.as_distinct cast_type);
      let cast_operand =
        if discards cast_type then as_whole operand else typed operand
      in
      context.needs_complete cast_operand.expression_type;
      value (call_or_cast_type context span cast_type)
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
      discard context left;
      let right = as_enclosing right in
      context.needs_complete right.expression_type;
      { (value (value_type right)) with bit_field = value_of right.bit_field }
  | Statement_expression block ->
      value (statement_expression context position block)
  | Label_address label ->
      context.label_address label;
      value (void_pointer context span)
  | Va_arg { list; type_name } ->
      ignore (typed list);
      let t = context.type_name type_name in
      (* 7.16.1.1p2: the promoted type of an argument is not [t] for
         every value type. *)
      if Ctype.is_opaque t then
        refuse_type_parameter context span "va_arg of a type parameter";
      context.needs_complete t;
      value (Ctype.unqualified t)
  | Offsetof { type_name; member; designators } ->
      List.iter (designator context) designators;
      let path =
        Tree.Member_designator member
        :: List.map (fun (step : Tree.designator) -> step.node) designators
      in
      offsetof_path context span (context.type_name type_name) path;
      value (size_type context span)
  | Choose { first; second; _ } ->
      selected context position whole [ first; second ]
  | Types_compatible (first, second) ->
      let first = type_as_seen context span (context.type_name first) in
      let second = type_as_seen context span (context.type_name second) in
      refuse_type_parameter_comparison context span
        "__builtin_types_compatible_p" [ first; second ];
      let answer = types_compatible_answer context span first second in
      record_answer context span [ first; second ]
        ~lowered:(fun compatible -> Compatible compatible)
        answer;
      Hashtbl.replace context.typed.compatibilities span answer;
      value (int_type context span)
  (* Clang's block, whose type typec does not model; its body is not
     typed. *)
  | Block_literal _ ->
      context.block_literal ();
      value (unknown context span "a block literal" Unknown_object)
  | Try { operand; scope } -> try_expression context whole operand scope

(* Design 5.1: a try in the position that the statement being typed
   gives it (rule 3). Its operand, which has no target type (3.3), is a
   result whose error type is the one that the function returns (rule
   1); the try has the value of its Ok, which is no lvalue (rule 2). *)
and try_expression context (whole : Tree.expression) operand scope =
  let span = whole.span in
  let held = placed_try context span in
  refuse_try_pragma context span held.holder;
  let views = try_views context span in
  let type_operand () = whole_value context operand in
  let operand_type =
    (context.moved_operand views ~scope operand.span type_operand)
      .expression_type
  in
  let operand_instance = operand_result context operand.span operand_type in
  let return_instance = return_result context span in
  if error_encoding operand_instance <> error_encoding return_instance then
    context.fail operand.span
      (Rule.message Try_error_type
         "the error type of the operand of try is not the one that the \
          function returns; no error type converts to another");
  context.needs_complete operand_type;
  let ok_field = result_field context operand_type Ctype.result_ok in
  let value_type = try_value context span held ok_field in
  let view = context.typed in
  let site =
    { try_span = span;
      operand = operand.span;
      holder = held.holder;
      form = held.form;
      place = views.place;
      temporary = next_temporary view.function_tries;
      operand_instance;
      return_instance;
      ok_field = Option.map field_name ok_field;
      err_field =
        Option.map field_name
          (result_field context operand_type Ctype.result_err) }
  in
  view.function_tries <- site :: view.function_tries;
  value value_type

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
  let described = "the variant " ^ quoted_variant named.variant_name in
  refuse_private_creation context whole.span named.variant_type ~described;
  let name = quote (named.chosen.constructor_name :> string) in
  let fields = named.chosen.fields in
  let refuse text =
    context.fail whole.span
      (constructor_message (text ^ void_fields_note named.chosen))
  in
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
    value_type (positioned context (Targeted field_type) argument)
  in
  initialises_whole context field_type argument;
  let is_record t = Ctype.is_record t = Answer true in
  if is_record field_type || is_record argument_type then
    match compatible context argument.span field_type argument_type with
    | Answer true | Depends_on _ -> ()
    | Answer false ->
        context.fail argument.span
          (constructor_message
             (Printf.sprintf
                "the argument for the field %s of %s does not have its type"
                (quote (Option.value field.member_name ~default:""))
                (quote (named.chosen.constructor_name :> string))))

(* The arguments of a call of a builtin that moves a value of the object
   that its first argument points to have the target types that the
   builtin states by that object; those of any other call have them by
   its prototype. The first argument of such a builtin is typed before
   the rest, whose target types it gives. *)
and call_arguments context callee (callee_typed : typed) arguments =
  match (builtin_rule context callee, arguments) with
  | Some (_, Moves_object { operands; _ }), first :: rest ->
      let first_typed = expression context first in
      let positions =
        moved_positions context first.span operands first_typed rest
      in
      first_typed :: List.map2 (argument context) positions rest
  | _ ->
      let positions = prototype_positions context callee_typed arguments in
      List.map2 (argument context) positions arguments

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
   where the default argument promotions would convert it; nor does a
   value of a type parameter, which they convert for some arguments
   (design 7.1 rule 3). *)
and argument context position argument =
  match position with
  | Targeted _ -> positioned context position argument
  | Untargeted | Discarded ->
      let typed = whole_value context argument in
      if Ctype.is_opaque typed.expression_type then
        refuse_type_parameter context argument.span
          "a value of a type parameter is an argument that no parameter \
           type receives, which the default argument promotions or a \
           builtin read by its type";
      read_operand context argument.span ~reads:false typed

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
   bit-field where it is one, as GCC and Clang do. Every one of the
   [operands] that it may select is typed, as GCC and Clang check the
   ones they do not select: the chosen one, whose value it gives,
   discarded where the selection is, and the others in no position.
   Where the selection is unknown, each stands where the chosen one
   would (design 5.2). *)
and selected context position (selecting : Tree.expression) operands =
  let selection = selection_of context selecting in
  let may_be_chosen (operand : Tree.expression) =
    match selection with
    | Unknown.Answer (chosen : Tree.expression) -> chosen.span = operand.span
    | Depends_on _ -> true
  in
  let type_operand (operand : Tree.expression) =
    let operand_position =
      if may_be_chosen operand then value_position position else Untargeted
    in
    { branch = operand;
      branch_typed = positioned context operand_position operand }
  in
  let branches = List.map type_operand operands in
  match selection with
  | Answer chosen -> operand_typed context chosen
  | Depends_on unknown ->
      discard_branches context position
        ~need:
          "the choice of a discarded selection with an association of a \
           result type"
        (Depends_on unknown) branches;
      value (Ctype.unknown { unknown with kind = Object_or_function })

(* The operand that a _Generic or __builtin_choose_expr selects, made
   once. Making it types none of the operands that it may select, so an
   initialiser can find a string literal that a selection gives before
   it types the selection in its position. *)
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
   function designator if that is one. The type that selects is that of
   the controlling expression after lvalue conversion, as C17 says and
   GCC and Clang do in every mode. *)
and generic context span controlling associations =
  let controlling_typed = whole_value context controlling in
  let associations_typed =
    List.map (generic_association context span) associations
  in
  check_distinct context associations_typed;
  let default = default_association context associations_typed in
  let controlling_type =
    value_type (as_seen context span controlling_typed)
  in
  let types =
    controlling_type
    :: List.filter_map (fun a -> a.association_type) associations_typed
  in
  refuse_type_parameter_comparison context span "_Generic" types;
  let selection =
    select context span controlling_type associations_typed default
  in
  record_answer context span types
    ~lowered:(fun result -> Selected { controlling; associations; result })
    selection;
  selection

and choose context span condition first second =
  ignore (expression context condition);
  choice context span condition first second

(* The association of the selection at [span], with its type as the text
   of the selection sees it. *)
and generic_association context span
    (association : Tree.generic_association) =
  let association_type, result =
    match association.node with
    | Association (type_name, result) ->
        let t = context.type_name type_name in
        context.needs_complete t;
        (Some (type_as_seen context span t), result)
    | Default_association result -> (None, result)
  in
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
  let result = conditional_type context span second third in
  discard_branches context position
    ~need:
      "the type of a discarded conditional with a branch of a result type"
    (Ctype.is_void result) [ second; third ];
  result

(* 6.5.15p3 to p6: the type of a conditional of these branches. *)
and conditional_type context span second third =
  refuse_type_parameter_branch context span second.branch_typed;
  refuse_type_parameter_branch context span third.branch_typed;
  let branch_operand branch =
    context.needs_complete branch.branch_typed.expression_type;
    operand context (as_seen context span branch.branch_typed)
  in
  let second_operand = branch_operand second
  and third_operand = branch_operand third in
  refuse_mixed_pointers context span second_operand third_operand;
  match (second_operand, third_operand) with
  | Distinct_operand a, Distinct_operand b when one_distinct context span a b
    ->
      a
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
  let pointer_type branch = value_type branch.branch_typed in
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
  | _, Integer_expression { value = Known value; flaw = None }
    when Exact_integer.equal value Exact_integer.zero ->
      Null
  | _,
      ( Integer_expression { value = Opaque; _ }
      | Unevaluable _ ) ->
      Opaque_constant
  | _, (Integer_expression _ | Not_integer _) -> Not_null

(* 6.5.16p2, p3: the left operand is a modifiable lvalue, whose type after
   lvalue conversion the result has; a compound assignment takes what its
   operator takes (6.5.16.2). *)
and assignment context span (op : Tree.assignment_operator) left right =
  require_modifiable context span ~clause:"6.5.16p2" left;
  context.needs_complete left.expression_type;
  (match op with
  | Assign -> ()
  | Compound_assign op -> ignore (binary_type context span op left right));
  { (value (value_type left)) with bit_field = value_of left.bit_field }

(* GNU: the value of the last block item, or void. That item gives its
   value rather than discarding it (design 5.2), so it is discarded
   where the statement expression is. *)
and statement_expression context position (block : Tree.block) =
  let enclosing =
    { context.typed.enclosing with try_positions = No_positions }
  in
  within context enclosing (fun () ->
      statement_expression_items context position block)

(* No try stands in a statement expression (design 5.1 rule 3), whose
   statements [statement_expression] gives no positions. *)
and statement_expression_items context position (block : Tree.block) =
  match List.rev block.node.items with
  | Block_statement last :: before ->
      items context (List.rev before);
      statement_value context position last
  | (Block_declaration _ | Block_type_declaration _ | Block_defer _) :: _
  | [] ->
      block_items context block;
      Ctype.void

(* Types the last block item of a statement expression, a statement,
   and gives the value of the statement expression: that of an
   expression statement past the named labels before it, as Clang reads
   it; void for any other statement. The value is no bit-field in Clang,
   and has no _Atomic type, as Clang refuses an [Atomic_value] there. *)
and statement_value context position (statement : Tree.statement) =
  match statement.node with
  | Expression_statement value ->
      let typed = statement_operand context (value_position position) value in
      Ctype.unqualified (value_type typed)
  | Labeled
      { label = { node = Named_label _; _ } as label; statement = labeled } ->
      label_of context label;
      statement_value context position labeled
  | Labeled
      { label = { node = Case_label _ | Case_range _ | Default_label; _ }; _ }
  | Compound _ | Null_statement | Attribute_statement _ | If _ | Switch _
  | While _ | Do _ | For _ | Goto _ | Computed_goto _ | Continue _ | Break _
  | Return _ | Asm _ | Match _ ->
      typed_statement context statement;
      Ctype.void

(* 6.3.2.1p2: an expression evaluated on its own, as an expression
   statement is, an lvalue converted to its value. *)
and statement_operand context position value =
  let typed = positioned context position value in
  context.needs_complete typed.expression_type;
  typed

(* 6.3.2.2p1: an expression evaluated as a void expression, for its
   effects alone, which discards its value (design 5.2). The statements
   and the comma type such an expression here; a cast to void, which
   discards on purpose, and a void conditional, which discards a branch
   that it has typed, do otherwise. *)
and discard context value =
  refuse_dropped_result context value
    (statement_operand context Discarded value)

(* 7.19p3: each step of the member path of [offsetof] reaches into the
   type that the steps before it reach, which may not be a variant (design
   3.2 rule 6); the path may end at one. *)
and offsetof_path context span (reached : Ctype.t) path =
  match path with
  | [] -> ()
  | step :: rest ->
      refuse_variant context span reached;
      Option.iter
        (fun next -> offsetof_path context span next rest)
        (offsetof_step context reached step)

(* The type that [step] reaches from [reached]; [None] where the model
   cannot follow it, and the backend checks the rest of the path. The
   member is looked up as declared, since a qualifier that the backend
   adds to it does not change whether it is a variant. A subscript of a
   pointer, which offsetof does not take, is followed too, so that rule 6
   holds whether the backend refuses it or not. *)
and offsetof_step context (reached : Ctype.t) (step : Tree.designator_node) =
  match (step, reached.shape) with
  | Member_designator name, Record tag ->
      context.needs_complete reached;
      Option.map
        (fun (found : Ctype.found_member) -> found.member.member_type)
        (Ctype.find_member context.tags tag name.node)
  | (Index _ | Index_range _), Array { element; _ } -> Some element
  | (Index _ | Index_range _), Pointer referenced -> Some referenced
  | ( Member_designator _,
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
      | Array _ | Function _ | Unknown_type _ ) )
  | ( (Index _ | Index_range _),
      ( Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list
      | Function _ | Unknown_type _ ) ) ->
      None

and designator context (designator : Tree.designator) =
  match designator.node with
  | Index index -> ignore (expression context index)
  | Index_range { low; high } ->
      ignore (expression context low);
      ignore (expression context high)
  | Member_designator _ -> ()

and integer_constant context candidate =
  ignore (expression context candidate);
  constant_value context candidate

(* The type and value of an integer constant expression typed before. *)
and constant_value context candidate =
  refuse_dependent context candidate;
  match operand_constant context candidate with
  | Integer_expression { value; flaw = None } -> (
      match integer_type_of context (operand_typed context candidate) with
      | Ok integer -> Ok (integer, value)
      | Error diagnostic -> context.fail candidate.span diagnostic)
  | Integer_expression { flaw = Some (Comma_operator span); _ } -> Error span
  | Integer_expression { flaw = Some (Invalid { span; diagnostic }); _ }
  | Unevaluable { span; diagnostic } ->
      context.fail span diagnostic
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
        compatible context span (Ctype.without_top_qualifiers t) variant_type
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
    refuse_conversion context initialising.Tree.span scalar
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
      location = location_of context;
      index = integer_constant context;
    }
  in
  context.needs_complete t;
  place_declared_try context ~constant t initialiser;
  Initialiser.initialise typing t initialiser

and block_items context (block : Tree.block) = items context block.node.items

(* The items after a defer are its scope (design 6 rule 1). *)
and items context = function
  | [] -> ()
  | Tree.Block_declaration declaration :: rest ->
      block_declaration context declaration;
      items context rest
  | Block_type_declaration declaration :: rest ->
      context.type_declaration declaration;
      items context rest
  | Block_statement statement :: rest ->
      standing_statement context Block_item None statement;
      items context rest
  | Block_defer { keyword = _; statement } :: scope ->
      deferred_statement context statement;
      defer_scope context scope

(* No try stands in the statement of a defer (design 5.1 rule 4), whose
   statements this gives no positions, and no case or default label in
   it belongs to a switch around it (6 rule 5). The statement is moved
   text (6 rule 8). *)
and deferred_statement context (statement : Tree.statement) =
  let enclosing =
    { context.typed.enclosing with
      try_positions = No_positions;
      case_labels = guarded_from_switch context Deferred_statement }
  in
  within context enclosing (fun () ->
      context.read_moved statement.span (fun () ->
          typed_statement context statement))

(* No case or default label in the scope of a defer belongs to a switch
   around the scope, which would enter it past the defer (design 6 rule
   5). *)
and defer_scope context scope =
  let enclosing =
    { context.typed.enclosing with
      case_labels = guarded_from_switch context Defer_scope }
  in
  within context enclosing (fun () -> items context scope)

(* What a case or default label belongs to inside [guarded], which a
   switch around it may not enter: only where a label would belong to
   that switch does [guarded] decide, as anywhere else the label is
   refused for what is around [guarded]. *)
and guarded_from_switch context guarded =
  match context.typed.enclosing.case_labels with
  | Switch_body -> guarded
  | (No_switch | Match_arm | Test_statement | Deferred_statement | Defer_scope)
    as around ->
      around

(* A block-item declaration gives a try the position of design 5.1 rule
   3 that its initialiser confirms. *)
and block_declaration context (declaration : Tree.declaration) =
  let place =
    match declaration_try declaration with
    | Some held_span ->
        Unchecked_declaration
          { held_span;
            form = Initialiser;
            holder =
              { statement = declaration.span; labels = None;
                standing = Block_item } }
    | None -> No_place
  in
  holding context place (fun () -> context.declaration declaration)

and typed_statement context statement =
  standing_statement context Substatement None statement

(* A statement that stands as [standing], after the C labels [labels]
   span, which are those of a statement that holds a try (design 5.1
   rule 3). The labels of a match arm are no statement's. *)
and standing_statement context standing labels (statement : Tree.statement) =
  let enclosing = context.typed.enclosing in
  let scalar ~clause condition =
    require_scalar context condition.Tree.span ~clause
      (whole_value context condition)
  in
  match statement.node with
  | Labeled { label; statement = labeled } ->
      label_of context label;
      let first =
        match labels with
        | Some (labels : Tree.span) -> labels.first
        | None -> label.span.first
      in
      standing_statement context standing
        (Some { first; last = label.span.last })
        labeled
  | Expression_statement value ->
      let place =
        match statement_try value with
        | Some (held_span, form) ->
            Placed
              { held_span; form;
                holder = { statement = statement.span; labels; standing } }
        | None -> No_place
      in
      holding context place (fun () -> discard context value)
  | Compound block -> block_items context block
  | Computed_goto value -> ignore (expression context value)
  | Null_statement | Attribute_statement _ | Goto _ | Continue _ | Break _ ->
      ()
  | If { condition = Controlling condition; then_branch; else_branch } ->
      scalar ~clause:"6.8.4.1p1" condition;
      typed_statement context then_branch;
      Option.iter (typed_statement context) else_branch
  | If
      { condition = Pattern_test { pattern_span; pattern; operand };
        then_branch; else_branch } ->
      let otherwise =
        Option.map (fun (branch : Tree.statement) -> branch.span) else_branch
      in
      single_pattern_test context statement ~pattern_span ~pattern ~operand
        then_branch (If_test { otherwise });
      Option.iter (typed_statement context) else_branch
  | Switch { controlling; body } ->
      switch_controlling context controlling;
      within context { enclosing with case_labels = Switch_body } (fun () ->
          typed_statement context body)
  | Match { scrutinee; arms } ->
      match_statement context statement scrutinee arms
  | While { condition = Controlling condition; body } ->
      scalar ~clause:"6.8.5p2" condition;
      typed_statement context body
  | While
      { condition = Pattern_test { pattern_span; pattern; operand }; body } ->
      single_pattern_test context statement ~pattern_span ~pattern ~operand
        body While_test
  | Do { body; condition } ->
      typed_statement context body;
      scalar ~clause:"6.8.5p2" condition
  | For { clause; condition; step; body } ->
      Option.iter (for_clause context) clause;
      Option.iter (scalar ~clause:"6.8.5p2") condition;
      Option.iter (discard context) step;
      typed_statement context body
  (* 6.8.6.4p1 is left to the backend: GCC and Clang refuse a return
     that mismatches the function by default but accept it under
     -Wno-return-mismatch, and GNU C returns a void expression from a
     void function. Either way a void function discards the value; a
     return type that typec does not know is a target, as any other. *)
  (* Lowering writes the operand of a return in the scope of a defer in
     a block of its own, ahead of the copies (design 6 rule 12). *)
  | Return (Some value) when returns_void enclosing ->
      context.read_moved value.span (fun () -> discard context value)
  | Return value ->
      let position =
        match enclosing.return_type with
        | Some (Answer t) -> Targeted t
        | Some (Depends_on _) | None -> Untargeted
      in
      let operand (value : Tree.expression) =
        context.read_moved value.span (fun () ->
            ignore (positioned context position value))
      in
      Option.iter operand value
  (* Design 3.4: an asm operand takes a value whole, a distinct one too,
     since asm is unchecked and the backend sees the representation. *)
  | Asm { operands; qualifiers = _; template = _ } ->
      Option.iter
        (fun (operands : Tree.asm_operands) ->
          List.iter
            (fun (operand : Tree.asm_operand) ->
              let typed = whole_value context operand.node.value in
              refuse_type_parameter_asm context operand.span
                typed.expression_type)
            (operands.outputs @ operands.inputs))
        operands

(* The storage classes of 6.8.5p3 are left to the backend: in GNU C,
   GCC and Clang accept all but _Thread_local, which 6.7.1p3 refuses in a
   block. *)
and for_clause context (clause : Tree.for_clause) =
  match clause with
  | Clause_declaration declaration -> context.declaration declaration
  | Clause_expression value -> discard context value

(* 6.8.4.2p1. *)
and switch_controlling context controlling =
  match operand context (expression context controlling) with
  | Arithmetic_operand { arithmetic = Integer _; _ } | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail controlling.span
        (Rule.c_text
           "the controlling expression of a switch is not an integer (C11 \
            6.8.4.2p1)")

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
    | Test_statement ->
        context.fail label.span
          (Rule.message Enclosing_switch_label
             "a case or default label inside the statement of a \
              single-pattern test, which only a successful test enters")
    | Deferred_statement ->
        context.fail label.span
          (Rule.message Deferred_entry
             "a case or default label in the statement of a defer that \
              belongs to a switch around it, which would jump into the \
              statement")
    | Defer_scope ->
        context.fail label.span
          (Rule.message Deferred_entry
             "a case or default label in the scope of a defer statement \
              that belongs to a switch around the scope, which would jump \
              into the scope past the defer")
    | No_switch ->
        context.fail label.span
          (Rule.c_text "a case or default label outside a switch (C11 6.8.1p2)")
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
      match constant_value context value with
      | Ok _ -> ()
      | Error _ ->
          context.fail value.span
            (Rule.c_text
               "a case label is not an integer constant expression (C11 \
                6.8.4.2p3)"))
  | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail value.span
        (Rule.c_text "a case label is not an integer (C11 6.8.4.2p3)")

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
  let variant, constructors =
    scrutinee_variant context ~what:"the scrutinee of a match" scrutinee.span
      t
  in
  record_site context ~variant_type:t
    (Matching
       { statement = statement.span; scrutinee = scrutinee.span; variant;
         access = access_of context scrutinee t;
         selects =
           (fun () ->
             typed_arms context ~statement variant constructors arms) })

(* Design 4.6: the operand obeys 4.1 rule 1 and the pattern 4.1 rule 3,
   as a scrutinee and a label of a match do. The [else] statement is the
   caller's. *)
and single_pattern_test context (statement : Tree.statement) ~pattern_span
    ~(pattern : Tree.pattern) ~(operand : Tree.expression)
    (controlled : Tree.statement) form =
  let t = (expression context operand).expression_type in
  let variant, constructors =
    scrutinee_variant context ~what:"the operand of a single-pattern test"
      operand.span t
  in
  record_site context ~variant_type:t
    (Testing
       { statement = statement.span; scrutinee = operand.span; variant;
         access = access_of context operand t;
         selects =
           (fun () ->
             tested context variant constructors ~pattern_span pattern
               controlled form) })

(* The bindings of a test, then its statement, which is in their scope
   and in which no case or default label of a switch around it may stand
   (4.6 rules 4 and 6). *)
and tested context variant constructors ~pattern_span
    (pattern : Tree.pattern) (controlled : Tree.statement) form =
  let checked =
    pattern_constructor context ~site:Test_pattern variant constructors
      pattern_span pattern
  in
  let bindings = pattern_bindings context checked in
  let enclosing =
    { context.typed.enclosing with case_labels = Test_statement }
  in
  within context enclosing (fun () -> typed_statement context controlled);
  { form; constructor = checked.constructor.constructor_name;
    constructors = List.map constructor_name constructors; bindings;
    controlled = controlled.span }

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
  | Some
      ( Integer_expression { flaw = Some _; _ }
      | Not_integer _ | Unevaluable _ )
  | None ->
      false

and reachability_facts context =
  { Reachability.noreturn = calls_noreturn context;
    non_zero = non_zero_constant context;
    pragma_before =
      (fun index -> index > 0 && is_pragma context.text.tokens.(index - 1))
  }

(* Design 4.3 rule 1, asked of each arm once typing has read it, so that
   every match that typing reads, and lowering emits, is checked. An arm
   is walked again for each arm around it, at most as many times as the
   parser's bound on nested brackets. *)
and refuse_open_arm context arm =
  match Reachability.arm_refusal (reachability_facts context) arm with
  | Some { span; diagnostic } -> context.fail span diagnostic
  | None -> ()

(* 4.1 rule 1, 4.2 rule 4: a variant, whose qualifiers are ignored, and
   complete here, so that its constructors are known. [what] names the
   expression: a scrutinee, or the operand of a test (4.6 rule 2). *)
and scrutinee_variant context ~what span t =
  context.needs_complete t;
  match (Ctype.as_variant t, Ctype.constructors context.tags t) with
  | Some variant, Some constructors -> (variant, constructors)
  | Some variant, None ->
      context.fail span
        (Rule.message Match_scrutinee
           (Printf.sprintf
              "%s is of the incomplete variant %s, whose constructors are \
               unknown here"
              what (quoted_variant variant)))
  | None, _ ->
      context.fail span
        (Rule.message Match_scrutinee
           (what
          ^ " is not of a variant type; a pointer is not dereferenced \
             implicitly"))

(* The constructor that [pattern] at [site] names, with one sub-pattern
   per field or, in a test, no field list (4.1 rule 3, 4.6 rule 2). *)
and pattern_constructor context ~site variant constructors
    (label : Tree.span) (pattern : Tree.pattern) =
  let name = pattern.constructor.node in
  match
    List.find_opt
      (fun (constructor : Ctype.constructor) ->
        (constructor.constructor_name :> string) = name)
      constructors
  with
  | None ->
      context.fail label
        (Rule.message Pattern
           (Printf.sprintf "%s names no constructor of the variant %s"
              (quote name) (quoted_variant variant)))
  | Some constructor ->
      { constructor;
        sub_fields = sub_pattern_fields context ~site label pattern constructor
      }

(* The sub-patterns of [pattern] with the fields of [constructor]: one
   sub-pattern per field, or no field list, which only a test may omit
   for a constructor with fields (4.1 rule 3, 4.6 rule 2). *)
and sub_pattern_fields context ~site label (pattern : Tree.pattern)
    (constructor : Ctype.constructor) =
  let name = quote (constructor.constructor_name :> string) in
  let fields = List.length constructor.fields in
  let refuse text =
    context.fail label
      (Rule.message Pattern (text ^ void_fields_note constructor))
  in
  match (pattern.sub_patterns, site) with
  | None, Match_label when fields > 0 ->
      refuse
        (Printf.sprintf
           "the case label %s omits the field list of a constructor with \
            %d field(s), which only a single-pattern test may"
           name fields)
  | None, _ -> []
  | Some sub_patterns, _ when List.length sub_patterns <> fields ->
      refuse
        (Printf.sprintf
           "the pattern %s has %d sub-pattern(s), and the constructor has \
            %d field(s)"
           name (List.length sub_patterns) fields)
  | Some sub_patterns, _ -> List.combine sub_patterns constructor.fields

(* Each label of [arm] with its pattern checked against the constructor
   that it names; [None] for a [default]. *)
and labelled_constructors context variant constructors (arm : Tree.arm) =
  List.map
    (fun (label : Tree.arm_label) ->
      match label.node with
      | Default_arm_label -> (label, None)
      | Pattern_label pattern ->
          let checked =
            pattern_constructor context ~site:Match_label variant
              constructors label.span pattern
          in
          (label, Some checked))
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
    | (label, Some { constructor; _ }) :: rest ->
        let name = constructor.constructor_name in
        if List.mem name seen then
          context.fail label.span
            (Rule.message Exhaustiveness
               (Printf.sprintf "the constructor %s is covered twice"
                  (quote (name :> string))));
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
              (quoted_variant variant)))
  | (default : Tree.arm_label) :: _, [] ->
      context.fail default.span
        (Rule.message Default_arm
           "the `default` of a match covers no constructor")
  | _ :: _, _ :: _ -> missing

and constructor_name (constructor : Ctype.constructor) =
  constructor.constructor_name

(* What a diagnostic calls the constructors [names]. *)
and constructor_list names =
  let quoted =
    List.map (fun (name : Spelling.constructor) -> quote (name :> string)) names
  in
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
    | [ (_, Some checked) ] -> pattern_bindings context checked
    | _ ->
        List.iter (refuse_shared_binding context) labels;
        []
  in
  let cases =
    List.concat_map
      (function
        | _, Some { constructor; _ } -> [ constructor ]
        | _, None -> defaulted)
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

(* A pattern without a field list has no sub-pattern to bind, as if each
   field were [_] (4.6 rule 2). *)
and pattern_bindings context (checked : checked_pattern) =
  List.concat_map
    (sub_pattern_binding context checked.constructor)
    checked.sub_fields

and sub_pattern_binding context (constructor : Ctype.constructor)
    ((sub_pattern : Tree.sub_pattern), (field : Ctype.member)) =
  match (sub_pattern, field.member_name) with
  | Wildcard _, _ -> []
  | Binding { name = binding; declared }, Some field_name ->
      context.binding binding declared (non_modifiable field.member_type);
      [ { name = binding.node; constructor = constructor.constructor_name;
          field = field_name } ]
  | Binding _, None ->
      invalid_arg "Expressions.sub_pattern_binding: an unnamed field"

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

(* The defer statements of the body, which reachability finds once
   typing has read it, as its facts need, and the function around them
   that the form of a return in their scopes needs (design 13.5). *)
let record_defers context ~name ~declarator ~enclosing (block : Tree.block) =
  match Reachability.defers (reachability_facts context) block with
  | [] -> None
  | sites ->
      let returns =
        if returns_void enclosing then Returns_void else Returns_value
      in
      let recorded =
        { function_name = name; declarator; body = block.span; returns;
          sites }
      in
      context.typed.defers <- recorded :: context.typed.defers;
      Some recorded

let function_body context ~name ~declarator ~return_type block =
  let view = context.typed in
  let enclosing =
    { function_name = Some name; return_type = Some return_type;
      case_labels = No_switch; try_positions = Positions No_place }
  in
  view.function_tries <- [];
  (match Reachability.label_refusal block with
  | Some { span; diagnostic } -> context.fail span diagnostic
  | None -> ());
  within context enclosing (fun () -> block_items context block);
  view.tries <- view.function_tries @ view.tries;
  record_defers context ~name ~declarator ~enclosing block
