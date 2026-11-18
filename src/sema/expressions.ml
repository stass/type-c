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

type value_conversion =
  | Unconverted
  | To_slice of string
  | To_arithmetic of Arithmetic.t

type try_value =
  | Read of { field : string; conversion : value_conversion }
  | No_value

type try_site = {
  try_span : Tree.span;
  operand : Tree.span;
  temporary : int;
  operand_instance : Ctype.instance;
  return_instance : Ctype.instance;
  err_field : string option;
  value : try_value;
}

type try_holder = {
  holder : holder;
  hoisted : Try_plan.hoisted list;
  tries : try_site list;
  void_casts : Tree.span list;
}

(* [late_call] is whether an operand after the first holds a call or a
   statement expression, which may return a second time (section 8 rule
   10). *)
type slice_check = {
  whole : Tree.span;
  instance : string;
  check : check;
  late_call : bool;
}

and check =
  | Index of { slice : Tree.span; index : Tree.span }
  | Sub of { slice : Tree.span; low : Tree.span; high : Tree.span }
  | Conversion of { converted_to : string }

type slice_form = Tested of { body : Tree.span } | Untested

type slice_making = {
  span : Tree.span;
  instance : Ctype.instance;
  making : making;
  braced : Tree.span option;
}

and making =
  | From_array of { operand : Tree.span }
  | Unchecked of { pointer : Tree.span; count : Tree.span }
  | From_string of { literal : Tree.span }

(* A slice index as typing meets it: [body] is that of the function
   being typed, and [evaluated] is cleared where the index turns out to
   stand in an operand that C does not evaluate (design 13.5). *)
type slice_site = {
  checked : slice_check;
  body : Tree.span option;
  mutable evaluated : bool;
}

(* Whether a function returns void, which decides the form of a return
   of a value in the scope of a defer (design 13.5). *)
type returns = Returns_void | Returns_value

type function_defers = {
  function_name : string;
  declarator : Tree.declarator;
  parameters : string list;
  body : Tree.span;
  returns : returns;
  sites : Reachability.defer_site list;
}

(* The holder being typed (design 5.1 rule 3): the statement or
   declaration, the plan of its expression, and whether a pragma line
   stands in the stretch that must hold none, which is found once for
   all the tries of the holder. [unchecked_object]: a declaration whose
   object the initialiser has yet to confirm as one that may hold a
   try. *)
type held = {
  holder : holder;
  plan : Try_plan.t;
  pragma_in_stretch : bool Lazy.t;
  unchecked_object : bool;
}

(* What the statement being typed says of a try in it: refused under the
   rule given where the statement is no holder, as a loop's condition
   is, or placed by the plan of its holder. *)
type try_place = Not_held of Rule.t * string | Held of held

(* Whether statements are holders (design 5.1 rule 3), as those of a
   function body are outside any statement expression and deferred
   statement, and if so what the statement being typed says of a try;
   where they are not, the message that refuses a try there, which says
   what to write in that place. *)
type try_positions = No_positions of string | Positions of try_place

(* The messages of [No_positions], each with a remedy that can be
   followed from where the try stands. *)
let try_outside_functions =
  "try stands outside a function body; give it a statement or declaration \
   of its own in a function body"

let try_in_statement_expression =
  "try stands in a statement expression, from inside which its error path \
   would return; give it a statement or declaration of its own outside the \
   statement expression"

let try_in_deferred_statement =
  "try stands in the statement of a defer, which no return may leave; take \
   the result apart there with match"

(* The positions of statements that hold no try for the reason [text],
   unless the statements around them already hold none: the outermost
   reason is the one whose remedy leads out of every place that holds no
   try. *)
let without_holders positions text =
  match positions with
  | No_positions _ -> positions
  | Positions _ -> No_positions text

(* What holds an initialiser most closely, for a zero initialiser of
   design 7.1 rule 3 ({!zero_initialiser}). *)
type initialiser_holder = Holder_at of int | For_clause

(* The pattern that binds a name (design 4.1 rule 4, 4.6 rule 4): the
   label of an arm, whose items the binding's scope is, or the head
   [if (case P = e)] or [while (case P = e)] of a single-pattern test,
   whose statement it is. *)
type binder = Arm_label of Tree.span | Test_head of Tree.span

