(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The scopes of identifiers (C11 6.2.1) in the two name spaces that
    scopes hold (6.2.3): ordinary identifiers and tags. Members belong to
    their structure or union and labels to their function.

    A value is the stack of scopes open at a point of the translation
    unit, file scope at the bottom; it is persistent, so a point keeps the
    declarations visible there. It is the parser's (design 13.3), and
    generic in what a declaration binds. Leaving a scope is going back to
    the value saved on entering it.

    A lookup takes time logarithmic in the number of names visible,
    whatever the number of scopes open. *)

type ('ordinary, 'tag) t

val file : ('ordinary, 'tag) t
(** File scope with no declarations. *)

val file_within : ('ordinary, 'tag) t -> ('ordinary, 'tag) t
(** [file_within universe] is file scope with no declarations of its own
    inside the innermost scope of [universe], the universe scope that
    encloses file scope (design 2.3): every lookup finds what [universe]
    declares unless a scope declares the same name, and nothing that
    [universe] declares is a declaration of file scope. *)

val enter : ('ordinary, 'tag) t -> ('ordinary, 'tag) t
(** A block or function prototype scope inside the innermost one. *)

val is_file : ('ordinary, 'tag) t -> bool
(** Whether the innermost scope is file scope. *)

val depth : ('ordinary, 'tag) t -> int
(** The number of scopes open, file scope counted: [1] at file scope. *)

val reenter :
  ('ordinary, 'tag) t -> inner:('ordinary, 'tag) t -> ('ordinary, 'tag) t
(** [reenter outer ~inner] is the innermost scope of [inner] inside
    [outer]: the block of a function definition, which holds what its
    parameter list declares (6.2.1p4) inside the file scope where the
    function itself is declared after its declarator (6.2.1p7). *)

val find : ('ordinary, 'tag) t -> string -> 'ordinary option
(** The declaration of an ordinary identifier that is visible: that of
    the innermost scope that declares it. *)

val find_in_innermost : ('ordinary, 'tag) t -> string -> 'ordinary option
(** The declaration in the innermost scope only, for the rules on
    declaring an identifier twice in one scope (6.7p3). *)

val declare : ('ordinary, 'tag) t -> string -> 'ordinary -> ('ordinary, 'tag) t
(** Declares an ordinary identifier in the innermost scope, in place of
    any declaration of it there. *)

val declared_in_innermost : ('ordinary, 'tag) t -> (string * 'ordinary) list
(** The ordinary identifiers that the innermost scope declares, sorted by
    name, each with its declaration there. *)

val find_tag : ('ordinary, 'tag) t -> string -> 'tag option
val find_tag_in_innermost : ('ordinary, 'tag) t -> string -> 'tag option
val declare_tag : ('ordinary, 'tag) t -> string -> 'tag -> ('ordinary, 'tag) t

val tags_declared_in_innermost : ('ordinary, 'tag) t -> (string * 'tag) list
(** The tags that the innermost scope declares, as
    {!declared_in_innermost}. *)
