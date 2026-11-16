(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** A token of preprocessed C text. *)

(** The encoding prefix of a character constant or a string literal
    (C11 6.4.4.4, 6.4.5). A character constant in C11 is never [Utf8]:
    [u8'a'] is the identifier [u8] followed by ['a']. *)
type encoding =
  | Plain  (** no prefix *)
  | Utf8  (** [u8] *)
  | Char16  (** [u] *)
  | Char32  (** [U] *)
  | Wide  (** [L] *)

(** What a token is. Keywords are identifiers here: whether [try] or
    [defer] is a keyword depends on the file the token belongs to, which
    the parser decides. *)
type kind =
  | Identifier of string
      (** an identifier, by its name in UTF-8 however [cc -E] wrote its
          characters: the one source of the name for every later stage *)
  | Number
      (** a preprocessing number (C11 6.4.8), which is not always a
          constant: the macOS SDK writes versions such as [10.13.4] in
          Clang's [availability] attribute. {!Number.classify} tells the
          constant it is where one is needed. *)
  | Character of encoding
  | String of encoding
  | Punctuator of Punctuator.t
  | Pragma  (** a [#pragma] line other than [#pragma typec] *)
  | Typec_pragma  (** a [#pragma typec] line, which [typec] consumes *)

(** A token is the bytes [start] to [start + length - 1] of the text it
    was read from, and [length] is at least 1. A pragma token is its whole
    line, from [#] up to the newline. [location] is where diagnostics
    place the token; [owner] is the file it belongs to. *)
type t = {
  kind : kind;
  start : int;
  length : int;
  owner : File.t;
  location : Location.t;
}
