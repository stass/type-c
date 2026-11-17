(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one list of the pragmas that a deferred statement may hold
    (design 6 rule 9, 13.5). *)

(** Whether a pragma line whose identifiers are [names], in order, is one
    that a deferred statement may hold. *)
val is_statement_scoped : string list -> bool
