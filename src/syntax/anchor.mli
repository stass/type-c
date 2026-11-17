(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The places where emission may put a packing bracket (design 10.3),
    whose pragma lines take lines of their own and so must never stand
    inside an expression: in front of an external declaration, after
    the forward declaration that lowering writes for a type declaration
    at file scope, and after the last token. The parser alone names
    them: {!Tree}
    re-exports both types private and this module is private to the
    library, so other code reads an anchor or an item but makes
    neither. *)

(** An insertion in front of the token [before] of [Reader.t.tokens], or
    after the last token where [before] is the number of tokens. *)
type t = private { before : int }

val before : int -> t

(** An external declaration, which the parser read at file scope, so
    that its first token is an anchor. *)
type 'a item = private { declaration : 'a }

val item : 'a -> 'a item
