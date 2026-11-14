(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The qualifiers of a type (C11 6.7.3), apart from {!Ctype} so that the
    table of what GCC types otherwise ({!Backend_difference}), which
    {!Ctype} asks, can name them. *)

type t = {
  const : bool;
  volatile : bool;
  restrict : bool;
  atomic : bool;  (** The [_Atomic] qualifier or specifier (6.7.2.4p4). *)
}

val none : t

val union : t -> t -> t
(** The qualifiers that either has. *)
