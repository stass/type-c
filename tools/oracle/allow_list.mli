(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The reviewed disagreements between typec and Clang that the typing
    oracle accepts (plan 0.10, gate 4).

    Each line of the file is an entry, a pattern and the reason it is
    accepted separated by a tab, or blank, or a comment that starts with
    [#]. A pattern matches a disagreement as the comparison prints it,
    the whole line; in it [*] matches any run of bytes and every other
    byte itself. The reason is required. *)

type t

val read : string -> (t, string) result
(** [read contents] is the list that [contents], a file's, holds, or
    the first line that is not an entry and why. *)

val reason : t -> string -> string option
(** The reason of the first entry that matches a printed disagreement,
    if one does. *)