(* What encloses the statement being typed: the function, for __func__,
   return and try, the switch or match that case labels need, and the
   positions of try. [return_type] and [body] are [None] outside
   functions. [in_generic]: the function is the definition of a generic
   function. [binders] holds, by name, the last pattern of the function
   that binds the name, so that a use the parser finds undeclared,
   outside every binding's scope, can name a pattern; one entry per name
   bounds it by the function's text, and only a function has one. *)
type enclosing = {
  function_name : string option;
  body : Tree.span option;
  in_generic : bool;
  return_type : Ctype.t Unknown.answer option;
  case_labels : label_owner;
  try_positions : try_positions;
  binders : (string, binder) Hashtbl.t option;
}

(* Rule 3 (try-lifetime): an object that an expression of a holder makes,
   whose life C ends with a unit that lowering changes for a hoisted
   operand (13.5): a compound literal, which lives until its block
   ends, and an array member of a value that is no lvalue, which lives
   in a temporary object until its full expression ends; or such a
   member whose type typec does not compute, which may be an array. *)
type short_lived =
  | Literal_object of Tree.span
  | Temporary_array of Tree.span
  | Unknown_member of Tree.span * Unknown.t

type construction = {
  span : Tree.span;
  variant : Ctype.variant_name;
  constructor : Spelling.constructor;
  callee : Tree.span option;
  arguments : Tree.expression list;
  braced : Tree.span option;
}

type base = Base_object of Tree.span | Base_pointer of Tree.span

type access =
  | Through_pointer
  | Through_base of { base : base; members : string list }
  | Through_copy

type pattern_field = { constructor : Spelling.constructor; field : string }

type reach = {
  base : int;
  path : pattern_field list;
  field : pattern_field;
}

type position_object =
  | In_place of reach
  | Pointed_by of { local : int; pointer : reach }

type pattern_position = {
  variant : Ctype.variant_name;
  position_object : position_object;
}

type pointer_local = { local : int; local_variant : Ctype.variant_name }

type binding = { name : string; field : reach }

type matched_arm = {
  number : int;
  arm : Tree.span;
  labels : Tree.span;
  cases : Spelling.constructor list;
  bindings : binding list;
}

type test_form = If_test of { otherwise : Tree.span option } | While_test

type read_at = Scrutinee of Ctype.variant_name | Position of pattern_position

type selection_tree =
  | Arm of int
  | Read of {
      at : read_at;
      branches : (Spelling.constructor list * selection_tree) list;
    }

type nested = { locals : pointer_local list; tree : selection_tree }

type test = {
  form : test_form;
  constructor : Spelling.constructor;
  constructors : Spelling.constructor list;
  bindings : binding list;
  controlled : Tree.span;
  nested : nested option;
  size : Selection.size;
}

type arms = {
  matched : matched_arm list;
  nested : nested option;
  size : Selection.size;
}
type selection = Arms of arms | Test of test

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

let quote text = "'" ^ Shown.cut text ^ "'"

let quoted_variant name = quote (Type_name.of_variant name)

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
    | Matching of (unit -> arms) matching_of
    | Testing of (unit -> test) matching_of

  val create : unit -> t

  (* Design 4.7 rule 8: a constructor pattern at [span], whose variant
     the matching around it lowers to the names of, stands within the
     scope of that variant's declaration. *)
  val refuse_outside_pattern :
    Ctype.tags ->
    fail:(Tree.span -> Rule.diagnostic -> unit) ->
    variant_type:Ctype.t ->
    variant:Ctype.variant_name ->
    Tree.span ->
    unit

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
  val brace : t -> construction -> replacing:Tree.span -> unit
  (** Lowers a recorded construction to its braced list alone, in place
      of [replacing], the initialiser with its parentheses (design
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
    | Matching of (unit -> arms) matching_of
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

  let refuse_outside_pattern tags ~fail ~variant_type ~variant span =
    if not (within_scope tags variant_type span) then
      fail span (outside_scope Variant_scope ~what:"the pattern" ~variant)

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

  let brace sites construction ~replacing =
    Hashtbl.replace sites.constructions construction.span
      { construction with braced = Some replacing }

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
   type that typec does not know needs to tell (design 5.2). A
   [Discarded_branch] is a branch of a conditional that stands where its
   value is discarded: its value is discarded too, but a try there reads
   its value, as C gives both branches of a conditional one type
   (6.5.15p3, design 13.5). A [Listed] position has a target type whose
   conversion as if by assignment the construct around it checks: that
   of a value in a braced initialiser, whose target type is the
   subobject at its place, which the value may instead initialise a
   member of through elided braces (6.7.9p20), so the initialiser checks
   its conversion where it places it; and that of a branch of a
   conditional, whose value converts as the composite type of both
   branches does (6.5.15p6), which the conditional's own position
   checks. *)
type position =
  | Untargeted
  | Targeted of Ctype.t
  | Listed of Ctype.t
  | Discarded
  | Discarded_branch

(* The position of an operand whose value is that of the expression
   around it, which stands in [position]: the association that a
   selection selects and the last item of a statement expression. It is
   discarded where that expression is (design 5.2), but has no target
   type, as design 3.3 gives neither one. *)
let value_position = function
  | Discarded -> Discarded
  | Discarded_branch -> Discarded_branch
  | Untargeted | Targeted _ | Listed _ -> Untargeted

(* The position of a branch of a conditional that stands in [position]. *)
let branch_position = function
  | Discarded | Discarded_branch -> Discarded_branch
  | Targeted target | Listed target -> Listed target
  | Untargeted -> Untargeted

(* Where a pattern stands, which decides whether it may omit the field
   list of a constructor with fields: only a test may (design 4.1 rule 3,
   4.6 rule 2). *)
type pattern_site = Match_label | Test_pattern

(* A variant that a pattern names, with the index of each constructor
   by its name, made once for each variant in a match, so that finding
   the constructor of a pattern takes a time that grows with neither the
   variant nor the labels (design 4.7 rule 10). *)
type indexed_variant = {
  variant_type : Ctype.t;
  name : Ctype.variant_name;
  constructors : Ctype.constructor array;
  index_of : (string, int) Hashtbl.t;
}

(* What may stand at a position, by its type (design 4.7 rule 2): a
   variant; a pointer to a variant, with the type that it points to;
   any other type, which a type parameter is (7.1 rule 2). *)
type position_type =
  | Variant_position of indexed_variant
  | Pointer_position of Ctype.t
  | Other_position

(* A binding that a label declares, and the field that it copies (4.7
   rule 7). *)
type found_binding = {
  identifier : Tree.identifier;
  declared : Tree.declared;
  object_type : Ctype.t;
  copied : reach;
}

(* A pattern checked against the variant of its position: the
   constructor that it names, the pattern as selection reads it, and its
   bindings at every depth in source order. Only [constructor_pattern]
   makes one, so that the index of a selection pattern is that of its
   constructor in its variant. *)
type checked_pattern = {
  constructor : Ctype.constructor;
  selection : Selection.constructor_pattern;
  bindings : found_binding list;
}

type zero_initialiser = { list : Tree.span; holder : int }
type classified_list = Zero_list of zero_initialiser | Kept_list

(* Where a sub-pattern stands (4.7 rule 1): the field [member], of index
   [index], of the constructor [holder] at [position], which lowering
   reaches as [reached_field]. *)
type field_site = {
  holder : Ctype.constructor;
  position : Selection.position;
  index : int;
  member : Ctype.member;
  reached_field : reach;
}

(* A table keyed by positions that hashes every step: the polymorphic
   hash reads only the first few values of a list, so positions that
   share their nearest steps would share a bucket, and a wide pattern
   would take time quadratic in its width. *)
module Positions = Hashtbl.Make (struct
  type t = Selection.position

  let equal = ( = )

  let hash position =
    List.fold_left
      (fun hash (step : Selection.step) ->
        Hashtbl.hash (hash, step.holder, step.field, step.through_pointer))
      0 position
end)

(* What the patterns of one match or test share: where they stand, the
   variants that they name, by the id of each one's structure, each
   position below the scrutinee that a constructor pattern names, and
   the number of pointer locals that those positions take. *)
type pattern_reading = {
  site : pattern_site;
  variants : (int, indexed_variant) Hashtbl.t;
  places : pattern_position Positions.t;
  mutable locals : int;
}

let pattern_reading site =
  { site; variants = Hashtbl.create 8; places = Positions.create 8;
    locals = 0 }

(* An object below the scrutinee as lowering reaches it: from the object
   that the pointer local numbered [from_local] points to, through the
   fields in place [in_place], outermost first. *)
type object_reach = { from_local : int; in_place : pattern_field list }

let scrutinee_reach = { from_local = 0; in_place = [] }

(* How lowering reaches the object at a position, from which it reaches
   the fields there. *)
let object_reach (named : pattern_position) =
  match named.position_object with
  | In_place { base; path; field } ->
      { from_local = base; in_place = path @ [ field ] }
  | Pointed_by { local; _ } -> { from_local = local; in_place = [] }

(* The position [position] below the scrutinee, where a pattern of
   [variant] stands, at the field [field] or under it: named the first
   time that a pattern names it, and under a [*] given the next pointer
   local, so that a local is numbered after the one it is reached from
   (design 13.5). The result is how lowering reaches its object. *)
let placed reading position variant (field : reach) ~through_pointer =
  let new_object () =
    if through_pointer then begin
      reading.locals <- reading.locals + 1;
      Pointed_by { local = reading.locals; pointer = field }
    end
    else In_place field
  in
  let named =
    match Positions.find_opt reading.places position with
    | Some named -> named
    | None ->
        let named = { variant; position_object = new_object () } in
        Positions.replace reading.places position named;
        named
  in
  object_reach named

(* The pointer locals that the positions of [reading] take, in the order
   of their numbers. *)
let named_locals reading =
  let add _ (named : pattern_position) found =
    match named.position_object with
    | Pointed_by { local; _ } ->
        { local; local_variant = named.variant } :: found
    | In_place _ -> found
  in
  Positions.fold add reading.places []
  |> List.sort (fun one other -> compare one.local other.local)

(* [enclosing] belongs to the walk in progress. Only the reader's failure
   leaves a walk early, and it ends the read, so it is not restored on
   it. [selections] and [compatibilities] hold the answers to the
   constructs that ask whether types are compatible, by the span of the
   construct, and [answered] those that lowering replaces with their
   answer. [types] holds the type of each expression, which [positioned]
   alone gives, once. [dependences] holds, by the span of each expression
   that depends on a type parameter, that of the first place in it where
   the dependence arises, and [dependent_objects] the same of the
   initialiser of each [const] object (design 7.1 rule 4).
   [classified_lists] holds how lowering writes each braced list typed,
   by its span (design 7.1 rule 3). *)
type t = {
  types : (Tree.span, typed) Hashtbl.t;
  constants : (Tree.span, constant) Hashtbl.t;
  dependences : (Tree.span, Tree.span) Hashtbl.t;
  dependent_objects : (Tree.declaration_id, Tree.span) Hashtbl.t;
  selections : (Tree.span, Tree.expression Unknown.answer) Hashtbl.t;
  compatibilities : (Tree.span, bool Unknown.answer) Hashtbl.t;
  answered : (Tree.span, answered) Hashtbl.t;
  sites : Sites.t;
  mutable enclosing : enclosing;
  mutable holders : try_holder list;
  mutable holder_tries : try_site list;
  mutable holder_void_casts : Tree.span list;
  mutable holder_short_lived : short_lived list;
  mutable next_try : int;
  mutable next_truth : int;
  mutable defers : function_defers list;
  mutable slice_sites : slice_site list;
  classified_lists : (Tree.span, classified_list) Hashtbl.t;
  slice_makings : (Tree.span, slice_making) Hashtbl.t;
}

let outside_functions =
  { function_name = None; body = None; in_generic = false; return_type = None;
    case_labels = No_switch;
    try_positions = No_positions try_outside_functions; binders = None }

let create () =
  { types = Hashtbl.create 16;
    constants = Hashtbl.create 16;
    dependences = Hashtbl.create 16;
    dependent_objects = Hashtbl.create 16;
    selections = Hashtbl.create 16;
    compatibilities = Hashtbl.create 16;
    answered = Hashtbl.create 16;
    sites = Sites.create ();
    enclosing = outside_functions;
    holders = [];
    holder_tries = [];
    holder_void_casts = [];
    holder_short_lived = [];
    next_try = 0;
    next_truth = 0;
    defers = [];
    slice_sites = [];
    classified_lists = Hashtbl.create 16;
    slice_makings = Hashtbl.create 8 }

let find_at view span = Hashtbl.find_opt view.types span
let find view (expression : Tree.expression) = find_at view expression.span

let constant view (expression : Tree.expression) =
  Hashtbl.find_opt view.constants expression.span

let selection view (expression : Tree.expression) =
  Hashtbl.find_opt view.selections expression.span

let constructions view = Sites.constructions view.sites
let matchings view = Sites.matchings view.sites

let selection_sizes view =
  List.map
    (fun matching ->
      match matching.selects with
      | Arms arms -> arms.size
      | Test test -> test.size)
    (matchings view)

let try_holders view = List.rev view.holders
let defers view = List.rev view.defers
let classified_list view (list : Tree.span) =
  Hashtbl.find_opt view.classified_lists list

(* A site outside a function that C evaluates is refused (design section
   8 rule 9), so every [Tested] form has a body. *)
let slice_checks view =
  let form (site : slice_site) =
    match site.body with
    | Some body when site.evaluated -> Tested { body }
    | Some _ | None -> Untested
  in
  List.rev_map (fun site -> (site.checked, form site)) view.slice_sites

let slice_makings view =
  Hashtbl.to_seq_values view.slice_makings
  |> List.of_seq
  |> List.sort (fun (a : slice_making) b -> compare a.span b.span)

let answered view =
  Hashtbl.to_seq_values view.answered
  |> List.of_seq
  |> List.sort (fun a b -> compare a.construct.first b.construct.first)

let types_compatible view (expression : Tree.expression) =
  Hashtbl.find_opt view.compatibilities expression.span

type type_argument =
  | Written of Tree.type_name * Ctype.t
  | Deduced of Ctype.t

type name_reading = Constructor_word of string | Ordinary_word

type context = {
  typed : t;
  target : Target.t;
  text : Reader.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> Rule.diagnostic -> 'a;
  entity : Tree.span -> string -> Tree.reference -> Entity.t;
  overloaded : Tree.reference -> bool;
  generic_definition : bool;
  generic_function : Tree.reference -> Ctype.record_tag list option;
  type_argument : Tree.span -> type_argument -> unit;
  use_instance :
    Tree.span -> written:Tree.span -> Tree.reference -> Ctype.t list -> unit;
  apply_generic :
    Tree.span -> Typec_syntax.Spelling.type_name -> Ctype.t list -> Ctype.t;
  type_name : Tree.type_name -> Ctype.t;
  declaration : initialiser_holder -> Tree.declaration -> unit;
  type_declaration : Tree.scoped_type_declaration -> unit;
  binding : Tree.identifier -> Tree.declared -> Ctype.t -> unit;
  written_name : Tree.declared -> string -> string;
  name_reading : int -> (unit -> name_reading) -> name_reading;
  visible_variants : Tree.span -> Tree.type_declaration list;
  needs_complete : Ctype.t -> unit;
  slice_instance : Tree.span -> Ctype.t -> Ctype.t;
  block_literal : unit -> unit;
  subjectless : Tree.attribute list -> unit;
      (** notes attributes of a label or a null statement, whose subject
          mentions no type parameter (design 13.3) *)
  views : Parser.views;
  hoisted_operands :
    (Parser.try_views * Tree.span) list -> (unit -> unit) -> unit;
  read_moved : Tree.span -> (unit -> unit) -> unit;
  array_operand : whole:Tree.span -> Tree.span -> (unit -> typed) -> typed;
  label_address : Tree.label_name -> unit;
  copy_deferred : Tree.span -> unit;
}

let needing need (unknown : Unknown.t) =
  let why =
    match unknown.cause with
    | Not_typed -> "which typec does not type yet"
    | Typed_differently -> "which GCC types otherwise than Clang"
  in
  Rule.message Profile
    (Printf.sprintf "%s depends on %s at %s:%d, %s" need
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

(* Whether [span] is in Type-C text, which the rules of the design bind,
   rather than in C text. *)
let is_type_c_text context (span : Tree.span) =
  File.is_type_c_text context.text.tokens.(span.first).owner

(* The quoted names [quoted], after the noun [one] or [several], and the
   count of those not named. *)
let listed ~one ~several (quoted : string Shown.few) =
  let more = Shown.more quoted in
  match List.rev (Shown.named quoted) with
  | _ :: _ when more > 0 ->
      Printf.sprintf "%s %s and %d more" several
        (String.concat ", " (Shown.named quoted))
        more
  | [ only ] -> one ^ " " ^ only
  | last :: before ->
      Printf.sprintf "%s %s and %s" several
        (String.concat ", " (List.rev before))
        last
  | [] -> invalid_arg "Expressions.listed: nothing to name"

(* What reads a value where its type refuses it, as the message names
   it. *)
type operation =
  | Operator of string  (** An operator as written, or a builtin. *)
  | Operand of string  (** The operand's role, as "an index". *)
  | Unnamed_operation

(* The refusal of [operation] on a value of [what], a type as a message
   names it, before its fix. *)
let not_defined operation what =
  match operation with
  | Operator spelling ->
      Printf.sprintf "%s is not defined on %s" (quote spelling) what
  | Operand role -> Printf.sprintf "%s may not be of %s" role what
  | Unnamed_operation -> "this operation is not defined on " ^ what

(* The tokens of [span] as a message quotes them. *)
let excerpt context (span : Tree.span) =
  Reader.excerpt context.text ~first:span.first ~last:span.last

(* The constructor that a test of a variant in place of a C idiom looks
   for: one with fields, whose values the idiom meant to read; one
   without, which [!] asks for; or one with the field that [.] or [->]
   names. *)
type sought = Holding_fields | Without_fields | Holding_field of string

(* The operand that a test matches: the variant as written, or the one
   that a pointer written before [->] points to. *)
type scrutinee = Written of Tree.expression | Pointed_to of Tree.expression

(* A test that a refusal of a variant suggests in place of a C idiom. *)
type variant_test = { scrutinee : scrutinee; sought : sought }

(* The scrutinee as a test spells it, parenthesised after [*] unless it
   is a name. *)
let scrutinee_text context = function
  | Written operand -> excerpt context operand.span
  | Pointed_to { node = Identifier _; span } -> "*" ^ excerpt context span
  | Pointed_to operand -> "*(" ^ excerpt context operand.span ^ ")"

(* [constructor] as the pattern of a test, its fields bound by their
   names where [bound] holds and ignored elsewhere. *)
let test_pattern ~bound (constructor : Ctype.constructor) =
  let field (member : Ctype.member) =
    match member.member_name with
    | Some name when bound name -> name
    | Some _ | None -> "_"
  in
  let name = (constructor.constructor_name :> string) in
  match constructor.fields with
  | [] -> name
  | fields -> name ^ "(" ^ String.concat ", " (List.map field fields) ^ ")"

let single_pattern_test pattern scrutinee =
  quote (Printf.sprintf "if (case %s = %s)" pattern scrutinee)

let has_fields (constructor : Ctype.constructor) = constructor.fields <> []

let has_field name (constructor : Ctype.constructor) =
  List.exists
    (fun (member : Ctype.member) -> member.member_name = Some name)
    constructor.fields

let is_named spelling (constructor : Ctype.constructor) =
  (constructor.constructor_name :> string) = spelling

(* Whether a test of a variant seeks [constructor]. A result holds the
   value that an idiom reads in its Ok, as try reads it, and [!] asks
   whether it failed, which its Err tells. *)
let wanted ~result sought =
  match sought with
  | Without_fields when result -> is_named Ctype.result_err
  | Without_fields -> Fun.negate has_fields
  | Holding_fields when result -> is_named Ctype.result_ok
  | Holding_fields | Holding_field _ -> has_fields

(* The binding of the field [name] of [holders], the constructors that
   have it, by a test of the first. *)
let binding_fix name holders scrutinee =
  let quoted (c : Ctype.constructor) = quote (c.constructor_name :> string) in
  match holders with
  | [] -> ""
  | first :: _ ->
      Printf.sprintf "; %s is %s; bind it with %s" (quote name)
        (listed ~one:"a field of" ~several:"a field of"
           (Shown.map quoted (Shown.few holders)))
        (single_pattern_test
           (test_pattern ~bound:(String.equal name) first)
           scrutinee)

(* The fix of a C idiom on a variant of [constructors] by what was
   written: the binding of the field that a member access names, where
   a constructor has it, or else a test for the constructor sought, or
   the first where none is. *)
let variant_fix ~result constructors sought scrutinee =
  let holders =
    match sought with
    | Holding_field name -> List.filter (has_field name) constructors
    | Holding_fields | Without_fields -> []
  in
  match (sought, holders) with
  | Holding_field name, _ :: _ -> binding_fix name holders scrutinee
  | (Holding_fields | Without_fields | Holding_field _), _ -> (
      match (List.find_opt (wanted ~result sought) constructors, constructors)
      with
      | Some tested, _ | None, tested :: _ ->
          "; test it with "
          ^ single_pattern_test
              (test_pattern ~bound:(fun _ -> true) tested)
              scrutinee
      | None, [] -> "")

(* Design 3.2 rule 6: a variant's tag and fields are reached only
   through constructors and matching, so [operation] at [span] on the
   variant [t], or converting to it, is refused, with [test] as its fix
   where a test can replace the operand. C text may use the structure
   that a variant lowers to (design 10.6). The fix is spelt only here,
   once the refusal is certain, since it quotes the operand. *)
let refuse_variant ?test context (span : Tree.span) operation (t : Ctype.t) =
  match Ctype.as_variant t with
  | Some name when is_type_c_text context span ->
      let fix =
        match (test, Ctype.constructors context.tags t) with
        | Some test, Some constructors ->
            variant_fix ~result:(Ctype.as_result t <> None) constructors
              test.sought
              (scrutinee_text context test.scrutinee)
        | Some _, None | None, _ -> ""
      in
      context.fail span
        (Rule.message Variant_operation
           (not_defined operation ("the variant " ^ quoted_variant name)
           ^ fix))
  | Some _ | None -> ()

(* What a switch on a value of type [t] likely meant in Type-C text: a
   variant is taken apart by a match (design 4). *)
let switch_remedy context span (t : Ctype.t) =
  match Ctype.as_variant t with
  | Some _ when is_type_c_text context span ->
      "; a variant is taken apart with match"
  | Some _ | None -> ""

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

(* Whether two types are compatible, asked by [construct] at [span],
   which gives the answer: an error where the argument decides it
   (design 7.1 rule 4). *)
let compared context span construct a b =
  match
    Ctype.compatible_by_argument context.target context.tags
      (location_of context span) a b
  with
  | Every_argument answer -> answer
  | Argument_decides ->
      context.fail span
        (Rule.message Type_parameter_constant
           (construct ^ " compares a type parameter with another type, \
                         which is compatible with it for some arguments \
                         and not for others"))

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

(* The expression whose value [discarded] has: itself, or the right
   operand of a comma, without parentheses. *)
let rec discarded_value (discarded : Tree.expression) =
  let value = Try_plan.without_parentheses discarded in
  match value.node with
  | Comma (_, right) -> discarded_value right
  | _ -> value

(* Whether a backend takes the value of [value] as used when an operand
   has an effect, which design 13.5 measures. Both report any other
   operation that computes a value as unused whatever its operands, and
   a cast to void would silence that report; an assignment, a call, an
   increment and a decrement keep their effect in place. *)
let used_by_effects (value : Tree.expression) =
  match value.node with
  | Binary ({ node = Logical_and | Logical_or; _ }, _, _)
  | Conditional _ | Cast _ ->
      true
  | _ -> false

(* Design 13.5: whether lowering casts [discarded], an expression whose
   value is discarded and typed [typed], to void, as a try of [view]'s
   holder stands in its value, which the prelude may leave with no
   effect where the source had one. A value of type void draws no
   report, and the left operand of a comma is a discarded value of its
   own. *)
let needs_void_cast view (discarded : Tree.expression) typed =
  let value = discarded_value discarded in
  let within (site : try_site) =
    site.try_span.first >= value.span.first
    && site.try_span.last <= value.span.last
  in
  Ctype.is_void typed.expression_type <> Unknown.Answer true
  && used_by_effects value
  && List.exists within view.holder_tries

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
  | Binary
      ({ node = Equal_to | Not_equal_to | Logical_and | Logical_or; _ }, _, _)
  | Unary (Logical_not, _)
  | Cast _ ->
      true
  | _ -> false

let refuse_distinct context span reader (distinct : Ctype.distinct) =
  let name = distinct_name distinct in
  let underlying = quote (Type_name.of_ctype distinct.representation) in
  let cast =
    match reader with
    | Operand _ -> "cast it to "
    | Operator _ | Unnamed_operation -> "cast to "
  in
  context.fail span
    (Rule.message Distinct_operation
       (not_defined reader ("the distinct type " ^ name) ^ "; " ^ cast
      ^ underlying))

(* A builtin [name] that reads the distinct object [referenced] through
   the pointer that is its first argument: the cast that reaches the
   representation converts the pointer, keeping the object's
   qualifiers. *)
let refuse_distinct_object context span name (referenced : Ctype.t)
    (distinct : Ctype.distinct) =
  let cast =
    match
      Result.bind
        (Ctype.qualify referenced.qualifiers distinct.representation)
        Ctype.pointer_to
    with
    | Ok pointer ->
        "; cast the pointer to " ^ quote (Type_name.of_ctype pointer)
    | Error _ -> ""
  in
  context.fail span
    (Rule.message Distinct_operation
       (not_defined (Operator name)
          ("the distinct type " ^ distinct_name distinct)
       ^ cast))

(* An operand of an operation at [span], as the operation sees it;
   [reads] says whether the table lets the operation read a value of a
   distinct type, and [reader] names the operation where it does not. *)
let read_operand context span ~reads ~reader (typed : typed) =
  context.needs_complete typed.expression_type;
  let typed = as_seen context span typed in
  refuse_type_parameter_operand context span typed.expression_type;
  match Ctype.as_distinct typed.expression_type with
  | Some distinct when not reads -> refuse_distinct context span reader distinct
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

(* A variant or an instance of a generic: a structure or union whose C
   name only lowering makes, so that the backend's message about it would
   spell the encoding of its name. *)
let is_type_c_record (t : Ctype.t) =
  match t.shape with
  | Record { record_name = Variant_name _ | Instance_name _; _ } -> true
  | Record _ | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
  | Array _ | Function _ | Unknown_type _ ->
      false

let mentions_type_c_record t = Ctype.has_part is_type_c_record t

(* Why two pointers do not meet. *)
type pointer_gap =
  | Distinct_gap
      (** Design 3.4: [D *] and [U *] are incompatible. GNU C only warns
          where two pointers to incompatible types meet, and the backend,
          which sees U for D, does not even warn, so typec decides in
          Type-C text. *)
  | Record_gap
      (** C11 6.5.6p3, 6.5.8p2, 6.5.9p2, 6.5.15p3: pointers to
          incompatible types where a variant or an instance is part of
          one, as of [list(int) *] and [list(double) *], that an operation
          relates. GNU C only warns of most, naming the C encodings, so
          typec refuses them as C does, in any text. A conversion leaves
          the gap to [refuse_unassignable], which checks it in full. *)
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

(* Whether [a] and [b], where a variant or an instance is part of either,
   are incompatible as the backend sees them: a distinct type is its
   representation there, so a gap that it hides in C text, which leaves
   distinct types to the backend, still shows. *)
let records_differ context span a b =
  let a = Ctype.representation a and b = Ctype.representation b in
  (mentions_type_c_record a || mentions_type_c_record b)
  && differs context span a b

(* The one rule for conversions and for the operations on two pointers:
   two pointers whose referenced types [a] and [b] mention a distinct
   type, a type parameter, a variant or an instance meet only where those
   are compatible or one is void. *)
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
  else if records_differ context span a b then Some Record_gap
  else if
    (Ctype.mentions_distinct a || Ctype.mentions_distinct b)
    && differs context span a b
  then Some Distinct_gap
  else None

(* Design 7.1 rule 4: the size, alignment or offset of a type that
   mentions a type parameter differs between arguments, so no constant
   that C asks for may hold it. *)
let parameter_dependent =
  Rule.message Type_parameter_constant
    "the value depends on a type parameter here, through a layout, a \
     builtin or a `const` object, and is another constant in each \
     instance"

let is_plain_void_pointer (t : Ctype.t) =
  match t.shape with
  | Pointer { shape = Void; qualifiers; _ } -> qualifiers = Qualifiers.none
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Function _ | Unknown_type _ ->
      false

(* The first place where the expression at [span], typed before, depends
   on a type parameter, if it does. *)
let dependence_at context (span : Tree.span) =
  Hashtbl.find_opt context.typed.dependences span

(* Refuses the expression at [span] where C asks for a constant, if it
   depends on a type parameter: whatever its class, that of an instance
   can differ. *)
let refuse_dependent_at context span =
  match dependence_at context span with
  | Some source -> context.fail source parameter_dependent
  | None -> ()

(* 6.3.2.3p3: whether a value of type [source] that converts to [target]
   as if by assignment, or meets it in == or != or as the other branch of
   ?:, must be a null pointer constant: an integer that meets a pointer,
   or a void * that meets a pointer to a function (6.5.16.1p1, 6.5.9p2,
   6.5.15p3). *)
let asks_null_pointer (target : Ctype.t) (source : Ctype.t) =
  match (Ctype.unqualified target).shape with
  | Pointer referenced ->
      Ctype.is_integer source = Answer true
      || Ctype.is_function referenced = Answer true
         && is_plain_void_pointer (Ctype.unqualified source)
  | Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      false

(* Where C asks whether the value at [span] is a null pointer constant,
   whether the program is valid depends on it, and a value that depends
   on a type parameter is a constant of value 0 for some arguments and
   not for others (design 7.1 rule 4). Every conversion and comparison
   that asks calls this: [refuse_conversion], which each conversion as if
   by assignment reaches, through elided braces too, == and !=, and ?:. *)
let refuse_dependent_null context span ~target source =
  if asks_null_pointer target source then refuse_dependent_at context span

(* Design 7.1 rule 3: a value of a type parameter converts to no other
   type, as a structure does not, though a scalar argument would. *)
let refuse_type_parameter_conversion context span ~target ~source =
  if
    (Ctype.is_opaque target || Ctype.is_opaque source)
    && differs context span target source
  then
    refuse_type_parameter context span
      "a value converts to or from a type parameter of another type"

(* A cast converts a scalar to a scalar (6.5.4p2), so a refusal between
   two of them says so. *)
let cast_hint ~(target : Ctype.t) ~(source : Ctype.t) =
  let is_scalar t = Ctype.is_scalar t = Answer true in
  if is_scalar target && is_scalar source then " without a cast" else ""

(* What a refused conversion names: the value converted, by its type or
   as written, and the step that likely makes what was meant. *)
type refused = { subject : string; hint : string }

let value_of_type (source : Ctype.t) hint =
  { subject = "a value of type " ^ quote (Type_name.of_ctype source); hint }

(* What a value converts to: an object or a parameter, as by assignment,
   or the field of a constructor that the value is the argument for. *)
type receiver =
  | Assigned
  | Field_argument of { field : string; constructor : string }

(* The argument of type [source] for the field [field] of type [target]
   of [constructor]. *)
let field_argument_text ~field ~constructor ~source ~target =
  Printf.sprintf "the argument for the field %s of %s is of type %s, not %s"
    (quote field) (quote constructor)
    (quote (Type_name.of_ctype source))
    (quote (Type_name.of_ctype target))

(* C11 6.5.16.1p1: the [refused] value, of type [source], does not
   convert to [target] as by assignment. The argument for a field is
   named as the argument, whose type the message already sets against
   the field's, so it needs no word of a cast; a refusal of C otherwise,
   so it carries no rule's name. *)
let refuse_assignment context span ~receiver ~target ~source
    { subject; hint } =
  match receiver with
  | Assigned ->
      context.fail span
        (Rule.c_text
           (Printf.sprintf "%s does not convert to %s%s%s (C11 6.5.16.1p1)"
              subject
              (quote (Type_name.of_ctype target))
              (cast_hint ~target ~source) hint))
  | Field_argument { field; constructor } ->
      context.fail span
        (Rule.message Constructor_expression
           (field_argument_text ~field ~constructor ~source ~target ^ hint))

(* Design 5, C11 6.5.16.1p1: a value of a variant or an instance converts
   to no other type, as a structure does not. The backend would refuse it
   too, naming both types by their C encodings; typec names them as
   Type-C writes them, unless a type argument decides it (design 7.1
   rule 4). [refused] names the value and the likely step, once the
   refusal is certain. *)
let refuse_record_conversion context span ~receiver ~target ~source ~refused
    =
  let refuse () =
    refuse_assignment context span ~receiver ~target ~source (refused ())
  in
  if is_type_c_record source || is_type_c_record target then
    match
      Ctype.compatible_by_argument context.target context.tags
        (location_of context span) target source
    with
    | Every_argument (Answer false) -> refuse ()
    | Argument_decides when Ctype.is_opaque target || Ctype.is_opaque source
      ->
        (* [refuse_type_parameter_conversion] refuses it, as it does a
           value of a type parameter towards any other type. *)
        ()
    | Argument_decides ->
        refuse_type_parameter context span
          "a value converts between types that a type argument decides \
           are compatible or not"
    | Every_argument (Answer true | Depends_on _) -> ()

(* C11 6.5.16.1p1: whether a pointer to [source] converts to a pointer
   to [target] as by assignment: [target] has every qualifier of
   [source], and the two are compatible or one is void. _Atomic is no
   qualifier here (6.2.5p27): compatibility compares it. A void * meets a
   pointer to a function too, as GNU C and POSIX (dlsym) let it. What
   typec cannot tell converts, as the backend decides it: the qualifiers
   of a type that typec does not compute are unknown too. *)
let pointer_assignable context span ~(target : Ctype.t) ~(source : Ctype.t) =
  let is_unknown (t : Ctype.t) =
    match t.shape with
    | Unknown_type _ -> true
    | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
    | Va_list | Array _ | Function _ ->
        false
  in
  let keeps_qualifiers =
    Qualifiers.union target.qualifiers source.qualifiers = target.qualifiers
  in
  let without_qualifiers (t : Ctype.t) =
    let atomic = { Qualifiers.none with atomic = t.qualifiers.atomic } in
    Ctype.qualify atomic (Ctype.unqualified t)
  in
  let may_be_compatible =
    match (without_qualifiers target, without_qualifiers source) with
    | Ok target, Ok source ->
        compatible context span target source <> Answer false
    | Error _, _ | _, Error _ -> true
  in
  let is_void t = Ctype.is_void t = Answer true in
  is_unknown target || is_unknown source
  || keeps_qualifiers
     && (is_void target || is_void source || may_be_compatible)

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
      match Ctype.promoted_arithmetic context.target context.tags t with
      | Answer (Some (arithmetic, promoted)) ->
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

(* Refuses an operation at [span], under C's [clause], that relates two
   pointers that [pointers_differ] keeps apart: one with a distinct type
   in Type-C text only, one with a variant or an instance in any text. *)
let refuse_mixed_pointers context span ~clause left right =
  match (left, right) with
  | Pointer_operand a, Pointer_operand b -> (
      match pointers_differ context span a.referenced b.referenced with
      | Some (Parameter_gap use) -> refuse_type_parameter context span use
      | Some Distinct_gap when is_type_c_text context span ->
          context.fail span
            (Rule.message Distinct_operation
               (Printf.sprintf
                  "the pointers %s and %s are not compatible; a cast \
                   converts one to the other"
                  (quote (Type_name.of_ctype a.pointer))
                  (quote (Type_name.of_ctype b.pointer))))
      | Some Record_gap ->
          context.fail span
            (Rule.c_text
               (Printf.sprintf
                  "the pointers %s and %s point to types that are not \
                   compatible; a cast converts one to the other (C11 %s)"
                  (quote (Type_name.of_ctype a.pointer))
                  (quote (Type_name.of_ctype b.pointer))
                  clause))
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

let token_spelling context index =
  Reader.spelling context.text context.text.tokens.(index)

let spelling context (span : Tree.span) = token_spelling context span.first

(* The operation of [whole], as a refusal of its operand names it: an
   operator by the token the parser read it from, which begins a prefix
   operation and ends a postfix one. *)
let operation_of context (whole : Tree.expression) =
  let operator token = Operator (token_spelling context token) in
  match whole.node with
  | Binary ({ span; _ }, _, _) | Assignment ({ span; _ }, _, _) ->
      operator span.first
  | Unary _ -> operator whole.span.first
  | Post_increment _ | Post_decrement _ -> operator whole.span.last
  | Member _ -> Operator "."
  | Pointer_member _ -> Operator "->"
  | Subscript _ -> Operator "[]"
  | Call _ -> Operand "a called function"
  | Cast _ -> Operand "the operand of a cast"
  | _ -> Unnamed_operation

(* The constructor that a test in place of [whole] on a variant looks
   for, by what was written. *)
let sought_of (whole : Tree.expression) =
  match whole.node with
  | Member { member; _ } | Pointer_member { member; _ } ->
      Holding_field member.node
  | Unary (Logical_not, _) -> Without_fields
  | _ -> Holding_fields

(* The operator of a step of the member path of offsetof. *)
let offsetof_operation : Tree.designator_node -> operation = function
  | Member_designator _ -> Operator "."
  | Index _ | Index_range _ -> Operator "[]"

(* A controlling expression or the first operand of ?:, which C compares
   with zero, so it may not be a variant; a test replaces it. *)
let require_condition context ~clause (condition : Tree.expression) typed =
  refuse_variant context condition.span (Operand "a condition")
    ~test:{ scrutinee = Written condition; sought = Holding_fields }
    typed.expression_type;
  require_scalar context condition.span ~clause typed

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

(* 6.5.1p2: a name that a pattern of the function binds, used outside
   the scope of the binding; [binder] is one such pattern of several. *)
let bound_elsewhere context span name binder =
  let what, pattern_span, scope =
    match binder with
    | Arm_label pattern -> ("the pattern", pattern, "its arm")
    | Test_head head -> ("the test", head, "its statement")
  in
  let location = location_of context pattern_span in
  context.fail span
    (Rule.c_text
       (Printf.sprintf
          "%s is not declared here (C11 6.5.1p2); %s %s at %s:%d binds it \
           only in %s"
          (quote name) what
          (quote (excerpt context pattern_span))
          location.file location.line scope))

(* The pattern of the enclosing function that binds [name], if any. *)
let binder_of context name =
  let binders = context.typed.enclosing.binders in
  Option.bind binders (fun binders -> Hashtbl.find_opt binders name)

(* 6.5.1p2: a name that the parser finds no declaration of. *)
let undeclared context span name =
  match binder_of context name with
  | Some binder -> bound_elsewhere context span name binder
  | None ->
      context.fail span
        (Rule.c_text (quote name ^ " is not declared (C11 6.5.1p2)"))

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
           ^ ", the backend"))
  | Of_other_architectures ->
      context.fail span
        (Rule.message Profile
           (quote name ^ " is not a builtin of "
           ^ Target.compiler_name target.backend.compiler
           ^ ", the backend, on this target's architecture ("
           ^ Target.architecture_name target.architecture
           ^ ")"))
  | Not_builtin -> undeclared context span name

let const_char context span =
  let const = { Qualifiers.none with const = true } in
  checked context span
    (Ctype.qualify const (integer_type context span Integer.Char))

(* 6.4.2.2p1: [__func__] is a [static const char] array that holds the
   name of the function, as [__FUNCTION__] is in GCC and Clang; Clang
   gives [__PRETTY_FUNCTION__] a signature, so its length is the
   backend's. An instance of a generic function has a name of its own,
   so its length is the instance's (design 7.1 rule 3). *)
let predefined context span name =
  let name_array length =
    lvalue
      (checked context span
         (Ctype.array_of context.tags (const_char context span) length))
  in
  let enclosing = context.typed.enclosing in
  match (name, enclosing.function_name) with
  | ("__func__" | "__FUNCTION__"), Some _ when enclosing.in_generic ->
      name_array Opaque
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
  | Resolved reference when context.generic_function reference <> None ->
      context.fail span
        (Rule.message Generic_function_use
           (quote name
          ^ " is a generic function, whose name alone is no function: it \
             is called, or names an instance with type arguments"))
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
let pointer_member context span ~(pointer : Tree.expression)
    (pointer_typed : typed) (name : Tree.identifier) =
  match operand context pointer_typed with
  | Pointer_operand
      { referenced = { shape = Record tag; qualifiers; _ } as referenced; _ }
    ->
      refuse_variant context span (Operator "->")
        ~test:
          { scrutinee = Pointed_to pointer; sought = Holding_field name.node }
        referenced;
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

(* Slices (design section 8) *)

let is_pragma (token : Token.t) =
  match token.kind with
  | Pragma _ | Typec_pragma -> true
  | Identifier _ | Number | Character _ | String _ | Punctuator _ -> false

(* The claimed tag of a slice instance and the type of its elements:
   the universe generic of section 8, as no other generic has its name
   (design 3.6). *)
let slice_of context (t : Ctype.t) =
  match t.shape with
  | Record ({ record_name = Instance_name instance; _ } as tag)
    when (instance.generic :> string) = Ctype.universe_slice -> (
      context.needs_complete (Ctype.record tag);
      match Ctype.find_member context.tags tag "data" with
      | Some { member = { member_type = { shape = Pointer element; _ }; _ }; _ }
        ->
          Some (Encoding.instance_name instance, element)
      | _ -> None)
  | _ -> None

(* Design section 8 rule 1: an index has an integer type that converts
   to [size_t] without dropping a bit that tells it from one in range. *)
let refuse_slice_index context span ~what (index : typed) =
  let width = Target.integer_width context.target in
  match operand context index with
  | Arithmetic_operand { arithmetic = Integer integer; _ } ->
      if width integer > width context.target.size_type then
        context.fail span
          (Rule.message Slice_index
             (Printf.sprintf
                "%s has the type %s, wider than `size_t`: the conversion \
                 would drop the bits that tell it from one in range; a cast \
                 to `size_t` writes the narrowing"
                what
                (quote (Type_name.of_ctype index.expression_type))))
  | Unknown_operand unknown ->
      context.fail span (needing ("the type of " ^ what) unknown)
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail span
        (Rule.message Slice_index
           (what ^ " has no integer type (C11 6.5.2.1p1)"))

(* A check that lowering writes as a test where C evaluates it (13.5). *)
let record_check context checked =
  let view = context.typed in
  view.slice_sites <-
    { checked; body = view.enclosing.body; evaluated = true }
    :: view.slice_sites

(* Design section 8 rule 1: [s[i]] is an lvalue of the element type. *)
let slice_index context span ~instance ~slice ~(index : Tree.expression)
    element (index_typed : typed) =
  refuse_slice_index context index.span ~what:"the index of a slice"
    index_typed;
  context.needs_complete element;
  record_check context
    { whole = span; instance;
      check = Index { slice; index = index.span };
      late_call = Tree.holds_call index };
  lvalue element

(* Design section 8 rule 3: [slice_sub(s, lo, hi)] is a slice of the
   type of [s], unqualified, as the value of [s] is. *)
let slice_sub context span ~(slice : Tree.expression) (sliced : typed)
    ((low : Tree.expression), low_typed) ((high : Tree.expression), high_typed)
    =
  let what = "a bound of `slice_sub`" in
  refuse_slice_index context low.span ~what low_typed;
  refuse_slice_index context high.span ~what high_typed;
  match slice_of context sliced.expression_type with
  | Some (instance, _) ->
      let check =
        Sub { slice = slice.span; low = low.span; high = high.span }
      in
      record_check context
        { whole = span; instance; check;
          late_call = Tree.holds_call low || Tree.holds_call high };
      value (Ctype.unqualified sliced.expression_type)
  | None ->
      context.fail slice.span
        (Rule.message Slice_operand
           (Printf.sprintf "the first operand of `slice_sub` has the type %s, \
                            which is no slice"
              (quote (Type_name.of_ctype sliced.expression_type))))

(* The instance of a slice type that [context.slice_instance] made. *)
let made_instance (t : Ctype.t) =
  match t.shape with
  | Record { record_name = Instance_name instance; _ } -> instance
  | _ -> invalid_arg "Expressions.made_instance: no instance"

(* A [slice_from_array] or a [slice_unchecked] over [element], which
   lowering writes as a compound literal until an initialiser braces it
   ([initialises_whole]). *)
let made_slice context span element making =
  let slice_type = context.slice_instance span element in
  let instance = made_instance slice_type in
  Hashtbl.replace context.typed.slice_makings span
    { span; instance; making; braced = None };
  value slice_type

let refuse_slice_operand context (operand : Tree.expression) reason =
  context.fail operand.span (Rule.message Slice_operand reason)

(* Whether [slice_from_array] takes an array operand, or refuses it
   where [slice_unchecked] needs the count that the program holds, or
   refuses it outright. Each refusal says why. *)
type array_slicing =
  | Sliceable
  | Needs_count of string
  | Unsliceable of string

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

(* A string literal that rule 6 of section 8 lets denote a [str]: plain
   or UTF-8 characters, whose elements C writes as [char]. *)
let is_char_literal context literal =
  match joined_encoding context literal with
  | Plain | Utf8 -> true
  | Char16 | Char32 | Wide -> false

(* The string literal, of any prefix, whose array [expression] is,
   through parentheses and the selections that typing has made: a write
   to it is undefined (C11 6.4.5p7). None where a selection depends on a
   type parameter, as each instance may select another operand. *)
let string_literal_source context expression =
  match value_source context expression with
  | Unknown.Answer { node = String literal; span } -> Some (span, literal)
  | Answer _ | Depends_on _ -> None

(* The fix that a refusal of [literal] as a slice names. *)
let string_literal_slice_fix context literal =
  match is_char_literal context literal with
  | true -> "a string literal is a slice only where its target type is 'str'"
  | false ->
      "a string literal of wide characters is a slice only through an array \
       that it initialises"

(* Design section 8 rule 2: [slice_from_array(a)] takes an lvalue of a
   complete array type that is not variably modified, which lowering
   writes again as the operand of a [sizeof] that C does not evaluate
   (13.5), and that is no string literal, whose slice would be writable.
   An element type that mentions a type parameter is no variable length
   array (10.3). [operand] is [array], of [length]. *)
let array_slicing context (operand : Tree.expression) (array : typed)
    (length : Ctype.length) =
  let tokens = context.text.tokens in
  let rec pragma_from index =
    index <= operand.span.last
    && (is_pragma tokens.(index) || pragma_from (index + 1))
  in
  let unchecked_takes_count =
    "`slice_unchecked` takes the count that the program holds"
  in
  match string_literal_source context operand with
  | Some (span, literal) ->
      Unsliceable
        ("the operand of `slice_from_array` is the string literal "
        ^ quote (excerpt context span)
        ^ ", whose slice would be writable; "
        ^ string_literal_slice_fix context literal)
  | None when pragma_from operand.span.first ->
      Unsliceable
        "the operand of `slice_from_array` holds a pragma line, which its \
         second writing, as the operand of `sizeof`, would repeat"
  | None -> (
      match length with
      | (Constant _ | Opaque) when array.category <> Lvalue ->
          Unsliceable "the operand of `slice_from_array` is no lvalue"
      | Constant _ | Opaque -> (
          match Ctype.is_variably_modified array.expression_type with
          | Answer false | Depends_on _ -> Sliceable
          | Answer true ->
              Needs_count
                ("the operand of `slice_from_array` is variably modified, and \
                  C would evaluate it again as the operand of `sizeof`; "
                ^ unchecked_takes_count))
      | Unknown | Variable ->
          Needs_count
            ("the operand of `slice_from_array` is an array of unknown or \
              variable length; " ^ unchecked_takes_count))

let slice_from_array context span (operand : Tree.expression) (array : typed) =
  let refuse = refuse_slice_operand context operand in
  match array.expression_type.shape with
  | Array { element; length } -> (
      match array_slicing context operand array length with
      | Sliceable ->
          made_slice context span element
            (From_array { operand = operand.span })
      | Needs_count why | Unsliceable why -> refuse why)
  | Unknown_type unknown ->
      context.fail operand.span
        (needing "the type of the operand of `slice_from_array`" unknown)
  | _ ->
      refuse
        (Printf.sprintf
           "the operand of `slice_from_array` has the type %s, which is no \
            array"
           (quote (Type_name.of_ctype array.expression_type)))

(* Design section 8 rule 4: [slice_unchecked(p, n)] is a slice of what
   [p] points to; the count converts to [size_t] as an initialiser of
   the member [len] does (13.5). *)
let slice_unchecked context span (pointer : Tree.expression)
    (pointer_typed : typed) (count : Tree.expression) =
  match operand context pointer_typed with
  | Pointer_operand { referenced; _ } ->
      made_slice context span referenced
        (Unchecked { pointer = pointer.span; count = count.span })
  | Unknown_operand unknown ->
      context.fail pointer.span
        (needing "the type of the first operand of `slice_unchecked`" unknown)
  | Arithmetic_operand _ | Distinct_operand _ | Other_operand _ ->
      refuse_slice_operand context pointer
        (Printf.sprintf
           "the first operand of `slice_unchecked` has the type %s, which \
            is no pointer"
           (quote (Type_name.of_ctype pointer_typed.expression_type)))

(* Design 13.5: an index inside [operand], an operand that C does not
   evaluate, has no test. *)
let leave_untested view (operand : Tree.span) =
  let inside (span : Tree.span) =
    operand.first <= span.first && span.last <= operand.last
  in
  List.iter
    (fun site -> if inside site.checked.whole then site.evaluated <- false)
    view.slice_sites

(* The judgement of design 13.5 for the operand of [sizeof] and of
   [__typeof__], which errs to the side of the test: C leaves the
   operand alone where typing knows its type and that type is not
   variably modified. *)
let judge_by_type view (operand : Tree.span) (t : Ctype.t) =
  match Ctype.is_variably_modified t with
  | Answer false -> leave_untested view operand
  | Answer true | Depends_on _ -> ()

(* Design section 8 rule 9: an index that C evaluates outside a function
   body has no function to declare the temporaries of its test. *)
let refuse_untested_outside context =
  let refused (site : slice_site) =
    site.evaluated && Option.is_none site.body
  in
  match List.rev (List.filter refused context.typed.slice_sites) with
  | [] -> ()
  | site :: _ ->
      context.fail site.checked.whole
        (Rule.message Slice_test_place
           "an index of a slice or a `slice_sub` that C evaluates stands \
            in a function body, where the function declares the \
            temporaries of its test")

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
  let related clause = refuse_mixed_pointers context span ~clause left right in
  let arithmetic ~integer clause =
    arithmetic_binary context span ~integer ~clause left right
  in
  match op with
  | Multiply | Divide -> arithmetic ~integer:false "6.5.5p2"
  | Remainder -> arithmetic ~integer:true "6.5.5p2"
  | Add -> addition context span left right
  | Subtract ->
      related "6.5.6p3";
      subtraction context span left right
  | Shift_left | Shift_right -> shift context span left right
  | Less_than | Greater_than | Less_or_equal | Greater_or_equal ->
      related "6.5.8p2";
      comparison context span ~relational:true ~clause:"6.5.8p2" left right
  | Equal_to | Not_equal_to ->
      related "6.5.9p2";
      comparison context span ~relational:false ~clause:"6.5.9p2" left right
  | Bitwise_and -> arithmetic ~integer:true "6.5.10p2"
  | Bitwise_xor -> arithmetic ~integer:true "6.5.11p2"
  | Bitwise_or -> arithmetic ~integer:true "6.5.12p2"
  | Logical_and -> logical context span ~clause:"6.5.13p2" left right
  | Logical_or -> logical context span ~clause:"6.5.14p2" left right

(* The conditional operator (6.5.15) *)

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
    | Depends_on unknown, (Discarded | Discarded_branch) ->
        Some (needing need unknown)
    | Answer false, _ | Depends_on _, (Untargeted | Targeted _ | Listed _) ->
        None
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
        let same u = compared context span "_Generic" t u = Answer true in
        if List.exists same earlier
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
        match compared context span "_Generic" controlling_type t with
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
    compared context span "__builtin_types_compatible_p"
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

(* Whether [name], undeclared, is the name of the enclosing function,
   which differs between the instances of a generic function. *)
let is_instance_name context name (resolution : Tree.resolution) =
  match (name, resolution) with
  | ("__func__" | "__FUNCTION__" | "__PRETTY_FUNCTION__"), Undeclared ->
      context.typed.enclosing.in_generic
  | _ -> false

(* Whether the value of [operand] is a pointer into objects of a type
   that mentions a type parameter, whose arithmetic asks for its size. *)
let points_to_parameter context operand =
  match (value_type (operand_typed context operand)).shape with
  | Pointer target | Array { element = target; _ } ->
      Ctype.mentions_opaque context.tags target
  | _ -> false

(* Whether an undeclared [name] names a builtin function of the target,
   which a call reaches through its callee, parentheses and all. *)
let is_builtin_function context name =
  match Builtin_function.find context.target name with
  | Builtin _ -> true
  | Of_other_compiler | Of_other_architectures | Not_builtin -> false

(* Design 7.1 rule 4: whether [whole] gives an answer of the argument by
   itself, apart from its operands: the layout of a type that mentions a
   type parameter, which pointer arithmetic and the address of a member
   ask for as [sizeof] does; the name of a builtin that the values of
   its arguments do not decide, which its call depends through; the
   value of a [const] object whose initialiser depends; and a statement
   expression, whose value the check does not follow. *)
let gives_dependence context (whole : Tree.expression) =
  let in_generic = context.typed.enclosing.in_generic in
  match whole.node with
  | Sizeof_expression _ | Sizeof_type _ | Alignof _ | Alignof_expression _
  | Offsetof _ ->
      measures_parameter context whole
  | Binary ({ node = Add | Subtract; _ }, left, right)
  | Subscript { operand = left; index = right } ->
      points_to_parameter context left || points_to_parameter context right
  | Member { operand; _ } | Pointer_member { operand; _ } ->
      Ctype.mentions_opaque context.tags
        (operand_typed context operand).expression_type
  | Identifier { name; resolution = Undeclared }
    when is_builtin_function context name ->
      in_generic && not (Builtin_function.values_decide name)
  | Identifier { resolution = Resolved (In_tree id); _ } ->
      Hashtbl.mem context.typed.dependent_objects id
  | Identifier { name; resolution } -> is_instance_name context name resolution
  | Statement_expression _ -> in_generic
  | _ -> false

(* The expressions of an initialiser list, designator indices among
   them. *)
let rec initialiser_list_expressions (list : Tree.initialiser_list) =
  List.concat_map
    (fun (item : Tree.designated_initialiser) ->
      List.concat_map designator_expressions item.node.designators
      @ initialiser_expressions item.node.initialiser)
    list.node

and initialiser_expressions = function
  | Tree.Expression_initialiser expression -> [ expression ]
  | Braced list -> initialiser_list_expressions list

and designator_expressions (designator : Tree.designator) =
  match designator.node with
  | Index index -> [ index ]
  | Index_range { low; high } -> [ low; high ]
  | Member_designator _ -> []

(* The expressions whose values the value of [whole] is computed from,
   evaluated or not (design 7.1 rule 4). A type name gives a type and no
   value, so what it holds is no operand. *)
let value_operands (whole : Tree.expression) =
  match whole.node with
  | Identifier _ | Constant _ | Character _ | String _ | Label_address _
  | Block_literal _ | Sizeof_type _ | Alignof _ | Types_compatible _
  | Qualified_constructor _ | Statement_expression _ ->
      []
  | Parenthesized operand | Sizeof_expression operand
  | Alignof_expression operand | Unary (_, operand) | Post_increment operand
  | Post_decrement operand | Cast { operand; _ } | Member { operand; _ }
  | Pointer_member { operand; _ } | Try { operand; _ }
  | Va_arg { list = operand; _ } ->
      [ operand ]
  | Subscript { operand = left; index = right }
  | Binary (_, left, right)
  | Assignment (_, left, right)
  | Comma (left, right) ->
      [ left; right ]
  | Call { callee; arguments } -> callee :: arguments
  | Instance _ -> []
  | Slice_operation operation -> Tree.slice_operands operation
  | Conditional { condition; if_true; if_false } ->
      (condition :: Option.to_list if_true) @ [ if_false ]
  | Generic { controlling; associations } ->
      let result (association : Tree.generic_association) =
        match association.node with
        | Association (_, result) | Default_association result -> result
      in
      controlling :: List.map result associations
  | Choose { condition; first; second } -> [ condition; first; second ]
  | Compound_literal { values; _ } -> initialiser_list_expressions values
  | Offsetof { designators; _ } ->
      List.concat_map designator_expressions designators

(* The first place where an expression typed before depends on a type
   parameter, if it does. *)
let dependence context (expression : Tree.expression) =
  dependence_at context expression.span

(* Design 7.1 rule 4: an expression depends on a type parameter where it
   gives an answer of the argument, or where an operand depends. Its
   operands are typed, and so recorded, before it. *)
let record_dependence context (whole : Tree.expression) =
  let source =
    if gives_dependence context whole then Some whole.span
    else List.find_map (dependence context) (value_operands whole)
  in
  Option.iter (Hashtbl.replace context.typed.dependences whole.span) source

(* Refuses [expression] where C asks for a constant, if it depends on a
   type parameter: whatever its class, that of an instance can differ. *)
let refuse_dependent context (expression : Tree.expression) =
  refuse_dependent_at context expression.span

(* [refuse_dependent_null] for two operands that meet, of == and != or
   the branches of ?:, each a typed expression with its type. *)
let operands_meet context (a, (a_type : Ctype.t)) (b, (b_type : Ctype.t)) =
  refuse_dependent_null context a.Tree.span ~target:b_type a_type;
  refuse_dependent_null context b.Tree.span ~target:a_type b_type

(* Whether an object of type [t] is [const], or an array of [const]
   elements, which the backends read as a constant. *)
let rec is_const_object (t : Ctype.t) =
  match t.shape with
  | Array { element; _ } -> is_const_object element
  | _ -> t.qualifiers.const

let note_object context id t initialiser =
  if is_const_object t then
    match
      List.find_map (dependence context) (initialiser_expressions initialiser)
    with
    | Some source -> Hashtbl.replace context.typed.dependent_objects id source
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

(* Design 7.1 rule 3: the name of the function is read as an array, of
   the instance's length, by an operation that takes it whole; any other
   converts it to a pointer to its first character. *)
let refuse_instance_name context operand =
  match value_source context operand with
  | Answer { node = Identifier { name; resolution }; span }
    when is_instance_name context name resolution ->
      refuse_type_parameter context span
        (name ^ " in a generic function is read as an array, whose length \
                 is that of the name of each instance")
  | Answer _ | Depends_on _ -> ()

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
  (* A slice is a structure, made by a compound literal at the use or
     over the temporaries of a function (design 13.5). *)
  | Slice_operation (Slice_sub _) -> itself Not_constant
  | Slice_operation ((Slice_from_array _ | Slice_unchecked _) as operation) ->
      itself
        (combined
           (List.map (operand_kind context) (Tree.slice_operands operation)))
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
  | Binary ({ node = Logical_and; _ }, left, right) ->
      logical_constant context span typed ~decisive:false Logical_and left
        right
  | Binary ({ node = Logical_or; _ }, left, right) ->
      logical_constant context span typed ~decisive:true Logical_or left right
  | Binary
      ( { node =
            ( Less_than | Greater_than | Less_or_equal | Greater_or_equal
            | Equal_to | Not_equal_to ) as op;
          _ },
        left,
        right ) ->
      comparison_constant context span op left right
  | Binary ({ node = op; _ }, left, right) ->
      binary_constant context span typed op left right
  | Conditional { condition; if_true; if_false } ->
      let second = Option.value if_true ~default:condition in
      conditional_constant context span typed condition second if_false
  | Comma (left, right) -> comma_constant context span left right
  | Label_address _ -> itself Address_constant
  | Call _ | Statement_expression _ | Va_arg _ | Block_literal _ ->
      itself Backend_constant
  (* An instance is a function with internal linkage (design 7.3). *)
  | Instance _ -> itself (Designator { static_storage = true; named = false })
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
       (Printf.sprintf "the first argument of %s is not %s"
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
  | Pointer_operand
      { referenced = { shape = Distinct distinct; _ } as referenced; _ }
    when is_type_c_text context span ->
      refuse_distinct_object context span name referenced distinct
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
            constant expression")

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
           (quote name ^ " takes at least one argument"))

(* 6.5.2.2p5, or the rule of the builtin that [callee] names. *)
let call context span callee (callee_typed : typed) arguments =
  match builtin_rule context callee with
  | Some (name, rule) -> rule_call context span name rule arguments
  | None ->
      value (call_type context span callee_typed (List.length arguments))

(* A cast to [void] discards its operand, so it takes a variant whole
   (design 3.2 rule 6). This is the one place that decides it. *)
let discards cast_type = Ctype.is_void cast_type = Answer true

(* Whether [element], the element type of a slice, is [const char], so
   that the slice is the one a string literal initialises. *)
let is_const_char (element : Ctype.t) =
  match element.shape with
  | Arithmetic (Integer Char) -> element.qualifiers.const
  | _ -> false

(* What likely makes the value of the [target] slice, if it is one, that
   a cast to it does not. A variant gets no hint: the cast reaches here
   only in C text, which names no constructor. *)
let cast_target_hint context span ~target ~source =
  let same_type =
    compatible context span (Ctype.unqualified target)
      (Ctype.unqualified source)
    = Answer true
  in
  if same_type then "; the value has that type already, so drop the cast"
  else
    match slice_of context target with
    | Some (_, element) when is_const_char element ->
        "; initialise one instead, as in `str s = \"text\";`, or make \
         one of an array with `slice_from_array`"
    | Some _ -> "; make one of an array with `slice_from_array`"
    | None -> ""

(* What likely reaches a scalar in the value of the [source] variant or
   slice that a cast of it does not. *)
let cast_source_hint context source =
  if slice_of context source <> None then
    "; its member `data` points to its elements"
  else if Ctype.as_variant source <> None then
    "; match it to reach what it holds"
  else ""

(* C11 6.5.4p2: a cast converts a scalar value to a scalar type, or any
   value to void. A cast to a type that a variant or an instance is part
   of, other than a pointer, or of such a value to anything but void,
   would make the backend name the C encodings of the types, so typec
   refuses it in any text, a cast to the value's own type included: GNU
   C takes that one as an extension, of which -pedantic warns in the C
   encodings, and nothing is lost by the refusal. *)
let refuse_record_cast context span ~target ~source =
  let refuse text = context.fail span (Rule.c_text (text ^ " (C11 6.5.4p2)")) in
  let neither_scalar_nor_void =
    Ctype.is_scalar target = Answer false && Ctype.is_void target = Answer false
  in
  if neither_scalar_nor_void && mentions_type_c_record target then
    refuse
      (Printf.sprintf
         "a cast converts a value only to a scalar type or to void, and %s \
          is neither%s"
         (quote (Type_name.of_ctype target))
         (cast_target_hint context span ~target ~source))
  else if is_type_c_record source && Ctype.is_void target = Answer false then
    refuse
      (Printf.sprintf
         "a cast converts only a scalar value to a type other than void, \
          and %s is no scalar type%s"
         (quote (Type_name.of_ctype source))
         (cast_source_hint context source))

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
        " (in this instance the type void removes the field(s) %s)"
        (String.concat ", " (List.map quote names))

(* The pattern that matches every value of [constructor], to suggest
   where a case label leaves its field list out. *)
let ignoring_pattern (constructor : Ctype.constructor) =
  let wildcards = List.map (fun _ -> "_") constructor.fields in
  (constructor.constructor_name :> string)
  ^ "(" ^ String.concat ", " wildcards ^ ")"

(* For a scrutinee that is not a variant: the remedy when it points to
   one, since matching never dereferences. *)
let pointer_note (t : Ctype.t) =
  match t.shape with
  | Pointer referenced when Ctype.as_variant referenced <> None ->
      "; a pointer is not dereferenced implicitly"
  | Pointer _ | Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list
  | Array _ | Function _ | Unknown_type _ ->
      ""

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
let target_constructor context position (span : Tree.span) name =
  match position with
  | (Targeted t | Listed t) when is_type_c_text context span ->
      context.needs_complete t;
      Option.bind (Ctype.constructors context.tags t) (fun constructors ->
          named_in t constructors name)
  | Targeted _ | Listed _ | Untargeted | Discarded | Discarded_branch -> None

(* The constructor that the name at the start of [span] denotes, as the
   first reading of the name decided: an instance of a generic function
   reads it as its definition check did, where the target type was
   opaque (7.3 rule 3). The check reads a constructor only at a target
   type that is a variant, whose constructors each instance keeps. *)
let unqualified_constructor context position (span : Tree.span) name =
  let found = target_constructor context position span name in
  let first () =
    match found with
    | Some named ->
        Constructor_word (Type_name.of_variant named.variant_name)
    | None -> Ordinary_word
  in
  match (context.name_reading span.first first, found) with
  | Ordinary_word, _ -> None
  | Constructor_word _, Some named -> Some named
  | Constructor_word _, None ->
      invalid_arg
        "Expressions.unqualified_constructor: a constructor that the \
         instance's target type lacks"

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

(* How a name that the parser finds declared as nothing else stands
   where it may mean a constructor. *)
type stray_form =
  | Alone_or_called  (** [C] or [C(arguments)] *)
  | Called_in_parentheses  (** [(C)(arguments)] *)

(* The undeclared name that [callee] is, in parentheses. *)
let rec parenthesized_name (callee : Tree.expression) =
  match callee.node with
  | Parenthesized { node = Identifier { name; resolution = Undeclared }; _ }
    ->
      Some name
  | Parenthesized inner -> parenthesized_name inner
  | _ -> None

(* The undeclared name that [expression] is, calls, or calls in
   parentheses. An undeclared name may still be a builtin, which a
   constructor never shadows: every builtin is spelled with a reserved
   identifier, which no constructor may be. *)
let stray_name (expression : Tree.expression) =
  match expression.node with
  | Identifier { name; resolution = Undeclared }
  | Call
      { callee = { node = Identifier { name; resolution = Undeclared }; _ };
        _ } ->
      Some (Alone_or_called, name)
  | Call { callee; _ } ->
      Option.map
        (fun name -> (Called_in_parentheses, name))
        (parenthesized_name callee)
  | _ -> None

(* A variant declaration with the constructor of a name. *)
type declared_constructor = {
  variant : Tree.type_declaration;
  constructor : Tree.constructor;
}

let declared_constructor name (variant : Tree.type_declaration) =
  let named (c : Tree.constructor) = (c.node.name.node :> string) = name in
  match variant.node.definition with
  | Variant { constructors; _ } ->
      Option.map
        (fun constructor -> { variant; constructor })
        (List.find_opt named constructors)
  | Incomplete_variant | Alias _ | Distinct _ | Record_alias _ -> None

(* The constructor [name] of the variant declared last of those in scope
   at [span]: the innermost, or the unit's over the universe's, which is
   the one most likely meant. *)
let constructor_in_scope context (span : Tree.span) name =
  List.find_map (declared_constructor name) (context.visible_variants span)

(* A variant as its declaration writes it, as 'err' or 'result(T, E)'. *)
let variant_head (declaration : Tree.type_declaration) =
  let name = (declaration.node.name.node :> string) in
  match declaration.node.type_parameters with
  | [] -> name
  | parameters ->
      let parameter (written : Tree.parameter_name) =
        (written.name.node :> string)
      in
      name ^ "(" ^ String.concat ", " (List.map parameter parameters) ^ ")"

(* The constructor qualified by its variant, with what a generic one
   still needs. *)
let qualified_example found name =
  let qualified = quote (variant_head found.variant ^ "." ^ name) in
  match found.variant.node.type_parameters with
  | [] -> qualified
  | _ :: _ -> qualified ^ " with its type arguments"

(* The constructor as a constructor expression writes it. *)
let called_example found name =
  match found.constructor.node.fields with
  | [] -> quote name
  | _ :: _ -> quote (name ^ "(...)")

(* 6.5.1p2 and design 3.3: a constructor names nothing where no variant
   with it is expected, C text names no constructor at all (design 2.1),
   and a constructor is no function, so its name in parentheses is not
   called. The refusal says which variant has the constructor and what
   the position expects, or how the constructor is written. *)
let stray_constructor_message context span position form found =
  let name = (found.constructor.node.name.node :> string) in
  let quoted = quote name and variant = quote (variant_head found.variant) in
  let unqualified_only =
    Printf.sprintf
      "%s is a constructor of %s, written without its variant only where a \
       variant with it is expected"
      quoted variant
  in
  match (is_type_c_text context span, form, position) with
  | false, _, _ ->
      Rule.c_text
        (Printf.sprintf
           "%s is not declared (C11 6.5.1p2); as a constructor of %s it is \
            written only in a Type-C file, a .tc or .tci"
           quoted variant)
  | true, Called_in_parentheses, _ ->
      constructor_message
        (Printf.sprintf
           "%s is a constructor of %s, not a function, so it is not called \
            in parentheses; write %s"
           quoted variant (called_example found name))
  | true, Alone_or_called, (Targeted t | Listed t) ->
      constructor_message
        (Printf.sprintf "%s; here a value of type %s is expected"
           unqualified_only
           (quote (Type_name.of_ctype t)))
  | true, Alone_or_called, (Untargeted | Discarded | Discarded_branch) ->
      constructor_message
        (Printf.sprintf
           "%s; here none is, so write the variant before it, as %s"
           unqualified_only
           (qualified_example found name))

(* The constructor that a stray name means, if any. A binding used past
   its scope is refused as one, whatever its spelling. *)
let stray_constructor context (expression : Tree.expression) =
  match stray_name expression with
  | Some (_, name) when Option.is_some (binder_of context name) -> None
  | Some (form, name) ->
      Option.map
        (fun found -> (form, found))
        (constructor_in_scope context expression.span name)
  | None -> None

(* Refuses before [expression_node] would type the name as undeclared. *)
let refuse_stray_constructor context position (expression : Tree.expression) =
  match stray_constructor context expression with
  | Some (form, found) ->
      context.fail expression.span
        (stray_constructor_message context expression.span position form
           found)
  | None -> ()

(* Try (design 5.1) *)

(* Rule 3: a try where the statement being typed is no holder, or that
   stands under an operator that the rule does not name. *)
let not_held =
  Not_held
    ( Try_position,
      "try stands outside an expression statement, a declaration of one \
       object, a return, or the condition of an if, switch or match, or in \
       an operand that C does not evaluate as a value, such as that of \
       sizeof; give it a statement or declaration of its own" )

let in_loop_clause =
  Not_held
    ( Try_loop,
      "the condition of a loop and the clauses of a for hold no try, as C \
       evaluates them apart from the statement around them, the condition \
       on each iteration; give the try a statement or declaration of its \
       own before the loop or in its body" )

(* Whether [expression] is a try, in parentheses or not, as an
   initialiser of a braced list that holds one is (design 5.1 rule 3). *)
let is_try expression =
  match (Try_plan.without_parentheses expression).node with
  | Try _ -> true
  | _ -> false

(* The views that the parser took at a hoisted operand, which is moved
   text (design 5.1 rule 3, 13.5). *)
let hoisted_views context (hoisted : Try_plan.hoisted) =
  match Parser.try_views context.views hoisted.replaced.first with
  | Some views -> (views, hoisted.operand)
  | None -> invalid_arg "Expressions: a hoisted operand without views"

(* Rule 3 (try-lifetime): no hoisted operand holds an array that is no
   lvalue, and none that is evaluated under a condition holds a compound
   literal, whose life lowering would end before the source does: with
   the hoisted operand, a full expression of its own, and with the if of
   the prelude (13.5). Rule 5 refuses a member whose type typec does not
   compute. *)
let refuse_short_lived context (hoisted : Try_plan.hoisted list) object_made =
  (* The hoisted operands that hold [span]. *)
  let holding (span : Tree.span) =
    List.filter
      (fun (operand : Try_plan.hoisted) ->
        operand.operand.first <= span.first
        && span.last <= operand.operand.last)
      hoisted
  in
  let conditioned (operand : Try_plan.hoisted) = operand.conditions <> [] in
  let refuse span text = context.fail span (Rule.message Try_lifetime text) in
  match object_made with
  | Literal_object span ->
      if List.exists conditioned (holding span) then
        refuse span
          "a compound literal in an operand that is evaluated with the \
           tries, ahead of the rest of the statement and under a condition, \
           would end its life before the statement ends; give it a \
           declaration before the statement or declaration that holds the \
           try"
  | Temporary_array span ->
      if holding span <> [] then
        refuse span
          "an array member of a value that is no lvalue, in an operand that \
           is evaluated with the tries, ahead of the rest of the statement, \
           would end its life with that operand; give the value a \
           declaration before the statement or declaration that holds the \
           try"
  | Unknown_member (span, unknown) ->
      if holding span <> [] then
        context.fail span
          (needing
             "whether a member of a value that is no lvalue, in an operand \
              that is evaluated with the tries, ahead of the rest of the \
              statement, is an array"
             unknown)

(* Types with [type_expression] the expression of [holder], a statement or
   declaration of rule 3, where statements are holders: the plan of the
   expression places its tries and numbers what its prelude hoists, each
   hoisted operand passes the check of moved text, and the tries typed
   are recorded with the holder for lowering. [stretch_last] is the last
   token of the stretch that holds no pragma line. *)
let holding context ?(declaration = false) (holder : holder) ~stretch_last
    expression
    type_expression =
  let pragma_in_stretch () =
    let first =
      match holder.labels with
      | Some labels -> labels.first
      | None -> holder.statement.first
    in
    let tokens = context.text.tokens in
    let rec pragma_from index =
      index <= stretch_last
      && (is_pragma tokens.(index) || pragma_from (index + 1))
    in
    pragma_from (max 0 (first - 1))
  in
  let view = context.typed in
  let enclosing = view.enclosing in
  match enclosing.try_positions with
  | No_positions _ -> type_expression ()
  | Positions _ ->
      let plan =
        Try_plan.plan
          ~inspects:(fun name ->
            is_builtin_function context name
            && not (Builtin_function.values_decide name))
          ~next_try:view.next_try ~next_truth:view.next_truth expression
      in
      view.next_try <- Try_plan.next_try plan;
      view.next_truth <- Try_plan.next_truth plan;
      let held =
        { holder;
          plan;
          pragma_in_stretch = lazy (pragma_in_stretch ());
          unchecked_object = declaration }
      in
      view.holder_tries <- [];
      view.holder_void_casts <- [];
      view.holder_short_lived <- [];
      let typed = ref None in
      context.hoisted_operands
        (List.map (hoisted_views context) (Try_plan.hoisted plan))
        (fun () ->
          typed :=
            Some
              (within context
                 { enclosing with try_positions = Positions (Held held) }
                 type_expression));
      let typed =
        match !typed with
        | Some typed -> typed
        | None -> invalid_arg "Expressions: a holder left untyped"
      in
      List.iter
        (refuse_short_lived context (Try_plan.hoisted plan))
        (List.rev view.holder_short_lived);
      (match Try_plan.hoisted plan with
      | [] -> ()
      | hoisted ->
          view.holders <-
            { holder;
              hoisted;
              tries = List.rev view.holder_tries;
              void_casts = view.holder_void_casts }
            :: view.holders);
      view.holder_tries <- [];
      view.holder_void_casts <- [];
      view.holder_short_lived <- [];
      typed

(* Types a statement whose expressions refuse every try as [place]. *)
let refusing context place type_statement =
  let enclosing = context.typed.enclosing in
  match enclosing.try_positions with
  | No_positions _ -> type_statement ()
  | Positions _ ->
      within context
        { enclosing with try_positions = Positions place }
        type_statement

let refuse_not_held context span = function
  | Not_held (rule, text) -> context.fail span (Rule.message rule text)
  | Held _ -> invalid_arg "Expressions: a held try refused as not held"

(* Rule 3: the holder of the try at [span] and its place there, which
   its plan gives; a try that the plan does not reach is refused. *)
let placed_try context span =
  match context.typed.enclosing.try_positions with
  | Positions (Held held) -> (
      match Try_plan.place held.plan span with
      | Some (Hoisted hoisted) -> (held, hoisted)
      | Some (Refused (rule, text)) ->
          context.fail span (Rule.message rule text)
      | None -> refuse_not_held context span not_held)
  | Positions (Not_held _ as place) -> refuse_not_held context span place
  | No_positions text -> context.fail span (Rule.message Try_position text)

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

(* A declaration holds a try only once the object that it initialises,
   of type [t], is one that rule 3 allows; its initialiser, which is
   typed after its declarator, sees the object first. *)
let place_declared_try context ~constant t =
  let view = context.typed in
  match view.enclosing.try_positions with
  | Positions (Held ({ unchecked_object = true; _ } as held)) ->
      List.iter
        (fun (hoisted : Try_plan.hoisted) ->
          match hoisted.form with
          | Tried _ -> refuse_try_object context hoisted.replaced ~constant t
          | Truth _ | Discarded_left -> ())
        (Try_plan.hoisted held.plan);
      view.enclosing <-
        { view.enclosing with
          try_positions =
            Positions (Held { held with unchecked_object = false })
        }
  | Positions (Held { unchecked_object = false; _ } | Not_held _)
  | No_positions _ ->
      ()

(* Rule 3: no pragma line stands from directly before the holder of a
   try, its C labels included, to the end of its expression; the token
   before the first is a pragma exactly where one stands directly
   before it. *)
let refuse_try_pragma context span (held : held) =
  if Lazy.force held.pragma_in_stretch then
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
        (Rule.message Try_operand
           (Printf.sprintf "the operand of try is of type %s, not a result type"
              (quote (Type_name.of_ctype operand_type))))

let return_result context span =
  let need = "whether the function that holds try returns a result" in
  let return_type =
    match context.typed.enclosing.return_type with
    | Some (Answer t) -> t
    | Some (Depends_on unknown) -> context.fail span (needing need unknown)
    | None -> invalid_arg "Expressions: a try placed outside a function"
  in
  match try_result context span ~need return_type with
  | Some instance -> instance
  | None ->
      context.fail span
        (Rule.message Try_operand
           (Printf.sprintf
              "try is in a function that returns %s, not a result type"
              (quote (Type_name.of_ctype return_type))))

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
   void, which stands only where its value is discarded; and whether the
   holder reads the field: not where the value is discarded, but in a
   branch of a discarded conditional, whose other branch has a value of
   the same type (13.5). *)
let try_value context span position ok_field =
  match (ok_field, position) with
  | Some (field : Ctype.member), Discarded ->
      (Ctype.unqualified field.member_type, No_value)
  | Some field, (Untargeted | Targeted _ | Listed _ | Discarded_branch) ->
      ( Ctype.unqualified field.member_type,
        Read { field = field_name field; conversion = Unconverted } )
  | None, (Discarded | Discarded_branch) -> (Ctype.void, No_value)
  | None, (Untargeted | Targeted _ | Listed _) ->
      context.fail span
        (Rule.message Try_void
           "this try has no value, as the Ok of its result holds void; use \
            it as a statement or cast it to void")

(* The first of [arguments] take [positions], those past them none. *)
let rec zip_positions positions arguments =
  match (positions, arguments) with
  | position :: positions, _ :: arguments ->
      position :: zip_positions positions arguments
  | [], arguments -> List.map (fun _ -> Untargeted) arguments
  | _ :: _, [] -> []

(* The operands of == and != meet as a pointer and an integer that
   converts to it (6.5.9p2). *)
let equality_operands context (op : Tree.binary_operator) (left, left_typed)
    (right, right_typed) =
  match op with
  | Equal_to | Not_equal_to ->
      operands_meet context
        (left, value_type left_typed)
        (right, value_type right_typed)
  | _ -> ()

(* Whether [expression] is the value of a try or a member of it, through
   parentheses, which the prelude holds in an object of the holder's
   block (13.5). *)
let rec is_try_member (expression : Tree.expression) =
  match (Try_plan.without_parentheses expression).node with
  | Try _ -> true
  | Member { operand; member = _ } -> is_try_member operand
  | _ -> false

(* A member of a value that is no lvalue, of type [t], at [span]. *)
let temporary_member span (t : Ctype.t) =
  match Ctype.is_array t with
  | Answer true -> Some (Temporary_array span)
  | Answer false -> None
  | Depends_on unknown -> Some (Unknown_member (span, unknown))

(* What of [expression] lowering could end the life of early. An array
   that is no lvalue is a member of one, as no other expression of C
   gives an array value. *)
let short_lived (expression : Tree.expression) typed =
  match expression.node with
  | Compound_literal _ -> Some (Literal_object expression.span)
  | Member _ ->
      if typed.category = Lvalue || is_try_member expression then None
      else temporary_member expression.span typed.expression_type
  | _ -> None

(* Records the typing of [expression], and what of it lowering could end
   the life of early where it stands in a holder of try. It stays outside
   the recursive group of [expression]: as a member of it, the recursion
   over deep trees overflowed the stack that test_deep_trees allows. *)
let note_typed context (expression : Tree.expression) typed =
  let view = context.typed in
  if Hashtbl.mem view.types expression.span then
    invalid_arg "Expressions: an expression typed twice";
  Hashtbl.replace view.types expression.span typed;
  Hashtbl.replace view.constants expression.span
    (classify context expression typed);
  match (view.enclosing.try_positions, short_lived expression typed) with
  | Positions (Held _), Some object_made ->
      view.holder_short_lived <- object_made :: view.holder_short_lived
  | (No_positions _ | Positions (Not_held _)), _ | Positions (Held _), None ->
      ()

(* Statements (6.8) and the expressions that hold them *)

(* The value of an expression that an operation reads (design 3.4): the
   plain typing entry, which refuses a value of a distinct type in Type-C
   text, naming the expression by its [role], as "an array length", and
   gives C text the representation. Only the uses that design
   3.4 lets take such a value whole call [whole_value] instead. *)
let rec expression context ~role (expression : Tree.expression) =
  let typed = whole_value context expression in
  read_operand context expression.span ~reads:false ~reader:(Operand role)
    typed

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
    | None ->
        refuse_stray_constructor context position expression;
        expression_node context position expression
  in
  note_typed context expression typed;
  (* The conversion reads the dependence of the value. *)
  record_dependence context expression;
  match position with
  | Targeted target -> assigned context expression ~target typed
  | Listed target -> listed_value context expression ~target typed
  | Untargeted | Discarded | Discarded_branch -> typed

(* 6.5.16.1p2, 6.5.2.2p7: [typed], the value of [expression], converted
   to [target] as if by assignment. Apart from [positioned], which
   recurses through deep trees, so that its frame stays small. *)
and assigned context expression ~target typed =
  let converted = listed_value context expression ~target typed in
  refuse_conversion context expression target converted;
  converted

(* Design 3.4: Type-C text converts no value implicitly to or from a
   distinct type, nor a pointer to one but as [pointers_differ] allows.
   The backend sees a distinct type as its representation (design 10.2), so
   it cannot refuse these conversions. C text sees the representations
   as the backend does, so every rule below decides on the types as
   seen, and in C text no distinct type is left to cross; messages name
   the types as written. The record rule reads the written types, which
   are the seen ones wherever it applies, as no distinct type is a record
   (design 3.4), so its message names the types as written too. What is
   left is C's own rule, which [refuse_unassignable] applies. *)
and refuse_conversion ?(receiver = Assigned) context
    (converted : Tree.expression) target (typed : typed) =
  let span = converted.span in
  let target = Ctype.unqualified target in
  let source = value_type typed in
  let seen_target = type_as_seen context span target in
  let seen_source = type_as_seen context span source in
  let named () =
    match Deduction.slice_meets (Deduction.start []) ~slice:target with
    | Some is_target ->
        slicing_fix context converted typed ~takes:(fun element ->
            is_target element || is_const_slice_of context span ~target element)
    | None -> None
  in
  let refused () =
    match named () with
    | Some refused -> refused
    | None ->
        value_of_type source (conversion_hint context converted ~source ~target)
  in
  refuse_record_conversion context span ~receiver ~target ~source ~refused;
  let crosses =
    match (seen_target.shape, seen_source.shape) with
    | Pointer t, Pointer s -> (
        match pointers_differ context span t s with
        | Some (Parameter_gap use) -> refuse_type_parameter context span use
        | Some Distinct_gap -> true
        | Some Record_gap | None -> false)
    | (Record _ | Array _), _ -> false
    | _ ->
        (Ctype.as_distinct seen_target <> None
        || Ctype.as_distinct seen_source <> None)
        && differs context span seen_target seen_source
  in
  if crosses then
    context.fail span
      (Rule.message Distinct_conversion
         (Printf.sprintf
            "a value of type %s does not convert to %s without a cast"
            (quote (Type_name.of_ctype source))
            (quote (Type_name.of_ctype target))));
  refuse_dependent_null context span ~target:seen_target seen_source;
  refuse_type_parameter_conversion context span ~target:seen_target
    ~source:seen_source;
  refuse_unassignable context converted ~receiver ~target ~source
    ~seen_target ~seen_source

(* Design 5: C11 6.5.16.1p1 in full, in Type-C text and wherever a
   variant or an instance is part of either type. GNU C only warns of
   much that C refuses, as a pointer to a type that differs in signedness
   or that drops a qualifier, and its messages spell a type that an
   instance writes through a type argument by its encoding; C text that a
   unit includes keeps the rules that the backend applies to it. *)
and refuse_unassignable context (converted : Tree.expression) ~receiver ~target
    ~source ~seen_target ~seen_source =
  let checked =
    is_type_c_text context converted.span
    || mentions_type_c_record seen_target
    || mentions_type_c_record seen_source
  in
  let converts () =
    assignable context converted ~target:seen_target ~source:seen_source
  in
  if checked && not (converts ()) then
    refuse_assignment context converted.span ~receiver ~target ~source
      (value_of_type source (conversion_hint context converted ~source ~target))

(* Whether the value of [converted], of type [source], converts to
   [target] as by assignment (C11 6.5.16.1p1). Whether it is a null
   pointer constant is asked only where a pointer takes an integer, as
   asking refuses one that depends on a type parameter. *)
and assignable context (converted : Tree.expression) ~(target : Ctype.t)
    ~(source : Ctype.t) =
  let span = converted.span in
  match (target.shape, source.shape) with
  | Unknown_type _, _ | _, Unknown_type _ -> true
  | (Arithmetic _ | Enum _), (Arithmetic _ | Enum _) -> true
  | Arithmetic (Integer Bool), Pointer _ -> true
  | Pointer referenced, Pointer source_referenced ->
      pointer_assignable context span ~target:referenced
        ~source:source_referenced
  | Pointer _, _ ->
      Ctype.is_integer source = Answer true
      && null_pointer_constant context converted <> Not_null
  | ( ( Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list
      | Array _ | Function _ ),
      _ ) ->
      compatible context span target (Ctype.unqualified source) <> Answer false

(* The step that likely gives what was meant where [converted], a value
   of type [source], does not convert to [target]: making the variant
   [target] of it, reaching what the variant [source] holds, or a cast
   between two scalars. *)
and conversion_hint context converted ~(source : Ctype.t) ~(target : Ctype.t)
    =
  match (Ctype.as_variant target, Ctype.as_variant source) with
  | Some _, None -> making_hint context converted ~source ~target
  | None, Some _ -> opening_hint context converted ~source ~target
  | Some _, Some _ -> ""
  | None, None -> ""

(* The step that likely makes the variant [target] where [converted], of
   type [source], is written: reading the variant that it points to, the
   one constructor without fields for a null pointer, or a constructor
   whose one field takes it. *)
and making_hint context (converted : Tree.expression) ~source ~target =
  let constructors = hinted_constructors context target in
  let name (c : Ctype.constructor) = (c.constructor_name :> string) in
  if points_to context converted.span ~pointer:source target then
    Printf.sprintf "; write %s for the value it points to"
      (quote (scrutinee_text context (Pointed_to converted)))
  else
    match
      ( is_null_pointer context converted source,
        List.filter (Fun.negate has_fields) constructors,
        holding_constructor context converted ~source ~target constructors )
    with
    | true, [ empty ], _ ->
        Printf.sprintf "; write %s for no value" (quote (name empty))
    | _, _, Some holder ->
        Printf.sprintf "; make one with %s"
          (quote (name holder ^ "(" ^ excerpt context converted.span ^ ")"))
    | _, _, None ->
        "; make one with a constructor of " ^ quote (Type_name.of_ctype target)

(* The constructors of the variant [t] that a hint names; an instance
   named only in a prototype is completed first, as a constructor
   written there would complete it. *)
and hinted_constructors context t =
  context.needs_complete t;
  Option.value (Ctype.constructors context.tags t) ~default:[]

(* Whether [pointer] points to a type compatible with [target]. *)
and points_to context span ~(pointer : Ctype.t) target =
  match (Ctype.unqualified pointer).shape with
  | Pointer referenced ->
      compatible context span (Ctype.unqualified referenced) target
      = Answer true
  | Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      false

(* Whether [converted], of type [source], is a null pointer constant of
   pointer type, which says "no value", as an integer 0 need not. *)
and is_null_pointer context converted (source : Ctype.t) =
  is_plain_void_pointer (Ctype.unqualified source)
  && null_pointer_constant context converted = Null

(* The constructor of the variant [target] whose one field a value of
   type [source] converts to: the one whose field is of that very type,
   or else the only one that takes it, or else a result's Ok, which
   holds the value that try reads. *)
and holding_constructor context converted ~source ~target constructors =
  let field_type (c : Ctype.constructor) =
    match c.fields with
    | [ field ] -> Some (Ctype.unqualified field.member_type)
    | _ -> None
  in
  let takes c =
    match field_type c with
    | Some field -> assignable context converted ~target:field ~source
    | None -> false
  in
  let same c =
    match field_type c with
    | Some field ->
        compatible context converted.span field (Ctype.unqualified source)
        = Answer true
    | None -> false
  in
  let takers = List.filter takes constructors in
  match (List.filter same takers, takers) with
  | [ chosen ], _ | [], [ chosen ] -> Some chosen
  | _ when Ctype.as_result target <> None ->
      List.find_opt (is_named Ctype.result_ok) takers
  | _ -> None

(* The step that likely reaches what the variant [source] holds: try,
   where it is a result whose Ok holds a value that converts to
   [target], or else matching. *)
and opening_hint context converted ~source ~target =
  let ok_converts (c : Ctype.constructor) =
    match c.fields with
    | [ field ] ->
        is_named Ctype.result_ok c
        && assignable context converted ~target
             ~source:(Ctype.unqualified field.member_type)
    | _ -> false
  in
  let constructors = hinted_constructors context source in
  if Ctype.as_result source <> None && List.exists ok_converts constructors
  then "; take its value with try, or match it"
  else "; match it to reach what it holds"

(* [typed], the value of [expression] in a braced initialiser, made a
   slice where [target] is one (design section 8 rule 5); the
   initialiser checks the conversion where it places the value. *)
and listed_value context expression ~target typed =
  context.needs_complete typed.expression_type;
  convert_slice context expression ~target typed

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
  let operation = operation_of context whole in
  let typed ?(reader = operation) operand =
    let operand_typed = whole_value context operand in
    (* An operator's operand is what a test replaces; an operand of
       another role, as an index or a called function, is not. *)
    let test =
      match reader with
      | Operator _ ->
          Some { scrutinee = Written operand; sought = sought_of whole }
      | Operand _ | Unnamed_operation -> None
    in
    refuse_variant ?test context span reader operand_typed.expression_type;
    read_operand context span ~reads:(reads_distinct whole.node) ~reader
      operand_typed
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
      compound_literal context whole type_name values
  | Subscript { operand; index } -> (
      let array = typed operand in
      let index_typed = typed ~reader:(Operand "an index") index in
      match slice_of context array.expression_type with
      | Some (instance, element) ->
          slice_index context span ~instance ~slice:operand.span ~index
            element index_typed
      | None -> subscript context span array index_typed)
  | Slice_operation (Slice_sub { slice; low; high }) ->
      let sliced = typed slice in
      let low_typed = typed low in
      let high_typed = typed high in
      slice_sub context span ~slice sliced (low, low_typed) (high, high_typed)
  | Slice_operation (Slice_from_array operand) ->
      let array =
        context.array_operand ~whole:span operand.span (fun () -> typed operand)
      in
      slice_from_array context span operand array
  | Slice_operation (Slice_unchecked { pointer; count }) ->
      let pointer_typed = typed pointer in
      refuse_slice_index context count.span
        ~what:"the count of `slice_unchecked`" (typed count);
      slice_unchecked context span pointer pointer_typed count
  | Qualified_constructor _ ->
      invalid_arg "Expressions: a constructor that is no constructor expression"
  | Call { callee; arguments } when generic_callee context callee <> None ->
      generic_call context span (Option.get (generic_callee context callee))
        arguments
  | Instance { generic; type_arguments } ->
      explicit_instance context span generic type_arguments
  | Call { callee; arguments } ->
      refuse_parenthesized_constructor context callee;
      let callee_typed = typed callee in
      let arguments = call_arguments context callee callee_typed arguments in
      call context span callee callee_typed arguments
  | Member { operand; member } ->
      direct_member context span (typed operand) member
  | Pointer_member { operand; member } ->
      pointer_member context span ~pointer:operand (typed operand) member
  (* The value of a postfix operation is no bit-field in Clang. *)
  | Post_increment operand | Post_decrement operand ->
      increment context span ~clause:"6.5.2.4p1" (typed operand)
  | Unary ((Address as op), operand) ->
      let whole = as_whole operand in
      refuse_instance_name context operand;
      unary context span op whole
  | Unary (op, operand) -> unary context span op (typed operand)
  | Sizeof_expression operand ->
      let whole = as_whole operand in
      refuse_instance_name context operand;
      if designates_bit_field whole then
        context.fail span (Rule.c_text "sizeof of a bit-field (C11 6.5.3.4p1)");
      context.needs_complete whole.expression_type;
      judge_by_type context.typed operand.span whole.expression_type;
      value (size_type context span)
  | Sizeof_type type_name ->
      context.needs_complete (context.type_name type_name);
      value (size_type context span)
  | Alignof type_name ->
      context.needs_complete (context.type_name type_name);
      leave_untested context.typed type_name.span;
      value (size_type context span)
  | Alignof_expression operand ->
      context.needs_complete (as_whole operand).expression_type;
      leave_untested context.typed operand.span;
      refuse_instance_name context operand;
      value (size_type context span)
  | Cast { type_name; operand } ->
      let cast_type = context.type_name type_name in
      refuse_variant context span (Operand "the target of a cast") cast_type;
      if Ctype.is_opaque cast_type then
        refuse_type_parameter context span "a cast to a type parameter";
      Option.iter
        (fun distinct ->
          refuse_private_creation context span cast_type
            ~described:("the distinct type " ^ distinct_name distinct))
        (Ctype.as_distinct cast_type);
      let cast_operand =
        if discards cast_type then void_cast_operand context operand
        else typed operand
      in
      context.needs_complete cast_operand.expression_type;
      refuse_record_cast context span ~target:cast_type
        ~source:cast_operand.expression_type;
      value (call_or_cast_type context span cast_type)
  | Binary ({ node = op; _ }, left, right) ->
      let left_typed = typed left in
      let right_typed = typed right in
      equality_operands context op (left, left_typed) (right, right_typed);
      value (binary_type context span op left_typed right_typed)
  | Conditional { condition; if_true; if_false } ->
      value (conditional context span position condition if_true if_false)
  | Assignment ({ node = Assign as op; _ }, left, right) ->
      let left_typed = as_whole left in
      let right_position = Targeted left_typed.expression_type in
      assignment context span op left_typed
        (positioned context right_position right)
  | Assignment ({ node = Compound_assign _ as op; _ }, left, right) ->
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
  | Try { operand } -> try_expression context position whole operand

(* 6.3.2.2p1: the operand of a cast to void, whose value is discarded;
   a try there may be of type void (design 5.1 rule 2), as where its
   value is discarded otherwise. Any other operand is taken whole, since
   the cast discards it on purpose (design 5.2). *)
and void_cast_operand context (operand : Tree.expression) =
  match (Try_plan.without_parentheses operand).node with
  | Try _ -> positioned context Discarded operand
  | _ -> whole_value context operand

(* Design 5.1: a try in the place that the plan of its holder gives it
   (rule 3). Its operand, which has no target type (3.3), is a result
   whose error type is the one that the function returns (rule 1); the
   try has the value of its Ok, which is no lvalue (rule 2). *)
and try_expression context position (whole : Tree.expression) operand =
  let span = whole.span in
  let held, hoisted = placed_try context span in
  refuse_try_pragma context span held;
  let operand_type = (whole_value context operand).expression_type in
  let operand_instance = operand_result context operand.span operand_type in
  let return_instance = return_result context span in
  if error_encoding operand_instance <> error_encoding return_instance then
    context.fail operand.span
      (Rule.message Try_error_type
         "the error type of the operand of try is not the one that the \
          function returns; no error type converts to another");
  context.needs_complete operand_type;
  let ok_field = result_field context operand_type Ctype.result_ok in
  let value_type, read = try_value context span position ok_field in
  let temporary =
    match hoisted.form with
    | Tried { number } -> number
    | Truth _ | Discarded_left -> invalid_arg "Expressions: a try not tried"
  in
  let view = context.typed in
  let site =
    { try_span = span;
      operand = operand.span;
      temporary;
      operand_instance;
      return_instance;
      err_field =
        Option.map field_name
          (result_field context operand_type Ctype.result_err);
      value = read }
  in
  view.holder_tries <- site :: view.holder_tries;
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
         braced = None });
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
   compatible (6.5.16.1p1), in C text too, where the other conversions
   are the backend's (design 5). *)
and constructor_argument context named (field : Ctype.member) argument =
  let field_type = field.member_type in
  let typed = positioned context (Listed field_type) argument in
  let receiver =
    Field_argument
      {
        field = Option.value field.member_name ~default:"";
        constructor = (named.chosen.constructor_name :> string);
      }
  in
  refuse_conversion ~receiver context argument field_type typed;
  let argument_type = value_type typed in
  initialises_whole context field_type argument;
  let is_record t = Ctype.is_record t = Answer true in
  if is_record field_type || is_record argument_type then
    match compatible context argument.span field_type argument_type with
    | Answer true | Depends_on _ -> ()
    | Answer false ->
        refuse_assignment context argument.span ~receiver ~target:field_type
          ~source:argument_type
          (value_of_type argument_type "")

(* The arguments of a call of a builtin that moves a value of the object
   that its first argument points to have the target types that the
   builtin states by that object; those of any other call have them by
   its prototype. The first argument of such a builtin is typed before
   the rest, whose target types it gives. *)
and call_arguments context callee (callee_typed : typed) arguments =
  match (builtin_rule context callee, arguments) with
  | Some (name, Moves_object { operands; _ }), first :: rest ->
      let first_typed =
        expression context ~role:("the first argument of " ^ quote name) first
      in
      let positions =
        moved_positions context first.span operands first_typed rest
      in
      first_typed :: List.map2 (argument context) positions rest
  | _ ->
      let positions = prototype_positions context callee_typed arguments in
      List.map2 (argument context) positions arguments

(* The generic function that the called expression names, through any
   parentheses (design 7.2): the identifier, its name, its declaration
   and its type parameters. *)
and generic_callee context (callee : Tree.expression) =
  match callee.node with
  | Parenthesized inner -> generic_callee context inner
  | Identifier { name; resolution = Resolved reference } ->
      Option.map
        (fun parameters -> (callee, name, reference, parameters))
        (context.generic_function reference)
  | _ -> None

(* The type that the declaration of a generic function gives it. *)
and generic_type context span name reference =
  match (context.entity span name reference).declared with
  | Function { function_type; _ } -> function_type
  | Object _ | Enumerator _ | Typedef _ ->
      invalid_arg "Expressions: a generic function that is no function"

and substituted context span bindings t =
  match
    Deduction.substitute context.tags ~apply:(context.apply_generic span)
      ~complete:context.needs_complete bindings t
  with
  | Ok t -> t
  | Error failure -> fail_deduction context span failure

and fail_deduction : 'a. context -> Tree.span -> Deduction.failure -> 'a =
 fun context span failure ->
  let shown t = quote (Type_name.of_ctype t) in
  let refuse text = context.fail span (Rule.message Deduction_mismatch text) in
  match failure with
  | Mismatch { parameter_part; argument_part } ->
      refuse
        (Printf.sprintf
           "the argument's type does not match its parameter's: it has %s \
            where the parameter type has %s"
           (shown argument_part) (shown parameter_part))
  | Twice { first; second } ->
      refuse
        (Printf.sprintf
           "a type parameter that the parameter type holds twice meets %s \
            and %s"
           (shown first) (shown second))
  | Unknown_part unknown ->
      refuse
        (Printf.sprintf
           "whether the argument's type matches its parameter's depends \
            on %s, whose type typec does not compute"
           unknown.construct)
  | Not_built error -> checked context span (Error error)

(* Design 7.2 rule 1: the arguments are typed from left to right, and
   each either converts to its parameter's type, where the arguments
   before it deduce every type parameter in that type, or deduces them.
   The instance is used once every type parameter is deduced. *)
and generic_call context span (callee, name, reference, parameters)
    arguments =
  let function_type = generic_type context callee.Tree.span name reference in
  match function_type.shape with
  | Function { parameters = Prototype { types; _ } as prototype; _ } ->
      check_arity context span prototype (List.length arguments);
      let bindings =
        deduced_arguments context (Deduction.start parameters) types
          arguments
      in
      let callee_typed =
        instance_designator context span ~written:callee.span reference
          bindings function_type
      in
      note_typed context callee callee_typed;
      value (call_type context span callee_typed (List.length arguments))
  | Unknown_type unknown ->
      List.iter
        (fun each -> ignore (argument context Untargeted each))
        arguments;
      value (unknown_value unknown)
  | _ -> invalid_arg "Expressions: a generic function without a prototype"

(* Types each argument and gives what the arguments deduce. Those past
   the parameters, which an ellipsis takes, have no target type. *)
and deduced_arguments context bindings parameter_types arguments =
  match (parameter_types, arguments) with
  | _, [] -> bindings
  | [], rest ->
      List.iter (fun extra -> ignore (argument context Untargeted extra)) rest;
      bindings
  | parameter :: parameters, first :: rest ->
      let bindings =
        if Deduction.is_deduced_in bindings parameter then begin
          let target = substituted context first.span bindings parameter in
          ignore (argument context (Targeted target) first);
          bindings
        end
        else deducing_argument context bindings parameter first
      in
      deduced_arguments context bindings parameters rest

(* An argument typed on its own, whose type deduces the type parameters
   in its parameter's type; it then converts to that type as any
   argument does. *)
and deducing_argument context bindings parameter (first : Tree.expression) =
  let typed = whole_value context first in
  let argument_type = Ctype.unqualified (value_type typed) in
  let deduced =
    match Deduction.deduce bindings ~parameter ~argument:argument_type with
    | Ok deduced -> deduced
    | Error (Mismatch _ as failure) -> (
        let fix =
          match Deduction.slice_meets bindings ~slice:parameter with
          | Some takes -> slicing_fix context first typed ~takes
          | None -> None
        in
        match fix with
        | Some refused ->
            refuse_slice_deduction context first ~parameter refused
        | None -> fail_deduction context first.span failure)
    | Error failure -> fail_deduction context first.span failure
  in
  List.iter
    (fun t -> context.type_argument first.span (Deduced t))
    (Deduction.newly_deduced ~before:bindings ~after:deduced);
  let target = substituted context first.span deduced parameter in
  context.needs_complete typed.expression_type;
  refuse_conversion context first target typed;
  deduced

(* Design 7.2 rule 2: the [refused] argument [argument], which a slice
   that a builtin makes of it would match, does not match [parameter]. *)
and refuse_slice_deduction context (argument : Tree.expression) ~parameter
    { subject; hint } =
  context.fail argument.span
    (Rule.message Deduction_mismatch
       (Printf.sprintf "%s does not match the parameter type %s%s" subject
          (quote (Type_name.of_ctype parameter))
          hint))

(* The function designator of the instance whose type arguments
   [bindings] holds, used at [span], once every one is deduced (rule
   3). *)
and instance_designator context span ~written reference bindings function_type
    =
  match Deduction.arguments bindings with
  | Error (record : Ctype.record_tag) ->
      let parameter =
        match record.record_name with
        | Opaque_name name -> quote name
        | _ -> invalid_arg "Expressions: a type parameter that is no opaque"
      in
      context.fail span
        (Rule.message Undeduced_type_parameter
           (Printf.sprintf
              "no argument deduces the type parameter %s of %s; give it \
               its type arguments in an explicit instance"
              parameter
              (quote (excerpt context written))))
  | Ok type_arguments ->
      context.use_instance span ~written reference type_arguments;
      let instance_type = substituted context span bindings function_type in
      value
        (function_designator context span ~old_style_definition:false
           instance_type)

(* Design 7.2 rule 4: [f(T1, ..., Tn)] is a function designator of the
   instance. *)
and explicit_instance context span (generic : Tree.expression) type_arguments
    =
  let name, reference =
    match generic.node with
    | Identifier { name; resolution = Resolved reference } -> (name, reference)
    | _ -> invalid_arg "Expressions: an instance of no generic function"
  in
  let parameters = Option.get (context.generic_function reference) in
  if List.compare_lengths parameters type_arguments <> 0 then
    context.fail span
      (Rule.message Instance_arguments
         (Printf.sprintf
            "the number of type arguments, %d, differs from the number of \
             type parameters of the generic function %s, %d"
            (List.length type_arguments) (quote name)
            (List.length parameters)));
  let read (written : Tree.type_name) =
    let t = context.type_name written in
    context.type_argument written.span (Written (written, t));
    t
  in
  let bindings =
    Deduction.explicit parameters (List.map read type_arguments)
  in
  let function_type = generic_type context generic.span name reference in
  let designator =
    instance_designator context span ~written:span reference bindings
      function_type
  in
  note_typed context generic designator;
  designator

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
  | Targeted _ | Listed _ -> positioned context position argument
  | Untargeted | Discarded | Discarded_branch ->
      let typed = whole_value context argument in
      if Ctype.is_opaque typed.expression_type then
        refuse_type_parameter context argument.span
          "a value of a type parameter is an argument that no parameter \
           type receives, which the default argument promotions or a \
           builtin read by its type";
      read_operand context argument.span ~reads:false
        ~reader:(Operand "an argument without a parameter type")
        typed

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
  leave_untested context.typed controlling.span;
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
  let selection =
    select context span controlling_type associations_typed default
  in
  record_answer context span types
    ~lowered:(fun result -> Selected { controlling; associations; result })
    selection;
  selection

and choose context span condition first second =
  ignore
    (expression context ~role:"the condition of __builtin_choose_expr"
       condition);
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
and compound_literal context (whole : Tree.expression) type_name values =
  let t = context.type_name type_name in
  let constant = context.typed.enclosing.function_name = None in
  lvalue
    (initialiser context ~holder:(Holder_at whole.span.first) ~constant t
       (Tree.Braced values))

(* 6.5.15p3 to p6. A GNU [a ?: b] has [a] as its second operand. *)
and conditional context span position condition if_true if_false =
  let condition_typed = whole_value context condition in
  require_condition context ~clause:"6.5.15p2" condition condition_typed;
  let branch_typed = positioned context (branch_position position) in
  let second =
    match if_true with
    | Some branch -> { branch; branch_typed = branch_typed branch }
    | None -> { branch = condition; branch_typed = condition_typed }
  in
  let third = { branch = if_false; branch_typed = branch_typed if_false } in
  let second, third = meet_slices context second third in
  operands_meet context
    (second.branch, value_type second.branch_typed)
    (third.branch, value_type third.branch_typed);
  let result = conditional_type context span position second third in
  discard_branches context position
    ~need:
      "the type of a discarded conditional with a branch of a result type"
    (Ctype.is_void result) [ second; third ];
  result

(* Design section 8 rule 5: of a slice of non-const elements and the
   slice of those elements made const, the first converts to the second;
   any other pair of branches stays as it is. *)
and meet_slices context second third =
  let towards branch other =
    let target = value_type other.branch_typed in
    let converted =
      convert_slice context branch.branch ~target branch.branch_typed
    in
    { branch with branch_typed = converted }
  in
  (towards second third, towards third second)

(* 6.5.15p3 to p6: the type of a conditional of these branches, which
   stands in [position]. *)
and conditional_type context span position second third =
  refuse_type_parameter_branch context span second.branch_typed;
  refuse_type_parameter_branch context span third.branch_typed;
  let branch_operand branch =
    context.needs_complete branch.branch_typed.expression_type;
    operand context (as_seen context span branch.branch_typed)
  in
  let second_operand = branch_operand second
  and third_operand = branch_operand third in
  refuse_mixed_pointers context span ~clause:"6.5.15p3" second_operand
    third_operand;
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
      refuse_unconverted_branch context position [ second; third ];
      fail_operands context span "6.5.15p3"

(* Branches that have no type in common: where the conditional has a
   target type, one that does not convert to it is the likely mistake,
   as in 'c ? Some(1) : 0', so its conversion is refused first. *)
and refuse_unconverted_branch context position branches =
  match position with
  | Targeted target | Listed target ->
      List.iter
        (fun { branch; branch_typed } ->
          refuse_conversion context branch target branch_typed)
        branches
  | Untargeted | Discarded | Discarded_branch -> ()

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
   type is one is unknown too, and whether one that depends on a type
   parameter is one differs between arguments (design 7.1 rule 4). *)
and zero_constant context candidate =
  let typed = operand_typed context candidate in
  let is_integer = Ctype.is_integer typed.expression_type in
  if is_integer = Answer true then refuse_dependent context candidate;
  match (is_integer, operand_constant context candidate) with
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
  let enclosing = context.typed.enclosing in
  let enclosing =
    { enclosing with
      try_positions =
        without_holders enclosing.try_positions try_in_statement_expression }
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
   that it has typed, do otherwise. The value is cast to void where its
   tries may leave it with no effect (design 13.5). *)
and discard context value =
  let typed = statement_operand context Discarded value in
  refuse_dropped_result context value typed;
  if needs_void_cast context.typed value typed then
    context.typed.holder_void_casts <-
      value.span :: context.typed.holder_void_casts

(* 7.19p3: each step of the member path of [offsetof] reaches into the
   type that the steps before it reach, which may not be a variant (design
   3.2 rule 6); the path may end at one. *)
and offsetof_path context span (reached : Ctype.t) path =
  match path with
  | [] -> ()
  | step :: rest ->
      refuse_variant context span (offsetof_operation step) reached;
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
  let designator_role = "an index of a designator" in
  match designator.node with
  | Index index -> ignore (expression context ~role:designator_role index)
  | Index_range { low; high } ->
      ignore (expression context ~role:designator_role low);
      ignore (expression context ~role:designator_role high)
  | Member_designator _ -> ()

and integer_constant context ~role candidate =
  ignore (expression context ~role candidate);
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

(* Design 13.5: a constructor, or a slice made from an array, a pointer
   or a string literal, that initialises a whole object of its type,
   with no brace elided before it, lowers to its braced list alone,
   which keeps a static initialiser constant. The list replaces the
   parentheses around it too: in them it would be a statement expression
   of GNU C. An atomic object takes no braced list in Clang, so it keeps
   the compound literal. *)
and initialises_whole context t (initialising : Tree.expression) =
  let rec made (expression : Tree.expression) =
    match expression.node with
    | Parenthesized inner -> made inner
    | _ -> expression
  in
  let inner = made initialising in
  let replacing = initialising.span in
  let object_type = Ctype.without_top_qualifiers t in
  let sites = context.typed.sites and makings = context.typed.slice_makings in
  match
    (Sites.construction sites inner.span, Hashtbl.find_opt makings inner.span)
  with
  | Some construction, _ ->
      let made_type = (operand_typed context inner).expression_type in
      if compatible context replacing object_type made_type = Answer true then
        Sites.brace sites construction ~replacing
  | None, Some making ->
      if is_instance_type object_type making.instance then
        Hashtbl.replace makings inner.span
          { making with braced = Some replacing }
  | None, None -> ()

(* Whether [t] is the type of the slice instance [instance], which a
   slice that converts takes in place of its own (section 8 rule 5). *)
and is_instance_type (t : Ctype.t) instance =
  match t.shape with
  | Record { record_name = Instance_name own; _ } ->
      Encoding.instance_name own = Encoding.instance_name instance
  | _ -> false

(* Design section 8 rules 5 and 6: whether [target] is the slice of
   [element] made const, which a slice of [element] or a string literal
   of such elements converts to. *)
and is_const_slice_of context span ~target (element : Ctype.t) =
  let const = { Qualifiers.none with const = true } in
  match slice_of context (Ctype.without_top_qualifiers target) with
  | Some (_, target_element) when not element.qualifiers.const -> (
      match Ctype.qualify const element with
      | Ok const_element ->
          compatible context span target_element const_element = Answer true
      | Error _ -> false)
  | Some _ | None -> false

(* Design section 8 rules 5 and 6: [typed], the value of [expression],
   converted to [target] where it converts. A string literal of plain or
   UTF-8 characters, a [slice_from_array] and a [slice_unchecked] are
   made as slices of [target]; any other slice converts through a
   temporary, as a test does (13.5). *)
and convert_slice context (expression : Tree.expression) ~target typed =
  let span = expression.span in
  let converted = value (Ctype.unqualified target) in
  (* The instance converted to, once [target] is known to be a slice. *)
  let target_instance () =
    made_instance (Ctype.without_top_qualifiers target)
  in
  let makings = context.typed.slice_makings in
  let source = typed.expression_type in
  let source_slice = slice_of context (value_type typed) in
  match (expression.node, source.shape, source_slice) with
  | String literal, Array { element; _ }, _
    when is_char_literal context literal
         && is_const_slice_of context span ~target element ->
      Hashtbl.replace makings span
        { span; instance = target_instance ();
          making = From_string { literal = span }; braced = None };
      converted
  | _, _, Some (instance, element)
    when is_const_slice_of context span ~target element ->
      (match Hashtbl.find_opt makings span with
      | Some making ->
          Hashtbl.replace makings span
            { making with instance = target_instance () }
      | None ->
          let converted_to = Encoding.instance_name (target_instance ()) in
          convert_value context expression ~instance ~converted_to);
      converted
  | _ -> typed

(* The conversion of a slice that no making holds. Lowering moves the
   operand of a try in front of its statement, so a try's site converts
   the read of its value, where lowering writes it; any other value
   converts through a temporary (13.5). *)
and convert_value context (expression : Tree.expression) ~instance
    ~converted_to =
  match expression.node with
  | Try _ -> convert_try context expression.span (To_slice converted_to)
  | _ ->
      record_check context
        { whole = expression.span; instance;
          check = Conversion { converted_to }; late_call = false }

(* The value of [converted], of [typed], refused where a slice is
   expected, named as written, with the builtin of section 8 that makes
   the slice where [takes] holds of the slice's element type. A string
   literal written in place is a slice only as rule 6 says; one that a
   selection gives has no fix, as [array_slicing] refuses it. *)
and slicing_fix context (converted : Tree.expression) (typed : typed)
    ~takes =
  let written = excerpt context converted.span in
  let as_written what hint =
    Some { subject = what ^ " " ^ quote written; hint }
  in
  let call builtin arguments =
    quote (Printf.sprintf "%s(%s)" builtin arguments)
  in
  let unchecked = call "slice_unchecked" (written ^ ", n") in
  match (Try_plan.without_parentheses converted).node with
  | String literal ->
      as_written "the string literal"
        ("; " ^ string_literal_slice_fix context literal)
  | _ -> (
      match typed.expression_type.shape with
      | Array { element; length } when takes element -> (
          match array_slicing context converted typed length with
          | Sliceable ->
              as_written "the array"
                ("; slice it with " ^ call "slice_from_array" written)
          | Needs_count _ ->
              as_written "the array"
                ("; slice its first n elements with " ^ unchecked)
          | Unsliceable _ -> None)
      | Array _ -> None
      | _ -> (
          match (value_type typed).shape with
          | Pointer element when takes element ->
              as_written "the pointer"
                ("; slice the n elements it points to with " ^ unchecked)
          | _ -> None))

(* The try at [span] converts the value that its holder reads. *)
and convert_try context span conversion =
  let view = context.typed in
  let converting (site : try_site) =
    match site.value with
    | Read { field; conversion = _ } when site.try_span = span ->
        { site with value = Read { field; conversion } }
    | Read _ | No_value -> site
  in
  view.holder_tries <- List.map converting view.holder_tries

(* Design 5.1 rule 3: a try that initialises an object in a braced list
   has its value converted to the object's arithmetic type in the
   prelude, where the two arithmetic types differ; rule 5 refuses one
   where typec does not know either type. *)
and convert_listed_try context (initialising : Tree.expression) object_type =
  let tried = Try_plan.without_parentheses initialising in
  let value_type = (operand_typed context initialising).expression_type in
  let need = "the type that a braced list converts the value of try to" in
  match
    ( Ctype.as_arithmetic context.tags value_type,
      Ctype.as_arithmetic context.tags object_type )
  with
  | Answer None, _ | Answer (Some _), Answer None -> ()
  | Depends_on unknown, _ | Answer (Some _), Depends_on unknown ->
      context.fail tried.span (needing need unknown)
  | Answer (Some value), Answer (Some into) ->
      if value <> into then convert_try context tried.span (To_arithmetic into)

(* Rule 5: the walk of a list gives no object to an initialiser past a
   position that depends on a length or an index that typec does not
   compute (P16), nor one whose type typec does not compute, so a try
   there of an arithmetic type has no type to convert its value to. *)
and refuse_unplaced_try context (initialising : Tree.expression) =
  let value_type = (operand_typed context initialising).expression_type in
  match Ctype.as_arithmetic context.tags value_type with
  | Answer None -> ()
  | Answer (Some _) | Depends_on _ ->
      context.fail initialising.span
        (Rule.message Profile
           "the type of the object that try initialises in a braced list, \
            which its value converts to, depends on a position or a type \
            that typec does not compute; give the try a declaration of its \
            own")

and initialiser context ~holder ~constant t initialiser =
  (* [value] types an expression, which classes it too; the other
     callbacks take one that it has typed, or type none. *)
  let value subobject initialising =
    let position =
      match subobject with
      | Some subobject_type -> Listed subobject_type
      | None -> Untargeted
    in
    (positioned context position initialising).expression_type
  in
  let whole t initialising =
    (positioned context (Targeted t) initialising).expression_type
  in
  (* The tries of the list that [converts] gave an object, by span. *)
  let placed_tries = Hashtbl.create 4 in
  let converts scalar initialising =
    refuse_conversion context initialising scalar
      (operand_typed context initialising);
    if is_try initialising then begin
      Hashtbl.replace placed_tries initialising.span ();
      convert_listed_try context initialising scalar
    end
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
      whole;
      converts;
      initialises;
      source = source_through (selection_of context);
      initialises_whole = initialises_whole context;
      type_c_text = is_type_c_text context;
      location = location_of context;
      index = integer_constant context ~role:"an index of a designator";
      in_generic = context.generic_definition;
      lowers_zero = lowers_zero context holder;
      keeps_list = keeps_list context;
    }
  in
  context.needs_complete t;
  place_declared_try context ~constant t;
  let initialised = Initialiser.initialise typing t initialiser in
  (match initialiser with
  | Braced list ->
      List.iter (refuse_unplaced_try context)
        (List.filter
           (fun initialising ->
             is_try initialising
             && not (Hashtbl.mem placed_tries initialising.Tree.span))
           (initialiser_list_expressions list))
  | Expression_initialiser _ -> ());
  initialised

(* Design 7.1 rule 3: lowering writes the zero initialiser at [list] as
   [{}] under [__extension__] before its holder, which Apple Clang 21
   does not read before a declaration in the first clause of a [for]. *)
and lowers_zero context holder (list : Tree.span) =
  match holder with
  | Holder_at holder ->
      Hashtbl.replace context.typed.classified_lists list
        (Zero_list { list; holder })
  | For_clause ->
      context.fail list
        (Rule.message Zero_initialiser_in_for
           "the zero initialiser of an object whose type mentions a type \
            parameter, in a declaration in the first clause of a for \
            statement: declare the object before the loop")

(* Design 7.1 rule 3: lowering keeps the list at [list] as written. *)
and keeps_list context (list : Tree.span) =
  Hashtbl.replace context.typed.classified_lists list Kept_list

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
  let enclosing = context.typed.enclosing in
  let enclosing =
    { enclosing with
      try_positions =
        without_holders enclosing.try_positions try_in_deferred_statement;
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

(* A block-item declaration of one declarator is the holder of the tries
   in its initialiser (design 5.1 rule 3), which the initialiser confirms
   for the object that it declares. *)
and block_declaration context (declaration : Tree.declaration) =
  let declare () =
    context.declaration (Holder_at declaration.span.first) declaration
  in
  match declaration.node with
  | Declaration
      { declarators = [ { node = { initialiser = Some initialiser; _ }; _ } ];
        _ } ->
      holding context ~declaration:true
        { statement = declaration.span;
          labels = None;
          standing = Block_item }
        ~stretch_last:declaration.span.last (Initialiser initialiser) declare
  | Declaration _ | Static_assert _ -> declare ()

and typed_statement context statement =
  standing_statement context Substatement None statement

(* A statement that stands as [standing], after the C labels [labels]
   span, which are those of a statement that holds a try (design 5.1
   rule 3). The labels of a match arm are no statement's. *)
and standing_statement context standing labels (statement : Tree.statement) =
  let enclosing = context.typed.enclosing in
  let controlling ~clause tested =
    require_condition context ~clause tested (whole_value context tested)
  in
  let holder =
    { statement = statement.span; labels; standing }
  in
  (* Rule 3: the holder of the tries of an expression that a [)] ends, as
     a controlling expression, a scrutinee or the operand of a test. *)
  let held_in_parentheses (value : Tree.expression) =
    holding context holder ~stretch_last:(value.span.last + 1)
      (Expression value)
  in
  let in_loop type_clause = refusing context in_loop_clause type_clause in
  match statement.node with
  | Labeled { label; statement = labeled } ->
      label_of context label;
      (match label.node with
      | Named_label { attributes; _ } -> context.subjectless attributes
      | Case_label _ | Case_range _ | Default_label -> ());
      let first =
        match labels with
        | Some (labels : Tree.span) -> labels.first
        | None -> label.span.first
      in
      standing_statement context standing
        (Some { first; last = label.span.last })
        labeled
  | Expression_statement value ->
      holding context holder ~stretch_last:statement.span.last
        (Expression value)
        (fun () -> discard context value)
  | Compound block -> block_items context block
  | Computed_goto value ->
      ignore (expression context ~role:"the target of a computed goto" value)
  | Attribute_statement attributes -> context.subjectless attributes
  | Null_statement | Goto _ | Continue _ | Break _ -> ()
  | If { condition = Controlling condition; then_branch; else_branch } ->
      held_in_parentheses condition (fun () ->
          controlling ~clause:"6.8.4.1p1" condition);
      typed_statement context then_branch;
      Option.iter (typed_statement context) else_branch
  | If
      { condition = Pattern_test { pattern_span; pattern; operand };
        then_branch; else_branch } ->
      let otherwise =
        Option.map (fun (branch : Tree.statement) -> branch.span) else_branch
      in
      single_pattern_test context statement ~pattern_span ~pattern ~operand
        ~hold:(held_in_parentheses operand) then_branch (If_test { otherwise });
      Option.iter (typed_statement context) else_branch
  | Switch { controlling; body } ->
      held_in_parentheses controlling (fun () ->
          switch_controlling context controlling);
      within context { enclosing with case_labels = Switch_body } (fun () ->
          typed_statement context body)
  | Match { scrutinee; arms } ->
      match_statement context statement scrutinee arms
        ~hold:(held_in_parentheses scrutinee)
  | While { condition = Controlling condition; body } ->
      in_loop (fun () -> controlling ~clause:"6.8.5p2" condition);
      typed_statement context body
  | While
      { condition = Pattern_test { pattern_span; pattern; operand }; body } ->
      single_pattern_test context statement ~pattern_span ~pattern ~operand
        ~hold:in_loop body While_test
  | Do { body; condition } ->
      typed_statement context body;
      in_loop (fun () -> controlling ~clause:"6.8.5p2" condition)
  | For { clause; condition; step; body } ->
      in_loop (fun () ->
          Option.iter (for_clause context) clause;
          Option.iter (controlling ~clause:"6.8.5p2") condition;
          Option.iter (discard context) step);
      typed_statement context body
  (* 6.8.6.4p1 is left to the backend: GCC and Clang refuse a return
     that mismatches the function by default but accept it under
     -Wno-return-mismatch, and GNU C returns a void expression from a
     void function. Either way a void function discards the value; a
     return type that typec does not know is a target, as any other. *)
  (* Lowering writes the operand of a return in the scope of a defer in
     a block of its own, ahead of the copies (design 6 rule 12). *)
  | Return (Some value) when returns_void enclosing ->
      holding context holder ~stretch_last:statement.span.last
        (Expression value) (fun () ->
          context.read_moved value.span (fun () -> discard context value))
  | Return value ->
      let position =
        match enclosing.return_type with
        | Some (Answer t) -> Targeted t
        | Some (Depends_on _) | None -> Untargeted
      in
      let operand (value : Tree.expression) =
        holding context holder ~stretch_last:statement.span.last
          (Expression value) (fun () ->
            context.read_moved value.span (fun () ->
                ignore (positioned context position value)))
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
  | Clause_declaration declaration ->
      context.declaration For_clause declaration
  | Clause_expression value -> discard context value

(* 6.8.4.2p1. *)
and switch_controlling context controlling =
  let typed =
    expression context ~role:"the controlling expression of a switch"
      controlling
  in
  match operand context typed with
  | Arithmetic_operand { arithmetic = Integer _; _ } | Unknown_operand _ -> ()
  | Arithmetic_operand _ | Pointer_operand _ | Distinct_operand _
  | Other_operand _ ->
      context.fail controlling.span
        (Rule.c_text
           ("the controlling expression of a switch is not an integer \
             (C11 6.8.4.2p1)"
           ^ switch_remedy context controlling.span (value_type typed)))

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
  match
    operand context (expression context ~role:"the value of a case label" value)
  with
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

and match_statement context (statement : Tree.statement) scrutinee arms
    ~hold =
  let typed =
    hold (fun () ->
        expression context ~role:"the scrutinee of a match" scrutinee)
  in
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
             let reading = pattern_reading Match_label in
             let root = indexed_in reading variant t constructors in
             typed_arms context ~statement reading root arms) })

