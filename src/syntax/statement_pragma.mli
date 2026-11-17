(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one list of the pragmas that a deferred statement and the scope
    of a defer statement may hold (design 6 rule 9, 13.5). *)

(** Whether a pragma line whose identifiers are [names], in order, is one
    that a deferred statement may hold: one that annotates the loop
    after it, or one in force to the end of its compound statement. *)
val is_statement_scoped : string list -> bool

(** Whether a pragma line whose identifiers are [names], in order,
    annotates the loop after it and nothing else: the one kind that the
    scope of a defer statement may hold. *)
val is_loop_pragma : string list -> bool
