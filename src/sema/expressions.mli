(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The types of expressions (C11 6.3, 6.5) and the statements of function
    bodies (6.8): the type of each expression node, whether it is an
    lvalue, and the constraints that a type depends on.

    The declaration reader types each function body where the definition
    stands, so that a body sees the tags and declarations of the unit at
    its own point, and every expression it reads elsewhere, such as an
    array length or the operand of [typeof]. It gives this module a
    {!context}: how to read what an expression declares and refers to,
    which it alone knows, and its one way to fail.

    Types are those that Clang gives. An expression whose type depends on
    a type that typec does not compute has that unknown type (design
    13.3, P21), as has one that GCC, as the backend, types otherwise
    ({!Backend_difference}); a constraint on an unknown type is the
    backend's to check. The pass reports what it must
    detect to give the types (design 13.3): undeclared names, operands
    that an operator does not take, members that a structure lacks, calls
    of what is not a function, operands that must be lvalues, the
    constraints that decide what a generic selection selects, and the
    statement constraints on controlling expressions, the places of
    [case], [default], [break] and [continue], and [case] values.
    Assignment and argument conversions and the constraints of [return]
    are the backend's.

    Typing also gives each expression its class of constant expression
    (6.6), and the value of an integer one, which every rule that needs a
    constant reads. Initialisers are typed through {!Initialiser}. *)

open Typec_syntax

(** A bit-field member: its width, and the integer type that it is
    declared with or that its enumerated type is compatible with, by which
    its value promotes (6.3.1.1p2) whatever type the backend gives the
    value. [location] is where the member is named, for the unknown type
    of a promotion that GCC gives otherwise. *)
type field = {
  width : int;
  integer : Integer.t Unknown.answer;
  location : Typec_cpp.Location.t;
}

(** Whether an expression is a bit-field, whose integer promotion depends
    on its width: one that it designates, as a member access does, which
    [&] and [sizeof] do not take (6.5.3.2p1, 6.5.3.4p1), or the value of
    one, as Clang takes an assignment to a bit-field, a prefix [++] of one
    and a comma whose right operand is one. *)
type bit_field = Not_bit_field | Bit_field of field | Bit_field_value of field

(** Whether an expression is an lvalue, and whether lvalue conversion
    (6.3.2.1p2) applies to it as it does to one. *)
type category =
  | Lvalue
  | Value
      (** No lvalue. Clang converts it as an lvalue: a member of a
          structure that is no lvalue has the qualifiers of the member,
          and its value has none. *)
  | Atomic_value
      (** The value of an [_Atomic] type that Clang gives the call of a
          function returning one, a cast to one, and a comma or
          conditional expression of such values. Clang converts no such
          value, so it keeps [_Atomic], and takes one only whole and as
          the left operand of [*], [/], [%], [+], [-], [&], [^] and [|]
          with an arithmetic right one, whose usual arithmetic
          conversions drop [_Atomic]. *)

(** What typing gives an expression. [expression_type] is the type that
    Clang gives the expression itself, before the conversions of its
    context: an lvalue keeps its qualifiers, an array and a function
    their own types (6.3.2.1); its value has the type that
    {!Ctype.lvalue_conversion} gives, unless it is an [Atomic_value]. *)
type typed = {
  expression_type : Ctype.t;
  category : category;
  bit_field : bit_field;
}

val designates_bit_field : typed -> bool
(** Whether the expression designates a bit-field, which [sizeof] and [&]
    refuse, rather than give the value of one. *)

(** {1 Constant expressions (6.6)} *)

(** Why an expression of integer constants is an integer constant
    expression only where it is not evaluated (6.6p3, p4), as in the right
    operand of a [&&] whose left operand is false. *)
type flaw =
  | Comma_operator of Tree.span
  | Invalid of { span : Tree.span; diagnostic : Rule.diagnostic }
      (** An operation that fails (6.6p4): an overflow, a division by
          zero, a shift out of range. Its value is opaque. *)