(* Design 4.6: the operand obeys 4.1 rule 1 and the pattern 4.1 rule 3,
   as a scrutinee and a label of a match do. The [else] statement is the
   caller's. *)
and single_pattern_test context (statement : Tree.statement) ~pattern_span
    ~(pattern : Tree.pattern) ~(operand : Tree.expression) ~hold
    (controlled : Tree.statement) form =
  let read_operand_of_test () =
    expression context ~role:"the operand of a single-pattern test" operand
  in
  let t = (hold read_operand_of_test).expression_type in
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
             let reading = pattern_reading Test_pattern in
             let root = indexed_in reading variant t constructors in
             (* The head ends at the parenthesis after the operand. *)
             let head =
               { Tree.first = statement.span.first;
                 last = operand.span.last + 1 }
             in
             tested context reading root ~head ~pattern_span pattern
               controlled form) })

(* The selection tree of a test, its bindings, which [head] binds, then
   its statement, which is in their scope and in which no case or default
   label of a switch around it may stand (4.6 rules 4 and 6). *)
and tested context reading root ~head ~pattern_span (pattern : Tree.pattern)
    (controlled : Tree.statement) form =
  let checked =
    constructor_pattern context reading root ~position:[]
      ~reached:scrutinee_reach pattern_span pattern
  in
  let size, nested = test_tree context ~pattern_span reading root checked in
  let bindings =
    List.map (declare_binding context (Test_head head))
      checked.bindings
  in
  let enclosing =
    { context.typed.enclosing with case_labels = Test_statement }
  in
  within context enclosing (fun () -> typed_statement context controlled);
  { form; constructor = checked.constructor.constructor_name;
    constructors = List.map constructor_name (Array.to_list root.constructors);
    bindings; controlled = controlled.span; nested; size }

