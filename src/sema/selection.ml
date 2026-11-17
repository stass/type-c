(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type pattern =
  | Any
  | Constructor of constructor_pattern
  | Pointer of constructor_pattern

and constructor_pattern = {
  variant : Ctype.constructor array;
  index : int;
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

(* 2^22, provisional (P32): a match without nested patterns takes about
   four steps per label, so one of 2^20 labels fits, while a refusal
   still comes quickly. *)
let max_steps = 4_194_304

(* Lowering writes each node as a [switch] nested in the branch above it
   (design 13.5), one brace deeper; 127 nodes leave room within Clang's
   default bracket depth of 256 for the nesting around the match. *)
let max_depth = 127

type refusal = Too_many_steps | Too_deep

exception Refused of refusal

let name (constructor : Ctype.constructor) = constructor.constructor_name

module Slots = Map.Make (Int)

(* A position and the number that names it in one call of [select]: two
   places are at one position where their slots are equal, so a step of
   selection compares positions at a cost that does not grow with their
   depth (rule 10). *)
type place = { position : position; slot : int }

let scrutinee_place = { position = []; slot = 0 }

(* A step down from the place of slot [above], by the index of the
   constructor that holds the field, so that a lookup compares no
   names. *)
type step_key = {
  above : int;
  holder_index : int;
  field_index : int;
  pointer : bool;
}

module Below = Map.Make (struct
  type t = step_key

  let compare = compare
end)

(* The slots given so far in one call of [select], by the step down to
   each, and the count of them. A map rather than a hash table, so that
   no choice of input makes a lookup slow. *)
type slots = { mutable given : int Below.t; mutable count : int }

(* The place one [step] below [place], where [step.holder] is the
   constructor of index [holder_index] in the variant at [place]. *)
let below slots place ~holder_index step =
  let key =
    { above = place.slot; holder_index; field_index = step.field;
      pointer = step.through_pointer }
  in
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

(* A tag that a label asks for (rule 6): the constructor of index [named]
   in [variant] at [place]. *)
type test = { place : place; variant : Ctype.constructor array; named : int }

(* The tests of [pattern] at [place], in the order in which the label
   writes its constructor patterns. *)
let rec tests slots place (pattern : constructor_pattern) =
  { place; variant = pattern.variant; named = pattern.index }
  :: List.concat (List.mapi (field_tests slots place pattern) pattern.fields)

and field_tests slots place (holder : constructor_pattern) field sub_pattern =
  let field_place through_pointer =
    below slots place ~holder_index:holder.index
      { holder = name holder.variant.(holder.index); field; through_pointer }
  in
  match sub_pattern with
  | Any -> []
  | Constructor pattern -> tests slots (field_place false) pattern
  | Pointer pattern -> tests slots (field_place true) pattern

(* A case label that selection has not given up: its index among the
   labels, the tests that it has still to pass, the first at a tag not
   read, and the index of the constructor that it names at each slot. *)
type candidate = { label : int; remaining : test list; names : int Slots.t }

(* The label's own pattern is read against the constructors of the
   scrutinee, which the root reads. *)
let candidate slots scrutinee label (pattern : constructor_pattern) =
  let remaining =
    tests slots scrutinee_place { pattern with variant = scrutinee }
  in
  let names =
    List.fold_left
      (fun names test -> Slots.add test.place.slot test.named names)
      Slots.empty remaining
  in
  { label; remaining; names }

(* What a tag that selection has read holds: the constructor of an index
   that a label names there, or one of those that no label still
   possible names. *)
type held = One of int | Unnamed

(* The state of one call of [select]: the steps of selection taken so
   far (rule 10) and whether the match has a [default]. *)
type building = { mutable steps : int; with_default : bool }

(* The two bounds of rule 10 are checked here. Every step of selection
   is taken through [take], so the step bound holds the work of building
   the tree and, since every branch costs a step, its size; every node
   is made at a depth checked by [deepen], so the depth bound holds
   every path. *)
let take building steps =
  building.steps <- building.steps + steps;
  if building.steps > max_steps then raise (Refused Too_many_steps)

let deepen depth = if depth > max_depth then raise (Refused Too_deep)

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
      | Some (One held) when held = test.named ->
          advance building reads { candidate with remaining = rest }
      | Some (One _ | Unnamed) -> None)

(* The candidates at a node at [place], over a variant of [count]
   constructors, sorted: those whose next test reads the node's tag, by
   the index of the constructor that each names there, and the others,
   which ask for another tag first and so stay possible in every
   branch; each list in source order. *)
let sort place count candidates =
  let asking = Array.make count [] in
  let elsewhere = ref [] in
  List.iter
    (fun candidate ->
      match candidate.remaining with
      | test :: _ when test.place.slot = place.slot ->
          asking.(test.named) <- candidate :: asking.(test.named)
      | _ -> elsewhere := candidate :: !elsewhere)
    (List.rev candidates);
  (asking, !elsewhere)

(* Whether some candidate names, at [place], the constructor of each
   index of a variant of [count] constructors. *)
let named_at place count candidates =
  let named = Array.make count false in
  List.iter
    (fun candidate ->
      match Slots.find_opt place.slot candidate.names with
      | Some index -> named.(index) <- true
      | None -> ())
    candidates;
  named

let in_source_order first second =
  List.merge (fun one other -> compare one.label other.label) first second

(* The tree below the tags [reads], at [depth] from the root, where
   [candidates] are the labels that selection has not given up, in
   source order, each advanced past the tests that [reads] pass
   (rule 6). The first candidate is selected once it has passed every
   test; otherwise a node reads the tag that it asks for next. *)
let rec choose building ~depth candidates reads =
  match candidates with
  | [] -> Leaf (if building.with_default then Default else Nothing)
  | { label; remaining = []; _ } :: _ -> Leaf (Label label)
  | { remaining = test :: _; _ } :: _ ->
      deepen depth;
      Node
        { position = test.place.position;
          branches =
            branches building ~depth candidates reads test.place test.variant
        }

(* The branches of a node at [place], [depth] from the root, over the
   constructors [variant]. The constructors that no candidate names
   there lead to one subtree, since no label can tell them apart. A
   branch looks only at the candidates that it can keep: those that name
   its constructor there and those that ask for another tag first. Each
   candidate that the node sorts and each constructor that it sorts is
   a step, whether or not it names a constructor there. *)
and branches building ~depth candidates reads place variant =
  let count = Array.length variant in
  take building (List.length candidates + count);
  let asking, elsewhere = sort place count candidates in
  let named = named_at place count candidates in
  let branch constructors held kept =
    let reads = Slots.add place.slot held reads in
    { constructors;
      subtree =
        choose building ~depth:(depth + 1)
          (List.filter_map (advance building reads) kept)
          reads }
  in
  let own_indices, other_indices =
    List.partition (fun index -> named.(index)) (List.init count Fun.id)
  in
  let own =
    List.map
      (fun index ->
        branch [ variant.(index) ] (One index)
          (in_source_order asking.(index) elsewhere))
      own_indices
  in
  match List.map (fun index -> variant.(index)) other_indices with
  | [] -> own
  | others -> own @ [ branch others Unnamed elsewhere ]

let select scrutinee labels ~default =
  let building = { steps = 0; with_default = default } in
  let slots = { given = Below.empty; count = 0 } in
  let candidates = List.mapi (candidate slots scrutinee) labels in
  match
    branches building ~depth:1 candidates Slots.empty scrutinee_place
      scrutinee
  with
  | root_branches ->
      Ok { scrutinee = root_branches; labels = List.length labels; default }
  | exception Refused refusal -> Error refusal

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
      read : (int * value) list;
    }