(** An lvalue or a function designator, as a constant expression reads
    it. [static_storage]: it designates an object of static storage
    duration or a function, whose address is an address constant
    (6.6p9), as is its value where it is an array or a function;
    otherwise neither is a constant. [named]: an object that an
    identifier declares, or a member or element of one, whose value no
    constant expression reads (6.6p9) unless it is [const], as GCC and
    Clang read it. *)
type designation = { static_storage : bool; named : bool }

(** The class of an expression that is not an integer constant
    expression. *)
type kind =
  | Arithmetic_constant  (** 6.6p8. *)
  | Address_constant
      (** 6.6p9, or one plus or minus an integer constant expression
          (6.6p7); an integer constant expression cast to a pointer is
          one, a null pointer among them. *)
  | Designator of designation
  | Backend_constant
      (** A constant expression only as the backend decides (6.6p10):
          what typec cannot tell that GCC and Clang both refuse, such as a
          call, which each folds for some builtins, a comma operator, which
          Clang takes, or an operand of a type that typec does not
          compute. *)
  | Not_constant
      (** What GCC and Clang both refuse where it is evaluated: an
          assignment, an increment or a decrement (6.6p3), the value of a
          named object that is not [const], the address of an object of
          automatic or thread storage duration (6.6p9). *)

type constant =
  | Integer_expression of { value : Integer_constant.t; flaw : flaw option }
      (** An integer constant expression (6.6p6) and its value, whose type
          is the one that typing gives the expression. *)
  | Not_integer of { kind : kind; first : Tree.span }
      (** [first] is the first operand or operator that 6.6p6 does not
          allow. *)
  | Unevaluable of { span : Tree.span; diagnostic : Rule.diagnostic }
      (** An integer expression of constants that typec does not evaluate,
          or that breaks a constraint: [sizeof] of an incomplete type, a
          cast to a type that typec does not compute, a [_Generic] whose
          selection depends on one. It is an error wherever it is part of
          an integer constant expression, evaluated or not. *)

(** The typed view of a translation unit, filled as the reader types its
    expressions. Each expression node is typed once and found by its
    span, which no other expression node has: every composite expression
    has tokens of its own beyond those of its operands. *)
type t

val create : unit -> t

(** A constructor expression (design 3.3) that lowering replaces (13.5):
    its span; the name of its variant and of the constructor; the span
    of the name where the constructor is called with arguments, [None]
    for one without fields; its arguments; and, where it initialises a
    whole object of its variant with no brace elided before it, the span
    of that initialiser, which its braced list alone replaces with the
    parentheses around the constructor. *)
type construction = {
  span : Tree.span;
  variant : Ctype.variant_name;
  constructor : Spelling.constructor;
  callee : Tree.span option;
  arguments : Tree.expression list;
  braced : Tree.span option;
}

val constructions : t -> construction list
(** The constructor expressions typed, in source order. *)

(** How a lowered match reaches its scrutinee (design 13.5): through a
    pointer to it, or through a copy where the scrutinee is volatile or
    atomic or is no lvalue that typec knows [&] may take. *)
type access = Through_pointer | Through_copy

(** One step from a position of a pattern down to a field (design 4.7
    rule 1): the member [field] of the constructor [constructor] that the
    position holds, where [through_pointer] says that the position the
    step reaches is the object that the field points to (rule 5). *)
type field_step = {
  constructor : Spelling.constructor;
  field : string;
  through_pointer : bool;
}

(** A binding of a match: its name and the field that it copies, from
    the scrutinee down, outermost step first (design 4.1 rule 4, 4.7
    rule 7). *)
type binding = { name : string; field : field_step list }

(** An arm of a match: its span; the span from its first label to its
    last; the constructors it takes, in the order of its labels, where a
    [default] stands for those no label names (design 4.2); and its
    bindings in order. *)
type matched_arm = {
  arm : Tree.span;
  labels : Tree.span;
  cases : Spelling.constructor list;
  bindings : binding list;
}

(** Whether a test is the condition of an [if], with the span of its
    [else] statement if it has one, or of a [while]. *)
type test_form = If_test of { otherwise : Tree.span option } | While_test

(** A single-pattern test (design 4.6): its form, the constructor that it
    asks for, every constructor of its variant in order, whose tags are
    the valid ones (4.5), its bindings in order, and the span of its
    statement. *)