(* Design 4.7 rule 9: a test selects as a match of its one label would,
   under the bounds of rule 10, and needs no check of 4.2. Its tree is
   lowered where it has more than one node, with the leaf of the label 1
   and every other leaf 0 (13.5). *)
and test_tree context ~pattern_span reading root
    (checked : checked_pattern) =
  match
    Selection.select root.constructors [ checked.selection ] ~default:false
  with
  | Error refusal ->
      context.fail pattern_span
        (Rule.c_text (selection_refusal ~what:"the test" refusal))
  | Ok tree ->
      let arm_of_leaf : Selection.leaf -> int = function
        | Label _ -> 1
        | Nothing -> 0
        | Default -> invalid_arg "Expressions.test_tree: a default"
      in
      (tree.size, nested_of reading root ~arm_of_leaf tree)

(* The arms of a match of the variant [root]: their labels, the coverage
   of its values and the items of each arm, and the selection tree that
   lowering writes where it has more than one node. *)
and typed_arms context ~(statement : Tree.statement) reading root arms =
  let labelled = List.map (labelled_patterns context reading root) arms in
  let tree =
    coverage context ~statement:statement.span root (List.concat labelled)
  in
  let defaulted = Selection.defaulted tree in
  let enclosing = { context.typed.enclosing with case_labels = Match_arm } in
  let matched =
    List.mapi
      (fun number ((arm : Tree.arm), labels) ->
        let matched = matched_arm context arm labels defaulted ~number in
        within context enclosing (fun () -> arm_items context arm);
        refuse_open_arm context arm;
        matched)
      (List.combine arms labelled)
  in
  let arm_of_leaf = arm_of_match_leaf (List.combine matched labelled) in
  { matched; nested = nested_of reading root ~arm_of_leaf tree;
    size = tree.size }

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
and refuse_open_arm context (arm : Tree.arm) =
  if Reachability.arm_end_reached (reachability_facts context) arm then
    context.fail arm.span
      (Rule.message Arm_end
         (Printf.sprintf
            "%s can reach its end; control does not fall out of an arm, so \
             end it with break, return, continue or goto"
            (listed_labels context arm ~one:"the arm of"
               ~several:"the arm of")))

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
           (Printf.sprintf "%s is of type %s, not a variant type%s" what
              (quote (Type_name.of_ctype t))
              (pointer_note t)))

