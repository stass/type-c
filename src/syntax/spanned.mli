(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one way to build a node of the syntax tree, {!Tree.spanned}, which
    re-exports these types. A node is private, so it is built only by
    {!make}, which counts it, or as a name that holds no node, and the
    bound that the counter holds on the depth of the tree covers every
    node (design 13.7).

    A node is counted after its parts, which exist before {!make} is
    called, and its caller keeps one rule: a node's span holds the spans
    of its parts. Then, of the nodes counted before a node and not yet
    inside another, those whose first token lies in its span are its
    parts or inside them, so the node is one taller than the tallest of
    them, whatever loop or recursion read it. *)

type span = { first : int; last : int }

type +'a t = private { span : span; node : 'a }

type counter
(** The nodes of one tree made so far, as far as heights need them. *)

val counter : max_depth:int -> counter
(** A tree with no nodes, whose nodes may be [max_depth] high. *)

val make : counter -> span -> 'a -> 'a t option
(** [make counter span node] counts and makes a node with [span], made
    after its parts, or gives None where it would be more than the
    counter's [max_depth] high. *)

val identifier : span -> string -> string t
(** A name at [span], outside the count. It holds no node, so the height
    it misses is one level, which no chain of names can repeat. *)