(* 8: enough to show what is missing, while the work and the text of the
   error stay small whatever the size of the tree (rule 6). *)
let max_named = 8

type missing =
  | Nothing_missing
  | Scrutinee_constructors of { named : Ctype.constructor list; more : int }
  | Values of { named : value list; more : int }

(* A tag read on the way to a leaf, with the constructors of the branch
   taken. *)
type read = { at : position; holds : Ctype.constructor list }

(* Each leaf of nothing below [branches], at [position], before [found]
   in the reverse of the tree's order: the read into it and the reads
   above it, the nearest first. *)
let rec leaves_of_nothing found above position branches =
  List.fold_left
    (fun found branch ->
      let read = { at = position; holds = branch.constructors } in
      match branch.subtree with
      | Leaf Nothing -> (read, above) :: found
      | Leaf (Label _ | Default) -> found
      | Node { position; branches } ->
          leaves_of_nothing found (read :: above) position branches)
    found branches

(* The first [max_named] of [all] and the count of the others. *)
let named_first all =
  let named = List.filteri (fun index _ -> index < max_named) all in
  (named, List.length all - List.length named)

(* A position on one path by the field of each step: the holder of a
   step is the constructor that the path reads above it. *)
module Keys = Map.Make (struct
  type t = int list

  let compare = compare
end)