(* The variant [name] of type [t] with its [constructors] indexed, once
   for each variant that the patterns of [reading] name. *)
and indexed_in (reading : pattern_reading) name (t : Ctype.t) constructors =
  let key = variant_key t in
  match Hashtbl.find_opt reading.variants key with
  | Some indexed -> indexed
  | None ->
      let constructors = Array.of_list constructors in
      let index_of = Hashtbl.create (Array.length constructors) in
      Array.iteri
        (fun index (constructor : Ctype.constructor) ->
          Hashtbl.replace index_of
            (constructor.constructor_name :> string)
            index)
        constructors;
      let indexed = { variant_type = t; name; constructors; index_of } in
      Hashtbl.replace reading.variants key indexed;
      indexed

(* A variant is a structure (design 10.1), which its id names. *)
and variant_key (t : Ctype.t) =
  match t.shape with
  | Record tag -> tag.record_id
  | _ -> invalid_arg "Expressions.variant_key: no variant"

(* What a sub-pattern at a field of type [t] may be (4.7 rule 2). *)
and position_type context reading (t : Ctype.t) =
  match (Ctype.as_variant t, Ctype.constructors context.tags t) with
  | Some name, Some constructors ->
      Variant_position (indexed_in reading name t constructors)
  | _ -> (
      match (Ctype.unqualified t).shape with
      | Pointer referenced when Option.is_some (Ctype.as_variant referenced)
        ->
          Pointer_position referenced
      | _ -> Other_position)

