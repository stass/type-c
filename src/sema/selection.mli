(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The selection tree of a match (design 4.7 rule 6): the tags that
    selection reads, laid out by what each can hold, with the label that
    each value selects at a leaf. What a match misses, the labels that it
    never selects (4.2) and the tags that it checks (4.5) are read from
    the tree and decided nowhere else; a match without nested patterns
    has a tree of one node. *)

open Typec_syntax

(** A sub-pattern as selection sees it. [Any] is [_], a binding or a
    typed binding, which match every value and read no tag; [Pointer p]
    is [*p] at a position that points to a variant (4.7 rule 5). *)
type pattern =
  | Any
  | Constructor of constructor_pattern
  | Pointer of constructor_pattern

(** A constructor pattern at a position: [variant] holds the
    constructors of the position's variant in declaration order,
    [constructor] is the one named, and [fields] holds one sub-pattern
    per field, or none where a test leaves the field list out (4.6
    rule 2), which reads no tag below. The [variant] of a label's own
    pattern is not read, since {!select} takes the scrutinee's. *)
and constructor_pattern = {
  variant : Ctype.constructor list;
  constructor : Ctype.constructor;
  fields : pattern list;
}

(** One step down from a position: field [field] (from 0) of the
    constructor [holder] that the position holds, followed through a
    pointer where [through_pointer]. *)
type step = {
  holder : Spelling.constructor;
  field : int;
  through_pointer : bool;
}

type position = step list
(** The steps from the scrutinee, which is [[]], to a position. *)

(** What a value selects: the case label of that index among the case
    labels in source order, the [default], or nothing. *)
type leaf = Label of int | Default | Nothing

(** A node reads the tag at [position] and has a branch for each of its
    constructors that a label still possible on the tags read above it
    names there, in declaration order, then one branch for all the
    others, if any, which no such label can tell apart. A branch holds one or
    more constructors. *)
type tree =
  | Leaf of leaf
  | Node of { position : position; branches : branch list }

and branch = { constructors : Ctype.constructor list; subtree : tree }

(** The tree of a match. Its root reads the tag of the scrutinee, which
    every match checks (4.5), so [scrutinee] holds the root's branches.
    [labels] counts the case labels and [default] says whether there is
    a [default]. *)
type t = private { scrutinee : branch list; labels : int; default : bool }

val max_size : int
(** The most nodes and leaves in one tree, a translation limit of typec
    (design 4.7 rule 10). *)

(** Why there is no tree: it would hold more than {!max_size} nodes and
    leaves. *)
type refusal = Too_large

val select :
  Ctype.constructor list ->
  constructor_pattern list ->
  default:bool ->
  (t, refusal) result
(** [select scrutinee labels ~default] is the tree of a match whose
    scrutinee's variant has the constructors [scrutinee], in declaration
    order, whose case labels have the patterns [labels] in source order,
    and which has a [default] where [default]. *)

(** A value as a pattern that a label could hold: [Unread] is a position
    that selection did not read, written [_]. *)
type value =
  | Unread
  | Holds of {
      constructor : Ctype.constructor;
      through_pointer : bool;
      fields : value list;
    }

(** What a match misses, read from the first leaf of nothing (4.2 rule
    1): nothing; constructors of the scrutinee, where that leaf is a
    branch of the root, below which selection reads nothing; or values,
    one for each constructor of the branch into the leaf. A branch
    above it of several constructors is named by its first. *)
type missing =
  | Nothing_missing
  | Scrutinee_constructors of Ctype.constructor list
  | Values of value list

val missing : t -> missing

val never_selected : t -> int list
(** The indices of the case labels that are no leaf, in source order. *)

val default_never_selected : t -> bool
(** Whether the match has a [default] that is no leaf. *)

val defaulted : t -> Ctype.constructor list
(** The constructors of the scrutinee all of whose values the [default]
    takes: those of the root's branches that are a leaf of the
    [default]. *)

val spelling : value -> string
(** [value] as it is written in a label: [Err(Overflow)],
    [Add(_, *Num(_))]. *)
