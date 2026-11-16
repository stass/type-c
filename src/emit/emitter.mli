(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Emission of a translation unit that {!Typec_cpp.Reader.read} has
    read: its text, with some ranges of its tokens replaced by new C text
    and declarations after it (design 13.4).

    Everything outside the replaced ranges is copied from the text, white
    space and line markers included, so a unit without edits or
    assertions is emitted byte for byte as it was read. {!Lowering} makes
    the edits and {!Assumptions} the assertions. *)

(** The text of an edit: C code as it is, or C code in the packing
    bracket of design 10.3, which lays it out with the packing of the
    command line whatever packing a pragma has put in force where it
    stands, and leaves that packing in force after it. A bracketed edit
    stands only where a declaration may, as its pragmas take lines of
    their own. Emission is the one function that writes a bracket, and a
    unit that it gives one ends with the packing probe (see {!emit}); a
    [Code] text that spells the pragmas itself escapes the probe. *)
type text = Code of string | Bracketed of string

(** Replace the tokens of [range] by [text], which the backend places
    at [location], the line of the construct it lowers, and reads under
    the flags in effect there. An insertion, a range of no tokens, goes
    in front of the token [range.first]. The white space and markers
    around the range are kept. *)
type edit = {
  range : Typec_cpp.Reader.range;
  location : Typec_cpp.Location.t;
  text : text;
}

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
    inside the opening lines of its bracket where it has one, and
    followed by one that restores the presumed line where the replaced
    range ends, so the rest of the text keeps its lines. Each marker
    carries the flags 3 and 4 in effect at its location
    ({!Typec_cpp.Location.flags}) and no enter or return flag, so the
    backend exempts the text from warnings as it would the tokens there,
    and the reader keeps the owner of every token. File names are written
    as the reader spelled them, escaped as in a line marker: the file of
    every token comes from a line marker or a [#line] directive.

    The ranges of the edits must be made from the tokens of [unit]. They
    are in the order that {!Typec_cpp.Reader.rewrite} takes, and the
    tokens an edit replaces belong to one file, so it never drops a
    marker that enters or leaves a file without its partner; [emit]
    raises [Invalid_argument] otherwise. *)
