(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** What an ordinary identifier denotes (C11 6.2.1, 6.2.2, 6.2.4): the
    facts that the declaration reader records for each declaration and
    that expression typing reads at each use. *)

type linkage = External | Internal | No_linkage

(** The storage duration of an object (6.2.4). *)
type storage = Static_storage | Thread_storage | Automatic_storage

type declared =
  | Object of {
      object_type : Ctype.t;
      linkage : linkage;
      storage : storage;
      register : bool;
          (** declared [register], so that its address may not be taken
              (C11 6.5.3.2p1) *)
    }
  | Function of {
      function_type : Ctype.t;
      linkage : linkage;
      inline : bool;  (** [inline] in some declaration *)
      noreturn : bool;  (** [_Noreturn] in some declaration *)
      gnu_inline : bool;
          (** The attribute [gnu_inline] in some [inline] declaration: the
              GNU89 rule decides whether the inline definition is external,
              which it is unless it says [extern inline], in place of
              C11 6.7.4p7, which decides from every file-scope declaration
              of the function. *)
      overload : bool;
          (** The attribute [overloadable] (Clang): one function of an
              overload set of its name, an entity of its own that no other
              declaration redeclares and that is not in
              [Declarations.linked]. *)
      old_style_definition : bool;
          (** This declaration is a definition with a non-empty identifier
              list (6.9.1p6), whose uses see no prototype in Clang
              (DR 316). *)
    }
  | Typedef of { typedef_type : Ctype.t }
  | Enumerator of { enumerator_type : Ctype.t; value : Integer_constant.t }
      (** The type is [int] when every value of the enumeration fits it,
          else the enumerated type; while its list is read, the type is
          that of its value, as in C23 6.7.2.2 and GCC and Clang. A value
          that typec does not evaluate is an error (design P16). *)

(** What the text of a declaration says of the type that the backend
    reads for it, which may hold an attribute that the type in
    [declared] lacks (design 3.5 rule 2, 13.5). *)
type spelling = {
  inexact : bool;
      (** The text, or that of an earlier declaration of the entity that
          it sees, holds an attribute or a [__typeof__] of an expression,
          or a typedef name or alias declared with one. A Type-C type
          declaration other than an alias names a type of its own, which
          no argument shares, and is exact. *)
  written_through : Typec_syntax.Tree.reference list;
      (** The declarations that the typedef names of the text denote, and
          those of an earlier declaration that it sees, at the depth of
          [inexact]. The backend reads each typedef name as declared
          where it reads the entity, as GCC changes a typedef name
          declared again with an attribute in place. *)
}

(** The spelling of a type that no source text spells. *)
let exact = { inexact = false; written_through = [] }

(** The declarations of one object or function share its [entity]. *)
type t = {
  name : string;
  entity : int;
  declared : declared;
  spelling : spelling;  (** That of this declaration and those it sees. *)
}
