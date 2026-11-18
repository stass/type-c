(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* 40: longer than the names people write, and small enough that each
   comparison fills a table of at most 41 by 41 entries. *)
let max_length = 40

(* The most edits after which a name is still taken as a misspelling: a
   name of one or two bytes is that close to too many names to say which
   was meant, and two edits in a short name leave too little of it. *)
let most_edits name =
  match String.length name with
  | 0 | 1 | 2 -> 0
  | 3 | 4 -> 1
  | _ -> 2

(* The edits that turn [a] into [b], where a swap of two adjacent bytes
   is one edit (the optimal string alignment distance). [table.(i).(j)] is
   the distance between the first [i] bytes of [a] and the first [j] of
   [b]. *)
let distance a b =
  let m = String.length a and n = String.length b in
  let table = Array.make_matrix (m + 1) (n + 1) 0 in
  for i = 0 to m do table.(i).(0) <- i done;
  for j = 0 to n do table.(0).(j) <- j done;
  for i = 1 to m do
    for j = 1 to n do
      let replaced = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      let best =
        min
          (min (table.(i - 1).(j) + 1) (table.(i).(j - 1) + 1))
          (table.(i - 1).(j - 1) + replaced)
      in
      let swapped =
        i > 1 && j > 1 && a.[i - 1] = b.[j - 2] && a.[i - 2] = b.[j - 1]
      in
      let edited =
        if swapped then min best (table.(i - 2).(j - 2) + 1) else best
      in
      table.(i).(j) <- edited
    done
  done;
  table.(m).(n)

(* The distance from [name] to [spelling] where it is at most [bound]
   and the spelling differs from the name. Lengths further apart than
   [bound] need more edits, so they skip the table. *)
let near ~bound name spelling =
  let apart = abs (String.length spelling - String.length name) in
  if apart > bound || String.length spelling > max_length then None
  else
    let edits = distance name spelling in
    if edits = 0 || edits > bound then None else Some (edits, spelling)

let closest name spellings =
  let bound = most_edits name in
  if bound = 0 || String.length name > max_length then None
  else
    (* Sorted without duplicates, so a name in two variants is one
       candidate, not a tie with itself. *)
    let candidates = List.filter_map (near ~bound name) spellings in
    match List.sort_uniq compare candidates with
    | (first, _) :: (second, _) :: _ when first = second -> None
    | (_, spelling) :: _ -> Some spelling
    | [] -> None
