(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The scopes of identifiers (C11 6.2.1) in the two name spaces that
    scopes hold (6.2.3): ordinary identifiers and tags. Members belong to
    their structure or union and labels to their function.

    A value is the stack of scopes open at a point of the translation
    unit, file scope at the bottom; it is persistent, so a point keeps the
    declarations visible there. It is generic in what a declaration binds,
    so that a reader that needs less than the types, such as whether an
    identifier is a typedef name, can keep the same scopes. Leaving a
    scope is going back to the value saved on entering it.

    A lookup takes time logarithmic in the number of names visible,
    whatever the number of scopes open. *)

type ('ordinary, 'tag) t

val file : ('ordinary, 'tag) t
(** File scope with no declarations. *)

val enter : ('ordinary, 'tag) t -> ('ordinary, 'tag) t
(** A block or function prototype scope inside the innermost one. *)

val reenter :
  ('ordinary, 'tag) t -> inner:('ordinary, 'tag) t -> ('ordinary, 'tag) t
(** [reenter outer ~inner] is the innermost scope of [inner] inside
    [outer]: the block of a function definition, which holds what its
    parameter list declares (6.2.1p4) inside the file scope where the
    function itself is declared after its declarator (6.2.1p7). *)

val is_file_scope : ('ordinary, 'tag) t -> bool

val find : ('ordinary, 'tag) t -> string -> 'ordinary option
(** The declaration of an ordinary identifier that is visible: that of
    the innermost scope that declares it. *)

val find_in_innermost : ('ordinary, 'tag) t -> string -> 'ordinary option
(** The declaration in the innermost scope only, for the rules on
    declaring an identifier twice in one scope (6.7p3). *)

val declare : ('ordinary, 'tag) t -> string -> 'ordinary -> ('ordinary, 'tag) t
(** Declares an ordinary identifier in the innermost scope, in place of
    any declaration of it there. *)

val find_tag : ('ordinary, 'tag) t -> string -> 'tag option
val find_tag_in_innermost : ('ordinary, 'tag) t -> string -> 'tag option
val declare_tag : ('ordinary, 'tag) t -> string -> 'tag -> ('ordinary, 'tag) t

val innermost_ordinary : ('ordinary, 'tag) t -> (string * 'ordinary) list
(** The ordinary identifiers that the innermost scope declares, in the
    order of their names. *)
