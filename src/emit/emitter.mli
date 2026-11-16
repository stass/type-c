(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Emission of a translation unit that {!Typec_cpp.Reader.read} has
    read: its text, with some ranges of its tokens replaced by new C text
    and declarations after it (design 13.4).

    Everything outside the replaced ranges is copied from the text, white
    space and line markers included, so a unit without edits or
    assertions is emitted byte for byte as it was read. {!Lowering} makes
    the edits and {!Assumptions} the assertions. *)

(** A piece of moved text (design 13.4): C text with the location that
    the backend places it at and the flags 3 and 4 it reads it under.
    No piece holds a pragma line or a [#] that would begin one, so the
    pragmas that text in a packing bracket holds are the bracket's
    own. *)
type piece

val token : Typec_cpp.Reader.t -> int -> piece option
(** [token unit index] is the token [index] of [unit] at its own
    location, wherever lowering writes it, or None where the token is a
    pragma line; such a token cannot be moved, and its definition is
    refused rather than moved without it.
    An identifier is written as its name ({!Typec_cpp.Reader.spelling}),
    in UTF-8 where universal character names spell it, which names the
    same identifier. *)

val generated : Typec_cpp.Location.t -> string -> piece
(** [generated location text] is [text], which typec writes from no token
    of the moved text, at [location]: the line of the token that a name
    is written for, or of the construct that puts the text there.
    [Invalid_argument] unless every byte of [text] is one of an
    identifier, UTF-8 included, the blank, or a punctuator of C other
    than [#], [%], [?], [/] and [\\]: then it spells no directive, line
    splice, comment, line break or string literal, and so no pragma line,
    as [_Pragma] takes a string literal (C11 6.10.9). *)

(** The text of an edit: C code as it is, or moved text in the packing
    bracket of design 10.3, which lays it out with the packing of the
    command line whatever packing a pragma has put in force where it
    stands, and leaves that packing in force after it. Emission is the
    one function that writes a bracket, and a unit that it gives one ends
    with the packing probe (see {!emit}). *)
type text = Code of string | Bracketed of piece list

(** Replace the tokens of [range] by [text], which the backend places
    at [location], the line of the construct it lowers, and reads under
    the flags in effect there; the pieces of a bracketed text are each at
    their own location, and the bracket's pragmas at [location]. An
    insertion, a range of no tokens, goes in front of the token
    [range.first]. The white space and markers around the range are
    kept. Only {!code} and {!bracketed} make one. *)
type edit = private {
  range : Typec_cpp.Reader.range;
  location : Typec_cpp.Location.t;
  text : text;
}

val code : Typec_cpp.Reader.range -> location:Typec_cpp.Location.t ->
  string -> edit
(** [code range ~location text] replaces [range] by [text] at [location].
    [Invalid_argument] unless [text] holds only the bytes that
    {!generated} takes, so code never writes the pragmas of a bracket
    past the probe. *)

val bracketed : Typec_cpp.Reader.t -> at:Typec_syntax.Tree.anchor ->
  location:Typec_cpp.Location.t -> piece list -> edit
(** [bracketed unit ~at ~location pieces] inserts [pieces] in a packing
    bracket at [location] at the anchor [at] of [unit], which only the
    parser names, so that the bracket, whose pragmas take lines of their
    own, stands where a declaration may and never inside an
    expression. *)

(** What lowering makes of a unit: its edits, and the declarations that
    follow its text, the static assertions of {!Assumptions}. *)
type lowered = { edits : edit list; assertions : string list }

val emit : Typec_cpp.Reader.t -> lowered -> string
(** [emit unit { edits; assertions }] is the text of [unit] with each
    edit applied, then, where there are [assertions] or a bracketed
    edit, a line marker for line 1 of the file ["<typec>"] with flag 3,
    each assertion on a line of its own, and, where an edit is
    bracketed, the packing probe of design 10.3. The probe declares
    [struct __tc_pack_probe_1] and [struct __tc_pack_probe_2], each in a
    bracket, inside regions of [#pragma pack(1)] and [#pragma pack(2)],
    and asserts ({!Assumptions.assertion}) that they are aligned alike,
    which holds where [#pragma pack()] restores the packing of the
    command line and leaves the stack of [push] alone, as the bracket
    assumes; the packing and the stack around it are as they were.
    The text of an edit is preceded by a line marker for its location,
    and a bracketed text by one for the location of each run of pieces
    that share one, the pieces of a run on one line; the edit is
    followed by a marker that restores the presumed line where the
    replaced range ends, so the rest of the text keeps its lines. Each marker
    carries the flags 3 and 4 in effect at its location
    ({!Typec_cpp.Location.flags}) and no enter or return flag, so the
    backend exempts the text from warnings as it would the tokens there,
    and the reader keeps the owner of every token. File names are written
    as the reader spelled them, escaped as in a line marker: the file of
    every token comes from a line marker or a [#line] directive.

    The ranges and pieces of the edits must be made from the tokens of
    [unit], and a bracket's declaration parsed from them. The ranges
    are in the order that {!Typec_cpp.Reader.rewrite} takes, and the
    tokens an edit replaces belong to one file, so it never drops a
    marker that enters or leaves a file without its partner; [emit]
    raises [Invalid_argument] otherwise. *)
