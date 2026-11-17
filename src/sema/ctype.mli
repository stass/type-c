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

(** Who may create values of a variant or a distinct type (design 9.2
    rule 1). *)
type privacy =
  | Public
  | Private of Typec_cpp.File.t
      (** The file whose text declares the type, whose owners
          {!Typec_cpp.File.owns} names. *)

(** An enumerated type, created as a {!record_tag} is. *)
type enum_tag = private {
  enum_id : int;
  enum_name : string option;
  enum_at_file_scope : bool;  (** As for {!record_tag}. *)
}

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

(** An application of a generic that is a type of its own (design 3.5
    rule 3). Its identity is its generic and the encodings of its
    arguments ({!Encoding.encode}), so two applications are one type
    exactly when those are equal, as the rule says. *)
type instance = {
  generic : Typec_syntax.Spelling.type_name;
  arguments : string list;  (** The encoding of each argument, in order. *)
  argument_types : t list;
      (** The type of each argument, in order, from which deduction and
          substitution (design 7.2) apply the generic again; no part of
          the instance's identity. *)
  mentions_parameter : bool;
      (** Whether an argument mentions a type parameter of a definition
          check ({!declare_opaque}), which no encoding of design 10.3
          writes; a function of [arguments]. *)
}

(** The name that a variant lowers to (design 10.1) and from which the
    names that it derives are made: that of its declaration, or that of
    an instance of a variant generic (10.3). *)
and variant_name =
  | Declared of Typec_syntax.Spelling.type_name
  | Applied of instance

and record_tag = private {
  record_id : int;
  kind : record_kind;
  record_name : record_name;
  record_at_file_scope : bool;
      (** Declared at file scope, not in a block or a parameter list. *)
}

(** The name of a structure or union, which chooses its row in the table of
    instance encodings (design 10.3). *)
and record_name =
  | Anonymous
  | Named of string  (** The tag of its own specifier. *)
  | Variant_name of variant_name
      (** The structure that the variant of this name lowers to (design
          10.1), which only C text may treat as a structure (3.2 rule 6,
          10.6); only {!declare_variant} and {!declare_variant_instance}
          make a tag of one. *)
  | Alias_name of string
      (** The untagged structure or union that an alias of this name
          defines, whose tag the declaration claims (design 10.2); only
          {!declare_alias_record} makes one. *)
  | Instance_name of instance
      (** The structure or union of an instance of an alias generic
          (design 10.3); only {!declare_instance} makes one. *)
  | Opaque_name of string
      (** A type parameter of the definition check of a generic (design
          3.5 rule 4, 7.1 rule 2), an opaque value type. Only
          {!declare_opaque} makes one. *)

(** The parameters of a function type (6.7.6.3). Their types are adjusted
    and unqualified: an array or function parameter is a pointer, and a
    qualifier of a parameter belongs to the parameter, not to the type
    (6.7.6.3p7, p8, p15). *)
and parameters =
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
      (** The return type keeps its qualifiers, as Clang keeps them and
          GCC does not (C17 6.7.6.3p5,
          {!Backend_difference.Return_qualifiers}); a call has the
          unqualified type. *)
  | Unknown_type of Unknown.t
      (** A type that typec does not compute. Its qualifiers are those
          written on it; any within it, as [typeof] of a [const] object
          has, are part of what is unknown, so no relation compares them. *)

(** Created once for each declaration of a distinct type, as a
    {!record_tag} is, and only by {!declare_distinct}. *)
and distinct = private {
  distinct_id : int;
  distinct_name : string;
  distinct_instance : instance option;
      (** The instance that it is, of a distinct generic (design 3.5
          rule 3), whose generic [distinct_name] is. *)
  distinct_privacy : privacy;
  distinct_at_file_scope : bool;  (** As for {!record_tag}. *)
  representation : t;
      (** The unqualified arithmetic or pointer type that it has the size,
          alignment and representation of. *)
}

(** Persistent maps by instance, which a {!trial} restores by keeping
    the map that it began with. *)
module Instances : Map.S with type key = instance

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
  | Fixed_and_unfixed
      (** An enumeration declared both with and without a fixed type (C23
          6.7.2.2). *)
  | Another_fixed_type
      (** An enumeration declared with two fixed types (C23 6.7.2.2). *)
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
(** Adjusts and unqualifies the parameter types. *)

val qualify : Qualifiers.t -> t -> (t, error) result
(** Adds qualifiers. On an array type they go to its element type. *)

val atomic : t -> (t, error) result
(** The specifier [_Atomic(T)] (6.7.2.4). *)

(** {1 Tags} *)

(** Each declaration says whether it stands at file scope, which design
    3.5 rule 2 asks of every type in a type argument. *)

val create_tags : unit -> tags

val declare_record :
  tags -> record_kind -> string option -> at_file_scope:bool -> record_tag
(** A structure or union with the tag of its own specifier, or none. *)

val declare_variant :
  tags -> Typec_syntax.Spelling.type_name -> at_file_scope:bool -> record_tag
(** The structure that the variant of this name lowers to (design 10.1). *)

val declare_alias_record :
  tags -> record_kind -> string -> at_file_scope:bool -> record_tag
(** The untagged structure or union that the alias of this name defines
    (design 10.2). *)

val declare_instance :
  tags ->
  record_kind ->
  instance ->
  define:(record_tag -> unit) ->
  record_tag
(** The structure or union of an instance, which stands at file scope
    (design 10.3): the same tag for the same instance. The first
    declaration defers [define] of the record to the first need of it
    complete, which {!define_instance} meets; until then it is
    incomplete. [define] completes the record or raises; a need of the
    record from within [define] finds it incomplete. A [define] that
    leaves it incomplete, as one of a generic variant that is not
    complete yet does, runs again at the next need. *)

val declare_variant_instance :
  tags -> instance -> define:(record_tag -> unit) -> record_tag
(** The structure of an instance of a variant generic, as
    {!declare_instance} declares one of an alias generic; [define]
    completes it with {!define_variant_instance}. *)

val read_instance : tags -> instance -> read:(unit -> t) -> t
(** The type of an instance of a transparent alias or distinct generic:
    [read ()] at its first reading, the same type after. *)

val trial : tags -> (unit -> 'a) -> 'a
(** [read ()], after which the tags hold what they held before it, apart
    from the ids that it used: a generic's definition check defines no
    instance (design 3.5 rule 7). *)

val define_instance : tags -> t -> instance option
(** A need of [t] complete (design 10.3): runs the deferred definition of
    the instance that [t] is, or is an array of, and gives the instance
    where this call completed it. Only the one function of the front end
    that every need passes through calls it, so that nothing else
    defines an instance. *)

val end_deferral : tags -> unit
(** Drops every definition deferred still, when reading ends: no later
    question defines an instance. *)

(** A point in the order in which a unit declares its tags. *)
type moment

val now : tags -> moment
val record_declared_before : record_tag -> moment -> bool
(** Whether the tag was first declared before the moment. *)

val enum_declared_before : enum_tag -> moment -> bool
(** Whether the tag was first declared before the moment. *)

type named_tag = Named_record of record_tag | Named_enum of enum_tag

val named_tags : t -> named_tag list
(** The structures, unions and enumerations that [t] names as a type
    argument names them (design 10.3): those it is, points to, is an
    array of, returns or takes, not the members of one. *)

val named_type : named_tag -> t
(** The structure, union or enumerated type of the tag. *)

val needed_tag : t -> named_tag option
(** The structure, union or enumeration that a need of [t] complete asks
    for: [t] itself, or the element of an array. *)

val declare_opaque : tags -> string -> record_tag
(** A new type parameter of the definition check of a generic, named as
    the definition writes it: a complete structure without members, an
    opaque value type. *)

val is_opaque : t -> bool
(** Whether [t], qualified or not, is an opaque value type. *)

val mentions_opaque : tags -> t -> bool
(** Whether [t] mentions a type parameter (design 7.1 rule 4): an opaque
    value type is part of [t], as {!mentions_distinct} reads "part", an
    argument of an instance that [t] is, or the type of a member of a
    structure or union that [t] is. *)

(** A constructor of a variant: its name and its fields in order, whose
    position in the list of its variant is its tag (design 10.1 rule 1).
    In an instance, a field whose type is void does not exist (design 3.5
    rule 6); [void_fields] names those, in order, for messages. *)
type constructor = {
  constructor_name : Typec_syntax.Spelling.constructor;
  fields : member list;
  void_fields : string list;
}

val declare_enum : tags -> string option -> at_file_scope:bool -> enum_tag

val declare_distinct :
  ?instance:instance ->
  tags ->
  string ->
  privacy ->
  t ->
  at_file_scope:bool ->
  (t, error) result
(** A new distinct type of this name and privacy over its
    representation; with [instance], that instance of the distinct
    generic of this name. *)

type typedef_name = { name : string; declared : Typec_syntax.Tree.reference }
(** A typedef name of an untagged structure, union or enumeration, with
    the declarator that gives it to the type (design 3.5 rule 2). *)

val name_untagged : tags -> t -> typedef_name list -> unit
(** Records the names of the typedef declarators that derive no type in
    the declaration whose specifier is the untagged structure, union or
    enumeration [t], qualified or not (design 3.5 rule 2), with the
    qualifiers of [t], which the names denote. The one
    declaration that holds the specifier gives all its names at once. Any
    other type is left as it is: one that an attribute makes unknown has
    no name to record. *)

val typedef_names : tags -> t -> typedef_name list
(** The distinct names that {!name_untagged} recorded for [t], sorted,
    each with its first declarator; none for a type that is no untagged
    structure, union or enumeration. *)

val typedef_qualifiers : tags -> t -> Qualifiers.t
(** The qualifiers of the type that the names of {!typedef_names} denote,
    those of the specifiers of their declaration, whatever the qualifiers
    of [t]: [const] for [typedef const struct { int x; } s;]. *)

val define_record :
  Target.t -> tags -> record_tag -> member list -> (unit, error) result
(** Completes a structure or union with its members in order. *)

val define_variant :
  Target.t ->
  tags ->
  record_tag ->
  privacy ->
  scope:Typec_syntax.Tree.span ->
  constructor list ->
  member list ->
  (unit, error) result
(** Completes the structure of a declared variant, as {!define_record}
    does, and gives the variant its privacy, the tokens where its
    declaration is in scope, and its constructors. *)

val define_variant_instance :
  Target.t ->
  tags ->
  record_tag ->
  privacy ->
  constructor list ->
  member list ->
  (unit, error) result
(** Completes the structure of an instance of a variant generic, as
    {!define_variant} does a declared variant, with no scope: its names
    stand at file scope before the first use of its application (design
    10.3), so every use is in their scope. *)

val constructors : tags -> t -> constructor list option
(** The constructors of a variant, qualified or not, in order; [None]
    where [t] is no variant or one that is incomplete here. *)

val variant_scope : tags -> t -> Typec_syntax.Tree.span option
(** The tokens from the declaration of a variant, qualified or not, to
    the end of the scope that holds it, where the names that it derives
    denote it (design 10.1 rule 6); [None] for any other type, for an
    incomplete variant and for an instance, whose names stand before
    every use (10.3). A variant stays complete after its scope ends, so
    the caller checks that a use lies within; at file scope the end is
    the last token, which may be a pragma token. *)

val privacy : tags -> t -> privacy
(** The privacy of a variant that is complete here or of a distinct type,
    qualified or not; [Public] for any other type. *)

val check_unfixed_list : tags -> enum_tag -> (unit, error) result
(** Whether the list of an enumeration without a fixed type may be read
    here: not where the type has a fixed type or a list already. *)

val define_enum :
  tags -> enum_tag -> Integer.t Unknown.answer -> (unit, error) result
(** Completes an enumerated type without a fixed type at its list, as
    {!check_unfixed_list} allows, with its compatible integer type (see
    {!Arithmetic.enum_compatible_type}). The type is unknown where an
    attribute that typec does not know decides it. *)

val fix_enum :
  tags ->
  enum_tag ->
  Integer.t Unknown.answer ->
  listed:bool ->
  (Integer.t Unknown.answer, error) result
(** A declaration of an enumerated type with this fixed type (C23
    6.7.2.2), and its list where [listed]. The first completes the type
    with its fixed type, which every later one repeats; the result is that
    type, the one its enumerators take. A known type that differs from the
    first is an error; an unknown one is not, as it may be any. *)

val record_members : tags -> record_tag -> member list option
(** The members of a complete structure or union, in order. *)

(** A member that a structure or union may hold at any depth. *)
type held =
  | Const_member  (** one that is const-qualified *)
  | Flexible_array_member

val holds : tags -> t -> held option Unknown.answer
(** The first member, in order, that an object of the type, or each
    element of one of the array type, holds as a member, as a member of a
    member, or as an element of an array member, at any depth; pointed-to
    types and the representations of distinct types are not held. An
    incomplete structure or union holds none. The answer is found when a
    structure or union is defined, so asking costs no walk. *)

val holds_variant : tags -> t -> bool
(** Whether an object of the type, or each element of one of the array
    type, is a variant or holds one as {!holds} holds a member. An
    incomplete structure or union and an unknown type hold none. The
    answer is found when a structure or union is defined, so asking costs
    no walk. *)

val first_variant : tags -> t -> t option
(** The first variant among the type and the subobjects that eliding its
    braces, then theirs, would put an initialiser in (C11 6.7.9p20): the
    first element of an array of a length other than 0, and the first
    member with a position of a structure or union (see {!member_at}). An
    incomplete structure or union has none. The answer for a structure or
    union is found when it is defined, so asking walks only the array
    types around one. *)

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

val as_variant : t -> variant_name option
(** The name of the variant whose structure [t] is, qualified or not, or
    [None] where [t] is no variant. *)

val as_result : t -> instance option
(** The instance of the universe's [result] (design 3.6) that [t] is,
    qualified or not, whichever name a declaration gives it: what design
    5.1 and 5.2 call a result type. [None] where [t] is no result type. *)

val result_ok : string
val result_err : string
(** The names of the constructors of the universe's [result], as its
    text ({!Typec_cpp.File.universe_text}) declares them. *)

val has_distinct : tags -> bool
(** Whether a distinct type has been declared, so that a type that typec
    does not know may be one or have one inside it. *)

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

val compatible :
  Target.t -> tags -> Typec_cpp.Location.t -> t -> t -> bool Unknown.answer
(** Whether two types are compatible (6.2.7p1, 6.7.3p10, 6.7.6.1p2,
    6.7.6.2p6, 6.7.6.3p15), asked at [location]. The parameters of a
    prototype and of an old-style definition are compared as C11 says, by
    their promoted types, which rejects some pairs that GCC and Clang
    accept with a warning, such as [int g(float);] before
    [int g(x) float x; {...}]. Function types whose return types are
    qualified differently are incompatible, as in Clang; with GCC, which
    drops all but [_Atomic] of those qualifiers, the answer depends on an
    unknown type at [location] ({!Backend_difference.Return_qualifiers}).
    Parts that differ where they are known make two types incompatible
    whatever their unknown parts are. *)

(** The answer of a comparison in the definition of a generic function,
    where a type parameter stands for every argument (design 7.1 rule
    4). *)
type compatibility =
  | Every_argument of bool Unknown.answer
      (** the answer of {!compatible}, the same for every argument *)
  | Argument_decides
      (** a type parameter meets another type in a part that decides *)

val compatible_by_argument :
  Target.t -> tags -> Typec_cpp.Location.t -> t -> t -> compatibility
(** {!compatible}, but that a type parameter compared with another type
    is compatible with it for some arguments and not for others: the
    argument decides unless a part where no type parameter meets another
    type differs. *)

val same_type :
  ?exact:bool ->
  Target.t -> tags -> Typec_cpp.Location.t -> t -> t -> bool Unknown.answer
(** Whether two types are the same (6.7p3), as for the redefinition of a
    typedef name, asked at [location]: equal, but that an {!Opaque} length
    is the same as any constant one, which the backend checks, and that
    the qualifiers of return types compare as for {!compatible}. [exact]
    (default false), where no backend compares the two types later: an
    {!Opaque} length is the same as no length. *)

val composite :
  Target.t -> tags -> Typec_cpp.Location.t -> t -> t -> (t, error) result
(** The composite type of two compatible types (6.2.7p3): [Incompatible]
    when they are not, [Too_large] when the composite exceeds
    {!max_size}. An enumerated type and its compatible integer type have
    the integer type as their composite, as in Clang; with GCC, which
    types it otherwise, it is an unknown type at [location], where the
    composite is formed ({!Backend_difference.Enum_integer_composite}).
    With GCC, the composite of two function types whose compatibility
    depends on the qualifiers of their return types is an unknown
    function type at [location]
    ({!Backend_difference.Return_qualifiers}).
    Where one type is unknown the composite is that unknown type: keeping
    the known side would guess that the unknown one adds nothing to it,
    as [extern int a[];] with an unknown type for [a] that gives its
    length would. *)
