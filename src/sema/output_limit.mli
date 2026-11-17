(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The output limit of design 3.5 rule 7, a translation limit of typec
    on the bytes of C text that it writes for a unit: a base and a factor
    for each byte of the preprocessed unit. Emission holds the unit's
    text to it, and the front end the copies of its deferred statements,
    which it reads before lowering writes them. *)

val piece_charge : int -> int
(** [piece_charge length] is what one piece of C text of [length] bytes
    is charged: its bytes and the blank after it, and at least 32
    whatever its length. *)

val of_unit : Typec_cpp.Reader.t -> int
(** [of_unit unit] is the output limit of [unit] in bytes, from its
    length ({!Typec_cpp.Reader.length}). *)

val described : Typec_cpp.Reader.t -> string
(** [described unit] names the limit of [unit] and its formula, for a
    refusal. *)
