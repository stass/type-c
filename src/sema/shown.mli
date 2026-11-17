(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The text that a diagnostic shows of a name or a type, cut at one
    length, so that no message grows with what it names: an instance may
    be spelled in thousands of bytes, and a crafted one in more than
    memory holds. *)

val max_length : int
(** The most bytes of a name that a diagnostic shows. *)

val cut : string -> string
(** [cut text] is [text] where it has at most {!max_length} bytes, and
    else its first bytes, cut at a character boundary, and ["..."], at
    most {!max_length} bytes in all. *)

val bounded : ((string -> unit) -> unit) -> string
(** [bounded write] is the text that [write add] passes to [add], cut as
    {!cut} cuts it. [add] stops [write] once the text is longer than
    {!max_length} bytes, so that showing a text allocates about
    {!max_length} bytes, and takes steps that grow with {!max_length}
    and the depth of what [write] walks, not with the length of the
    whole. *)
