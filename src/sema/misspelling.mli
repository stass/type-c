(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The name that a misspelt one most likely means, for a diagnostic to
    suggest. *)

val max_length : int
(** The longest name, in bytes, that a suggestion compares; a longer one
    is given none, so that a crafted name costs no work. *)

val closest : string -> string list -> string option
(** [closest name spellings] is the one of [spellings] that the fewest
    edits turn [name] into, if that is one spelling alone and the edits
    are few for the length of [name]. An edit inserts, deletes or
    replaces a byte, or swaps two adjacent ones. *)
