(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Reachability (design 4.4) over the body of a function, and the rules
    on leaving and entering a match arm that rest on it (4.3): the end of
    every arm is unreachable (rule 1), and a label inside an arm is the
    target only of a goto in the same arm (rule 3). The analysis is
    syntactic: it reads the tree and the two facts of typing below, and
    evaluates no condition other than a constant. A refusal needs a
    match, so C code gains none. Label scopes are resolved here until
    the tree resolves labels (TODO.md). *)

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

(** Both walk a tree that typing has read, whose nesting it has bounded
    ({!Expressions.max_depth}), so their recursion is bounded too. *)

val arm_refusal : facts -> Tree.arm -> refusal option
(** The breach of design 4.3 rule 1 by the arm, if its end can be
    reached. Typing asks it of every match it reads. *)

val jump_refusal : facts -> Tree.block -> refusal option
(** The first jump, in source order, in the body of a function that
    breaches design 4.3 rule 3, if any. *)
