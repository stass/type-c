(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Types spelled as C type names (C11 6.7.7), for diagnostics, such as
    ["int (*)[3]"] or ["void (*(*)(int))(void)"], and as lowered C writes
    them. (The quotes keep the OCaml comment closed.) In a diagnostic, a
    Type-C type is spelled as Type-C writes it: a variant or a type
    declaration by its name, an instance by its application, such as
    ["option(int)"], which is not C; and every spelling for a diagnostic
    is cut as {!Shown.cut} cuts it, at a cost that does not grow with the
    type. C built from such a spelling, as the probes of [test/run] build
    it, holds only types whose spelling is shorter than
    {!Shown.max_length}: a longer one is cut and fails to compile. *)

val of_ctype : Ctype.t -> string
(** Qualifiers are spelled [const volatile restrict _Atomic] before the
    type they qualify, and after the [*] of a pointer. An anonymous
    structure, union or enumeration is spelled [struct <anonymous>], and an
    opaque array length [[<constant>]] and a type that typec does not know
    by its construct between [<] and [>], which are not C. *)

val of_instance : Ctype.instance -> string
(** An application as Type-C writes it, such as ["option(int)"]. *)

val of_variant : Ctype.variant_name -> string
(** The name of a variant as Type-C writes it: its name, or the
    application of its generic, such as ["option(int)"], which a
    qualified constructor names it by (design 3.3). *)

val declaration : Ctype.t -> string -> string
(** [declaration t name] declares [name] with type [t], such as
    ["int (*name)[3]"]. *)

type tag_line = { tag : string; line : string }
(** The line [struct T;] or [union T;] that declares the tag [T] at file
    scope (design 10.3), as [line]. *)

val tag_lines : Ctype.t -> tag_line list
(** The lines that stand before the typedef of an argument of type [t]
    (design 10.3): one for each structure or union that [t] names by a
    tag in the lowered C, that of a variant, an alias of 10.2 or an
    instance included, and none for an enumeration, which ISO C does not
    declare so, or for an untagged type. *)

type lowered = { text : string; spelled : Ctype.typedef_name list }
(** A declaration as lowered C writes it, and the typedef names that its
    [text] spells, which are source names that the text uses
    where lowering writes it (design 10.3, 13.5). *)

val lowered_declaration : Ctype.tags -> Ctype.t -> string -> lowered
(** {!declaration} as lowered C writes it (design 10.3), never cut, and
    the typedef names that it spells in the order of its text, of a type
    that has an encoding: a structure, union or enumeration by its tag in the
    lowered C, that of a variant or an alias of 10.2 included, or else
    by the one typedef name that names it, and a distinct type by its
    name. *)
