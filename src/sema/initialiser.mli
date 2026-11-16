(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Initialisation (C11 6.7.9): which subobject each initialiser of a
    braced list initialises, through designators, GNU range designators
    and brace elision, and the length that an initialiser gives an array
    of unknown size (6.7.9p22).

    Where a position depends on what typec does not know, an opaque
    length or index (design P16) or an unknown type (P21), the rest of
    the braced list is typed without a subobject for each initialiser,
    and the length that it gives an array of unknown size is opaque:
    never guessed. A designator of the list then finds its subobject
    again.

    The pass reports what it must detect to give the types (design
    13.3): designators that name no subobject, array designators that
    are not integer constant expressions or are out of range, string
    literals that initialise an array of another character type, arrays
    initialised by an expression, and objects of incomplete type.
    Excess initialisers, which GCC and Clang accept with a warning, are
    typed and left to the backend, and so are the conversions of each
    initialiser to its subobject and the initialiser of a variable length
    array, which GCC and Clang take where they fold its length. *)

open Typec_syntax

(** What initialisation asks of expression typing.

    - [value] types an expression of the initialiser, once, in its one
      position, and gives its type before the conversions of its
      context. The position is its target type (design 3.3): the type
      of the subobject where the walk meets it or, where that
      subobject's braces may be elided, of the first variant inside it;
      [None] for an excess one.
    - [converts] checks the implicit conversion of an expression that
      [value] has typed to the scalar type that it initialises, which is
      not its target type where the walk has elided braces around the
      scalar.
    - [initialises] checks an expression that [value] has typed and that
      initialises a subobject, as an excess one does not.
    - [source] gives the expression whose value an expression is,
      through parentheses and the selections of [_Generic] and
      [__builtin_choose_expr], or the unknown type that a selection
      depends on. It types the operands of a selection, not the
      expression, which keeps its position for [value].
    - [initialises_whole] notes an expression that [value] has typed and
      that initialises a whole subobject of the type with no brace
      elided before it, where a braced list could stand in for it.
    - [type_c_text] says whether a span begins in Type-C text.
    - [index] gives the value of the expression of an array designator,
      or the span of what keeps it from being an integer constant
      expression.
    - [fail] is as in {!Expressions.context}.

    In Type-C text an initialiser opens no variant's members but through
    the [{0}] that zeroes it (design 3.2 rules 6 and 7). *)
type typing = {
  target : Target.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> Rule.diagnostic -> 'a;
  value : Ctype.t option -> Tree.expression -> Ctype.t;
  converts : Ctype.t -> Tree.expression -> unit;
  initialises : Tree.expression -> unit;
  source : Tree.expression -> Tree.expression Unknown.answer;
  initialises_whole : Ctype.t -> Tree.expression -> unit;
  type_c_text : Tree.span -> bool;
  index : Tree.expression -> (Integer_constant.t, Tree.span) result;
}

val max_levels : int
(** The deepest subobject that an initialiser reaches, counting a level
    for each brace that it elides and each structure, union or array
    that a designator enters; a deeper one is an error. It bounds the work
    of each initialiser of a list, which follows the nesting of the type,
    to a constant, as the parser's limit on nested brackets bounds the
    braces written. *)

val initialise : typing -> Ctype.t -> Tree.initialiser -> Ctype.t
(** [initialise typing t initialiser] checks [initialiser] for an object of
    type [t] and gives the type of the object: [t], or for an array of
    unknown size the array of the length that [initialiser] gives. *)
