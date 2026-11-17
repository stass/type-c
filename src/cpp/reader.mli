(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Reading the output of [cc -E] into tokens.

    The input is the text that GCC or Clang writes for [-E -dD]: tokens,
    white space, line markers ([# N "file" flags]), [#line] directives,
    [#pragma] lines and definition lines ([#define] and [#undef], design
    13.3). A [#] that is the first byte of a line starts a directive;
    after a blank it is a punctuator. Comments, other directives and raw
    string literals are errors, as is any byte that starts no token.

    A definition line is no part of the unit's text: the reader reads
    the macro's name, skips the rest of the line without lexing it, and
    records the change in {!Macros.t}; {!rewrite} and {!length} leave the
    line out.

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

    A unit is a Type-C unit when its main file is Type-C text
    ({!File.is_type_c_text}, design 2.1), and a C unit otherwise; the
    files it enters do not change that. In front of the own text of a
    Type-C unit {!read} reads the universe text, {!File.universe_text},
    so that its tokens come first and keep their indices whatever the
    unit holds. They belong to {!File.universe} and are placed at its
    lines, and the unit's own text is then read as if it were alone. A C
    unit has no universe text.

    Reading takes time and memory linear in the size of the text and
    never recurses on it. *)

(** The text as [cc -E] wrote it, and the universe text in front of it
    where the unit is a Type-C unit. Only {!spelling} and {!rewrite} read
    it: a stage cannot slice it by token offsets and take the bytes of an
    identifier for its name. {!rewrite} gives the bytes for emission
    alone. *)
type text

(** The text, its tokens in order and its macros. The bytes before,
    between and after the tokens are white space, line markers and
    definition lines only, so the tokens with those gaps spell the text
    exactly. *)
type t = private { text : text; tokens : Token.t array; macros : Macros.t }

(** Why a text is not [cc -E] output: the message and the presumed
    location of the line where reading stopped. *)
type error = { location : Location.t; message : string }

val read : name:string -> string -> (t, error) result
(** [read ~name text] reads [text], which was read from the file [name]:
    the tokens are those of the universe text, where the unit is a
    Type-C unit, then those of [text]. [name] is the presumed file name
    until a line marker changes it, and its suffix does not decide the
    kind of the unit: the name in the marker that opens the main file
    does, which is the source path that [cc -E] was given. *)

(** An include line of the text of an interface, read in the output of
    [cc -E -dI] (design 9.3): its [directive], as ["include"], and its
    [header_name] with its delimiters, as ["\"a.tci\""] or
    ["<stdint.h>"]; [next_token] is the index of the token that follows it
    in the output, which may belong to the file it includes. *)
type include_line = {
  next_token : int;
  directive : string;
  header_name : string;
  location : Location.t;
}

(** A part of the text of an interface: an include line, or a token of
    the unit. *)
type own_part = Include_line of include_line | Own_token of Token.t

(** The output of the [-E -dI] step of an interface whose header is
    written: the unit, the include lines and tokens of the text of the
    interface in order, and whether that text holds a token or a
    directive line other than a line marker. The text of the interface is
    what the output holds while the main file is the current file at the
    bottom of the include stack, from the first line marker that places
    the main file at line 1 or later. From there the stack alone decides:
    a marker that names another file without entering or leaving one, as
    a [#line] writes, leaves the text where it is. *)
type interface = private {
  unit : t;
  own_text : own_part list;
  holds_text : bool;
}

val read_interface : name:string -> string -> (interface, error) result
(** [read_interface ~name text] is {!read} of the output of the [-E -dI]
    step of an interface. In the text of the interface it reads each
    [#include], [#include_next] and [#import] line exactly, as [-dI]
    writes it, and refuses every other directive that {!read} refuses; in
    deeper text it passes over every line that {!read} would refuse as a
    directive, since none reaches the header. The bytes of the lines it
    reads or passes over stay in the text, so {!rewrite} copies them. *)

val spelling : t -> Token.t -> string
(** [spelling result token] is what [token] means: the name that an
    identifier carries, in UTF-8, and the bytes of any other token. *)

val excerpt : t -> first:int -> last:int -> string
(** [excerpt result ~first ~last] spells the tokens from [first] to
    [last] with one space wherever white space or a line marker parts
    two of them in the text: how a message quotes a phrase of the
    source. *)

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
    of an identifier may differ from its {!spelling}. It holds no byte of
    the universe text, which the backend never reads, and no definition
    line, since Clang applies a [#define] that it reads in preprocessed
    input. The newline of a definition line outside every range stays,
    so the lines after it keep their numbers; a range drops the lines in
    it with their newlines, as it drops any. The ranges must be
    made from the tokens of [result], and none may start at a token of
    the universe text. Each starts at or after the token after the range
    before it, [first + count], so they do not overlap and insertions in
    front of one token keep their order; [Invalid_argument] otherwise. *)

val length : t -> int
(** [length result] is the bytes of the text as [cc -E] wrote it that
    {!rewrite} copies when it replaces nothing: the universe text and the
    definition lines are not among them. *)

val error_message : error -> string
(** ["file:line: error: message"], the form of a C compiler's errors, with
    every character that is not printable ASCII escaped as C writes it:
    a character of UTF-8 as a universal character name, and any other
    byte as [\xNN]. *)