(* The constructor that [pattern] names in [variant], at [position],
   whose object lowering reaches as [reached], with one sub-pattern per
   field or, in a test, no field list (4.1 rule 3, 4.6 rule 2, 4.7 rules
   2 and 8). The one place that makes a selection pattern. *)
and constructor_pattern context reading (variant : indexed_variant)
    ~position ~reached (span : Tree.span) (pattern : Tree.pattern) =
  let name = pattern.constructor.node in
  Sites.refuse_outside_pattern context.tags ~fail:context.fail
    ~variant_type:variant.variant_type ~variant:variant.name span;
  match Hashtbl.find_opt variant.index_of name with
  | None ->
      context.fail span (no_constructor name variant ~nested:(position <> []))
  | Some index ->
      let constructor = variant.constructors.(index) in
      let checked =
        List.mapi
          (fun index (sub, member) ->
            sub_pattern context reading
              (field_site ~holder:constructor ~position ~reached index member)
              sub)
          (sub_pattern_fields context ~site:reading.site span pattern
             constructor)
      in
      { constructor;
        selection =
          { variant = variant.constructors; index;
            fields = List.map fst checked };
        bindings = List.concat_map snd checked }

(* Design 4.1 rule 3; at a field, 4.7 rule 3, which says how a field of
   variant type is bound. *)
