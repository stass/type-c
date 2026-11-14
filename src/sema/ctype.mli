(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The types of C (C11 6.2.5) and the rules that relate them: qualifiers
    (6.7.3), compatible and composite types (6.2.7) and the conversions of
    lvalues (6.3.2.1).

    A type is built only through the functions below, which reject the
    types that a constraint of C forbids whatever declaration spells them:
    a qualified function type, a misplaced [restrict] or [_Atomic], an
    array of functions or of an incomplete type, a function returning an
    array or a function, a [void] parameter, a structure member of
    incomplete type, a bit-field too wide for its type. Rules that depend
    on how or where a type is written, such as storage classes, [(void)]
    as the spelling of no parameters, which unnamed members are anonymous
    or variably modified types at file scope, belong to the code that
    reads declarations.

    The front end knows no layout of aggregates (design P16): a structure
    or union has members but no size, alignment or offsets. *)

type qualifiers = {
  const : bool;
  volatile : bool;
  restrict : bool;
  atomic : bool;  (** The [_Atomic] qualifier or specifier (6.7.2.4p4). *)
}

val no_qualifiers : qualifiers

(** A structure or union type, created once for each declaration that
    introduces one (6.7.2.3p5); two are the same type when they are the
    same tag. *)
type record_kind = Struct | Union

type record_tag = private {
  record_id : int;
  kind : record_kind;
  record_name : string option;  (** [None] for an anonymous structure. *)
}

(** An enumerated type, created as a {!record_tag} is. *)
type enum_tag = private { enum_id : int; enum_name : string option }

(** The length of an array type (6.7.6.2p4). A variable length is
    evaluated at run time, so the type does not carry it. *)
type length = Constant of int | Unknown | Variable

(** The parameters of a function type (6.7.6.3). Their types are adjusted
    and unqualified: an array or function parameter is a pointer, and a
    qualifier of a parameter belongs to the parameter, not to the type
    (6.7.6.3p7, p8, p15). *)
type parameters =
  | Prototype of { types : t list; variadic : bool }
  | Unspecified
      (** A declarator with an empty identifier list that is not part of a
          definition: [int f();]. *)
  | Old_style of t list
      (** The parameter types of a definition with a possibly empty
          identifier list: [int f() {...}] has none (6.7.6.3p14). *)

(** Qualifiers of an array type belong to its element type (6.7.3p9) and a
    function type has none, so both always have {!no_qualifiers}. [size]
    counts the nodes of the type as a tree, a type shared through a
    typedef once for each use; it never exceeds {!max_size}. *)
and t = private { qualifiers : qualifiers; shape : shape; size : int }

and shape =
  | Void
  | Arithmetic of Arithmetic.t
  | Enum of enum_tag
  | Pointer of t  (** The referenced type. *)
  | Record of record_tag
  | Array of { element : t; length : length }
  | Function of { return : t; parameters : parameters }
      (** The return type is unqualified (6.7.6.3p5). *)

(** A member of a structure or union (6.7.2.1). An unnamed member of
    structure or union type that is not a bit-field is taken as an
    anonymous member, whose members are members of the containing type
    (6.7.2.1p13); the declaration code passes one only when its type
    specifier is a structure or union without a tag. *)
type member = {
  member_name : string option;
  member_type : t;
  bit_field_width : int option;
}

(** The definitions of the structure, union and enumerated types of one
    translation unit. A tag is declared before it is defined, so that a
    type can refer to itself; it is complete once defined. The members live
    here rather than in the type so that a type is a finite tree, which
    structural equality compares in time linear in {!max_size}. *)
type tags

(** Why a type cannot be built or a tag cannot be defined. *)
type error =
  | Too_large  (** More nodes than {!max_size}. *)
  | Qualified_function  (** 6.7.3p9: undefined in C, an error here. *)
  | Atomic_array  (** 6.7.3p3. *)
  | Restrict_without_object_pointer  (** 6.7.3p2. *)
  | Atomic_of_unsuitable_type  (** 6.7.2.4p3. *)
  | Array_of_function  (** 6.7.6.2p1. *)
  | Array_of_incomplete  (** 6.7.6.2p1. *)
  | Negative_length  (** 6.7.6.2p1; a zero length is a GNU extension. *)
  | Function_returning_array  (** 6.7.6.3p1. *)
  | Function_returning_function  (** 6.7.6.3p1. *)
  | Void_parameter  (** 6.7.6.3p10: [void] only as [(void)]. *)
  | Redefinition  (** A tag defined twice (6.7.2.3p1). *)
  | Duplicate_member of string  (** 6.7.2.1p13 with 6.7.2.3. *)
  | Incomplete_member
      (** 6.7.2.1p3: of incomplete or function type, other than a flexible
          array member. *)
  | Misplaced_flexible_array  (** 6.7.2.1p3: not the last member. *)
  | Variably_modified_member  (** 6.7.2.1p9. *)
  | Invalid_bit_field  (** 6.7.2.1p4. *)
  | Incompatible  (** No composite type: 6.2.7p1. *)

