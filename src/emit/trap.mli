(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** How the C that lowering writes traps (design 10.5): with
    [__builtin_trap] alone, or by calling the trap function that
    [--trap-function=name] names. Every trap of a unit is {!call}, so
    a unit traps one way. *)

type t

val builtin : t
(** The trap without [--trap-function]: [__builtin_trap()]. *)

val calling : string -> t option
(** [calling name] is the trap that calls the function [name], or None
    unless [name] is a C identifier of ASCII letters, digits and
    underscores that does not begin with a digit. [name] comes from the
    command line and goes into the C text unquoted, so this is the one
    check that keeps other text out of it. *)

val call : t -> string
(** [call trap] is the trap as an expression of type [void]:
    [__builtin_trap()], or [__tc_trap()] for a trap function. A trap
    calls [__tc_trap] rather than [name], which a declaration in a block
    may hide; a name reserved to typec cannot be hidden (design
    13.5). *)

val prototype : t -> string list
(** [prototype trap] is the file-scope declaration that {!call} needs in
    front of the unit's own text, one line per element: none for
    {!builtin}; the prototype of [__tc_trap], a [static inline]
    function, for a trap function. *)

val definition : t -> string list
(** [definition trap] is the file-scope definition that {!call} needs
    after the unit's own text, one line per element: none for
    {!builtin}; for a trap function [name], that of [__tc_trap], which
    declares [_Noreturn void name(void)] in its body, calls it, then
    [__builtin_trap()]. *)

val definition_guard : t -> string option
(** [definition_guard trap] is the include guard of {!definition} in the
    header of an interface (design 9.3, 13.5): none for {!builtin};
    [__tc_trap__name] for a trap function [name], so that two headers of
    one trap function define [__tc_trap] once and two of different ones
    fail to compile together. *)
