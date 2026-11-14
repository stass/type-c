(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The declarations of a translation unit at file scope (C11 6.7, 6.9):
    the type that each declaration gives each identifier, its linkage
    (6.2.2), the tags it declares (6.7.2.3) and the values of its integer
    constant expressions (6.6p6).

    A redeclaration of an object or a function must have a type
    compatible with the visible one, and the identifier then has their
    composite type (6.2.7p4). Function bodies and initialisers are not
    read: an initialiser that completes an array type (6.7.9p22) leaves
    it incomplete here.

    The pass reports the errors it must detect to give the types (design
    13.3): constraints that decide a type or the meaning of a declaration,
    undeclared identifiers in constant expressions outside [sizeof], and
    constant expressions that it evaluates and finds out of range or
    false. Old-style definitions read their declaration lists (6.9.1p6).
    The backend reports the others. *)

open Typec_cpp
open Typec_syntax

type linkage = External | Internal | No_linkage

(** The storage duration of an object (6.2.4). *)
type storage = Static_storage | Thread_storage | Automatic_storage

type declared =
  | Object of { object_type : Ctype.t; linkage : linkage; storage : storage }
  | Function of {
      function_type : Ctype.t;
      linkage : linkage;
      inline : bool;  (** [inline] in some declaration *)
      noreturn : bool;  (** [_Noreturn] in some declaration *)
    }
  | Typedef of Ctype.t
  | Enumerator of { enumerator_type : Ctype.t; value : Integer_constant.t }
      (** The type is [int] when every value of the enumeration fits it,
          else the enumerated type; while its list is read, the type is
          that of its value, as in C23 6.7.2.2 and GCC and Clang. A value
          that typec does not evaluate is an error (design P16). *)

(** What an ordinary identifier denotes. The declarations of one object or
    function share its [entity]. *)
type entity = { name : string; entity : int; declared : declared }

type tag = Record_tag of Ctype.record_tag | Enum_tag of Ctype.enum_tag
type scope = (entity, tag) Scope.t

(** What each external declaration declares, in the order of the tree. *)
type item =
  | Declaration of entity list
      (** One for each declarator, as declared there; none for a GNU [;]
          alone or a file-scope [asm]. *)
  | Static_assertion
  | Function_definition of { function_entity : entity; body_scope : scope }
      (** [body_scope] is the block of the body before its first token:
          the parameters and what their list declares (6.2.1p4), inside
          the file scope that holds the function. *)

type t = {
  tags : Ctype.tags;
  file_scope : scope;  (** At the end of the translation unit. *)
  items : item list;
}

(** Where the declarations are wrong: the location of the token where the
    construct starts, and a message that names the clause of C11. *)
type error = Reader.error = { location : Location.t; message : string }

val max_expression_depth : int
(** The deepest constant expression that is evaluated; a deeper one is an
    error. *)

val read : Target.t -> Reader.t -> Tree.translation_unit -> (t, error) result
(** [read target text unit] reads [unit], parsed from [text], for
    [target]. *)
