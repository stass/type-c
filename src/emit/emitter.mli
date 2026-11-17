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

(** The C text of one unit while lowering makes it, held to the output
    limit of design 3.5 rule 7 ({!Typec_sema.Output_limit}). Every piece
    and every edit is made for an output and charged, as it is made, the
    bytes that {!emit} writes for it, markers and pragmas included, and a
    piece at least 32 ({!Typec_sema.Output_limit.piece_charge}); the
    unit's own text is charged in full first. So the charge covers all
    that {!emit} writes for the unit but the static assertions that end
    it, a fixed text of typec's. Only {!limited} makes an output.

    The charge holds only if lowering puts each piece it makes into one
    edit. A copy of moved text is made afresh: the pieces of a moved
    edit are read only through {!copied}, which charges them again, and
    the text of a code edit is made into a piece again. *)
type output

val limited :
  Typec_cpp.Reader.t ->
  (output -> 'a) ->
  ('a * int, Typec_cpp.Reader.error) result
(** [limited unit make] is [make output] for an output of [unit] with the
    bytes charged for it, which are at most the limit, or the error at
    the location of the first piece, edit or {!joined} text whose charge
    would pass the output limit of [unit], after which nothing more is
    made.
    [output] belongs to [make] alone: one that escapes it would raise
    past this function, and edits of two outputs are each held to a
    limit of their own. *)

val unit : output -> Typec_cpp.Reader.t
(** [unit output] is the unit that [output] is made from. *)

val token : output -> int -> piece option
(** [token output index] is the token [index] of the unit at its own
    location, wherever lowering writes it, or None where it is no
    {!Typec_cpp.Token.is_movable} token, a pragma line or a [#]; such a
    token cannot be moved as a piece, and a definition that holds one is
    refused rather than moved without it. {!moved_token} moves a pragma
    line in the text of {!moved}.
    An identifier is written as its name ({!Typec_cpp.Reader.spelling}),
    in UTF-8 where universal character names spell it, which names the
    same identifier. *)

val generated : output -> Typec_cpp.Location.t -> string -> piece
(** [generated output location text] is [text], which typec writes from
    no token of the moved text, at [location]: the line of the token that
    a name is written for, or of the construct that puts the text there.
    [Invalid_argument] unless every byte of [text] is one of an
    identifier, UTF-8 included, the blank, or a punctuator of C other
    than [#], [%] and [\\], and each [?] and [/] stands between two other
    bytes, no [?] beside a [?] and no [/] beside a [/] or [*]: then it
    spells no directive, trigraph, line splice, comment, line break or
    string literal, and so no pragma line, as [_Pragma] takes a string
    literal (C11 6.10.9). *)

val joined : output -> Typec_cpp.Location.t -> separator:string ->
  ('a -> string) -> 'a list -> string
(** [joined output location ~separator spell items] is the texts that
    [spell] gives [items], with [separator] between them, for typec's own
    text at [location]. Each is held to the limit as it is made, before
    the next is, so that a text that holds a name for each of many
    items, such as the enumerators of a variant, is refused before it is
    built. The text is charged when the edit or piece that holds it is
    made. *)

val assembled : output -> Typec_cpp.Location.t -> separator:string ->
  ((string -> unit) -> unit) -> string
(** [assembled output location ~separator write] is the parts that [write]
    adds through the function it is given, in order, with [separator]
    between them, for typec's own text at [location]. Each is held to
    the limit as {!joined} holds an item, and the text takes time linear
    in its length however [write] nests, as for the nodes of a tree. *)

(** A [#pragma] line of moved text (design 13.5), at the location of
    its own line. Only the text of {!moved} holds one, so a packing
    bracket holds no pragma but its own. *)
type pragma_line

(** A piece of the text of {!moved}: a piece, or a pragma line, which
    stands on a line of its own. *)
type moved_piece = Piece of piece | Pragma_line of pragma_line

val moved_token : output -> int -> moved_piece option
(** [moved_token output index] is the token [index] of the unit at its own
    location, wherever lowering writes it: a pragma line where it is a
    [#pragma] line that is a sequence of preprocessing tokens
    ({!Typec_cpp.Token.Identifiers}), the piece of {!token} where there
    is one, and None for any other token. Those are a [#], a
    [#pragma typec] line, which sets the state of its own place, and a
    line that is no such sequence, which can splice the line after it;
    moved text that holds one is an error (design 11.1, 13.5). *)

(** The pieces of a {!Moved} edit, which lowering reads only through
    {!copied}. *)
type moved_pieces

val copied : output -> moved_pieces -> moved_piece list
(** [copied output pieces] is [pieces] for a copy of the moved text that
    holds them, each charged again as a piece, as {!emit} writes it once
    more wherever the copy goes. *)

(** The text of an edit: C code as it is, at [location]; moved text in
    the packing bracket of design 10.3, at [location], which lays it out
    with the packing of the command line whatever packing a pragma has
    put in force where it stands, and leaves that packing in force after
    it; or moved text as it is. Emission is the one function that writes
    a bracket, and a unit that it gives one ends with the packing probe
    (see {!emit}). *)
type text =
  | Code of { location : Typec_cpp.Location.t; code : string }
  | Bracketed of { location : Typec_cpp.Location.t; pieces : piece list }
  | Moved of moved_pieces

(** Replace the tokens of [range] by [text]. The backend places code and
    the pragmas of a bracket at the location of the text, the line of
    the construct it lowers, and each piece of moved text, bracketed or
    not, at its own, and reads each under the flags in effect at its
    location. An insertion, a range of no tokens, goes in front of the
    token [range.first]. The white space and markers around the range
    are kept. Only {!code}, {!closing}, {!bracketed} and {!moved} make
    one.

    An edit has an [owner], the token that orders it ({!in_order}): the
    first token it replaces, or the token an insertion goes in front of,
    except that a closing insertion ({!closing}) has the token it
    follows. It belongs to its [extent], the tokens of the construct
    that it lowers, and moves or goes with every span of tokens that
    holds its extent: the tokens it replaces, or, for an insertion, the
    construct that {!extended} names. A place between two tokens can
    begin one construct and end another, so only the construct says
    which; an insertion that names none belongs to its owner alone. *)
type edit = private {
  range : Typec_cpp.Reader.range;
  text : text;
  owner : int;
  extent : Typec_syntax.Tree.span;
}

val extended : edit -> extent:Typec_syntax.Tree.span -> edit
(** [extended edit ~extent] is [edit] belonging to [extent], the
    construct that it lowers. [Invalid_argument] unless [extent] holds
    the edit's own extent. *)

val code : output -> Typec_cpp.Reader.range ->
  location:Typec_cpp.Location.t -> string -> edit
(** [code output range ~location text] replaces [range] by [text] at
    [location]. [Invalid_argument] unless [text] holds only the bytes
    that {!generated} takes, so code never writes the pragmas of a
    bracket past the probe. *)

val closing : output -> after:int -> location:Typec_cpp.Location.t ->
  string -> edit
(** [closing output ~after ~location text] inserts [text], as {!code}
    does, between token [after] and the next, as the end of the
    construct that ends at token [after], which owns it. *)

val bracketed : output -> at:Typec_syntax.Tree.anchor ->
  location:Typec_cpp.Location.t -> piece list -> edit
(** [bracketed output ~at ~location pieces] inserts [pieces] in a
    packing bracket at [location] at the anchor [at] of the unit, which
    only the parser names, so that the bracket, whose pragmas take lines
    of their own, stands where a declaration may and never inside an
    expression. *)

val moved : output -> Typec_cpp.Reader.range -> moved_piece list -> edit
(** [moved output range pieces] replaces [range] by [pieces], each at its
    own location, without a bracket: the operand of a [try] and a copy of a
    deferred statement (design 13.5), whose pragma lines are the
    source's own. It takes any range, so the text of an instance, which
    needs the bracket, is kept from it only by the lowering that calls
    it. *)

val in_order : edit list -> edit list
(** [edits] in the order in which they apply: by the first token of
    their ranges, an insertion before a token ahead of an edit that
    replaces it, a closing insertion after a token ahead of an insertion
    before the next; of two insertions at one place, the one whose
    extent holds the other's ahead of it before a token and behind it
    after one, as the construct around the other opens first and closes
    last; and other edits of one range and owner in the order of the
    list. Their owners follow the same order. *)

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
    Code is preceded by a line marker for its location, and the pieces
    of a bracketed or moved text by one for the location of each run of
    pieces that share one, the pieces of a run on one line, and each
    pragma line by one for its own location, the line on a line of its
    own; the edit is followed by a marker that restores the presumed
    line where the replaced range ends, so the rest of the text keeps
    its lines. Each marker carries the flags 3 and 4 in effect at its
    location ({!Typec_cpp.Location.flags}) and no enter or return flag,
    so the backend exempts the text from warnings as it would the tokens
    there, and the reader keeps the owner of every token. File names are
    written as the reader spelled them, escaped as in a line marker: the
    file of every token comes from a line marker or a [#line]
    directive.

    The ranges and pieces of the edits must be made from the tokens of
    [unit], and a bracket's declaration parsed from them. [emit] applies
    them {!in_order}; their ranges do not overlap, and the
    tokens an edit replaces belong to one file, so it never drops a
    marker that enters or leaves a file without its partner; [emit]
    raises [Invalid_argument] otherwise. *)
