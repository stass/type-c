(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The declarations of a translation unit (C11 6.7, 6.9): the type that
    each declaration gives each identifier, its linkage (6.2.2), the tags
    it declares (6.7.2.3), the values of its integer constant expressions
    (6.6p6), and through {!Expressions} the types of the expressions of
    its function bodies and declarations.

    A redeclaration of an object or a function must have a type
    compatible with the visible one, and the identifier then has their
    composite type (6.2.7p4). Each function body is typed where its
    definition stands, so that it sees the tags and declarations of the
    unit at that point, and the declarations of its blocks are read as
    those at file scope are. An initialiser is read with its declarator
    and completes the type of an array of unknown size (6.7.9p22), as a
    later declaration with the length would; one of an object of static
    or thread storage duration is constant (6.7.9p4).

    The reader keeps no scope: it follows the links that the parser
    records in the tree (design 13.3), from each use to the declaration it
    resolves to and from each declaration to the one before it in its
    scope, which it redeclares unless one of them is a Clang overload
    (design 13.3), and keeps what each declaration declares by its id.

    The pass reports the errors it must detect to give the types (design
    13.3): constraints that decide a type or the meaning of a declaration,
    those that {!Expressions} reports, and constant expressions that it
    evaluates and finds out of range or false. Old-style definitions read their declaration lists
    (6.9.1p6). The backend reports the others. *)

open Typec_cpp
open Typec_syntax

(** What an ordinary identifier denotes; see {!Entity}. *)
type entity = Entity.t

type tag = Record_tag of Ctype.record_tag | Enum_tag of Ctype.enum_tag

(** What each external declaration declares, in the order of the tree. *)
type item =
  | Declaration of entity list
      (** One for each declarator, as declared there; none for a GNU [;]
          alone or a file-scope [asm]. *)
  | Static_assertion
  | Function_definition of entity
  | Type_declaration of entity  (** a typedef name (design 3.1) *)

type t

val tags : t -> Ctype.tags
val items : t -> item list

val entity : t -> Tree.reference -> entity option
(** What a declaration that the reader has read declares, as of that
    declaration and its initialiser: a later one of the same entity may
    complete its type. [None] for one in a place that the reader does not
    read, the body of a Clang block literal, and for a builtin typedef name
    that the target lacks. *)

val tag : t -> Tree.tag_id -> tag option
(** The tag that a tag declaration declares, [None] as for {!entity}. *)

val type_declarations : t -> Tree.type_declaration list
(** The type declarations that the reader has read, in source order:
    those that lowering replaces (design 13.5). *)

val linked : t -> string -> entity option
(** The object or function with linkage (6.2.2) of that name: the one
    entity that its declarations with linkage denote in any scope, as of
    the last of them. An overload, which has a symbol of its own, is not
    linked. *)

(** Where the declarations are wrong: the location of the token where the
    construct starts, and a message that names the clause of C11. *)
type error = Reader.error = { location : Location.t; message : string }

val expression : t -> Tree.expression -> Expressions.typed option
(** The type of an expression that the reader has typed, as
    {!Expressions.find} gives it: every expression of a parsed function
    body and every one that a declaration holds, initialisers included. *)

val constant : t -> Tree.expression -> Expressions.constant option
(** The class of constant expression of an expression that the reader
    has typed; see {!Expressions.constant}. *)

val selection : t -> Tree.expression -> Tree.expression Ctype.answer option
(** What a generic selection that the reader has typed selects; see
    {!Expressions.selection}. *)

val types_compatible : t -> Tree.expression -> bool Ctype.answer option
(** The answer of a [__builtin_types_compatible_p] that the reader has
    typed; see {!Expressions.types_compatible}. *)

val read : Target.t -> Reader.t -> Tree.translation_unit -> (t, error) result
(** [read target text unit] reads [unit], parsed from [text], for
    [target]. *)