type test = {
  form : test_form;
  constructor : Spelling.constructor;
  constructors : Spelling.constructor list;
  bindings : binding list;
  controlled : Tree.span;
}

(** The selection tree of a match as lowering writes it (design 13.5):
    a leaf is the number of an arm from 0 in source order; a node reads
    the tag of the field [tag], from the scrutinee down, which is the
    scrutinee where it is empty, of the variant [variant], with a branch
    for one or more of its constructors. *)
type selection_tree =
  | Arm of int
  | Read of {
      tag : field_step list;
      variant : Ctype.variant_name;
      branches : (Spelling.constructor list * selection_tree) list;
    }

(** The arms of a match, and its selection tree where the tree has more
    than one node (design 4.7 rule 6); a tree of one node is the [switch]
    on the scrutinee's tag that [matched] gives. *)
type arms = { matched : matched_arm list; nested : selection_tree option }

(** What a matching selects with the tag of its scrutinee: the arms of a
    match statement, or the one constructor of a single-pattern test. *)
type selection = Arms of arms | Test of test

(** A match statement (design 4) or a single-pattern test (4.6) that
    lowering replaces (13.5): its span, that of its scrutinee, which is
    the operand of a test, the name of its variant, how it reaches the
    scrutinee, and what it selects. Typing records a matching before it
    types what it selects, which is then still to be typed. *)
type 'selects matching_of = {
  statement : Tree.span;
  scrutinee : Tree.span;
  variant : Ctype.variant_name;
  access : access;
  selects : 'selects;
}

type matching = selection matching_of

val matchings : t -> matching list
(** The match statements and single-pattern tests typed, in source
    order. *)

(** Where a statement stands: as a block item, or as the substatement of
    another statement. *)
type standing = Block_item | Substatement

(** The expression statement or declaration that holds a [try] in a
    position of design 5.1 rule 3: its span, without the C labels before
    it; the span of those labels, from the first to the last, if it has
    any; and where it stands. *)
type holder = {
  statement : Tree.span;
  labels : Tree.span option;
  standing : standing;
}

(** The positions of design 5.1 rule 3: the whole of an expression
    statement, [try e;]; the whole right operand of a simple assignment
    that is one; and the whole initialiser of the one declarator of a
    block-item declaration. *)
type try_form = Whole_statement | Assigned | Initialiser

(** A [try] (design 5.1) that lowering replaces (13.5): its span and that
    of its operand; its holder and its position there; the view that
    the parser took in front of the holder, where lowering writes the
    operand; the number of its temporary, counted from 0 in each
    function in source order; the
    instance of [result] that the operand is, and that the function
    returns; and the names of the fields of the [Ok] and the [Err] of
    the operand's type, [None] where the argument is void (design 3.5
    rule 6); and the claimed tag of the slice instance that its value
    converts to (section 8 rule 5), if it converts. *)
type try_site = {
  try_span : Tree.span;
  operand : Tree.span;
  holder : holder;
  form : try_form;
  place : Parser.View.t;
  temporary : int;
  operand_instance : Ctype.instance;
  return_instance : Ctype.instance;
  ok_field : string option;
  err_field : string option;
  converted_to : string option;
}

val tries : t -> try_site list
(** The tries typed, in source order. *)

(** A slice index [s[i]] (design section 8 rule 1), a [slice_sub]
    (rule 3) or a conversion to a slice of const elements (rule 5): its
    whole, the claimed tag of the instance that it reads, the
    [struct R] of design 13.5, and its operands, or for a conversion
    the claimed tag of the instance that it makes, the [struct C].
    [late_call] is whether an operand after the first holds a call or a
    statement expression, which may return a second time (rule 10). *)
type slice_check = {
  whole : Tree.span;
  instance : string;
  check : check;
  late_call : bool;
}

and check =
  | Index of { slice : Tree.span; index : Tree.span }
  | Sub of { slice : Tree.span; low : Tree.span; high : Tree.span }
  | Conversion of { converted_to : string }