and no_constructor name (variant : indexed_variant) ~nested =
  let text =
    Printf.sprintf "%s names no constructor of the variant %s" (quote name)
      (quoted_variant variant.name)
  in
  if nested then
    Rule.message Pattern
      (text ^ "; a field of a variant type is bound with its type, as in `T x`")
  else Rule.message Pattern text

and field_site ~(holder : Ctype.constructor) ~position
    ~(reached : object_reach) index (member : Ctype.member) =
  match member.member_name with
  | Some field ->
      let held = { constructor = holder.constructor_name; field } in
      { holder; position; index; member;
        reached_field =
          { base = reached.from_local; path = reached.in_place;
            field = held } }
  | None -> invalid_arg "Expressions.field_site: an unnamed field"

(* The sub-pattern [sub] at [site]: as selection reads it, and its
   bindings (4.7 rules 2 to 5). *)
and sub_pattern context reading (site : field_site) (sub : Tree.sub_pattern)
    =
  let position_type = position_type context reading site.member.member_type in
  match (sub.node, position_type) with
  | Wildcard, _ -> (Selection.Any, [])
  | Alone { name; declared }, _ ->
      alone_sub_pattern context reading site sub.span name declared
        position_type
  | Nested pattern, Variant_position variant ->
      let checked =
        pattern_at context reading site sub.span pattern variant
          ~through_pointer:false
      in
      (Constructor checked.selection, checked.bindings)
  | Followed pattern, Pointer_position referenced ->
      let variant = followed_variant context reading sub.span referenced in
      let checked =
        pattern_at context reading site sub.span pattern variant
          ~through_pointer:true
      in
      (Pointer checked.selection, checked.bindings)
  | Typed_binding { type_name; name; declared }, Variant_position variant ->
      refuse_other_type context type_name variant;
      bound_at site name declared
  | (Nested _ | Followed _ | Typed_binding _), _ ->
      refuse_sub_pattern context sub site.member.member_type position_type

(* An identifier alone at [site], spanning [span]: a constructor pattern
   or a binding, as its first reading decided (4.7 rule 3). *)
and alone_sub_pattern context reading site span (name : Tree.identifier)
    declared position_type =
  let first () = alone_reading context reading name position_type in
  match (context.name_reading name.span.first first, position_type) with
  | Ordinary_word, _ -> bound_at site name declared
  | Constructor_word _, Variant_position variant ->
      let checked =
        pattern_at context reading site span
          { constructor = name; sub_patterns = None }
          variant ~through_pointer:false
      in
      (Constructor checked.selection, checked.bindings)
  | Constructor_word _, (Pointer_position _ | Other_position) ->
      invalid_arg "Expressions.alone_sub_pattern: a constructor off a variant"

(* The constructor pattern [pattern] of [variant] at the position below
   [site], the field itself or the object that it points to where
   [through_pointer]. *)
