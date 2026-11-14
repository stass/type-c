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
    changes, is {!Unknown_type}: never guessed. Every question whose answer
    depends on it answers {!Depends_on}, and the caller reports an error
    only where it needs the answer. Building a type checks no constraint
    that depends on an unknown type: the backend checks those. *)

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
type length =
  | Constant of int
  | Opaque
      (** {e Provisional (design P16).} An integer constant expression
          that the backend evaluates, such as [sizeof (struct s)]. It is
          compatible with any other length, which the backend checks. *)
  | Unknown
  | Variable

(** What typec knows of a type it does not compute: whether it is a
    function type, which the declarator that gives it decides where there
    is one. *)
type unknown_kind =
  | Unknown_object  (** An object type, such as a block pointer. *)
  | Unknown_function
      (** A function type, such as a function that an attribute changes. *)
  | Object_or_function  (** As [typeof] of an expression may give. *)

(** A type that typec does not compute: the construct that gives it, as a
    message names it ("a block pointer"), and the location of the token
    that starts it, for the error at a point that needs the type. *)
type unknown = {
  construct : string;
  location : Typec_cpp.Location.t;
  kind : unknown_kind;
}

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
  | Unknown_type of unknown
      (** A type that typec does not compute. Its qualifiers are those
          written on it; any within it, as [typeof] of a [const] object
          has, are part of what is unknown, so no relation compares them. *)

(** The answer to a question about a type, or the unknown type it depends
    on. *)
type 'a answer = Answer of 'a | Depends_on of unknown

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

val unknown : unknown -> t

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

val define_enum :
  tags -> enum_tag -> Integer.t answer -> (unit, error) result
(** Completes an enumerated type with its compatible integer type (see
    {!Arithmetic.enum_compatible_type}), or with the unknown type that
    decides it: a fixed type or an attribute that typec does not know. *)

val record_members : tags -> record_tag -> member list option
(** The members of a complete structure or union, in order. *)

val find_member : tags -> record_tag -> string -> member option
(** The member of that name, looked up through anonymous members too. *)

val enum_integer : tags -> enum_tag -> Integer.t answer option
(** The integer type compatible with a complete enumerated type; [None]
    while it is incomplete. *)

(** {1 Classification (6.2.5)}

    Each answers {!Depends_on} where the answer depends on an unknown
    type. *)

val is_void : t -> bool answer
val is_integer : t -> bool answer
val is_real : t -> bool answer
val is_arithmetic : t -> bool answer
val is_scalar : t -> bool answer
val is_pointer : t -> bool answer
val is_array : t -> bool answer
val is_function : t -> bool answer

val is_object : t -> bool answer
(** Not a function type; [void] is an incomplete object type. *)

val is_complete : tags -> t -> bool answer
(** A complete object type, at this point of the translation unit. *)

val is_variably_modified : t -> bool answer
(** A variable length array, or derived from one (6.7.6p3). *)

val as_arithmetic : tags -> t -> Arithmetic.t option answer
(** The arithmetic type of an operand, without its qualifiers. An
    enumerated type gives its compatible integer type, or [None] while it
    is incomplete. *)

(** {1 Relations and conversions} *)

val unqualified : t -> t

val without_top_qualifiers : keep_atomic:bool -> t -> t
(** The type without its top-level qualifiers, which for an array are
    those of its innermost element (6.7.3p9), but [_Atomic] if
    [keep_atomic]. *)

val decay : t -> t
(** The pointer that an array or a function converts to (6.3.2.1p3, p4);
    any other type is unchanged, and so is an unknown type that may be an
    array. *)

val lvalue_conversion : t -> t
(** The type of the value of an lvalue (6.3.2.1p2-4): {!decay}, or the
    unqualified type. *)

val compatible : Target.t -> tags -> t -> t -> bool answer
(** Whether two types are compatible (6.2.7p1, 6.7.3p10, 6.7.6.1p2,
    6.7.6.2p6, 6.7.6.3p15). The parameters of a prototype and of an
    old-style definition are compared as C11 says, by their promoted
    types, which rejects some pairs that GCC and Clang accept with a
    warning, such as [int g(float);] before [int g(x) float x; {...}].
    Parts that differ where they are known make two types incompatible
    whatever their unknown parts are. *)

val same_type : t -> t -> bool answer
(** Whether two types are the same (6.7p3), as for the redefinition of a
    typedef name: equal, but that an {!Opaque} length is the same as any
    constant one, which the backend checks. *)

val composite : Target.t -> tags -> t -> t -> (t, error) result
(** The composite type of two compatible types (6.2.7p3): [Incompatible]
    when they are not, [Too_large] when the composite exceeds
    {!max_size}. An enumerated type and its compatible integer type have
    the enumerated type as their composite, as in GCC. Where one type is
    unknown the composite is that unknown type: keeping the known side
    would guess that the unknown one adds nothing to it, as
    [extern int a[];] with an unknown type for [a] that gives its length
    would. *)
