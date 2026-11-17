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
    constructors of the position's variant in declaration order, which
    selection does not change, so that the patterns at positions of one
    variant can share it; [index] is the index in [variant] of the one
    named; and [fields] holds one sub-pattern per field, or none where a
    test leaves the field list out (4.6 rule 2), which reads no tag
    below. The [variant] of a label's own pattern is not read, since
    {!select} takes the scrutinee's. *)
and constructor_pattern = {
  variant : Ctype.constructor array;
  index : int;
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
(** The steps from a position up to the scrutinee, which is [[]], the
    nearest first, so that the position one step below shares the list of
    the position above it. *)

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

(** What building one tree took, which the bounds of rule 10 limit: the
    steps of selection ({!max_steps}), the nodes, and the nodes on the
    deepest path, the root counted ({!max_depth}). *)
type size = { steps : int; nodes : int; depth : int }

(** The tree of a match. Its root reads the tag of the scrutinee, which
    every match checks (4.5), so [scrutinee] holds the root's branches.
    [labels] counts the case labels, [default] says whether there is
    a [default] and [size] what building the tree took. *)
type t = private {
  scrutinee : branch list;
  labels : int;
  default : bool;
  size : size;
}

val max_steps : int
(** The most steps of selection in building one tree: each label that a
    node looks at to sort it, each constructor that it sorts into a
    branch and each look at a label's next test below a branch. A
    translation limit of typec (design 4.7 rule 10), which bounds the
    work of {!select} and the size of the tree. *)

val max_depth : int
(** The most nodes on one path of a tree, from the root to a leaf, which
    lowering writes as nested [switch] statements (design 13.5). A
    translation limit of typec (design 4.7 rule 10). *)

(** Why there is no tree: building it takes more than {!max_steps}
    steps, or the tree is deeper than {!max_depth}. *)
type refusal = Too_many_steps | Too_deep

val select :
  Ctype.constructor array ->
  constructor_pattern list ->
  default:bool ->
  (t, refusal) result
(** [select scrutinee labels ~default] is the tree of a match whose
    scrutinee's variant has the constructors [scrutinee], in declaration
    order, whose case labels have the patterns [labels] in source order,
    and which has a [default] where [default]. *)

(** A value as a pattern that a label could hold: [Unread] is a position
    that selection did not read, written [_]. [read] holds the value of
    each field read, by its index from 0, in increasing order; every
    other field is [Unread], so a value has the size of the reads on
    its path, not of the fields of its constructors. *)
type value =
  | Unread
  | Holds of {
      constructor : Ctype.constructor;
      through_pointer : bool;
      read : (int * value) list;
    }

val max_named : int
(** The most missing values that {!missing} names. *)

(** What a match misses (4.2 rule 1), read from its leaves of nothing:
    nothing; constructors of the scrutinee, where the one such leaf is a
    branch of the root, below which selection reads nothing; or values,
    one for each constructor of the branch into each leaf, in the tree's
    order. A branch above a leaf of several constructors is named by its
    first. Either names the first {!max_named} and counts the [more]
    after them. *)
type missing =
  | Nothing_missing
  | Scrutinee_constructors of { named : Ctype.constructor list; more : int }
  | Values of { named : value list; more : int }

val missing : t -> missing

val never_selected : t -> int list
(** The indices of the case labels that are no leaf, in source order. *)

val default_never_selected : t -> bool
(** Whether the match has a [default] that is no leaf. *)

val defaulted : t -> Ctype.constructor list
(** The constructors of the scrutinee all of whose values the [default]
    takes: those of the root's branches that are a leaf of the
    [default]. *)

val spelling : most:int -> value -> string
(** [value] as it is written in a label, [Err(Overflow)] or
    [Add(_, *Num(_))], cut after [most] + 1 bytes, so that a caller that
    shows [most] can tell that it was cut; the work does not grow beyond
    that. *)
