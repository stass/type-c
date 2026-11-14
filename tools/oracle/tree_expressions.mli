(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Every expression node of a parsed translation unit. *)

open Typec_syntax

val iter : (Tree.expression -> unit) -> Tree.translation_unit -> unit
(** [iter visit unit] calls [visit] on each expression node of [unit],
    an operand after the expression that holds it: those of function
    bodies, initialisers, declarators, type names and specifiers,
    designators, labels, static assertions and assembler operands. The
    body of a function that a system header defines is a span, which
    holds no nodes. *)
