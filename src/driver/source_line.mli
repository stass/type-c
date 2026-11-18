(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The line of the source file that typec's own diagnostic shows under
    its message, as GCC and Clang show theirs (design 13.6). The driver
    reads the file; this module decides which file, how much of it and
    how the line looks. *)

val path : Typec_cpp.Location.t -> string option
(** [path location] is the file that holds the line of [location]: its
    name as the line marker spells it, or [None] where the name holds a
    backslash. A marker writes a backslash only in an escape sequence,
    which typec does not decode, so the file under the spelled name is
    another file. *)

val longest_read : int
(** The most bytes at the start of the file that the driver reads; a
    line that does not end within them is not shown. *)

val quote : line:int -> string -> string option
(** [quote ~line text] is how the diagnostic shows line [line] of
    [text], the start of a source file, or [None] where [text] holds no
    such line: ["    2 | text"], the margin of the backends' snippets.
    Below line 100000 the margin is eight columns wide, so a tab, which
    is kept, lands on the tab stop it has in the file. A carriage return
    that ends the line is dropped, a line longer than 200 bytes is cut
    there at the start of a character and ends with ["..."], and the
    rest goes through {!Typec_cpp.Reader.escape}, as the file is
    untrusted text printed to a terminal. *)

val is_shown : string -> bool
(** [is_shown text] is whether [text] starts with the margin of
    {!quote}, so that a tool that reads typec's stderr tells the line
    from the message above it. *)
