(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Value types (design 3.2 rule 4): the types that a field of a
    constructor may have. *)

(** A property of a value type that a type lacks, the first in this
    order. *)
type problem =
  | Array
  | Va_list  (** [__builtin_va_list], whatever the target makes it *)
  | Variably_modified
  | Atomic
  | Qualified
  | Incomplete  (** not a complete object type at this point (rule 5) *)
  | Const_member  (** at any depth *)
  | Flexible_array_member  (** at any depth *)

val problem : Ctype.tags -> Ctype.t -> problem option Unknown.answer
(** The first property of a value type that the type lacks, or [None]
    for a value type. *)

val describe : problem -> string
(** The problem as a predicate of the type: "is an array". *)