(** How lowering writes a slice index (design 13.5, "The check of a
    slice"): with its test, over temporaries that the function whose
    [body] holds it declares, or, where C does not evaluate it, as the
    trap and its operands. *)
type slice_form = Tested of { body : Tree.span } | Untested

val slice_checks : t -> (slice_check * slice_form) list
(** The slice indexes, [slice_sub]s and conversions typed, each with its
    form. *)

(** A [slice_from_array] or a [slice_unchecked] at [span] (design
    section 8 rules 2 and 4), or a string literal that denotes a [str]
    (rule 6), a slice of [instance], its own or the one that it converts
    to (rule 5). Lowering writes it
    as a compound literal of the instance, or, where [braced] holds the
    span of the initialiser around it with its parentheses, as the
    braced list alone in place of that initialiser (13.5). *)
type slice_making = {
  span : Tree.span;
  instance : Ctype.instance;
  making : making;
  braced : Tree.span option;
}

and making =
  | From_array of { operand : Tree.span }
  | Unchecked of { pointer : Tree.span; count : Tree.span }
  | From_string of { literal : Tree.span }

val slice_makings : t -> slice_making list
(** The slices made from arrays, pointers and string literals. *)

(** Whether a function returns void, which decides the form of a
    [return e;] in the scope of a defer statement (design 13.5). *)
type returns = Returns_void | Returns_value

(** A function definition whose body holds a defer statement: its name
    and declarator, which the [__tc_ret] of 13.5 is written from, the
    span of its body, and its defer statements in source order. *)
type function_defers = {
  function_name : string;
  declarator : Tree.declarator;
  body : Tree.span;
  returns : returns;
  sites : Reachability.defer_site list;
}

val defers : t -> function_defers list
(** The functions typed that hold a defer statement, in source order. *)

(** The zero initialiser of an object or subobject whose type mentions a
    type parameter (design 7.1 rule 3): its braced [list], which
    lowering writes as [{}], and the first token of what holds it most
    closely, the compound literal whose list holds it or else the
    declaration whose initialiser does, before which lowering writes
    [__extension__] (13.5). *)
type zero_initialiser = { list : Tree.span; holder : int }

val zero_initialisers : t -> zero_initialiser list
(** The zero initialisers typed, in the order of typing. *)

(** How lowering answers a construct that asks whether types are
    compatible where Type-C text compares a distinct type with them
    (design 13.5), as the backend would answer for its representation:
    for a generic selection, its controlling expression, its
    associations and the result expression it selects; for
    [__builtin_types_compatible_p], its answer. *)
type answer =
  | Selected of {
      controlling : Tree.expression;
      associations : Tree.generic_association list;
      result : Tree.expression;
    }
  | Compatible of bool

type answered = { construct : Tree.span; answer : answer }

val answered : t -> answered list
(** The constructs typed that typec answers, in source order. *)

val find : t -> Tree.expression -> typed option
(** The type of an expression that has been typed: the type that a
    Type-C rule sees (design 13.3). A generic selection has that of the
    expression it selects, and the associations it does not select are
    typed as well, as C requires them to be valid. *)

val find_at : t -> Tree.span -> typed option
(** {!find} of the expression at the span, for a reader that holds the
    span alone, as {!Reachability.exit} does. *)

(** The answers to the constructs that ask whether two types are
    compatible, which the front end gives where a Type-C type is involved
    (design 13.5): each is the answer, or the unknown type that it depends
    on (P21), and [None] for an expression that is not such a construct
    or has not been typed. *)

val selection : t -> Tree.expression -> Tree.expression Unknown.answer option
(** The result expression of a generic selection (6.5.1.1p3), selected
    by the type that {!find} gives the controlling expression. The
    selection is unknown where that type is, or the compatibility of any
    association with it. That of [__builtin_choose_expr] is the operand
    its condition chooses, unknown where the backend evaluates the
    condition, as for a call of [__builtin_constant_p]. *)

val types_compatible : t -> Tree.expression -> bool Unknown.answer option
(** Whether the two types of [__builtin_types_compatible_p] are
    compatible without their top-level qualifiers but [_Atomic], as Clang
    compares them. *)

val constant : t -> Tree.expression -> constant option
(** The class of constant expression of an expression that has been
    typed. *)

(** A type argument of an instance of a generic function (design 7.2
    rule 5): one that an explicit instance writes, or one that a call
    deduces. *)
type type_argument =
  | Written of Tree.type_name * Ctype.t
  | Deduced of Ctype.t

(** What holds an initialiser most closely: the declaration or compound
    literal that begins at a token, before which lowering writes
    [__extension__] for a zero initialiser of design 7.1 rule 3 that the
    initialiser holds (13.5), or a declaration in the first clause of a
    [for], which holds none, as Apple Clang 21 does not read
    [__extension__] there. *)
type initialiser_holder = Holder_at of int | For_clause

(** How typing first read an identifier alone in a pattern, which the
    parser declared (design 4.7 rule 3): a constructor of the named
    variant, or a binding. Each later reading of the same identifier,
    in an instance of the generic function that holds it, takes the
    first, so that an instance reads it as its definition did (7.1 rule
    2). *)
type alone_reading = Constructor_word of string | Binding_word

(** What the declaration reader gives typing. [fail] reports the first
    error at the start of a span and does not return; [entity] gives what
    a resolved use of a name denotes, and [overloaded] whether it names
    a Clang overload set (design 13.3), [generic_definition] whether the
    text read is part of the definition of a generic function, head or
    body, which its check reads (design 7.1 rule 3), and
    [generic_function] the type parameters of the generic function
    that it names, if it names one (design 7.1); [type_argument] refuses
    a type argument of a generic function that is not valid (design 7.2
    rule 5), and [use_instance]
    is told of each use of an instance of one, with its type arguments
    and the tokens that lowering writes as the instance's name (design
    7.3); [apply_generic] applies a generic type to the types
    that a substitution makes of the arguments of one of its instances,
    at the call at the span (design 7.2); [type_name] reads a type name, once,
    declaring what it declares; [declaration holder] reads a declaration
    in a block, binding its identifiers and typing its initialisers, which
    [holder] holds, and
    [type_declaration] a type declaration there. [needs_complete] is
    the one function that every point that needs a type complete passes
    the type to (design 10.3), and [block_literal] is told of each block
    literal, whose body typec does not read, where it stands.
    [views] are those that the parser took in the unit, and
    [moved_operand views ~scope operand type_operand] types the operand
    at [operand] of a [try] with the [views], in the scope [scope], with
    [type_operand], where lowering moves it (design 5.1 rule 3).
    [read_moved span read] runs [read], which types the statement of a
    defer or the operand of a [return] at [span], text that lowering
    writes at each exit of a scope or in a block of its own (section 6
    rules 8 and 12), and records the names that it finds there.
    [array_operand ~whole operand read] types with [read] the operand at
    [operand] of the [slice_from_array] at [whole], which lowering
    writes a second time (section 8 rule 2). *)
