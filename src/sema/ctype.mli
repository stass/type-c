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
    or union has members but no size, alignment or offsets.

    {e Provisional (design 13.3).} A type that typec does not compute, such
    as a block pointer, [_Float16] or one that an unknown attribute
    changes, is {!Unknown_type} ({!Unknown}): never guessed. Every
    question whose answer depends on it answers {!Unknown.Depends_on}, and
    the caller reports an error only where it needs the answer. Building a
    type checks no constraint that depends on an unknown type: the backend
    checks those. *)

(** A structure or union type, created once for each declaration that
    introduces one (6.7.2.3p5); two are the same type when they are the
    same tag. *)
type record_kind = Struct | Union

type record_tag = private {
  record_id : int;
  kind : record_kind;
  record_name : string option;  (** [None] for an anonymous structure. *)
  variant : bool;
      (** Whether this is the structure that a variant lowers to (design
          10.1), which only C text may treat as a structure (3.2 rule 6,
          10.6); only {!declare_variant} makes one. *)
}

(** An enumerated type, created as a {!record_tag} is. *)
type enum_tag = private { enum_id : int; enum_name : string option }

(** The length of an array type (6.7.6.2p4). A variable length is
    evaluated at run time, so the type does not carry it. *)
type length =
  | Constant of int
  | Opaque
      (** {e Provisional (design P16).} An integer constant expression
          that the backend evaluates, such as [sizeof (struct s)]. It is
          compatible with any other length, which the backend checks. *)
  | Unknown
  | Variable

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
    function type has none, so both always have {!Qualifiers.none}. [size]
    counts the nodes of the type as a tree, a type shared through a
    typedef once for each use; it never exceeds {!max_size}. *)
and t = private { qualifiers : Qualifiers.t; shape : shape; size : int }

and shape =
  | Void
  | Arithmetic of Arithmetic.t
  | Enum of enum_tag
  | Pointer of t  (** The referenced type. *)
  | Record of record_tag
  | Distinct of distinct
      (** A distinct type (design 3.4): a scalar type compatible only with
          itself, of which only Type-C text knows; C text sees its
          representation (design 10.2), through {!representation}. *)
  | Va_list
      (** {e Provisional (design P20).} The type of [__builtin_va_list]
          ({!Typec_syntax.Builtin_typedef.Va_list}), whose representation
          is the target's and is not modelled: a complete object type,
          compatible only with itself, neither scalar nor an array, whose
          size is the backend's. A parameter of this type is therefore not
          adjusted. Where compatibility depends on the representation the
          reader is wrong in both directions: it accepts a
          [const va_list] parameter where another has [va_list], which
          x86-64 refuses, and refuses [char *] where another has
          [va_list], which i386 and arm64 Darwin accept. *)
  | Array of { element : t; length : length }
  | Function of { return : t; parameters : parameters }
      (** The return type is unqualified (6.7.6.3p5). *)
  | Unknown_type of Unknown.t
      (** A type that typec does not compute. Its qualifiers are those
          written on it; any within it, as [typeof] of a [const] object
          has, are part of what is unknown, so no relation compares them. *)

(** Created once for each declaration of a distinct type, as a
    {!record_tag} is, and only by {!declare_distinct}. *)
and distinct = private {
  distinct_id : int;
  distinct_name : string;
  representation : t;
      (** The unqualified arithmetic or pointer type that it has the size,
          alignment and representation of. *)
}

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
  | Int128_unavailable  (** [__int128] on a target without it. *)
  | Invalid_representation
      (** The type of a distinct type is no unqualified arithmetic or
          pointer type (design 3.4). *)

val error_message : error -> string

val max_size : int
(** The limit on the nodes of one type. It is far above the types of real
    programs and it bounds both the recursion depth and the work of every
    function that walks a type, which a depth limit alone would not: a
    chain of typedefs that each use the previous one twice doubles the
    tree at every step. *)

(** {1 Building types} *)

val void : t

val arithmetic : Target.t -> Arithmetic.t -> (t, error) result
(** The only way to make an arithmetic type, so that no type names
    [__int128] on a target without it, which has no width for it. *)

val integer : Target.t -> Integer.t -> (t, error) result

val enum : enum_tag -> t
val record : record_tag -> t

val va_list : t
(** The type of [__builtin_va_list], without qualifiers. *)

val unknown : Unknown.t -> t

val pointer_to : t -> (t, error) result

val array_of : tags -> t -> length -> (t, error) result
(** The element type must be a complete object type at this point. *)

val function_returning : t -> parameters -> (t, error) result
(** Adjusts and unqualifies the parameter types and unqualifies the return
    type. *)

val qualify : Qualifiers.t -> t -> (t, error) result
(** Adds qualifiers. On an array type they go to its element type. *)

val atomic : t -> (t, error) result
(** The specifier [_Atomic(T)] (6.7.2.4). *)

(** {1 Tags} *)

val create_tags : unit -> tags
val declare_record : tags -> record_kind -> string option -> record_tag

val declare_variant : tags -> string -> record_tag
(** The structure that the variant of this name lowers to (design 10.1). *)

(** A constructor of a variant: its name and its fields in order, whose
    position in the list of its variant is its tag (design 10.1 rule 1). *)
type constructor = { constructor_name : string; fields : member list }

val declare_enum : tags -> string option -> enum_tag

val declare_distinct : tags -> string -> t -> (t, error) result
(** A new distinct type of this name over its representation. *)

val define_record :
  Target.t -> tags -> record_tag -> member list -> (unit, error) result
(** Completes a structure or union with its members in order. *)

val define_variant :
  Target.t ->
  tags ->
  record_tag ->
  constructor list ->
  member list ->
  (unit, error) result
(** Completes the structure of a variant, as {!define_record} does, and
    gives the variant its constructors. *)

