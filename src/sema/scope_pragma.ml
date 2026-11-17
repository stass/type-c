(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

let state_pragma =
  Rule.message Deferred_pragma
    "a `#pragma` line in the scope of a defer statement that is not one \
     of the pragmas that annotate only the loop after them: a copy of the \
     deferred statement at an exit after it would be compiled under what \
     the pragma sets, and not as at the defer statement"

let pragma_before_exit =
  Rule.message Deferred_pragma
    "a `#pragma` line in the scope of a defer statement directly before \
     an exit of the scope, the end of its block, or a statement or \
     declaration that holds an exit, where lowering writes text that the \
     pragma would reach"

let is_pragma (token : Token.t) =
  match token.kind with
  | Pragma _ | Typec_pragma -> true
  | Identifier _ | Number | Character _ | String _ | Punctuator _ -> false

let is_loop_pragma (token : Token.t) =
  match token.kind with
  | Pragma (Identifiers names) -> Statement_pragma.is_loop_pragma names
  | Pragma (Not_tokens _) | Typec_pragma | Identifier _ | Number
  | Character _ | String _ | Punctuator _ ->
      false

(* The indices of the span, none where it is empty. *)
let indices (span : Tree.span) =
  List.init (max 0 (span.last - span.first + 1)) (fun offset ->
      span.first + offset)

(* The tokens of the scopes, each once: two scopes nest or lie apart,
   as each runs to the end of a block or an arm. *)
let union (scopes : Tree.span list) =
  let by_first (a : Tree.span) (b : Tree.span) = Int.compare a.first b.first in
  let add kept (scope : Tree.span) =
    match kept with
    | (outer : Tree.span) :: rest when scope.first <= outer.last ->
        { outer with last = max outer.last scope.last } :: rest
    | _ -> scope :: kept
  in
  let nonempty (scope : Tree.span) = scope.first <= scope.last in
  List.filter nonempty scopes |> List.sort by_first
  |> List.fold_left add [] |> List.rev

(* The pragma lines of the deferred statements, which move with them to
   their copies; the parser decides which they may hold. *)
let moved_pragmas tokens (sites : Reachability.defer_site list) =
  let moved = Hashtbl.create 16 in
  let add index =
    if is_pragma tokens.(index) then Hashtbl.replace moved index ()
  in
  List.iter
    (fun (site : Reachability.defer_site) ->
      List.iter add
        (indices
           (Tree.deferred_text ~keyword:site.keyword
              ~statement:site.deferred)))
    sites;
  moved

(* Each pragma line of the scopes that is not a loop pragma. *)
let state_refusals tokens sites =
  let moved = moved_pragmas tokens sites in
  let refused index =
    is_pragma tokens.(index)
    && (not (Hashtbl.mem moved index))
    && not (is_loop_pragma tokens.(index))
  in
  let scope (site : Reachability.defer_site) = site.scope_tokens in
  List.concat_map indices (union (List.map scope sites))
  |> List.filter refused
  |> List.map (fun index -> (index, state_pragma))

(* Whether [statement] holds one of the token indices [sorted], found
   by a binary search, so that the statements of a scope and its places
   cost their sum and not their product. *)
let holds_any sorted (statement : Tree.span) =
  (* The first position whose index is at least [statement.first]. *)
  let rec search low high =
    if low >= high then low
    else
      let middle = (low + high) / 2 in
      if sorted.(middle) < statement.first then search (middle + 1) high
      else search low middle
  in
  let position = search 0 (Array.length sorted) in
  position < Array.length sorted && sorted.(position) <= statement.last

(* The pragma line directly before the end of the block of [site], where
   lowering writes the copies or a trap, and those directly before the
   statements and items of its scope that hold a place of [site]. A jump
   that leaves an outer scope leaves this one too, so the places of the
   innermost scope around a statement are all that it can hold. *)
let placement_refusals tokens (site : Reachability.defer_site) =
  let place_tokens =
    Array.of_list (List.map Reachability.place_token site.places)
  in
  Array.sort Int.compare place_tokens;
  let holds = holds_any place_tokens in
  let before_end : Reachability.place -> int option = function
    | (Block_end closing | Trap closing)
      when closing - 1 >= site.scope_tokens.first
           && is_pragma tokens.(closing - 1) ->
        Some (closing - 1)
    | Block_end _ | Trap _ | Left_by _ -> None
  in
  let before_holders =
    List.filter holds site.annotated
    |> List.map (fun (statement : Tree.span) -> statement.first - 1)
  in
  List.map
    (fun index -> (index, pragma_before_exit))
    (List.filter_map before_end site.places @ before_holders)

let refusal tokens sites =
  let refusals =
    state_refusals tokens sites
    @ List.concat_map (placement_refusals tokens) sites
  in
  let by_index (a, _) (b, _) = Int.compare a b in
  match List.sort by_index refusals with
  | first :: _ -> Some first
  | [] -> None
