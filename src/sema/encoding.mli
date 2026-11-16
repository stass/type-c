(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The encoding of a type argument in the name of an instance (design
    10.3), which is also what tells two instances apart (3.5 rule 3). It
    is a function of the type alone, so the same application has the same
    name in every translation unit for one target. *)

(** Why a part of a type has no row in the table, which makes the type no
    type argument (design 3.5 rule 2). *)
type reason =
  | Int128  (** [__int128] or [unsigned __int128]. *)
  | Va_list
  | Unknown_type of Unknown.t
      (** A type that typec does not compute, among them the [_Float]
          types and vector types. *)
  | Array_not_under_pointer
  | Function_not_under_pointer
  | Opaque_length
      (** An array length that the front end does not compute (design
          P16). *)
  | Variable_length
  | Unnamed
      (** An untagged structure, union or enumeration that no typedef
          declarator names. *)
  | Several_names of string list
      (** An untagged structure, union or enumeration that more than one
          typedef declarator names, sorted. *)
  | Not_at_file_scope
      (** A structure, union, enumeration, variant or distinct type
          declared in a block or a parameter list. *)
  | Too_long
      (** The encoding, or the code of the instance that the part is an
          argument of, is longer than {!max_length} bytes. *)

(** The part of the type that has no row, and why. *)
type no_row = { part : Ctype.t; reason : reason }

val max_length : int
(** The limit on the bytes of an encoding and of the code of an instance,
    which bounds every instance name (design 10.3 sets none; a chain of
    typedefs of [pair(p, p)] doubles a name at each step). *)

val encode : Ctype.tags -> Ctype.t -> (string, no_row) result
(** The encoding of a type argument by the table of design 10.3. An
    untagged type is named by the typedef names that
    {!Ctype.name_untagged} recorded in [tags]. *)

val instance :
  Ctype.tags ->
  Typec_syntax.Spelling.type_name ->
  ('written * Ctype.t) list ->
  (Ctype.instance, 'written * no_row) result
(** The instance that an application of the generic to these arguments
    names, by the encoding of each (design 3.5 rule 3), or the argument,
    as written, that has no row. A type parameter of a definition check
    encodes as [_], its id and [_], which begin no encoding of 10.3. *)

val instance_name : Ctype.instance -> string
(** The name that an instance lowers to: its generic, [__] and the
    encoding of each argument (design 10.3). *)
