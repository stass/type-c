(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Parsing the tokens of preprocessed text into a {!Tree.translation_unit}
    (design 13.3): recursive descent over the complete token array.

    The parser is the one implementation of the scope rules of C11
    (6.2.1, the name spaces of 6.2.3 that scopes hold, and the tags of
    6.7.2.3): it decides where each scope begins and ends, records in the
    tree each declaration with the one it redeclares and each use with
    the declaration it resolves to ({!Tree.declared}), and reads a name
    as a typedef name where its visible declaration is one. It needs the
    kind of a name, never its type.

    The grammar is C11's declarations, expressions and statements (C11
    6.5, 6.7, 6.8, 6.9) and the GNU profile's (design 13.3). The body of
    a function that a system header defines is matched brace for brace
    and kept as a span, and so are the arguments of an attribute. A
    construct outside them, such as a C23 attribute ([[[nodiscard]]]), is
    an error that names the token where it starts.

    Pragma tokens ([#pragma] lines, including those that [_Pragma] writes
    in the middle of an expression, and [#pragma typec] lines) are not
    part of the grammar: the parser passes over them, and the node around
    them holds them in its span, so emission keeps them in place.

    Parsing takes time linear in the number of tokens, up to a logarithmic
    factor for each name it looks up, and its recursion is bounded by
    {!max_nesting}. *)

open Typec_cpp

(** Why the tokens are not a C11 translation unit: the presumed location
    of the token where parsing stopped, and a message that names what the
    grammar expected there and the token it found. *)
type error = Reader.error = { location : Location.t; message : string }

val max_nesting : int
(** The most brackets ([(], [[], [{]) and conditional operators that the
    parser accepts open at once; one more is an error. *)

val parse :
  keywords:Keyword_set.t ->
  Reader.t ->
  (Tree.translation_unit, error) result
(** [parse ~keywords text] parses [text] with [keywords], those that
    the backend reads it with ([Typec_sema.Target.keywords]). File scope
    holds the typedef names that GCC and Clang declare before the first
    token for a backend with [keywords] ({!Builtin_typedef.declared}). *)

(** What file scope declares at the end of a unit (C11 6.2.1p4), sorted
    by name: each ordinary identifier and each tag with its last
    declaration there, wherever in the unit it is declared, including the
    tags and enumerators that a type declaration claims (design 10.1 rule
    6) and the builtin typedef names that {!parse} declares there. *)
type file_scope = {
  ordinary : (string * Tree.reference) list;
  tags : (string * Tree.tag_id) list;
}

val parse_with_file_scope :
  keywords:Keyword_set.t ->
  Reader.t ->
  (Tree.translation_unit * file_scope, error) result
(** {!parse}, and what file scope declares where the unit ends, for a
    test that names what a unit declares there. *)

val error_message : error -> string
(** ["file:line: message"], as {!Reader.error_message}. *)
