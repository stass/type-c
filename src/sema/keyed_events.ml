(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A binary trie over the bits of the index: a node of height [h] spans
   the [2^h] indices from a multiple of [2^h], and its two halves are
   the nodes of height [h - 1] below it. Its shape follows from the
   indices it holds, so it needs no balancing. A leaf holds the one
   event of the span of its node, at any height, which keeps a sparse
   trie shallow; a split keeps the least key below it, so that a query
   passes over a whole node whose least key is not below its bound. *)

type 'a event = { index : int; key : int; value : 'a }

type 'a node =
  | Empty
  | Leaf of 'a event
  | Split of { least_key : int; low : 'a node; high : 'a node }

(* The root spans the indices from 0 to before [2^height]. *)
type 'a t = { height : int; root : 'a node }

let empty = { height = 0; root = Empty }

(* An empty node holds no key, so no bound passes over less of it. *)
let least_key = function
  | Empty -> max_int
  | Leaf event -> event.key
  | Split split -> split.least_key

let split low high =
  Split { least_key = min (least_key low) (least_key high); low; high }

(* [events] grown until its root spans [index]; the old root is the low
   half of each new one, and an empty root stays empty. An index stays
   below [Sys.max_array_length], so [1 lsl height] does not overflow. *)
let rec spanning index events =
  if index < 1 lsl events.height then events
  else
    let root =
      match events.root with
      | Empty -> Empty
      | Leaf _ | Split _ -> split events.root Empty
    in
    spanning index { height = events.height + 1; root }

(* [node], of height [height], with [event] at its index in place of the
   event there. A leaf of another index moves into the half of a split
   that spans it first; two indices in one span make its height at
   least 1, so [half] is never negative. *)
let rec added height event node =
  match node with
  | Empty -> Leaf event
  | Leaf old when old.index = event.index -> Leaf event
  | Leaf old -> added height event (into_half height old Empty Empty)
  | Split { low; high; _ } -> into_half height event low high

(* The split of height [height] with halves [low] and [high], [event]
   added to the one that spans its index. *)
and into_half height event low high =
  let half = height - 1 in
  if event.index land (1 lsl half) = 0 then split (added half event low) high
  else split low (added half event high)

let add index ~key value events =
  let events = spanning index events in
  let root = added events.height { index; key; value } events.root in
  { events with root }

type query = { from : int; before : int; key_below : int }

let takes query event =
  query.from <= event.index && event.index < query.before
  && event.key < query.key_below

(* Whether a query reads nothing of a split whose least key is
   [least_key], of height [height], that spans the indices from
   [first]. *)
let passes_over query ~first ~height least_key =
  least_key >= query.key_below
  || first >= query.before
  || first + (1 lsl height) <= query.from

(* The events of [node], of height [height], that spans the indices from
   [first], that [query] reads, followed by [rest]. *)
let rec taken query ~first ~height node rest () =
  match node with
  | Empty -> rest ()
  | Leaf event when takes query event ->
      Seq.Cons ((event.index, event.value), rest)
  | Leaf _ -> rest ()
  | Split { least_key; _ } when passes_over query ~first ~height least_key ->
      rest ()
  | Split { low; high; _ } ->
      let half = height - 1 in
      let middle = first + (1 lsl half) in
      let high_then_rest = taken query ~first:middle ~height:half high rest in
      taken query ~first ~height:half low high_then_rest ()

let between events ~from ~before ~key_below =
  let query = { from; before; key_below } in
  taken query ~first:0 ~height:events.height events.root Seq.empty
