(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one function of the tree from the expression of a holder to its
    [try] expressions (design 5.1 rule 3): the place of each [try], or
    the refusal that the operators between it and the holder give, and
    the hoisted operands that the prelude of the holder evaluates, in
    the order of 5.1 (13.5). A [try] that the walk does not reach stands
    under an operator that rule 3 does not name, and typing refuses it
    as [try-position]. *)

open Typec_syntax

(** The branch of a first operand's operator that a hoisted operand
    stands in: the second operand of [&&] and of [?:] where the first
    compared unequal to 0, the second of [||] and the third of [?:]
    where it did not. *)
type branch = When_true | When_false

(** The truth of the first operand with the number [truth], and the
    branch that it conditions. *)
type condition = { truth : int; branch : branch }

(** What the prelude evaluates: the operand of a [try], numbered from
    the next temporary of the function; the first operand of [&&], [||] or a
    conditional operator, numbered from the next truth of the function;
    or the left operand of a comma. *)
type form =
  | Tried of { number : int }
  | Truth of { number : int }
  | Discarded_left

(** A hoisted operand: its form, the span that the holder reads it
    through, [replaced] (the [try] itself, or else the operand), the
    span the prelude evaluates, [operand], and the conditions it stands
    under, innermost first. The innermost condition names the whole
    list, and the operands under one share its list. *)
type hoisted = {
  form : form;
  replaced : Tree.span;
  operand : Tree.span;
  conditions : condition list;
}

type place = Hoisted of hoisted | Refused of Rule.t * string

(** The expression of a holder: an expression, or the initialiser of the
    one declarator of a declaration. *)
type holder_expression =
  | Expression of Tree.expression
  | Initialiser of Tree.initialiser

type t

val plan :
  inspects:(string -> bool) ->
  next_try:int ->
  next_truth:int ->
  holder_expression ->
  t
(** The plan of a holder, whose tries and first operands take numbers
    from [next_try] and [next_truth]. [inspects name] says whether
    [name] is a builtin whose result more than the values of its
    arguments decides (design 7.1 rule 4), whose call takes no [try] in
    its arguments. *)

val without_parentheses : Tree.expression -> Tree.expression
(** The expression inside any parentheses around it. *)

val hoisted : t -> hoisted list
(** The hoisted operands, in the order of design 5.1. *)

val place : t -> Tree.span -> place option
(** The place of the [try] at the span, [None] where the walk does not
    reach it. *)

val next_try : t -> int
val next_truth : t -> int
(** The numbers that the next holder of the function takes. *)