let key position = List.map (fun step -> step.field) position

let through_pointer position =
  match position with
  | [] -> false
  | nearest :: _ -> nearest.through_pointer

(* The value at the position of key [at], which holds [holder], where
   [chosen] gives each position read one constructor and whether a
   pointer leads to it, and [below] the fields read below each
   position, in order. Only the fields read are visited, so the work
   does not grow with the number of fields. *)
let rec value_at chosen below at ~through_pointer holder =
  let field_value field =
    let at = field :: at in
    let constructor, through_pointer = Keys.find at chosen in
    (field, value_at chosen below at ~through_pointer constructor)
  in
  let fields = Option.value (Keys.find_opt at below) ~default:[] in
  Holds
    { constructor = holder;
      through_pointer;
      read = List.map field_value (List.sort_uniq compare fields) }

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
  let add_below at _ below =
    match at with
    | [] -> below
    | field :: above ->
        let fields = Option.value (Keys.find_opt above below) ~default:[] in
        Keys.add above (field :: fields) below
  in
  let below = Keys.fold add_below keyed Keys.empty in
  match Keys.find_opt [] keyed with
  | Some (scrutinee, _) ->
      value_at keyed below [] ~through_pointer:false scrutinee
  | None -> invalid_arg "Selection.value_of_reads: the scrutinee is not read"

(* A leaf of nothing stands for a value for each constructor of the
   branch into it. Only the values named are built, each from the reads
   on its path, so the work is linear in the size of the tree. *)
let missing tree =
  match List.rev (leaves_of_nothing [] [] [] tree.scrutinee) with
  | [] -> Nothing_missing
  (* A branch of the root leads to nothing only where no label names its
     constructors, so it is the last branch of the root; where it is the
     only leaf of nothing, its constructors are named as such. *)
  | [ ({ at = []; holds }, _) ] ->
      let named, more = named_first holds in
      Scrutinee_constructors { named; more }
  | leaves ->
      let values =
        List.concat_map
          (fun (last, above) ->
            List.map (fun constructor -> ((last.at, constructor), above))
              last.holds)
          leaves
      in
      let named, more = named_first values in
      Values
        { named =
            List.map
              (fun (last, above) ->
                value_of_reads (last :: List.map first above))
              named;
          more }

(* Raised once a spelling holds more than the bytes asked for. *)
exception Spelled

let spelling ~most value =
  let text = Buffer.create 64 in
  let add piece =
    let room = most - Buffer.length text in
    if String.length piece <= room then Buffer.add_string text piece
    else begin
      Buffer.add_substring text piece 0 (room + 1);
      raise Spelled
    end
  in
  (* Each field adds at least one byte, so a long field list is cut
     after the bytes asked for. *)
  let rec write = function
    | Unread -> add "_"
    | Holds { constructor; through_pointer; read } ->
        if through_pointer then add "*";
        add (name constructor :> string);
        if constructor.fields <> [] then begin
          add "(";
          write_fields read 0 constructor.fields;
          add ")"
        end
  and write_fields read field = function
    | [] -> ()
    | _ :: later ->
        if field > 0 then add ", ";
        let read = write_field read field in
        write_fields read (field + 1) later
  and write_field read field =
    match read with
    | (at, value) :: rest when at = field ->
        write value;
        rest
    | _ ->
        write Unread;
        read
  in
  (try write value with Spelled -> ());
  Buffer.contents text
