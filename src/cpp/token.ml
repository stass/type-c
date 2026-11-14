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
    the parser decides. A punctuator keeps its spelling, digraphs
    included. *)
type kind =
  | Identifier
  | Integer  (** an integer constant, suffix included *)
  | Floating  (** a floating constant, suffix included *)
  | Version
      (** a preprocessing number such as [10.13.4] or [10_4] that is no
          constant but a version of Clang's [availability] attribute,
          which the macOS SDK uses; [10.13] is [Floating] and [10] is
          [Integer] *)
  | Character of encoding
  | String of encoding
  | Punctuator
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
