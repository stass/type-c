(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp

(* The base lets a short unit hold the instances that the front end's
   instance budget lets through, and the factor lets the text of a long
   unit grow far past what the inputs of the tests ask; design P30 gives
   the measures. *)
let base = 33554432
let per_byte = 256

(* A piece costs typec some hundred bytes of memory whatever its text,
   so where a piece of one token was charged only its bytes, a unit of
   copied tokens would take 35 times its limit in memory. *)
let least_piece_charge = 32

(* A piece takes its text and the blank or the line break after it on
   the line of its run. *)
let piece_charge length = max (length + 1) least_piece_charge

let of_length length = base + (per_byte * length)
let of_unit unit = of_length (Reader.length unit)

let described unit =
  Printf.sprintf
    "the output limit of typec, %d bytes for this unit: %d and %d for each \
     byte of its preprocessed text"
    (of_unit unit) base per_byte
