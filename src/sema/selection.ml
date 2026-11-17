(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type pattern =
  | Any
  | Constructor of constructor_pattern
  | Pointer of constructor_pattern

and constructor_pattern = {
  variant : Ctype.constructor list;
  constructor : Ctype.constructor;
  fields : pattern list;
}

type step = {
  holder : Spelling.constructor;
  field : int;
  through_pointer : bool;
}

type position = step list
type leaf = Label of int | Default | Nothing

type tree =
  | Leaf of leaf
  | Node of { position : position; branches : branch list }

and branch = { constructors : Ctype.constructor list; subtree : tree }

type t = { scrutinee : branch list; labels : int; default : bool }

(* 2^22, provisional (P32): a match without nested patterns, of L labels
   over as many constructors, takes about L * L steps, so one of 2046
   labels fits, while a refusal still comes quickly. *)
let max_steps = 4_194_304

type refusal = Too_many_steps

exception Too_many_steps_taken

let name (constructor : Ctype.constructor) = constructor.constructor_name

module Slots = Map.Make (Int)
module Names = Set.Make (String)

(* A position and the number that names it in one call of [select]: two
   places are at one position where their slots are equal, so a step of
   selection compares positions at a cost that does not grow with their
   depth (rule 10). *)
type place = { position : position; slot : int }

let scrutinee_place = { position = []; slot = 0 }

module Below = Map.Make (struct
  type t = int * step

  let compare = compare
end)

(* The slots given so far in one call of [select], by the slot of the
   place above and the step down from it, and the count of them. A map
   rather than a hash table, so that no choice of constructor names
   makes a lookup slow. *)
type slots = { mutable given : int Below.t; mutable count : int }

(* The place one [step] below [place]. *)
let below slots place step =
  let key = (place.slot, step) in
  let slot =
    match Below.find_opt key slots.given with
    | Some slot -> slot
    | None ->
        (* The scrutinee holds slot 0. *)
        slots.count <- slots.count + 1;
        slots.given <- Below.add key slots.count slots.given;
        slots.count
  in
  { position = step :: place.position; slot }

(* A tag that a label asks for (rule 6): the constructor [named] at
   [place], whose variant has the constructors [variant]. *)
type test = {
  place : place;
  variant : Ctype.constructor list;
  named : Ctype.constructor;
}

(* The tests of [pattern] at [place], in the order in which the label
   writes its constructor patterns. *)
let rec tests slots place (pattern : constructor_pattern) =
  { place; variant = pattern.variant; named = pattern.constructor }
  :: List.concat
       (List.mapi
          (field_tests slots place pattern.constructor)
          pattern.fields)

and field_tests slots place (holder : Ctype.constructor) field sub_pattern =
  let field_place through_pointer =
    below slots place { holder = name holder; field; through_pointer }
  in
  match sub_pattern with
  | Any -> []
  | Constructor pattern -> tests slots (field_place false) pattern
  | Pointer pattern -> tests slots (field_place true) pattern

(* A label that selection has not given up: its index, the tests that
   it has still to pass, the first at a tag not read, and the
   constructor that it names at each slot. *)
type candidate = {
  index : int;
  remaining : test list;
  names : Spelling.constructor Slots.t;
}

let candidate slots index pattern =
  let remaining = tests slots scrutinee_place pattern in
  let names =
    List.fold_left
      (fun names test -> Slots.add test.place.slot (name test.named) names)
      Slots.empty remaining
  in
  { index; remaining; names }

(* What a tag that selection has read holds: one constructor that a
   label names there, or one of those that no label still possible
   names. *)
type held = One of Spelling.constructor | Unnamed

(* The state of one call of [select]: the steps of selection taken so
   far (rule 10) and whether the match has a [default]. *)
type building = { mutable steps : int; with_default : bool }

(* Every step of selection is taken here, so the bound holds the work of
   building the tree and, since every branch costs a step, its size. *)
let take building steps =
  building.steps <- building.steps + steps;
  if building.steps > max_steps then raise Too_many_steps_taken

(* [candidate] past the tests that the tags [reads] pass, or [None]
   where its next test reads a tag that holds another constructor: the
   label is then given up before it reads another tag (rule 6), so it
   is dropped at once. Each look at the label's next test is a step. *)
let rec advance building reads candidate =
  take building 1;
  match candidate.remaining with
  | [] -> Some candidate
  | test :: rest -> (
      match Slots.find_opt test.place.slot reads with
      | None -> Some candidate
      | Some (One held) when held = name test.named ->
          advance building reads { candidate with remaining = rest }
      | Some (One _ | Unnamed) -> None)

(* The tree below the tags [reads], where [candidates] are the labels
   that selection has not given up, in source order, each advanced past
   the tests that [reads] pass (rule 6). The first candidate is selected
   once it has passed every test; otherwise a node reads the tag that it
   asks for next. *)
let rec choose building candidates reads =
  match candidates with
  | [] -> Leaf (if building.with_default then Default else Nothing)
  | { index; remaining = []; _ } :: _ -> Leaf (Label index)
  | { remaining = test :: _; _ } :: _ ->
      Node
        { position = test.place.position;
          branches = branches building candidates reads test.place test.variant
        }

(* The branches of a node at [place] over a variant of the
   constructors [variant]. The constructors that no candidate names
   there lead to one subtree, since no label can tell them apart. Each
   candidate that the node looks at and each constructor that it sorts
   is a step. *)
and branches building candidates reads place variant =
  take building (List.length candidates + List.length variant);
  let named =
    List.fold_left
      (fun named candidate ->
        match Slots.find_opt place.slot candidate.names with
        | Some constructor -> Names.add (constructor :> string) named
        | None -> named)
      Names.empty candidates
  in
  let is_named constructor = Names.mem (name constructor :> string) named in
  let branch constructors held =
    let reads = Slots.add place.slot held reads in
    { constructors;
      subtree =
        choose building
          (List.filter_map (advance building reads) candidates)
          reads }
  in
  let own =
    List.map
      (fun constructor -> branch [ constructor ] (One (name constructor)))
      (List.filter is_named variant)
  in
  match List.filter (fun c -> not (is_named c)) variant with
  | [] -> own
  | others -> own @ [ branch others Unnamed ]

let select scrutinee labels ~default =
  let building = { steps = 0; with_default = default } in
  let slots = { given = Below.empty; count = 0 } in
  let candidates = List.mapi (candidate slots) labels in
  match
    branches building candidates Slots.empty scrutinee_place scrutinee
  with
  | root_branches ->
      Ok { scrutinee = root_branches; labels = List.length labels; default }
  | exception Too_many_steps_taken -> Error Too_many_steps

(* [visit] applied to each leaf below [branches], in time linear in the
   size of the tree whatever its depth. *)
let rec iter_leaves visit branches =
  List.iter
    (fun branch ->
      match branch.subtree with
      | Leaf leaf -> visit leaf
      | Node { branches; _ } -> iter_leaves visit branches)
    branches

let never_selected tree =
  let selected = Array.make tree.labels false in
  iter_leaves
    (function
      | Label index -> selected.(index) <- true
      | Default | Nothing -> ())
    tree.scrutinee;
  List.filter
    (fun index -> not selected.(index))
    (List.init tree.labels Fun.id)

let default_never_selected tree =
  let defaults = ref false in
  iter_leaves (fun leaf -> if leaf = Default then defaults := true)
    tree.scrutinee;
  tree.default && not !defaults

let defaulted tree =
  List.concat_map
    (fun branch ->
      match branch.subtree with
      | Leaf Default -> branch.constructors
      | Leaf (Label _ | Nothing) | Node _ -> [])
    tree.scrutinee

type value =
  | Unread
  | Holds of {
      constructor : Ctype.constructor;
      through_pointer : bool;
      fields : value list;
    }

type missing =
  | Nothing_missing
  | Scrutinee_constructors of Ctype.constructor list
  | Values of value list

(* A tag read on the way to a leaf, with the constructors of the branch
   taken. *)
type read = { at : position; holds : Ctype.constructor list }

(* The read into the first leaf of nothing below [branches], at
   [position], and the reads above it, the nearest first. *)
let rec path_to_nothing above position branches =
  List.find_map
    (fun branch ->
      let read = { at = position; holds = branch.constructors } in
      match branch.subtree with
      | Leaf Nothing -> Some (read, above)
      | Leaf (Label _ | Default) -> None
      | Node { position; branches } ->
          path_to_nothing (read :: above) position branches)
    branches

(* A position by the constructor and the field of each step, which name
   it whatever the steps say of pointers. *)
module Keys = Map.Make (struct
  type t = (Spelling.constructor * int) list

  let compare = compare
end)

let key position = List.map (fun step -> (step.holder, step.field)) position

let through_pointer position =
  match position with
  | [] -> false
  | nearest :: _ -> nearest.through_pointer

(* The value at the position of key [at], which holds [holder], where
   [chosen] gives each position read one constructor and whether a
   pointer leads to it. *)
let rec value_at chosen at ~through_pointer holder =
  let field_value field _ =
    let below = (name holder, field) :: at in
    match Keys.find_opt below chosen with
    | None -> Unread
    | Some (constructor, through_pointer) ->
        value_at chosen below ~through_pointer constructor
  in
  Holds
    { constructor = holder;
      through_pointer;
      fields = List.mapi field_value holder.fields }

(* A branch above the leaf is named by its first constructor; a branch
   holds at least one. *)
let first read =
  match read.holds with
  | constructor :: _ -> (read.at, constructor)
  | [] -> invalid_arg "Selection.first: a branch of no constructor"

(* The value that the reads [chosen] give; every path reads the
   scrutinee first. *)
let value_of_reads chosen =
  let keyed =
    List.fold_left
      (fun keyed (at, constructor) ->
        Keys.add (key at) (constructor, through_pointer at) keyed)
      Keys.empty chosen
  in
  match Keys.find_opt [] keyed with
  | Some (scrutinee, _) -> value_at keyed [] ~through_pointer:false scrutinee
  | None -> invalid_arg "Selection.value_of_reads: the scrutinee is not read"

let missing tree =
  match path_to_nothing [] [] tree.scrutinee with
  | None -> Nothing_missing
  | Some ({ at = []; holds }, _) -> Scrutinee_constructors holds
  | Some (last, above) ->
      let chosen_above = List.map first above in
      Values
        (List.map
           (fun constructor ->
             value_of_reads ((last.at, constructor) :: chosen_above))
           last.holds)

let rec spelling = function
  | Unread -> "_"
  | Holds { constructor; through_pointer; fields } ->
      let star = if through_pointer then "*" else "" in
      let fields =
        match fields with
        | [] -> ""
        | _ -> "(" ^ String.concat ", " (List.map spelling fields) ^ ")"
      in
      star ^ (name constructor :> string) ^ fields