and pattern_at context reading site span pattern (variant : indexed_variant)
    ~through_pointer =
  let below =
    { Selection.holder = site.holder.constructor_name; field = site.index;
      through_pointer }
    :: site.position
  in
  let reached =
    placed reading below variant.name site.reached_field ~through_pointer
  in
  constructor_pattern context reading variant ~position:below ~reached span
    pattern

(* A binding of the field at [site] (4.1 rule 4, 4.7 rule 7). *)
and bound_at site (name : Tree.identifier) declared =
  ( Selection.Any,
    [ { identifier = name; declared;
        object_type = non_modifiable site.member.member_type;
        copied = site.reached_field } ] )

(* 4.7 rule 5: [*] reads the tag of a complete variant in place. *)
and followed_variant context reading span (referenced : Ctype.t) =
  if referenced.qualifiers.volatile || referenced.qualifiers.atomic then
    context.fail span
      (Rule.message Pattern
         "a `*` follows no pointer to a volatile or atomic variant, which \
          selection would read at separate moments; a match in the arm \
          copies the object");
  context.needs_complete referenced;
  match position_type context reading referenced with
  | Variant_position variant -> variant
  | Pointer_position _ | Other_position ->
      context.fail span
        (Rule.message Pattern
           (Printf.sprintf
              "a `*` follows a pointer to %s, whose constructors are \
               unknown here"
              (quote (Type_name.of_ctype referenced))))

(* 4.7 rule 3: what an identifier alone is where typing first reads it,
   which the type of its position decides. *)
and alone_reading context reading name position_type =
  match position_type with
  | Variant_position variant ->
      Constructor_word (Type_name.of_variant variant.name)
  | Pointer_position referenced ->
      refuse_constructor_binding context reading name referenced;
      Ordinary_word
  | Other_position -> Ordinary_word

(* 4.7 rule 5: a binding of a pointer to a variant does not have the
   name of one of the variant's constructors, which [*] would match. *)
and refuse_constructor_binding context reading (name : Tree.identifier)
    referenced =
  match position_type context reading referenced with
  | Variant_position variant when Hashtbl.mem variant.index_of name.node ->
      context.fail name.span
        (Rule.message Pattern
           (Printf.sprintf
              "the binding %s of a pointer to the variant %s has the name \
               of one of its constructors; `*%s` matches that constructor, \
               and a binding of the pointer takes another name"
              (quote name.node) (quoted_variant variant.name) name.node))
  | Variant_position _ | Pointer_position _ | Other_position -> ()

(* 4.7 rule 4: the type of a typed binding is that of its field, since
   the binding converts nothing. *)
and refuse_other_type context (type_name : Tree.type_name)
    (variant : indexed_variant) =
  let named = Ctype.unqualified (context.type_name type_name) in
  match named.shape with
  | Record tag when tag.record_id = variant_key variant.variant_type -> ()
  | _ ->
      context.fail type_name.span
        (Rule.message Pattern
           (Printf.sprintf
              "the typed binding names the type %s, and its field is of \
               the variant %s; a binding converts nothing"
              (quote (excerpt context type_name.span))
              (quoted_variant variant.name)))

(* 4.7 rule 2: a sub-pattern that the type of its position does not
   list. *)
and refuse_sub_pattern context (sub : Tree.sub_pattern) t position_type =
  let what_stands_there =
    match (sub.node, position_type) with
    | _, Variant_position _ ->
        "takes `_`, a constructor pattern or a typed binding"
    | Typed_binding { name; _ }, (Pointer_position _ | Other_position) ->
        "is bound by its name alone; write " ^ quote name.node
    | _, Pointer_position _ ->
        "takes `_`, a binding or `*` and a constructor pattern"
    | _, Other_position -> "takes `_` or a binding"
  in
  context.fail sub.span
    (Rule.message Pattern
       (Printf.sprintf
          "the sub-pattern %s stands at a field of type %s, which %s"
          (quote (excerpt context sub.span))
          (quote (Type_name.of_ctype t))
          what_stands_there))

(* Whether selection reads a tag below the constructor of [pattern]. *)
and reads_below (pattern : Selection.constructor_pattern) =
  List.exists
    (function Selection.Any -> false | Constructor _ | Pointer _ -> true)
    pattern.fields

(* The sub-patterns of [pattern] with the fields of [constructor]: one
   sub-pattern per field, or no field list, which only a test may omit
   for a constructor with fields (4.1 rule 3, 4.6 rule 2, 4.7 rule 9). *)
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
            %d field(s); write %s to ignore the fields"
           name fields
           (quote (ignoring_pattern constructor)))
  | None, _ -> []
  | Some sub_patterns, _ when List.length sub_patterns <> fields ->
      refuse
        (Printf.sprintf
           "the pattern %s has %d sub-pattern(s), and the constructor has \
            %d field(s)"
           name (List.length sub_patterns) fields)
  | Some sub_patterns, _ -> List.combine sub_patterns constructor.fields

(* Each label of [arm] with its pattern checked against the variant
   [root]; [None] for a [default]. *)
and labelled_patterns context reading root (arm : Tree.arm) =
  List.map
    (fun (label : Tree.arm_label) ->
      match label.node with
      | Default_arm_label -> (label, None)
      | Pattern_label { node = pattern; _ } ->
          ( label,
            Some
              (constructor_pattern context reading root ~position:[]
                 ~reached:scrutinee_reach label.span pattern) ))
    arm.node.labels

(* 4.2 rules 1 and 2, read from the selection tree of the labels of a
   match (4.7 rule 6): every case label and the one [default] are
   selected for some value, and every value is taken. The result is the
   tree. *)
and coverage context ~statement root labelled =
  let cases = List.filter_map snd labelled in
  let has_default =
    List.exists (fun (_, checked) -> Option.is_none checked) labelled
  in
  match
    Selection.select root.constructors
      (List.map (fun (checked : checked_pattern) -> checked.selection) cases)
      ~default:has_default
  with
  | Error refusal ->
      context.fail statement
        (Rule.c_text (selection_refusal ~what:"the match" refusal))
  | Ok tree ->
      refuse_unselected_labels context tree labelled;
      refuse_missing context ~statement root.name tree;
      refuse_unselected_default context tree labelled
        ~flat:(not (List.exists (fun c -> reads_below c.selection) cases));
      tree

(* The tree that lowering writes where it has more than one node; a tree
   of one node is the [switch] on the scrutinee's tag (13.5). *)
and nested_of reading root ~arm_of_leaf (tree : Selection.t) =
  if is_flat tree then None
  else
    Some
      { locals = named_locals reading;
        tree = lowered_tree reading root ~arm_of_leaf tree }

(* A tree of one node, whose root reads the scrutinee's tag alone
   (13.5). *)
and is_flat (tree : Selection.t) =
  List.for_all
    (fun (branch : Selection.branch) ->
      match branch.subtree with Leaf _ -> true | Node _ -> false)
    tree.scrutinee

(* The number of the arm of a match that a leaf selects (13.5). [numbered]
   pairs each arm with its labels. A tree of a match that passed
   {!coverage} has no leaf of nothing. *)
and arm_of_match_leaf numbered =
  let arm_of_label = Hashtbl.create 16 and default_arm = ref None in
  List.iter
    (fun ((arm : matched_arm), labels) ->
      List.iter
        (function
          | _, Some _ ->
              Hashtbl.replace arm_of_label (Hashtbl.length arm_of_label)
                arm.number
          | _, None -> default_arm := Some arm.number)
        labels)
    numbered;
  function
  | Selection.Label index -> Hashtbl.find arm_of_label index
  | Default -> Option.get !default_arm
  | Nothing -> invalid_arg "Expressions.arm_of_match_leaf: a value missed"

(* The tree that lowering writes (13.5): each leaf the number that
   [arm_of_leaf] gives it, and each node with the position of its tag. *)
and lowered_tree reading root ~arm_of_leaf (tree : Selection.t) =
  let rec lowered : Selection.tree -> selection_tree = function
    | Leaf leaf -> Arm (arm_of_leaf leaf)
    | Node { position; branches } ->
        Read
          { at = Position (Positions.find reading.places position);
            branches = List.map branch branches }
  and branch (branch : Selection.branch) =
    (List.map constructor_name branch.constructors, lowered branch.subtree)
  in
  Read
    { at = Scrutinee root.name; branches = List.map branch tree.scrutinee }

(* A translation limit of typec on selection (4.7 rule 10, C11
   5.2.4.1). *)
and selection_refusal ~what : Selection.refusal -> string = function
  | Too_many_steps ->
      Printf.sprintf
        "%s needs more than %d steps of selection, the most that typec \
         takes (a translation limit, C11 5.2.4.1)"
        what Selection.max_steps
  | Too_deep ->
      Printf.sprintf
        "the selection tree of %s is deeper than %d nodes, the most that \
         typec takes (a translation limit, C11 5.2.4.1)"
        what Selection.max_depth

(* In source order: a second [default] (4.2 rule 2), and a case label
   that is no leaf of [tree], since the labels before it match all that
   it matches (rule 1). For a label without a nested pattern that is a
   constructor named twice, which is how the error names it. *)
and refuse_unselected_labels context tree labelled =
  let never = Selection.never_selected tree in
  let rec walk case_index ~after_default = function
    | [] -> ()
    | ((label : Tree.arm_label), None) :: rest ->
        if after_default then
          context.fail label.span
            (Rule.message Default_arm "a match has a second `default`");
        walk case_index ~after_default:true rest
    | (label, Some (checked : checked_pattern)) :: rest ->
        if List.mem case_index never then
          context.fail label.span
            (Rule.message Exhaustiveness
               (unselected_label checked.constructor
                  ~flat:(not (reads_below checked.selection))));
        walk (case_index + 1) ~after_default rest
  in
  walk 0 ~after_default:false labelled

and unselected_label (constructor : Ctype.constructor) ~flat =
  if flat then
    Printf.sprintf "the constructor %s is covered twice"
      (quote (constructor.constructor_name :> string))
  else
    "the case label is never selected, since the labels before it match \
     every value that it matches"

(* The values that no label takes (4.2 rule 1). *)
and refuse_missing context ~statement variant tree =
  match missing_text variant (Selection.missing tree) with
  | None -> ()
  | Some text -> context.fail statement (Rule.message Exhaustiveness text)

(* A constructor of the scrutinee below which selection reads nothing is
   named as a constructor of the variant; a deeper value is named as a
   pattern (4.7 rule 6). *)
and missing_text variant (missing : Selection.missing) =
  match missing with
  | Nothing_missing -> None
  | Scrutinee_constructors constructors ->
      Some
        (Printf.sprintf "the match does not cover %s of the variant %s"
           (constructor_list (Shown.map constructor_name constructors))
           (quoted_variant variant))
  | Values values -> Some ("the match does not cover " ^ value_list values)

(* 4.2 rule 2: a [default] takes at least one value. *)
and refuse_unselected_default context tree labelled ~flat =
  if Selection.default_never_selected tree then
    match
      List.find_opt (fun (_, checked) -> Option.is_none checked) labelled
    with
    | Some ((default : Tree.arm_label), _) ->
        context.fail default.span
          (Rule.message Default_arm (unselected_default ~flat))
    | None -> ()

and unselected_default ~flat =
  if flat then "the `default` of a match covers no constructor"
  else
    "the `default` of the match takes no value, since its case labels \
     match every value"

and constructor_name (constructor : Ctype.constructor) =
  constructor.constructor_name

(* What a diagnostic calls the constructors [names]. *)
and constructor_list names =
  listed ~one:"the constructor" ~several:"the constructors"
    (Shown.map (fun (name : Spelling.constructor) -> quote (name :> string))
       names)

(* What a diagnostic calls the values [values], written as patterns. *)
and value_list values =
  listed ~one:"the value" ~several:"the values"
    (Shown.map (fun value -> quote (Selection.spelling value)) values)

(* An arm and its bindings, which only an arm of one label may declare
   (4.1 rule 6). A binding is a non-modifiable object of its field's
   type in the arm's scope (rule 4), at any depth (4.7 rule 7). *)
and matched_arm context (arm : Tree.arm) labelled defaulted ~number =
  let labels = arm.node.labels in
  let first = List.hd labels and last = List.hd (List.rev labels) in
  let bindings =
    match labelled with
    | [ ({ node = Pattern_label pattern; _ }, Some (checked : checked_pattern))
      ] ->
        List.map (declare_binding context (Arm_label pattern.span))
          checked.bindings
    | _ ->
        List.iter (refuse_shared_binding context arm) labelled;
        []
  in
  let cases =
    List.concat_map
      (function
        | _, Some (checked : checked_pattern) -> [ checked.constructor ]
        | _, None -> defaulted)
      labelled
  in
  { number; arm = arm.span;
    labels = { first = first.span.first; last = last.span.last };
    cases = List.map constructor_name cases;
    bindings }

and refuse_shared_binding context arm = function
  | binding_label, Some { bindings = { identifier; _ } :: _; _ } ->
      context.fail identifier.span
        (Rule.message Shared_arm
           (Printf.sprintf
              "%s share an arm, so %s may not be bound in it; give each label \
               its own arm"
              (listed_labels context arm ~first:binding_label
                 ~one:"the label" ~several:"the labels")
              (quote identifier.node)))
  | _, Some { bindings = []; _ } | _, None -> ()

(* The labels of [arm] as written, each without its [case] and colon, as
   many as a message names, [first] before the others where given, so
   that a long arm still shows the label the message is about. *)
and listed_labels ?first context (arm : Tree.arm) ~one ~several =
  let labels =
    match first with
    | Some label -> label :: List.filter (( != ) label) arm.node.labels
    | None -> arm.node.labels
  in
  listed ~one ~several (Shown.map (quoted_label context) (Shown.few labels))

and quoted_label context (label : Tree.arm_label) =
  match label.node with
  | Pattern_label pattern -> quote (excerpt context pattern.span)
  | Default_arm_label -> quote "default"

and declare_binding context binder (found : found_binding) =
  context.binding found.identifier found.declared found.object_type;
  Option.iter
    (fun binders -> Hashtbl.replace binders found.identifier.node binder)
    context.typed.enclosing.binders;
  { name = context.written_name found.declared found.identifier.node;
    field = found.copied }

(* A field type is unqualified and no array (design 3.2 rule 4), so it
   takes [const]. *)
and non_modifiable t =
  match Ctype.qualify { Qualifiers.none with const = true } t with
  | Ok qualified -> qualified
  | Error _ -> invalid_arg "Expressions.non_modifiable: no value type"

and arm_items context (arm : Tree.arm) = items context arm.node.items

(* Design 13.5: the lowered match reaches the scrutinee in place, through
   a pointer to it, unless it is volatile or atomic or its address may be
   misaligned; a member whose address may be misaligned is reached through
   a pointer to an aligned object that holds it. Any other scrutinee is
   copied, which only costs time. This is the one place that decides
   whether typec takes the address of a variant or of an object that holds
   one. *)
and access_of context (scrutinee : Tree.expression) (t : Ctype.t) =
  if t.qualifiers.volatile || t.qualifiers.atomic then Through_copy
  else if aligned_lvalue context scrutinee then Through_pointer
  else member_access context scrutinee []

(* The access to [e], a member reached by the designators [members] after
   it, through the object that holds it: an aligned lvalue [B] before
   [.], or the object of an aligned address [B] before [->]. A path
   through anything but a member designator, as a subscript or a pair of
   parentheses, is copied: lowering spells the path after the base. *)
and member_access context (e : Tree.expression) members =
  match e.node with
  | Member { operand; member } ->
      member_operand context operand (member.node :: members)
  | Pointer_member { operand; member } ->
      if aligned_address context operand then
        Through_base
          { base = Base_pointer operand.span; members = member.node :: members }
      else Through_copy
  | _ -> Through_copy

(* The access through [operand], the operand of a [.] that [members]
   follow: a further member, or the base object. *)
and member_operand context (operand : Tree.expression) members =
  match operand.node with
  | Member _ | Pointer_member _ -> member_access context operand members
  | _ ->
      if aligned_lvalue context operand then
        Through_base { base = Base_object operand.span; members }
      else Through_copy

(* Whether [e] is an lvalue that C lets [&] take (C11 6.5.3.2p1) and
   whose address C aligns for its type: a named object not declared
   [register], a compound literal, or the object that an address operand
   designates. A member is not, since its structure may be packed by a
   [#pragma pack] or an attribute that typec does not read, though the
   object that holds it may be ({!member_access}). Another
   lvalue is taken as not, which is safe: it is copied. *)
and aligned_lvalue context (e : Tree.expression) =
  match e.node with
  | Compound_literal _ -> true
  | Parenthesized inner -> aligned_lvalue context inner
  | Unary (Indirection, operand) -> aligned_address context operand
  | Subscript { operand; index } ->
      aligned_address context operand && aligned_address context index
  | Identifier { name; resolution = Resolved reference } -> (
      match (context.entity e.span name reference).declared with
      | Object { register; _ } -> not register
      | Function _ | Typedef _ | Enumerator _ -> false)
  | _ -> false

(* Whether an operand of [*e] or [e1[e2]] gives an aligned address: an
   array that is an aligned lvalue, since its elements are aligned where
   it is (6.3.2.1p3); a pointer that is read as a stored value or
   returned by a call, which the program formed, and the backend warned
   of, where it was formed; or the index or a slice, which is no address
   of a variant. A pointer formed in the operand, as by the conversion of
   a member array or by arithmetic, may point into a packed structure. *)
and aligned_address context (operand : Tree.expression) =
  match find context.typed operand with
  | Some { expression_type = { shape = Array _; _ }; _ } ->
      aligned_lvalue context operand
  | Some { expression_type = { shape = Pointer _; _ }; _ } ->
      stored_pointer operand
  | Some _ -> true
  | None -> false

and stored_pointer (operand : Tree.expression) =
  match operand.node with
  | Parenthesized inner -> stored_pointer inner
  | Identifier _ | Member _ | Pointer_member _ | Subscript _
  | Unary (Indirection, _) | Call _ ->
      true
  | _ -> false

(* The names of the parameters that the call of [__tc_ret] passes an
   lvalue of (design 13.5), as lowering declares them. A parameter
   without a name passes none: it is the one of [(void)], or the front
   end refuses it in a function that gets [__tc_ret] (Return_form). *)
let call_parameters context (declarator : Tree.declarator) =
  let named (parameter : Tree.parameter) =
    match parameter.node.declarator with
    | Named_parameter { declarator; declared } ->
        Option.map
          (context.written_name declared)
          (Tree.declared_name declarator)
    | Abstract_parameter _ -> None
  in
  let listed (name : Tree.parameter_name) =
    context.written_name name.declared name.name.node
  in
  match (Tree.defined_function declarator).parameters with
  | Identifier_list names -> List.map listed names
  | Prototype { parameters; variadic = _ } -> List.filter_map named parameters

(* The defer statements of the body, which reachability finds once
   typing has read it, as its facts need, and the function around them
   that the form of a return in their scopes needs (design 13.5). *)
let record_defers context ~name ~declarator ~enclosing (block : Tree.block) =
  match
    Reachability.defers (reachability_facts context)
      ~copied:context.copy_deferred block
  with
  | [] -> None
  | sites ->
      let returns =
        if returns_void enclosing then Returns_void else Returns_value
      in
      let recorded =
        { function_name = name; declarator;
          parameters = call_parameters context declarator; body = block.span;
          returns; sites }
      in
      context.typed.defers <- recorded :: context.typed.defers;
      Some recorded

let function_body context ~name ~in_generic ~declarator ~return_type
    (block : Tree.block) =
  let view = context.typed in
  let enclosing =
    { function_name = Some name; body = Some block.span; in_generic;
      return_type = Some return_type;
      case_labels = No_switch; try_positions = Positions not_held;
      binders = Some (Hashtbl.create 8) }
  in
  view.next_try <- 0;
  view.next_truth <- 0;
  (match Reachability.label_refusal block with
  | Some { span; diagnostic } -> context.fail span diagnostic
  | None -> ());
  within context enclosing (fun () -> block_items context block);
  record_defers context ~name ~declarator ~enclosing block

(* GNU [__typeof__] of an expression, whose indexes the judgement of
   design 13.5 leaves untested where C does not evaluate it. *)
let typeof_value context (expression : Tree.expression) =
  let typed = whole_value context expression in
  judge_by_type context.typed expression.span typed.expression_type;
  typed