type context = {
  typed : t;
  target : Target.t;
  text : Typec_cpp.Reader.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> Rule.diagnostic -> 'a;
  entity : Tree.span -> string -> Tree.reference -> Entity.t;
  overloaded : Tree.reference -> bool;
  generic_definition : bool;
  generic_function : Tree.reference -> Ctype.record_tag list option;
  type_argument : Tree.span -> type_argument -> unit;
  use_instance :
    Tree.span -> written:Tree.span -> Tree.reference -> Ctype.t list -> unit;
  apply_generic :
    Tree.span -> Typec_syntax.Spelling.type_name -> Ctype.t list -> Ctype.t;
  type_name : Tree.type_name -> Ctype.t;
  declaration : initialiser_holder -> Tree.declaration -> unit;
  type_declaration : Tree.scoped_type_declaration -> unit;
  binding : Tree.identifier -> Tree.declared -> Ctype.t -> unit;
      (** declares a binding of a match as an object of the type *)
  alone_reading : Tree.declared -> (unit -> alone_reading) -> alone_reading;
      (** the reading of an identifier alone that typing recorded first,
          else the one that the function gives, which it records *)
  needs_complete : Ctype.t -> unit;
  slice_instance : Tree.span -> Ctype.t -> Ctype.t;
      (** the instance of the universe [slice] over an element type that
          an expression at the span yields (design section 8) *)
  block_literal : unit -> unit;
  subjectless : Tree.attribute list -> unit;
      (** notes attributes of a label or a null statement, whose subject
          mentions no type parameter (design 13.3) *)
  views : Parser.views;
  moved_operand :
    Parser.try_views -> scope:Tree.scope_depth -> Tree.span ->
    (unit -> typed) -> typed;
  read_moved : Tree.span -> (unit -> unit) -> unit;
  array_operand : whole:Tree.span -> Tree.span -> (unit -> typed) -> typed;
  label_address : Tree.label_name -> unit;
      (** notes the label that [&&] takes the address of, a use of its
          name (design 13.5) *)
  copy_deferred : Tree.span -> unit;
      (** counts one more copy of the deferred statement at the span,
          which an exit of its scope runs, against the output limit
          (design 3.5 rule 7) *)
}

