(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Design 6 rule 9 on the [#pragma] lines in the scopes of defer
    statements, those of their deferred statements aside, which the
    parser checks. Lowering writes a copy of a deferred statement at
    each exit of its scope, and the copy is compiled under the pragmas
    in force there, so the state there is that at the defer statement:
    a scope holds only the pragmas that annotate the loop after them,
    and none directly before an exit, the end of its block or a
    statement that holds an exit, where the pragma would reach what
    lowering writes. *)

open Typec_cpp
open Typec_syntax

val refusal :
  Token.t array ->
  Reachability.defer_site list ->
  (int * Rule.diagnostic) option
(** [refusal tokens sites] is the first pragma line, by its index in
    [tokens], that the scopes of the defer statements [sites] of one
    function may not hold, with why, or [None]. *)
