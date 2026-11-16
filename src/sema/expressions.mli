(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The types of expressions (C11 6.3, 6.5) and the statements of function
    bodies (6.8): the type of each expression node, whether it is an
    lvalue, and the constraints that a type depends on.

    The declaration reader types each function body where the definition
    stands, so that a body sees the tags and declarations of the unit at
    its own point, and every expression it reads elsewhere, such as an
    array length or the operand of [typeof]. It gives this module a
    {!context}: how to read what an expression declares and refers to,
    which it alone knows, and its one way to fail.

    Types are those that Clang gives. An expression whose type depends on
    a type that typec does not compute has that unknown type (design
    13.3, P21), as has one that GCC, as the backend, types otherwise
    ({!Backend_difference}); a constraint on an unknown type is the
    backend's to check. The pass reports what it must
    detect to give the types (design 13.3): undeclared names, operands
    that an operator does not take, members that a structure lacks, calls
    of what is not a function, operands that must be lvalues, the
    constraints that decide what a generic selection selects, and the
    statement constraints on controlling expressions, the places of
    [case], [default], [break] and [continue], and [case] values.
    Assignment and argument conversions and the constraints of [return]
    are the backend's.

    Typing also gives each expression its class of constant expression
    (6.6), and the value of an integer one, which every rule that needs a
    constant reads. Initialisers are typed through {!Initialiser}. *)

open Typec_syntax

(** A bit-field member: its width, and the integer type that it is
    declared with or that its enumerated type is compatible with, by which
    its value promotes (6.3.1.1p2) whatever type the backend gives the
    value. [location] is where the member is named, for the unknown type
    of a promotion that GCC gives otherwise. *)
type field = {
  width : int;
  integer : Integer.t Unknown.answer;
  location : Typec_cpp.Location.t;
}

(** Whether an expression is a bit-field, whose integer promotion depends
    on its width: one that it designates, as a member access does, which
    [&] and [sizeof] do not take (6.5.3.2p1, 6.5.3.4p1), or the value of
    one, as Clang takes an assignment to a bit-field, a prefix [++] of one
    and a comma whose right operand is one. *)
type bit_field = Not_bit_field | Bit_field of field | Bit_field_value of field

(** What typing gives an expression. [expression_type] is the type that
    Clang gives the expression itself, before the conversions of its
    context: an lvalue keeps its qualifiers, an array and a function
    their own types (6.3.2.1); {!Ctype.lvalue_conversion} gives the type
    of its value. *)
type typed = {
  expression_type : Ctype.t;
  lvalue : bool;
  bit_field : bit_field;
}

val designates_bit_field : typed -> bool
(** Whether the expression designates a bit-field, which [sizeof] and [&]
    refuse, rather than give the value of one. *)

(** {1 Constant expressions (6.6)} *)

(** Why an expression of integer constants is an integer constant
    expression only where it is not evaluated (6.6p3, p4), as in the right
    operand of a [&&] whose left operand is false. *)
type flaw =
  | Comma_operator of Tree.span
  | Invalid of { span : Tree.span; diagnostic : Rule.diagnostic }
      (** An operation that fails (6.6p4): an overflow, a division by
          zero, a shift out of range. Its value is opaque. *)

(** An lvalue or a function designator, as a constant expression reads
    it. [static_storage]: it designates an object of static storage
    duration or a function, whose address is an address constant
    (6.6p9), as is its value where it is an array or a function;
    otherwise neither is a constant. [named]: an object that an
    identifier declares, or a member or element of one, whose value no
    constant expression reads (6.6p9) unless it is [const], as GCC and
    Clang read it. *)
type designation = { static_storage : bool; named : bool }

(** The class of an expression that is not an integer constant
    expression. *)
type kind =
  | Arithmetic_constant  (** 6.6p8. *)
  | Address_constant
      (** 6.6p9, or one plus or minus an integer constant expression
          (6.6p7); an integer constant expression cast to a pointer is
          one, a null pointer among them. *)
  | Designator of designation
  | Backend_constant
      (** A constant expression only as the backend decides (6.6p10):
          what typec cannot tell that GCC and Clang both refuse, such as a
          call, which each folds for some builtins, a comma operator, which
          Clang takes, or an operand of a type that typec does not
          compute. *)
  | Not_constant
      (** What GCC and Clang both refuse where it is evaluated: an
          assignment, an increment or a decrement (6.6p3), the value of a
          named object that is not [const], the address of an object of
          automatic or thread storage duration (6.6p9). *)