val whole_value : context -> Tree.expression -> typed
(** Types an expression and every expression in it, for a use that
    takes its value whole, as GNU [typeof] does: a value of a distinct
    type is not refused (design 3.4). An expression typed before raises
    [Invalid_argument]: it is typed once. *)

val typeof_value : context -> Tree.expression -> typed
(** {!whole_value} for the operand of GNU [__typeof__], which C does not
    evaluate unless its type is variably modified (design 13.5). *)

val refuse_untested_outside : context -> unit
(** Refuses the first slice index typed outside a function body that C
    evaluates (design section 8 rule 9); called after each external
    declaration, when every operand around an index has been judged. *)

val integer_constant :
  context ->
  Tree.expression ->
  (Integer.t * Integer_constant.t, Tree.span) result
(** Types an expression where an integer constant expression is needed
    (6.6p6), and gives the type that typing gives it and its value, or
    the span of the first operand or operator that keeps it from being
    one. One that typec cannot evaluate or whose evaluation fails is an
    error. An expression typed before raises [Invalid_argument]. *)

val initialiser :
  context ->
  holder:initialiser_holder ->
  constant:bool ->
  Ctype.t ->
  Tree.initialiser ->
  Ctype.t
(** Types the initialiser of an object of the type ({!Initialiser}), which
    [holder] holds, and gives the type of the object, which it completes
    where it is an array of unknown size. [constant] says that the object
    has static or thread storage duration, whose initialiser is constant
    (6.7.9p4): an expression that is [Not_constant] is an error. Where
    the initialiser is the [try] of a block-item declaration (design 5.1
    rule 3), it is the point that sees the object, and so decides whether
    the [try] stands in a position. *)

val refuse_instance_name : context -> Tree.expression -> unit
(** Refuses the expression typed before, where an operation takes it
    whole, if it is [__func__], [__FUNCTION__] or [__PRETTY_FUNCTION__]
    in a generic function, whose array has the length of each instance's
    name (design 7.1 rule 3). *)

val note_object :
  context -> Tree.declaration_id -> Ctype.t -> Tree.initialiser -> unit
(** Records that the object of the declaration, of type [t], has the
    initialiser typed before, which a use of the object depends on where
    the object is [const] and the initialiser depends on a type parameter
    (design 7.1 rule 4). *)

val function_body :
  context ->
  name:string ->
  in_generic:bool ->
  declarator:Tree.declarator ->
  return_type:Ctype.t Unknown.answer ->
  Tree.block ->
  function_defers option
(** Types the body of the function [name], declared by [declarator],
    whose [return] statements have
    its return type as their target type (design 3.3), or the unknown
    type of the function where typec does not know it. Where the body
    holds a defer statement, it gives what it records of them.
    [in_generic]: the function is the definition of a generic function. *)

val quote : string -> string
(** A spelling from the text in a message, quoted and cut short. *)

val missing_text : Ctype.variant_name -> Selection.missing -> string option
(** The error of design 4.2 rule 1 for what a match on the variant of
    this name misses, or [None] where it misses nothing. *)

val needing : string -> Unknown.t -> Rule.diagnostic
(** The refusal where [need] depends on an unknown type. *)
