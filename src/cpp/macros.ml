(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type definition = { owner : File.t; location : Location.t }
type change = Defined of definition | Undefined
type line = { name : string; position : int; change : change }

(* A map and not a hash table, since a header chooses the names and
   could choose names that collide in a hash table. *)
module Names = Map.Make (String)

(* The changes of each name with their positions, which ascend. *)
type t = (int * change) array Names.t

let of_lines lines =
  let add_latest latest_first { name; position; change } =
    let push earlier =
      Some ((position, change) :: Option.value earlier ~default:[])
    in
    Names.update name push latest_first
  in
  let in_order latest_first = Array.of_list (List.rev latest_first) in
  Names.map in_order (List.fold_left add_latest Names.empty lines)

(* How many of [changes] are at or before [position]: a binary search,
   as one name may change at every line of a long text. *)
let count_up_to changes position =
  let rec first_after low high =
    if low = high then low
    else
      let middle = (low + high) / 2 in
      if fst changes.(middle) <= position then first_after (middle + 1) high
      else first_after low middle
  in
  first_after 0 (Array.length changes)

let definition_of = function
  | Defined definition -> Some definition
  | Undefined -> None

let at table name position =
  let changes = Option.value (Names.find_opt name table) ~default:[||] in
  match count_up_to changes position with
  | 0 -> None
  | count -> definition_of (snd changes.(count - 1))