type constant =
  | Integer_expression of { value : Integer_constant.t; flaw : flaw option }
      (** An integer constant expression (6.6p6) and its value. *)
  | Not_integer of { kind : kind; first : Tree.span }
      (** [first] is the first operand or operator that 6.6p6 does not
          allow. *)
  | Unevaluable of { span : Tree.span; diagnostic : Rule.diagnostic }
      (** An integer expression of constants that typec does not evaluate,
          or that breaks a constraint: [sizeof] of an incomplete type, a
          cast to a type that typec does not compute, a [_Generic] whose
          selection depends on one. It is an error wherever it is part of
          an integer constant expression, evaluated or not. *)

(** The typed view of a translation unit, filled as the reader types its
    expressions. Each expression node is typed once and found by its
    span, which no other expression node has: every composite expression
    has tokens of its own beyond those of its operands. *)
type t

val create : unit -> t

(** A constructor expression (design 3.3) that lowering replaces (13.5):
    its span; the name of its variant and of the constructor; the span
    of the name where the constructor is called with arguments, [None]
    for one without fields; its arguments; and whether it initialises a
    whole object of its variant with no brace elided before it, where it
    lowers to the braced list alone. *)
type construction = {
  span : Tree.span;
  variant : Spelling.type_name;
  constructor : Spelling.constructor;
  callee : Tree.span option;
  arguments : Tree.expression list;
  braced : bool;
}

val constructions : t -> construction list
(** The constructor expressions typed, in source order. *)

(** How a lowered match reaches its scrutinee (design 13.5): through a
    pointer to it, or through a copy where the scrutinee is volatile or
    atomic or is no lvalue that typec knows [&] may take. *)
type access = Through_pointer | Through_copy

(** A binding of a match: its name, the constructor of its pattern and
    the field that it copies (design 4.1 rule 4). *)
type binding = {
  name : string;
  constructor : Spelling.constructor;
  field : string;
}

(** An arm of a match: its span; the span from its first label to its
    last; the constructors it takes, in the order of its labels, where a
    [default] stands for those no label names (design 4.2); and its
    bindings in order. *)
type matched_arm = {
  arm : Tree.span;
  labels : Tree.span;
  cases : Spelling.constructor list;
  bindings : binding list;
}

(** The statement that a single-pattern test controls, which lowering
    makes a block that declares the bindings first (design 13.5): a
    compound statement, whose bindings go before the token
    [bindings_before], after its brace and its GNU local labels; or
    another statement, which lowering puts in a block of its own. *)
type controlled =
  | Compound_controlled of { span : Tree.span; bindings_before : int }
  | Wrapped_controlled of Tree.span

(** Whether a test is the condition of an [if], with the span of its
    [else] statement if it has one, or of a [while]. *)
type test_form = If_test of { otherwise : Tree.span option } | While_test

(** A single-pattern test (design 4.6): its form, the constructor that it
    asks for, every constructor of its variant in order, whose tags are
    the valid ones (4.5), its bindings in order, and its statement. *)
type test = {
  form : test_form;
  constructor : Spelling.constructor;
  constructors : Spelling.constructor list;
  bindings : binding list;
  controlled : controlled;
}

(** What a matching selects with the tag of its scrutinee: the arms of a
    match statement, or the one constructor of a single-pattern test. *)
type selection = Arms of matched_arm list | Test of test

(** A match statement (design 4) or a single-pattern test (4.6) that
    lowering replaces (13.5): its span, that of its scrutinee, which is
    the operand of a test, the name of its variant, how it reaches the
    scrutinee, and what it selects. Typing records a matching before it
    types what it selects, which is then still to be typed. *)
type 'selects matching_of = {
  statement : Tree.span;
  scrutinee : Tree.span;
  variant : Spelling.type_name;
  access : access;
  selects : 'selects;
}

type matching = selection matching_of

val matchings : t -> matching list
(** The match statements and single-pattern tests typed, in source
    order. *)