val constructors : tags -> t -> constructor list option
(** The constructors of a variant, qualified or not, in order; [None]
    where [t] is no variant or one that is incomplete here. *)

val define_enum :
  tags -> enum_tag -> Integer.t Unknown.answer -> (unit, error) result
(** Completes an enumerated type with its compatible integer type (see
    {!Arithmetic.enum_compatible_type}), or with the unknown type that
    decides it: a fixed type or an attribute that typec does not know. *)

val record_members : tags -> record_tag -> member list option
(** The members of a complete structure or union, in order. *)

(** A member found by name. [path] is where: the position of the member
    that holds it (see {!member_at}), then its position in each anonymous
    member down to it. [anonymous_qualifiers] are the [const] and
    [volatile] of the anonymous members that it is found through, which
    are not part of its type: Clang does not give them to it, and GCC does
    (see {!Backend_difference}). *)
type found_member = {
  member : member;
  path : int list;
  anonymous_qualifiers : Qualifiers.t;
}

val find_member : tags -> record_tag -> string -> found_member option
(** The member of that name, looked up through anonymous members too. *)

(** {2 Positions}

    The members of a structure or union that an initialiser reaches have
    positions, from 0 in order: all but unnamed bit-fields (6.7.9p9). *)

val member_at : tags -> record_tag -> int -> member option
(** The member at a position of a complete structure or union; [None]
    past the last. *)

val enum_integer : tags -> enum_tag -> Integer.t Unknown.answer option
(** The integer type compatible with a complete enumerated type; [None]
    while it is incomplete. *)

(** {1 Classification (6.2.5)}

    Each answers {!Unknown.Depends_on} where the answer depends on an
    unknown type. *)

val is_void : t -> bool Unknown.answer
val is_integer : t -> bool Unknown.answer
val is_real : t -> bool Unknown.answer
val is_arithmetic : t -> bool Unknown.answer
val is_scalar : t -> bool Unknown.answer
val is_pointer : t -> bool Unknown.answer
val is_record : t -> bool Unknown.answer
val is_array : t -> bool Unknown.answer
val is_function : t -> bool Unknown.answer

val is_object : t -> bool Unknown.answer
(** Not a function type; [void] is an incomplete object type. *)

val is_complete : tags -> t -> bool Unknown.answer
(** A complete object type, at this point of the translation unit. *)

val is_variably_modified : t -> bool Unknown.answer
(** A variable length array, or derived from one (6.7.6p3). *)

val as_variant : t -> string option
(** The name of the variant whose structure [t] is, qualified or not, or
    [None] where [t] is no variant. *)

val as_distinct : t -> distinct option
(** The distinct type that [t] is, qualified or not. *)

val mentions_distinct : t -> bool
(** Whether a distinct type is part of [t]: [t] itself, or a type that it
    points to, is an array of, returns or takes. Members of a structure or
    union are not part of it. *)

val representation : t -> t
(** The type that C text sees for [t] (design 10.2): [t] with every
    distinct type that {!mentions_distinct} finds in it replaced by its
    representation, which keeps the distinct type's qualifiers. Members of
    a structure or union keep their types, which C text sees in turn as
    it reads them. *)

val as_arithmetic : tags -> t -> Arithmetic.t option Unknown.answer
(** The arithmetic type of an operand, without its qualifiers. An
    enumerated type gives its compatible integer type, or [None] while it
    is incomplete. *)

(** {1 Relations and conversions} *)

val unqualified : t -> t

val top_qualifiers : t -> Qualifiers.t
(** The top-level qualifiers of a type, which for an array are those of
    its innermost element (6.7.3p9). *)

val without_top_qualifiers : t -> t
(** The type without its top-level qualifiers but [_Atomic], as Clang
    compares types in [__builtin_types_compatible_p]. *)

val decay : t -> t
(** The pointer that an array or a function converts to (6.3.2.1p3, p4);
    any other type is unchanged, and so is an unknown type that may be an
    array. *)

val lvalue_conversion : t -> t
(** The type of the value of an lvalue (6.3.2.1p2-4): {!decay}, or the
    unqualified type. *)

val promoted : Target.t -> tags -> t -> t Unknown.answer
(** The type of an argument for a parameter of type [t] where no
    prototype is in scope (6.5.2.2p6): the default argument promotion of
    an arithmetic type, any other type unchanged. *)

val compatible : Target.t -> tags -> t -> t -> bool Unknown.answer
(** Whether two types are compatible (6.2.7p1, 6.7.3p10, 6.7.6.1p2,
    6.7.6.2p6, 6.7.6.3p15). The parameters of a prototype and of an
    old-style definition are compared as C11 says, by their promoted
    types, which rejects some pairs that GCC and Clang accept with a
    warning, such as [int g(float);] before [int g(x) float x; {...}].
    Parts that differ where they are known make two types incompatible
    whatever their unknown parts are. *)

val same_type : t -> t -> bool Unknown.answer
(** Whether two types are the same (6.7p3), as for the redefinition of a
    typedef name: equal, but that an {!Opaque} length is the same as any
    constant one, which the backend checks. *)

val composite :
  Target.t -> tags -> Typec_cpp.Location.t -> t -> t -> (t, error) result
(** The composite type of two compatible types (6.2.7p3): [Incompatible]
    when they are not, [Too_large] when the composite exceeds
    {!max_size}. An enumerated type and its compatible integer type have
    the integer type as their composite, as in Clang; with GCC, which
    types it otherwise, it is an unknown type at [location], where the
    composite is formed ({!Backend_difference.Enum_integer_composite}).
    Where one type is unknown the composite is that unknown type: keeping
    the known side would guess that the unknown one adds nothing to it,
    as [extern int a[];] with an unknown type for [a] that gives its
    length would. *)
