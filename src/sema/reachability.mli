(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Reachability (design 4.4) over the body of a function, and the rules
    on leaving and entering a match arm that rest on it (4.3): the end of
    every arm is unreachable (rule 1), and a label inside an arm is the
    target only of a goto in the same arm (rule 3). The analysis is
    syntactic: it reads the tree and the two facts of typing below, and
    evaluates no condition other than a constant. The parser resolves
    every label, and with it the rules of C and GNU C on defining and
    naming one (C11 6.8.1p3, 6.8.6.1p1); the jumps into a statement
    expression that GNU C forbids are checked here with rule 3, being
    rules on entering a statement. *)

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

type refusal = { span : Tree.span; diagnostic : Rule.diagnostic }

(** An exit from the scope of a defer statement by a jump (design 6 rule
    1): a [break], [continue] or [return;], the statement after its
    labels; or a [return e;], with the span of [e]. *)
type exit =
  | Jump of Tree.span
  | Value_return of { statement : Tree.span; operand : Tree.span }

(** Where the scope of a defer statement ends: at the [}], token
    [closing], of a block that can complete, which is an exit; of one
    that cannot, which is none (design 6 rule 1); or at the end of a
    match arm, which cannot complete (4.3 rule 1) and holds no [}]. *)
type ending = Completes of int | Cannot_complete of int | Arm_end

(** A defer statement: its keyword, its statement [S], where its scope
    ends, and the jumps that leave the scope, in the order of the walk.
    A [goto] that leaves it is not among them (TODO.md). *)
type defer_site = {
  keyword : Tree.span;
  deferred : Tree.span;
  ending : ending;
  exits : exit list;
}

(** Both walk a tree that the parser has bounded in depth
    ({!Typec_syntax.Parser.max_depth}), so their recursion is bounded
    too. *)

val arm_refusal : facts -> Tree.arm -> refusal option
(** The breach of design 4.3 rule 1 by the arm, if its end can be
    reached. Typing asks it of every match it reads. *)

val label_refusal : Tree.block -> refusal option
(** In the body of a function, the first jump, in source order, that
    enters a statement expression from outside it (GCC manual,
    "Statement Exprs"), breaches design 4.3 rule 3 or 6 rule 5, or stands
    in the scope of a defer statement against 6 rule 10, if any. It
    reads the tree alone, so typing may ask it first.
    The walk reads every expression of the body, those in types
    included, but the arguments of attributes and the parameters and
    body of a block literal, which is a function of its own. *)

val defers : facts -> Tree.block -> defer_site list
(** The defer statements of the body of a function, in source order,
    with the exits of their scopes. *)
