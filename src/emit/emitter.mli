(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Emission of a translation unit that {!Typec_cpp.Reader.read} has
    read: its text, with some ranges of its tokens replaced by new C text
    (design 13.4).

    Everything outside the replaced ranges is copied from the text, white
    space and line markers included, so a unit without edits is emitted
    byte for byte as it was read. {!Lowering} makes the edits. *)

(** Replace the tokens of [range] by [text], which the backend places
    at [location], the line of the construct it lowers. An insertion, a
    range of no tokens, goes in front of the token [range.first]. The
    white space and markers around the range are kept. *)
type edit = {
  range : Typec_cpp.Reader.range;
  location : Typec_cpp.Location.t;
  text : string;
}

val emit : Typec_cpp.Reader.t -> edit list -> string
(** [emit unit edits] is the text of [unit] with each edit applied. The
    text of an edit is preceded by a line marker for its location and
    followed by one that restores the presumed line where the replaced
    range ends, so the rest of the text keeps its lines. The markers
    carry no flags, so they do not change the file a token belongs to,
    but both GCC and Clang take the text after them as outside a system
    header. File names are written as the reader spelled them: escaped as
    in a line marker, or the input's name before the first marker, which
    the output of [cc -E] always starts with.

    The ranges of the edits must be made from the tokens of [unit]. They
    are in the order that {!Typec_cpp.Reader.rewrite} takes, and the
    tokens an edit replaces belong to one file, so it never drops a
    marker that enters or leaves a file without its partner; [emit]
    raises [Invalid_argument] otherwise. *)
