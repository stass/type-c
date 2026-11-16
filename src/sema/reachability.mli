(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Reachability (design 4.4) over the body of a function, and the rules
    on leaving and entering a match arm that rest on it (4.3): the end of
    every arm is unreachable (rule 1), and a label inside an arm is the
    target only of a goto in the same arm (rule 3). The analysis is
    syntactic: it reads the tree and the two facts of typing below, and
    evaluates no condition other than a constant. Label scopes are
    resolved here until the tree resolves labels (TODO.md), and with
    them the rules of C and GNU C on labels (C11 6.8.1p3, 6.8.6.1p1),
    the only refusals that C code without a match can gain. *)

open Typec_syntax

(** What typing knows that the rules of 4.4 read. *)
type facts = {
  noreturn : Tree.expression -> bool;
      (** whether a callee designates a function declared [_Noreturn] or
          with the GNU attribute [noreturn] *)
  non_zero : Tree.expression -> bool;
      (** whether a typed condition is an integer constant expression
          whose value is not zero *)
}

type refusal = { span : Tree.span; message : string }

(** Both walk a tree that typing has read, whose nesting it has bounded:
    that of expressions and statements by {!Expressions.max_depth}, and
    that of a declarator by the size of its type ({!Ctype.max_size}), so
    their recursion is bounded too. *)

val arm_refusal : facts -> Tree.arm -> refusal option
(** The breach of design 4.3 rule 1 by the arm, if its end can be
    reached. Typing asks it of every match it reads. *)

val label_refusal : facts -> Tree.block -> refusal option
(** In the body of a function, the first local label, in source order,
    that a block declares twice (GCC manual, "Local Labels"), or else the
    first label defined a second time in its scope (C11 6.8.1p3), or
    else the first jump that names a label not defined in its scope
    (6.8.6.1p1), enters a statement expression from outside it (GCC
    manual, "Statement Exprs") or breaches design 4.3 rule 3, if any.
    The walk reads every expression of the body, those in types
    included, but the arguments of attributes and the parameters and
    body of a block literal, which is a function of its own. *)
