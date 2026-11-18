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
  | Generic_declaration
      (** a generic type (design 3.5), whose name alone is no type *)
  | Generic_function_declaration of Tree.span
      (** a generic function (design 7.1), whose name alone is no
          function, with the span of its text, which only its instances
          write (design 7.3) *)

(** The typedef [name] of an argument (design 10.3), written as [line],
    after the lines that declare the tags it names. *)
type argument_typedef = {
  name : string;
  line : string;
  tag_lines : Type_name.tag_line list;
}

(** A text of an instance that a placement writes (design 10.3): at its
    first use, the typedefs of its arguments that no earlier text
    declares, before the texts that the reading of its definition puts
    there, and its declaration from [generic] after those; its definition
    at the first point that needs it complete. *)
type step =
  | Typedefs of argument_typedef list
  | Declared of { generic : Tree.type_declaration }
  | Prototype
      (** of a function instance, at its first use *)
  | Defined
      (** of a function instance, after what its reading puts at its
          first use *)

(** Where lowering places a text of an instance (design 10.3): at the
    anchor [at], in front of the external declaration whose use or need
    puts it there, or after the forward declaration that begins it. The
    text that lowering writes from no token of the definition carries
    the line of [application], an application of the instance. *)
type placement = {
  instance : Ctype.instance;
  step : step;
  at : Tree.anchor;
  application : Tree.span;
}

(** The definition of a generic that an instance writes: a generic
    type's declaration, or a generic function's definition with its
    type parameters, and the [span] of the generic function's text from
    [generic], which declares them and which readings read. *)
type generic_definition =
  | Type_generic of Tree.type_declaration
  | Function_generic of {
      span : Tree.span;
      type_parameters : Tree.parameter_name list;
      definition : Tree.function_definition;
    }

