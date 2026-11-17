(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The refusals of the form of a [return e;] in the scope of a defer
    statement (design 13.5). A function that returns a value and holds
    one names its return type through a call of its own name, which
    passes an lvalue of each parameter, in a typedef before its body,
    and puts the body in a block of its own; a function that returns
    void evaluates [e] as a statement. Each case where that text cannot
    be written is refused with a code of its own (13.6). *)

open Typec_syntax

(** A function definition whose body holds a defer statement. *)
type definition = {
  name : Tree.identifier;  (** the name that the definition declares *)
  function_type : Ctype.t;  (** the type that the definition declares *)
  return_type : Ctype.t Unknown.answer;
  targets : Entity.targets;
  marked : string option;
      (** as the declarations of the function in scope at the definition
          say ({!Entity.declared}) *)
  declaration_list : Tree.span list;
      (** the declarations of an old-style definition (C11 6.9.1p6) *)
  scope : Tree.scope_depth;
      (** that of the parameter list and the outermost block of the body,
          which are one scope in C (C11 6.2.1p4) *)
  owns : Resolution.own list;
      (** the names that the definition declares, its parameter list and
          body included *)
  defers : Expressions.function_defers;
}

val refusal :
  Expressions.t -> definition -> (Tree.span * Rule.diagnostic) option
(** The first refusal of the form in the definition, with where it is
    reported, given the types of its expressions: none where it holds no
    [return e;] in the scope of a defer statement. *)