(** How lowering answers a construct that asks whether types are
    compatible where Type-C text compares a distinct type with them
    (design 13.5), as the backend would answer for its representation:
    for a generic selection, its controlling expression, its
    associations and the result expression it selects; for
    [__builtin_types_compatible_p], its answer. *)
type answer =
  | Selected of {
      controlling : Tree.expression;
      associations : Tree.generic_association list;
      result : Tree.expression;
    }
  | Compatible of bool

type answered = { construct : Tree.span; answer : answer }

val answered : t -> answered list
(** The constructs typed that typec answers, in source order. *)

val find : t -> Tree.expression -> typed option
(** The type of an expression that has been typed: the type that a
    Type-C rule sees (design 13.3). A generic selection has that of the
    expression it selects, and the associations it does not select are
    typed as well, as C requires them to be valid. *)

(** The answers to the constructs that ask whether two types are
    compatible, which the front end gives where a Type-C type is involved
    (design 13.5): each is the answer, or the unknown type that it depends
    on (P21), and [None] for an expression that is not such a construct
    or has not been typed. *)

val selection : t -> Tree.expression -> Tree.expression Unknown.answer option
(** The result expression of a generic selection (6.5.1.1p3), selected
    by the type that {!find} gives the controlling expression. The
    selection is unknown where that type is, or the compatibility of any
    association with it. That of [__builtin_choose_expr] is the operand
    its condition chooses, unknown where the backend evaluates the
    condition, as for a call of [__builtin_constant_p]. *)

val types_compatible : t -> Tree.expression -> bool Unknown.answer option
(** Whether the two types of [__builtin_types_compatible_p] are
    compatible without their top-level qualifiers but [_Atomic], as Clang
    compares them. *)

val constant : t -> Tree.expression -> constant option
(** The class of constant expression of an expression that has been
    typed. *)

(** What the declaration reader gives typing. [fail] reports the first
    error at the start of a span and does not return; [entity] gives what
    a resolved use of a name denotes, and [overloaded] whether it names
    a Clang overload set (design 13.3); [type_name] reads a type name, once,
    declaring what it declares; [declaration] reads a declaration in a
    block, binding its identifiers and typing its initialisers, and
    [type_declaration] a type declaration there. *)
type context = {
  typed : t;
  target : Target.t;
  text : Typec_cpp.Reader.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> Rule.diagnostic -> 'a;
  entity : Tree.span -> string -> Tree.reference -> Entity.t;
  overloaded : Tree.reference -> bool;
  type_name : Tree.type_name -> Ctype.t;
  declaration : Tree.declaration -> unit;
  type_declaration : Tree.type_declaration -> unit;
  binding : Tree.identifier -> Tree.declared -> Ctype.t -> unit;
      (** declares a binding of a match as an object of the type *)
}

val whole_value : context -> Tree.expression -> typed
(** Types an expression and every expression in it, for a use that
    takes its value whole, as GNU [typeof] does: a value of a distinct
    type is not refused (design 3.4). An expression typed before raises
    [Invalid_argument]: it is typed once. *)

val integer_constant :
  context -> Tree.expression -> (Integer_constant.t, Tree.span) result
(** Types an expression where an integer constant expression is needed
    (6.6p6), and gives its value, or the span of the first operand or
    operator that keeps it from being one. One that typec cannot evaluate
    or whose evaluation fails is an error. An expression typed before
    raises [Invalid_argument]. *)

val initialiser :
  context -> constant:bool -> Ctype.t -> Tree.initialiser -> Ctype.t
(** Types the initialiser of an object of the type ({!Initialiser}) and
    gives the type of the object, which it completes where it is an array
    of unknown size. [constant] says that the object has static or thread
    storage duration, whose initialiser is constant (6.7.9p4): an
    expression that is [Not_constant] is an error. *)

val function_body :
  context -> name:string -> return_type:Ctype.t option -> Tree.block -> unit
(** Types the body of the function [name], whose [return] statements have
    its return type as their target type (design 3.3); [None] where the
    function's type is unknown. *)

val quote : string -> string
(** A spelling from the text in a message, quoted and cut short. *)

val needing : string -> Unknown.t -> Rule.diagnostic
(** The refusal where [need] depends on an unknown type. *)
