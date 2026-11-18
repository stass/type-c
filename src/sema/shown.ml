(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Long enough for an application of a few arguments, such as
   'map(slice(const char), vector(slice(const char)))', to show whole. *)
let max_length = 200
let ellipsis = "..."

(* A UTF-8 continuation byte, which no cut may precede. *)
let is_continuation text index = Char.code text.[index] land 0xC0 = 0x80

let cut text =
  if String.length text <= max_length then text
  else
    let rec boundary length =
      if length > 0 && is_continuation text length then boundary (length - 1)
      else length
    in
    let kept = boundary (max_length - String.length ellipsis) in
    String.sub text 0 kept ^ ellipsis

(* 8: enough to show what is missing or shared, while the work and the
   text of a message stay small whatever the size of what it lists. *)
let max_named = 8

type 'a few = { named : 'a list; more : int }

let few all =
  let named = List.filteri (fun index _ -> index < max_named) all in
  { named; more = List.length all - List.length named }

let map f { named; more } = { named = List.map f named; more }
let named few = few.named
let more few = few.more

let bounded write =
  (* Each call has its own exception, so a write within another's cannot
     stop the outer one. *)
  let exception Full in
  (* One byte past [max_length] is enough for [cut] to see that the text
     is longer. *)
  let capacity = max_length + 1 in
  let buffer = Buffer.create capacity in
  let add text =
    let room = capacity - Buffer.length buffer in
    Buffer.add_substring buffer text 0 (min room (String.length text));
    if Buffer.length buffer = capacity then raise Full
  in
  (try write add with Full -> ());
  cut (Buffer.contents buffer)
