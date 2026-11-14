(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The per-test results a recipe's test script prints, which the runner
    counts into the run record. A result is one line of the script's
    stdout:

    {v
    TEST pass NAME
    TEST fail NAME
    TEST fail-with-backend NAME
    v}

    [fail-with-backend] is a test that fails with the Type-C objects and
    also with the backend's own objects, so that it says something about
    the host and not about [typec]. A [NAME] is the rest of the line.
    Every other line of the output is the script's own and is ignored. *)

type t = {
  passed : int;
  failed : string list;  (** the names, in the order printed *)
  failed_with_backend : string list;
}

val none : t
(** No result at all. *)

val read : string -> (t, string) result
(** [read output] counts the result lines of a script's stdout. The error
    names a [TEST] line whose result is not one of the three above or
    whose name is empty or has blanks at either end. *)
