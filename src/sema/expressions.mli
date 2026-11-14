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

    An expression whose type depends on a type that typec does not
    compute has that unknown type (design 13.3, P21); a constraint on an
    unknown type is the backend's to check. The pass reports what it must
    detect to give the types (design 13.3): undeclared names, operands
    that an operator does not take, members that a structure lacks, calls
    of what is not a function, operands that must be lvalues, the
    constraints that decide what a generic selection selects, and the
    statement constraints on controlling expressions, the places of
    [case], [default], [break] and [continue], and [case] values.
    Assignment and argument conversions and the constraints of [return]
    are the backend's. *)

open Typec_syntax

(** Whether an expression is a bit-field, whose integer promotion depends
    on its width (6.3.1.1p2): one that it designates, as a member access
    does, which [&] and [sizeof] do not take (6.5.3.2p1, 6.5.3.4p1), or
    the value of one, as GCC and Clang take an assignment to a bit-field,
    a prefix [++] of one and a comma whose right operand is one. *)
type bit_field = Not_bit_field | Bit_field of int | Bit_field_value of int

(** What typing gives an expression. [expression_type] is the type that
    C gives the expression itself, before the conversions of its context:
    an lvalue keeps its qualifiers, an array and a function their own
    types (6.3.2.1); {!Ctype.lvalue_conversion} gives the type of its
    value. *)
type typed = {
  expression_type : Ctype.t;
  lvalue : bool;
  bit_field : bit_field;
}

(** The typed view of a translation unit, filled as the reader types its
    expressions. Each expression node is typed once and found by its
    span, which no other expression node has: every composite expression
    has tokens of its own beyond those of its operands. *)
type t

val create : unit -> t

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

val selection : t -> Tree.expression -> Tree.expression Ctype.answer option
(** The result expression of a generic selection (6.5.1.1p3), selected
    by the type that {!find} gives the controlling expression. The
    selection is unknown where that type is, or the compatibility of any
    association with it, and where the controlling expression is a
    bit-field, which GCC gives a type of its own width. *)

val types_compatible : t -> Tree.expression -> bool Ctype.answer option
(** Whether the two types of [__builtin_types_compatible_p] are
    compatible without their top-level qualifiers, as GCC and Clang
    compare them. That of an [_Atomic] type, which GCC drops and Clang
    keeps, is unknown where it changes the answer. *)

(** What the declaration reader gives typing. [fail] reports the first
    error at the start of a span and does not return; [entity] gives what
    a resolved use of a name denotes, and [overloaded] whether it names
    a Clang overload set (design 13.3); [type_name] reads a type name, once,
    declaring what it declares; [declaration] reads a declaration in a
    block, binding its identifiers and typing its initialisers; [constant]
    gives the value of an integer constant expression (6.6p6), [None] for
    an expression that is not one, evaluated as an operand that is not
    evaluated (6.6p3) unless [evaluated] says it is. *)
type context = {
  typed : t;
  target : Target.t;
  text : Typec_cpp.Reader.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> string -> 'a;
  entity : Tree.span -> string -> Tree.reference -> Entity.t;
  overloaded : Tree.reference -> bool;
  type_name : Tree.type_name -> Ctype.t;
  declaration : Tree.declaration -> unit;
  constant : evaluated:bool -> Tree.expression -> Integer_constant.t option;
}

val max_depth : int
(** The deepest nesting of expressions and statements that is typed; a
    deeper one is an error. *)

val expression : context -> Tree.expression -> typed
(** Types an expression and every expression in it, or gives the type
    found for it before. *)

val initialiser : context -> Tree.initialiser -> unit
(** Types the expressions of an initialiser. The rules of initialisation
    (6.7.9) are not checked, and an initialiser does not complete the
    type it initialises. *)

val function_body : context -> name:string -> Tree.block -> unit
(** Types the body of the function [name]. *)

val quote : string -> string
(** A spelling from the text in a message, quoted and cut short. *)
