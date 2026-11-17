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

(* 2^16, provisional (P32): far above what a written match needs, and
   small enough that the checks build the tree quickly. *)
let max_size = 65536

type refusal = Too_large

exception Too_large_tree

let name (constructor : Ctype.constructor) = constructor.constructor_name

module Positions = Map.Make (struct
  type t = position

  let compare = compare
end)

module Names = Set.Make (String)

(* A tag that a label asks for (rule 6): the constructor [named] at
   [position], whose variant has the constructors [variant]. *)
type test = {
  position : position;
  variant : Ctype.constructor list;
  named : Ctype.constructor;
}

(* The tests of [pattern] at [position], in the order in which the label
   writes its constructor patterns. *)
let rec tests position (pattern : constructor_pattern) =
  { position; variant = pattern.variant; named = pattern.constructor }
  :: List.concat
       (List.mapi (field_tests position pattern.constructor) pattern.fields)

and field_tests position (holder : Ctype.constructor) field sub_pattern =
  let below through_pointer =
    position @ [ { holder = name holder; field; through_pointer } ]
  in
  match sub_pattern with
  | Any -> []
  | Constructor pattern -> tests (below false) pattern
  | Pointer pattern -> tests (below true) pattern

(* A label that selection has not given up: its index, the tests that
   it has still to pass, the first at a tag not read, and the
   constructor that it names at each position. *)
type candidate = {
  index : int;
  remaining : test list;
  names : Spelling.constructor Positions.t;
}

let candidate index pattern =
  let remaining = tests [] pattern in
  let names =
    List.fold_left
      (fun names test -> Positions.add test.position (name test.named) names)
      Positions.empty remaining
  in
  { index; remaining; names }

(* What a tag that selection has read holds: one constructor that a
   label names there, or one of those that no label still possible
   names. *)
type held = One of Spelling.constructor | Unnamed

(* [candidate] past the tests that the tags [reads] pass, or [None]
   where its next test reads a tag that holds another constructor: the
   label is then given up before it reads another tag (rule 6), so it
   is dropped at once. *)
let rec advance reads candidate =
  match candidate.remaining with
  | [] -> Some candidate
  | test :: rest -> (
      match Positions.find_opt test.position reads with
      | None -> Some candidate
      | Some (One held) when held = name test.named ->
          advance reads { candidate with remaining = rest }
      | Some (One _ | Unnamed) -> None)

(* The state of one call of [select]: the count of nodes and leaves made
   so far and whether the match has a [default]. *)
type building = { mutable size : int; with_default : bool }

let count building =
  building.size <- building.size + 1;
  if building.size > max_size then raise Too_large_tree

(* The tree below the tags [reads], where [candidates] are the labels
   that selection has not given up, in source order, each advanced past
   the tests that [reads] pass (rule 6). The first candidate is selected
   once it has passed every test; otherwise a node reads the tag that it
   asks for next. *)
let rec choose building candidates reads =
  count building;
  match candidates with
  | [] -> Leaf (if building.with_default then Default else Nothing)
  | { index; remaining = []; _ } :: _ -> Leaf (Label index)
  | { remaining = test :: _; _ } :: _ ->
      Node
        { position = test.position;
          branches =
            branches building candidates reads test.position test.variant }

(* The branches of a node at [position] over a variant of the
   constructors [variant]. The constructors that no candidate names
   there lead to one subtree, since no label can tell them apart. *)
and branches building candidates reads position variant =
  let named =
    List.fold_left
      (fun named candidate ->
        match Positions.find_opt position candidate.names with
        | Some constructor -> Names.add (constructor :> string) named
        | None -> named)
      Names.empty candidates
  in
  let is_named constructor = Names.mem (name constructor :> string) named in
  let branch constructors held =
    let reads = Positions.add position held reads in
    { constructors;
      subtree =
        choose building (List.filter_map (advance reads) candidates) reads }
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
  let building = { size = 0; with_default = default } in
  let candidates = List.mapi candidate labels in
  let root () =
    count building;
    branches building candidates Positions.empty [] scrutinee
  in
  match root () with
  | root_branches ->
      Ok { scrutinee = root_branches; labels = List.length labels; default }
  | exception Too_large_tree -> Error Too_large

let rec leaves = function
  | Leaf leaf -> [ leaf ]
  | Node { branches; _ } -> branch_leaves branches

and branch_leaves branches =
  List.concat_map (fun branch -> leaves branch.subtree) branches

let never_selected tree =
  let selected = Array.make tree.labels false in
  List.iter
    (function
      | Label index -> selected.(index) <- true
      | Default | Nothing -> ())
    (branch_leaves tree.scrutinee);
  List.filter
    (fun index -> not selected.(index))
    (List.init tree.labels Fun.id)

let default_never_selected tree =
  tree.default && not (List.mem Default (branch_leaves tree.scrutinee))

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
  match List.rev position with
  | [] -> false
  | last :: _ -> last.through_pointer

(* The value at the position of key [at], which holds [holder], where
   [chosen] gives each position read one constructor and whether a
   pointer leads to it. *)
let rec value_at chosen at ~through_pointer holder =
  let field_value field _ =
    let below = at @ [ (name holder, field) ] in
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