(** The definition of an instance as lowering writes it (design 10.3):
    the declaration of the [generic] whose definition it is, the name
    that lowering writes for the tokens of each span in it, a use of a
    type parameter or an application, the spans of the fields that do
    not exist in it because their type is void (design 3.5 rule 6), and
    its constructs [typed] with the instance's arguments. Spans of names
    may nest, as an application's arguments do. *)
type instance_text = {
  generic : generic_definition;

  names : (Tree.span * string) list;
  void_field_spans : Tree.span list;
  typed : Expressions.t;
}

(** An instance of a generic function that the unit uses (design 7.3
    rule 1): the declaration of its [generic_function], the instance,
    whose name {!Encoding.instance_name} gives, its type arguments, and
    the use that is its first, in front of whose external declaration,
    at [anchor], its declaration stands (design 10.3). *)
type function_instance = {
  generic_function : Tree.reference;
  instance : Ctype.instance;
  type_arguments : Ctype.t list;
  first_use : Tree.span;
  anchor : Tree.anchor;
}

(** What the unit is read for: a C unit, or the header of an interface
    (design 9.3), which lowering writes with the definition of each
    instance under its guard. *)
type product = Unit_text | Header_text

type t

val product : t -> product
(** The product that {!read} was given. *)

val tags : t -> Ctype.tags
val items : t -> item list

val placements : t -> placement list
(** The texts of the instances (design 10.3), in the order in which
    they stand: a declaration where the instance is first used, and the
    definition of a structure, union or variant instance where a point
    first needs it complete. The texts that a definition needs, and
    those of the instances that the definition of an alias or distinct
    instance uses, which is its declaration, stand before it. A typedef
    instance is whole at its declaration. *)

val instance_names : t -> (Tree.span * string) list
(** The name of the instance that each application of the unit's own
    text, outside the definitions of generics, lowers to (design 13.5).
    Spans may nest, as an application's arguments do. *)

val function_instances : t -> function_instance list
(** The instances of generic functions that the unit's own text uses,
    outside the definitions of generic functions, in the order of their
    first uses: one for each instance, however many uses name it. *)

val zero_initialisers :
  t -> Tree.function_definition -> Expressions.zero_initialiser list
(** The zero initialisers of design 7.1 rule 3 in the definition of a
    generic function, which every instance writes as lowering does
    (13.5). *)

val instance_text : t -> Ctype.instance -> instance_text option
(** The definition of an instance as its reading found it, [None] for
    one whose definition no point needed. *)

val entity : t -> Tree.reference -> entity option
(** What a declaration that the reader has read declares, as of that
    declaration and its initialiser: a later one of the same entity may
    complete its type. [None] for one in a place that the reader does not
    read, the body of a Clang block literal. *)

val tag : t -> Tree.tag_id -> tag option
(** The tag that a tag declaration declares, [None] as for {!entity}. *)

val latest_generic : t -> Tree.type_declaration -> Tree.type_declaration
(** [latest_generic result generic] is the latest declaration of the
    generic type that [generic] declares: the variant that completes it
    where one does (design 3.1 rule 4), which is its definition. The
    declaration of every application is a generic's. *)

val applied_generic : t -> int -> generic_definition option
(** [applied_generic result index] is the generic of the application
    whose first token is the token [index], wherever the unit's reading
    met it, a definition of a generic included: the latest declaration
    of a generic type, as {!latest_generic} gives it, or the definition
    of a generic function; [None] where no application begins. *)

val applications : t -> (Ctype.instance * Tree.span) list
(** Each instance that the unit's reading applied, wherever the
    application stands: in the unit's own text, in an included file's,
    or in a definition that the reading of an instance read; a reading
    forgotten adds none, nor does an application that mentions a type
    parameter. With each, its latest application, in the order of
    {!Ctype.Instances}. *)

val instance_generic : t -> Ctype.instance -> generic_definition
(** [instance_generic result instance] is the generic of an instance
    that the unit applied, as {!applied_generic} gives it. *)

val type_declarations : t -> Tree.type_declaration list
(** The type declarations that the reader has read, in source order:
    those that lowering replaces (design 13.5). *)

val typed : t -> Expressions.t
(** The expressions of the unit's own text that the reader has typed,
    outside the definitions of generics: those whose constructs lowering
    replaces (design 13.5). *)

val slice_checks : t -> (Expressions.slice_check * Expressions.slice_form) list
(** The slice indexes, [slice_sub]s and conversions typed in the unit's
    own text and in the definition of each instance that it uses, each
    with its form ({!Expressions.slice_checks}). *)

val selection_sizes : t -> Selection.size list
(** What building the selection tree of each match and test took, in the
    unit's own text and in the definition of each instance that it uses
    ({!Expressions.selection_sizes}). *)

val try_holders : t -> Expressions.try_holder list
(** The holders of a [try] typed in the unit's own text and in the
    definition of each instance that it uses
    ({!Expressions.try_holders}). *)

val instance_budget : int
(** The instance budget of design 3.5 rule 7 in bytes: the most that
    {!instance_bytes} may reach before {!read} refuses the unit. *)

val instance_bytes : t -> int
(** The bytes that the readings for the unit's instances charged the
    instance budget (design 3.5 rule 7). *)

val copy_bytes : t -> int
(** The bytes that the copies of the unit's deferred statements charged
    the output limit in the front end (design 3.5 rule 7): the front
    end's bound on the copies, which lowering charges again. *)

val longest_instance_code : t -> int
(** The most bytes of the code of one instance that the unit encoded,
    those of definition checks included ({!Encoding.code_length}). *)

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

val selection : t -> Tree.expression -> Tree.expression Unknown.answer option
(** What a generic selection that the reader has typed selects; see
    {!Expressions.selection}. *)

val types_compatible : t -> Tree.expression -> bool Unknown.answer option
(** The answer of a [__builtin_types_compatible_p] that the reader has
    typed; see {!Expressions.types_compatible}. *)

val read :
  Target.t -> product:product -> Reader.t -> Parser.scopes -> (t, error) result
(** [read target ~product text scopes] reads the unit whose external
    declarations [scopes] holds, parsed from [text], for [target], as
    [product]. *)

val tag_max : t -> Exact_integer.t
(** The value of the hidden enumerator that ends the enumeration of
    every variant's tags in the unit, [INT_MAX] of its target, so that
    the tag has the size of [int] under either enumeration
    representation. *)
