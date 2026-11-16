(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Reading the output of [cc -E] into tokens.

    The input is the text that GCC or Clang writes for [-E]: tokens,
    white space, line markers ([# N "file" flags]), [#line] directives and
    [#pragma] lines. A [#] that is the first byte of a line starts a
    directive; after a blank it is a punctuator. Comments and other
    directives are errors, as is any byte that starts no token.

    The name of an identifier, which its token carries, is in UTF-8,
    whether its extended characters are written as universal character
    names, as GCC writes them, or in UTF-8, as Clang does, so each name
    has one spelling; the text keeps the bytes as written, for emission
    alone. Each extended character must be one that C11 Annex D allows
    in an identifier, and a universal character name must name a
    character that C11 6.4.3p2 allows it to name.

    Every token belongs to a file (its owner, {!File.t}) and has a
    presumed location ({!Location.t}). The enter (1) and return (2) flags
    of the line markers keep a stack of the files being read, and the
    owner of a token is the top of that stack. A file is a system header
    when the marker that opened it carries flag 3. Any other line marker
    and [#line] change the presumed location only. The first line marker
    with a file name opens the main file, under the marker's name and
    flags; it is an error for that marker to enter a file, or for a
    token to come before it, as in text without line markers ([-P]),
    where no token can be placed in its file.

    GCC and Clang also write a marker with flag 3 and without flag 1 or 2
    for [#pragma GCC system_header], and GCC writes one around the tokens
    of a macro that a system header defines. Neither changes the owner,
    so the text after that pragma belongs to a file that is not a system
    header. The presumed location records the flags 3 and 4 in effect
    ({!Location.flags}), which decide what the backend exempts from
    warnings, whatever the owner.

    Reading takes time and memory linear in the size of the text and
    never recurses on it. *)

(** The text as [cc -E] wrote it, which only {!spelling} and {!rewrite}
    read: a stage cannot slice it by token offsets and take the bytes of
    an identifier for its name. {!rewrite} gives the bytes for emission
    alone. *)
type text

(** The text and its tokens in order. The bytes before, between and after
    the tokens are white space and line markers only, so the tokens with
    those gaps spell the text exactly. *)
type t = private { text : text; tokens : Token.t array }

(** Why a text is not [cc -E] output: the message and the presumed
    location of the line where reading stopped. *)
type error = { location : Location.t; message : string }

val read : name:string -> string -> (t, error) result
(** [read ~name text] reads [text], which was read from the file [name].
    [name] is the presumed file name until a line marker changes it. *)

val spelling : t -> Token.t -> string
(** [spelling result token] is what [token] means: the name that an
    identifier carries, in UTF-8, and the bytes of any other token. *)

(** The [count] tokens from the token [first], or the place in front of
    the token [first] when [count] is 0: what a replacement replaces.
    Only {!range} makes one, so it lies within the tokens it was made
    from. *)
type range = private { first : int; count : int }

val range : Token.t array -> first:int -> count:int -> range
(** [range tokens ~first ~count] is the range of [tokens], those of a
    {!t}, from [first]. [Invalid_argument] unless [first] is one of the
    tokens and [count] is at least 0 and at most the tokens from
    [first]. *)

val end_token : range -> int
(** The token on whose line a range ends: its last token, or the token
    in front of which an insertion goes. *)

(** [text] in place of the tokens of [range]. *)
type replacement = { range : range; text : string }

val rewrite : t -> replacement list -> string
(** [rewrite result replacements] is the text as [cc -E] wrote it with
    the replacements made: the bytes that emission copies, in which those
    of an identifier may differ from its {!spelling}. The ranges must be
    made from the tokens of [result]. Each starts at or after the token
    after the range before it, [first + count], so they do not overlap
    and insertions in front of one token keep their order;
    [Invalid_argument] otherwise. *)

val error_message : error -> string
(** ["file:line: message"], the form of a C compiler's diagnostics, with
    every character that is not printable ASCII escaped as C writes it:
    a character of UTF-8 as a universal character name, and any other
    byte as [\xNN]. *)
