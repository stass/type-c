(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Types spelled as C type names (C11 6.7.7), for diagnostics and for C
    that is compared with a backend, such as ["int (*)[3]"] or
    ["void (*(*)(int))(void)"]. (The quotes keep the OCaml comment
    closed.) *)

val of_ctype : Ctype.t -> string
(** Qualifiers are spelled [const volatile restrict _Atomic] before the
    type they qualify, and after the [*] of a pointer. An anonymous
    structure, union or enumeration is spelled [struct <anonymous>], and an
    opaque array length [[<constant>]] and a type that typec does not know
    by its construct between [<] and [>], which are not C. *)

val declaration : Ctype.t -> string -> string
(** [declaration t name] declares [name] with type [t], such as
    ["int (*name)[3]"]. *)
