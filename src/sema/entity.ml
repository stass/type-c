(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** What an ordinary identifier denotes (C11 6.2.1, 6.2.2, 6.2.4): the
    facts that the declaration reader records for each declaration and
    that expression typing reads at each use. *)

type linkage = External | Internal | No_linkage

(** The storage duration of an object (6.2.4). *)
type storage = Static_storage | Thread_storage | Automatic_storage

(** The [target] attributes of the declarations of a function that a
    declaration sees, which decide whether its name names one version of
    it (design 13.5): none, all with the argument tokens [spellings], or
    two whose arguments differ token for token. *)
type targets = Untargeted | Targeted of string list | Versioned

(** [targets] of two declarations of one function seen together. *)
let both_targets earlier later =
  match (earlier, later) with
  | Untargeted, targets | targets, Untargeted -> targets
  | Targeted a, Targeted b when a = b -> earlier
  | Targeted _, Targeted _ | Versioned, _ | _, Versioned -> Versioned

(** The first marked attribute of two declarations of one function seen
    together. *)
let both_marks earlier later =
  match earlier with Some _ -> earlier | None -> later

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
      inline_definition : bool;
          (** Every file-scope declaration so far says [inline] without
              [extern], so that a definition is an inline definition
              (C11 6.7.4p7), which 6.7.4p3 constrains where the function
              has external linkage. The GNU89 rule of [gnu_inline] is not
              followed. *)
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
      targets : targets;
      marked : string option;
          (** The name of the first attribute that the table of attributes
              marks (design 13.3) in a declaration that this one sees, or
              ["overloadable"] where it follows an overload of its name in
              its scope: the name then may name more than one function, or
              a mention of it may be an error (13.5). *)
    }
  | Typedef of { typedef_type : Ctype.t }
  | Enumerator of { enumerator_type : Ctype.t; value : Integer_constant.t }
      (** The type is [int] when every value of the enumeration fits it,
          else the enumerated type; while its list is read, the type is
          that of its value, as in C23 6.7.2.2 and GCC and Clang. A value
          that typec does not evaluate is an error (design P16). *)

(** The declarations of one object or function share its [entity]. *)
type t = {
  name : string;
  entity : int;
  declared : declared;
  inexact : bool;
      (** This declaration, or an earlier one of the entity that it
          sees, is inexact (design 3.5 rule 2, 13.5): its text holds an
          attribute, an alignment specifier or a [__typeof__] of an
          expression, or a typedef name or alias declared with one, so
          that the backend's type may hold an attribute that the type in
          [declared] lacks. A Type-C type declaration other than an alias
          names a type of its own, which no argument shares, and is
          exact. *)
}

let linkage_of = function
  | Object { linkage; _ } | Function { linkage; _ } -> linkage
  | Typedef _ | Enumerator _ -> No_linkage