val error_message : error -> string

val max_size : int
(** The limit on the nodes of one type. It is far above the types of real
    programs and it bounds both the recursion depth and the work of every
    function that walks a type, which a depth limit alone would not: a
    chain of typedefs that each use the previous one twice doubles the
    tree at every step. *)

(** {1 Building types} *)

val void : t
val arithmetic : Arithmetic.t -> t
val integer : Integer.t -> t

val enum : enum_tag -> t
val record : record_tag -> t
val pointer_to : t -> (t, error) result

val array_of : tags -> t -> length -> (t, error) result
(** The element type must be a complete object type at this point. *)

val function_returning : t -> parameters -> (t, error) result
(** Adjusts and unqualifies the parameter types and unqualifies the return
    type. *)

val qualify : qualifiers -> t -> (t, error) result
(** Adds qualifiers. On an array type they go to its element type. *)

val atomic : t -> (t, error) result
(** The specifier [_Atomic(T)] (6.7.2.4). *)

(** {1 Tags} *)

val create_tags : unit -> tags
val declare_record : tags -> record_kind -> string option -> record_tag
val declare_enum : tags -> string option -> enum_tag

val define_record :
  Target.t -> tags -> record_tag -> member list -> (unit, error) result
(** Completes a structure or union with its members in order. *)

val define_enum : tags -> enum_tag -> Integer.t -> (unit, error) result
(** Completes an enumerated type with its compatible integer type; see
    {!Arithmetic.enum_compatible_type}. *)

val record_members : tags -> record_tag -> member list option
(** The members of a complete structure or union, in order. *)

val find_member : tags -> record_tag -> string -> member option
(** The member of that name, looked up through anonymous members too. *)

val enum_integer : tags -> enum_tag -> Integer.t option
(** The integer type compatible with a complete enumerated type. *)

(** {1 Classification (6.2.5)} *)

val is_void : t -> bool
val is_integer : t -> bool
val is_real : t -> bool
val is_arithmetic : t -> bool
val is_scalar : t -> bool
val is_pointer : t -> bool
val is_array : t -> bool
val is_function : t -> bool

val is_object : t -> bool
(** Not a function type; [void] is an incomplete object type. *)

val is_complete : tags -> t -> bool
(** A complete object type, at this point of the translation unit. *)

val is_variably_modified : t -> bool
(** A variable length array, or derived from one (6.7.6p3). *)

val as_arithmetic : tags -> t -> Arithmetic.t option
(** The arithmetic type of an operand, without its qualifiers. An
    enumerated type gives its compatible integer type, or [None] while it
    is incomplete. *)

(** {1 Relations and conversions} *)

val unqualified : t -> t

val decay : t -> t
(** The pointer that an array or a function converts to (6.3.2.1p3, p4);
    any other type is unchanged. *)

val lvalue_conversion : t -> t
(** The type of the value of an lvalue (6.3.2.1p2-4): {!decay}, or the
    unqualified type. *)

val compatible : Target.t -> tags -> t -> t -> bool
(** Whether two types are compatible (6.2.7p1, 6.7.3p10, 6.7.6.1p2,
    6.7.6.2p6, 6.7.6.3p15). The parameters of a prototype and of an
    old-style definition are compared as C11 says, by their promoted
    types, which rejects some pairs that GCC and Clang accept with a
    warning, such as [int g(float);] before [int g(x) float x; {...}]. *)

val composite : Target.t -> tags -> t -> t -> (t, error) result
(** The composite type of two compatible types (6.2.7p3): [Incompatible]
    when they are not, [Too_large] when the composite exceeds
    {!max_size}. An enumerated type and its compatible integer type have
    the enumerated type as their composite, as in GCC. *)
