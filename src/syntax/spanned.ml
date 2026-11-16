(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type span = { first : int; last : int }
type +'a t = { span : span; node : 'a }

(* A node counted: the first token of its span and its height, the most
   nodes on a path from it to a leaf. *)
type made = { first_token : int; height : int }

type counter = {
  max_depth : int;
  mutable outermost : made list;
      (** the nodes made and not yet inside a node made after them,
          latest first, so their first tokens decrease: [count] takes
          every entry at or after the first token it pushes *)
}

let counter ~max_depth = { max_depth; outermost = [] }

type counted = span

let count counter (span : span) =
  let rec take_parts tallest = function
    | (part : made) :: rest when part.first_token >= span.first ->
        take_parts (max tallest part.height) rest
    | rest -> (tallest, rest)
  in
  let tallest_part, outside = take_parts 0 counter.outermost in
  let height = tallest_part + 1 in
  if height > counter.max_depth then None
  else begin
    counter.outermost <- { first_token = span.first; height } :: outside;
    Some span
  end

let make span node = { span; node }
let identifier span name = { span; node = name }
