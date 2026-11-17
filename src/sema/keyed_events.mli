(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Values at the indices of tokens, each with an integer key, from which
    a query reads those in a range of indices whose keys lie below a
    bound, in the order of their indices, at a cost that grows with the
    number it reads times the logarithm of the greatest index, and not
    with the number it passes over. The check of
    design 13.5 keeps here the redeclarations of typedef names, keyed by
    where each name was first declared, and reads in a window only those
    of the names declared before it. *)

type 'a t

val empty : 'a t

val add : int -> key:int -> 'a -> 'a t -> 'a t
(** [add index ~key value events] holds [value] with [key] at [index], in
    place of any value there before. [index] is that of a token, at
    least 0 and below [Sys.max_array_length]. *)

val between :
  'a t -> from:int -> before:int -> key_below:int -> (int * 'a) Seq.t
(** [between events ~from ~before ~key_below] is each index from [from]
    to before [before] that holds a key below [key_below], with its
    value, in increasing order of the index. *)
