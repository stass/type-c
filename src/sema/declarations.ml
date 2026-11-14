(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type linkage = External | Internal | No_linkage
type storage = Static_storage | Thread_storage | Automatic_storage

type declared =
  | Object of { object_type : Ctype.t; linkage : linkage; storage : storage }
  | Function of {
      function_type : Ctype.t;
      linkage : linkage;
      inline : bool;
      noreturn : bool;
    }
  | Typedef of Ctype.t
  | Enumerator of { enumerator_type : Ctype.t; value : Integer_constant.t }

type entity = { name : string; entity : int; declared : declared }
type tag = Record_tag of Ctype.record_tag | Enum_tag of Ctype.enum_tag
type scope = (entity, tag) Scope.t

type item =
  | Declaration of entity list
  | Static_assertion
  | Function_definition of { function_entity : entity; body_scope : scope }

type t = { tags : Ctype.tags; file_scope : scope; items : item list }
type error = Reader.error = { location : Location.t; message : string }

(* Far above the operators of a real constant expression, it bounds the
   recursion of the evaluator on the chains that the parser reads in
   loops, whose trees are as deep as they are long. *)
let max_expression_depth = 10_000

(* The reader *)

type state = {
  target : Target.t;
  text : Reader.t;
  tags : Ctype.tags;
  mutable scope : scope;
  mutable prototype_scope : bool;
      (* In a parameter list that is not that of a definition, where [*]
         may stand (6.7.6.2p4). *)
  mutable next_entity : int;
  mutable expression_depth : int;
}

(* Raised at the first error; caught in [read]. *)
exception Failed of error

let fail state (span : Tree.span) message =
  let location = state.text.tokens.(span.first).location in
  raise (Failed { location; message })

(* A spelling from the text in a message, cut short. *)
let max_quoted = 64

let quote text =
  if String.length text <= max_quoted then "'" ^ text ^ "'"
  else "'" ^ String.sub text 0 max_quoted ^ "...'"

let checked state span = function
  | Ok t -> t
  | Error error -> fail state span (Ctype.error_message error)

let constant_checked state span = function
  | Ok constant -> constant
  | Error error -> fail state span (Integer_constant.error_message error)

let integer_type state span integer =
  checked state span (Ctype.integer state.target integer)

let fresh_entity state =
  let entity = state.next_entity in
  state.next_entity <- entity + 1;
  entity

(* [read] in a new innermost scope; also the scope as [read] left it. *)
let within_scope state ~prototype read =
  let saved_scope = state.scope and saved_prototype = state.prototype_scope in
  state.scope <- Scope.enter saved_scope;
  state.prototype_scope <- prototype;
  let result = read () in
  let inner = state.scope in
  state.scope <- saved_scope;
  state.prototype_scope <- saved_prototype;
  (result, inner)

(* Ordinary identifiers (6.2.2, 6.7p3, p4) *)

let linkage_of = function
  | Object { linkage; _ } | Function { linkage; _ } -> linkage
  | Typedef _ | Enumerator _ -> No_linkage

let check_linkage state span name prior next =
  if linkage_of prior = No_linkage || linkage_of next = No_linkage then
    fail state span
      (quote name
     ^ " is declared twice in one scope without linkage (C11 6.7p3)");
  if linkage_of prior <> linkage_of next then
    fail state span
      (quote name ^ " has both internal and external linkage (C11 6.2.2p7)")

let composite state span name prior next =
  match Ctype.composite state.target state.tags prior next with
  | Ok composite -> composite
  | Error Ctype.Incompatible ->
      fail state span
        (quote name ^ " is redeclared with an incompatible type (C11 6.7p4)")
  | Error error -> fail state span (Ctype.error_message error)

(* A declaration of [name] where [prior] is in the same scope. *)
let redeclared state span name prior next =
  match (prior, next) with
  | Typedef old, Typedef same when Ctype.same_type old same -> next
  | Typedef _, Typedef _ ->
      fail state span
        (quote name ^ " is redefined as a typedef of another type (C11 6.7p3)")
  | Object old, Object next ->
      check_linkage state span name prior (Object next);
      if old.storage <> next.storage then
        fail state span
          (quote name
         ^ " is declared both with and without _Thread_local (C11 6.7.1p3)");
      let object_type =
        composite state span name old.object_type next.object_type
      in
      Object { next with object_type }
  | Function old, Function next ->
      check_linkage state span name prior (Function next);
      let function_type =
        composite state span name old.function_type next.function_type
      in
      Function
        {
          next with
          function_type;
          inline = old.inline || next.inline;
          noreturn = old.noreturn || next.noreturn;
        }
  | (Object _ | Function _ | Typedef _ | Enumerator _), _ ->
      fail state span
        (quote name ^ " is redeclared as a different kind of identifier \
                       (C11 6.7p3)")

let declare_ordinary state span name declared =
  let entity =
    match Scope.find_in_innermost state.scope name with
    | None -> { name; entity = fresh_entity state; declared }
    | Some prior ->
        let declared = redeclared state span name prior.declared declared in
        { prior with declared }
  in
  state.scope <- Scope.declare state.scope name entity;
  entity

(* 6.2.2p4, p5: [extern], or a function without a storage class, takes the
   linkage of a visible declaration that has one. *)
let file_scope_linkage state name ~is_function storage =
  let visible () =
    match Scope.find state.scope name with
    | Some { declared; _ } when linkage_of declared <> No_linkage ->
        linkage_of declared
    | Some _ | None -> External
  in
  match (storage : Tree.storage_class option) with
  | Some Static -> Internal
  | Some Extern -> visible ()
  | None when is_function -> visible ()
  | None | Some (Typedef | Thread_local | Auto | Register) -> External

(* Declaration specifiers *)

(* What a list of declaration specifiers says. [storage] excludes
   [_Thread_local], which [thread_local] records. *)
type specified = {
  storage : Tree.storage_class option;
  thread_local : bool;
  base_type : Ctype.t;
  inline : bool;
  noreturn : bool;
  aligned : Tree.span option;  (** The first alignment specifier. *)
}

(* The declaration specifiers of each kind, in order. *)
type sorted = {
  storage_classes : Tree.storage_class list;
  basic : Tree.basic_type_specifier list;
  others : Tree.type_specifier list;
  qualifiers : Tree.type_qualifier list;
  function_specifiers : Tree.function_specifier list;
  alignments : Tree.alignment Tree.spanned list;
  attributes : Tree.attribute list;
}

let sort_specifiers (specifiers : Tree.specifiers) =
  let add sorted (specifier : Tree.declaration_specifier Tree.spanned) =
    match specifier.node with
    | Storage_class c ->
        { sorted with storage_classes = c :: sorted.storage_classes }
    | Type_specifier (Basic b) -> { sorted with basic = b :: sorted.basic }
    | Type_specifier other -> { sorted with others = other :: sorted.others }
    | Type_qualifier q -> { sorted with qualifiers = q :: sorted.qualifiers }
    | Function_specifier f ->
        { sorted with function_specifiers = f :: sorted.function_specifiers }
    | Alignment_specifier a ->
        let alignment = { Tree.span = specifier.span; node = a } in
        { sorted with alignments = alignment :: sorted.alignments }
    | Attributes list ->
        { sorted with attributes = List.rev_append list sorted.attributes }
  in
  let empty =
    { storage_classes = []; basic = []; others = []; qualifiers = [];
      function_specifiers = []; alignments = []; attributes = [] }
  in
  let sorted = List.fold_left add empty specifiers in
  { sorted with alignments = List.rev sorted.alignments }

(* 6.7.1p2: one storage class, but [_Thread_local] with [static] or
   [extern]. *)
let storage_class state span classes =
  let thread_local, others =
    List.partition (fun c -> c = Tree.Thread_local) classes
  in
  match (thread_local, others) with
  | ([] | [ _ ]), [] -> None
  | [], [ storage ] -> Some storage
  | [ _ ], [ ((Static | Extern) as storage) ] -> Some storage
  | _ ->
      fail state span
        "a declaration has storage classes that do not combine (C11 6.7.1p2)"

(* The arithmetic types that type specifiers name (6.7.2p2): the integer
   ones, then the floating ones, each multiset sorted in the order of
   [Tree.basic_type_specifier]. *)
let basic_type (specifiers : Tree.basic_type_specifier list) :
    Arithmetic.t option =
  match (Integer.of_specifiers specifiers, List.sort compare specifiers) with
  | Some integer, _ -> Some (Integer integer)
  | None, [ Float ] -> Some (Real Float)
  | None, [ Double ] -> Some (Real Double)
  | None, [ Long; Double ] -> Some (Real Long_double)
  | None, [ Float; Complex ] -> Some (Complex Float)
  | None, [ Double; Complex ] -> Some (Complex Double)
  | None, [ Long; Double; Complex ] -> Some (Complex Long_double)
  | None, _ -> None

let qualifiers_of (qualifiers : Tree.type_qualifier list) =
  let add (q : Ctype.qualifiers) (qualifier : Tree.type_qualifier) =
    match qualifier with
    | Const -> { q with const = true }
    | Restrict -> { q with restrict = true }
    | Volatile -> { q with volatile = true }
    | Atomic -> { q with atomic = true }
    (* Clang's nullability does not change a C type. *)
    | Nullability _ -> q
  in
  List.fold_left add Ctype.no_qualifiers qualifiers

let spanned_qualifiers (qualifiers : Tree.type_qualifier Tree.spanned list) =
  qualifiers_of (List.map (fun (q : _ Tree.spanned) -> q.node) qualifiers)

let record_kind : Tree.struct_or_union -> Ctype.record_kind = function
  | Struct -> Struct
  | Union -> Union

let wrong_kind_of_tag state (name : Tree.identifier) =
  fail state name.span
    (quote name.node
   ^ " is declared as a different kind of tag (C11 6.7.2.3p2)")

(* Raised where an expression is not an integer constant expression;
   caught in [constant_expression], which is not a failure. *)
exception Not_integer_constant of Tree.span

(* The size of a type that the target model gives (6.5.3.4p2, p4); the
   front end knows no other (design P16). *)
let size_in_bytes state span (t : Ctype.t) =
  let target = state.target in
  let of_integer integer =
    Some (Target.integer_width target integer / target.char_bit)
  in
  let of_floating : Arithmetic.floating -> int = function
    | Float -> target.sizeof_float
    | Double -> target.sizeof_double
    | Long_double -> target.sizeof_long_double
  in
  let incomplete () =
    fail state span
      "sizeof is applied to a function or an incomplete type (C11 6.5.3.4p1)"
  in
  if t.qualifiers.atomic then None
  else
    match t.shape with
    | Void | Function _ -> incomplete ()
    | Arithmetic (Integer Bool) -> None
    | Arithmetic (Integer integer) -> of_integer integer
    | Arithmetic (Real floating) -> Some (of_floating floating)
    (* 6.2.5p13: the real and imaginary parts of a complex type. *)
    | Arithmetic (Complex floating) -> Some (2 * of_floating floating)
    | Enum tag -> (
        match Ctype.enum_integer state.tags tag with
        | Some integer -> of_integer integer
        | None -> incomplete ())
    | Pointer _ -> Some target.sizeof_pointer
    | Record _ | Array _ when not (Ctype.is_complete state.tags t) ->
        incomplete ()
    | Array _ when Ctype.is_variably_modified t ->
        raise (Not_integer_constant span)
    | Record _ | Array _ -> None

(* Constant expressions (6.6) *)

(* The outcome of reading an expression as an integer constant
   expression. *)
type evaluation =
  | Constant of Integer_constant.t
  | Not_constant of Tree.span
      (** The operand or operator that 6.6p3 and p6 do not allow. *)

let not_constant (expression : Tree.expression) =
  raise (Not_integer_constant expression.span)

let rec strip_parentheses (expression : Tree.expression) =
  match expression.node with
  | Parenthesized inner -> strip_parentheses inner
  | _ -> expression

let is_floating_constant expression =
  match (strip_parentheses expression).node with
  | Constant (Floating _) -> true
  | _ -> false

let spelling state (span : Tree.span) =
  Reader.spelling state.text state.text.tokens.(span.first)

let identifier_value state (expression : Tree.expression) name =
  match Scope.find state.scope name with
  | Some { declared = Enumerator { value; _ }; _ } -> value
  | Some { declared = Object _ | Function _ | Typedef _; _ } ->
      not_constant expression
  | None ->
      fail state expression.span
        (quote name ^ " is not declared (C11 6.5.1p2)")

(* Declarators *)

(* A declarator applied to a type, read outside in. [parameter_qualifiers]
   are those between the brackets of the derivation that a parameter
   adjusts to a pointer (6.7.6.3p7); [body] is the parameter scope of the
   function derivation that a definition defines. *)
type derived = {
  name : string option;
  declared_type : Ctype.t;
  parameter_qualifiers : Ctype.qualifiers;
  body : scope option;
}

(* Whether a derivation is the last before the name: the outermost of the
   type it derives. *)
let rec applies_to_name (inner : Tree.declarator option) =
  match inner with
  | None -> true
  | Some { node = Name _; _ } -> true
  | Some { node = Parenthesized_declarator inner; _ } ->
      applies_to_name (Some inner)
  | Some { node = Pointer _ | Block_pointer _ | Array _ | Function _; _ } ->
      false

(* A construct of the GNU profile that the parser reads and no type
   models yet. *)
let not_typed state span construct package =
  fail state span
    (Printf.sprintf "%s is not typed yet (plan %s)" construct package)

(* The GNU attributes that change neither a type nor a value that the
   declarations compute: the alignment and layout of records are the
   backend's (6.7.5p3), and the rest shape diagnostics or code. Any other
   attribute may, as [mode] and [vector_size] change a type, so it is an
   error until typing reads it (TODO.md). *)
let neutral_attributes =
  [ "alloc_align"; "alloc_size"; "aligned"; "always_inline"; "availability";
    "cold"; "const"; "constructor"; "deprecated"; "destructor";
    "disable_tail_calls"; "enum_extensibility"; "flag_enum"; "format";
    "format_arg"; "gnu_inline"; "hot"; "leaf"; "malloc"; "noescape";
    "noinline"; "nonnull"; "noreturn"; "not_tail_called"; "nothrow"; "pure";
    "returns_nonnull"; "section"; "sentinel"; "swift_attr"; "unavailable";
    "unused"; "used"; "visibility"; "warn_unused_result"; "weak" ]

let read_attributes state (attributes : Tree.attribute list) =
  let read (attribute : Tree.attribute) =
    let name = attribute.node.name.node in
    if not (List.mem name neutral_attributes) then
      not_typed state attribute.span
        ("the attribute " ^ quote name)
        "0.7b"
  in
  List.iter read attributes

let rec read_specifiers state ~standalone (specifiers : Tree.specifiers) =
  let span = (List.hd specifiers).span in
  let sorted = sort_specifiers specifiers in
  read_attributes state sorted.attributes;
  let storage = storage_class state span sorted.storage_classes in
  let base = base_type state span ~standalone sorted in
  let qualifiers = qualifiers_of sorted.qualifiers in
  let base_type = checked state span (Ctype.qualify qualifiers base) in
  List.iter (alignment state) sorted.alignments;
  {
    storage;
    thread_local = List.mem Tree.Thread_local sorted.storage_classes;
    base_type;
    inline = List.mem Tree.Inline sorted.function_specifiers;
    noreturn = List.mem Tree.Noreturn sorted.function_specifiers;
    aligned =
      (match sorted.alignments with
      | [] -> None
      | first :: _ -> Some first.span);
  }

and base_type state span ~standalone sorted =
  match (sorted.basic, sorted.others) with
  | [], [] ->
      fail state span "a declaration has no type specifier (C11 6.7.2p2)"
  | [ Void ], [] -> Ctype.void
  | basic, [] when List.mem Tree.Float16 basic ->
      not_typed state span (quote "_Float16") "0.7b"
  | basic, [] -> (
      match basic_type basic with
      | Some arithmetic ->
          checked state span (Ctype.arithmetic state.target arithmetic)
      | None ->
          fail state span
            "type specifiers that do not combine (C11 6.7.2p2)")
  | [], [ other ] -> other_type state span ~standalone other
  | _ -> fail state span "type specifiers that do not combine (C11 6.7.2p2)"

and other_type state span ~standalone (specifier : Tree.type_specifier) =
  match specifier with
  | Basic _ -> invalid_arg "Declarations.other_type"
  | Atomic_type type_name ->
      checked state span (Ctype.atomic (read_type_name state type_name))
  | Struct_or_union { kind; tag; members; attributes } ->
      read_attributes state attributes;
      let kind = record_kind kind in
      Ctype.record (record_type state span ~standalone kind tag members)
  | Enum { underlying = Some _; _ } ->
      not_typed state span "the fixed type of an enumeration" "0.7b"
  | Enum { tag; enumerators; underlying = None; attributes } ->
      read_attributes state attributes;
      Ctype.enum (enum_type state span ~standalone tag enumerators)
  | Typeof_expression _ | Typeof_type _ ->
      not_typed state span (quote "typeof") "0.7b"
  | Typedef_name name -> (
      match Scope.find state.scope name with
      | Some { declared = Typedef t; _ } -> t
      | Some _ | None ->
          fail state span (quote name ^ " is not a typedef name"))

(* 6.7.5p3: the value is the backend's to check, as layout is. *)
and alignment state (alignment : Tree.alignment Tree.spanned) =
  match alignment.node with
  | Alignas_type type_name -> ignore (read_type_name state type_name)
  | Alignas_expression expression -> (
      match constant_expression state expression with
      | Constant _ -> ()
      | Not_constant span ->
          fail state span
            "an alignment is not an integer constant expression (C11 6.7.5p3)")

(* Tags (6.7.2.3) *)

(* The tag that [struct s] without a body names: the visible one, or one
   it declares here (p8). Alone in a declaration it declares one in this
   scope, hiding any other (p7). *)
and referenced_tag state ~standalone (name : Tree.identifier) =
  if standalone then Scope.find_tag_in_innermost state.scope name.node
  else Scope.find_tag state.scope name.node

and declare_tag state (name : Tree.identifier) tag =
  state.scope <- Scope.declare_tag state.scope name.node tag

and record_type state span ~standalone kind (tag : Tree.identifier option)
    members =
  let found =
    match (tag, members) with
    | None, _ -> None
    | Some name, Some _ -> Scope.find_tag_in_innermost state.scope name.node
    | Some name, None -> referenced_tag state ~standalone name
  in
  let record =
    match (found, tag) with
    | Some (Record_tag record), _ when record.kind = kind -> record
    | Some _, Some name -> wrong_kind_of_tag state name
    | _, Some name ->
        let record = Ctype.declare_record state.tags kind (Some name.node) in
        declare_tag state name (Record_tag record);
        record
    | _, None -> Ctype.declare_record state.tags kind None
  in
  Option.iter (define_record state span record) members;
  record

(* [span] is the specifier's: GNU C allows a body without members. *)
and define_record state span record (members : Tree.member_declaration list)
    =
  let members = List.concat_map (read_member state) members in
  checked state span
    (Ctype.define_record state.target state.tags record members)

and enum_type state span ~standalone (tag : Tree.identifier option) enumerators
    =
  let found =
    match (tag, enumerators) with
    | None, _ -> None
    | Some name, Some _ -> Scope.find_tag_in_innermost state.scope name.node
    | Some name, None -> referenced_tag state ~standalone name
  in
  (* GNU: an enumeration declared before its list, which 6.7.2.3p3 does
     not allow, as both backends accept it. *)
  let enum =
    match (found, tag) with
    | Some (Enum_tag enum), _ -> enum
    | Some (Record_tag _), Some name -> wrong_kind_of_tag state name
    | _, Some name ->
        let enum = Ctype.declare_enum state.tags (Some name.node) in
        declare_tag state name (Enum_tag enum);
        enum
    | _, None -> Ctype.declare_enum state.tags None
  in
  (match enumerators with
  | Some _ when Ctype.enum_integer state.tags enum <> None ->
      fail state span (Ctype.error_message Ctype.Redefinition)
  | Some enumerators -> define_enum state span enum enumerators
  | None -> ());
  enum

(* Members (6.7.2.1) *)

and read_member state (member : Tree.member_declaration) =
  match member.node with
  | Member_static_assert assertion ->
      static_assert state assertion;
      []
  | Members { specifiers; declarators = [] } ->
      let specified =
        let standalone = List.length specifiers = 1 in
        read_specifiers state ~standalone specifiers
      in
      if is_anonymous_record specifiers then
        [ { Ctype.member_name = None; member_type = specified.base_type;
            bit_field_width = None } ]
      else []
  | Members { specifiers; declarators } ->
      let specified = read_specifiers state ~standalone:false specifiers in
      List.map (read_member_declarator state specified) declarators

(* 6.7.2.1p13: an unnamed member whose type is a structure or union
   specifier without a tag. *)
and is_anonymous_record (specifiers : Tree.specifiers) =
  List.exists
    (fun (specifier : Tree.declaration_specifier Tree.spanned) ->
      match specifier.node with
      | Type_specifier (Struct_or_union { tag = None; members = Some _; _ }) ->
          true
      | _ -> false)
    specifiers

and read_member_declarator state specified
    (declarator : Tree.member_declarator) =
  match declarator.node with
  | Field { declarator = field; attributes } ->
      read_attributes state attributes;
      let derived = derive_object state specified field in
      { Ctype.member_name = derived.name; member_type = derived.declared_type;
        bit_field_width = None }
  | Bit_field { declarator = field; width; attributes } ->
      read_attributes state attributes;
      Option.iter
        (fun span ->
          fail state span
            "a bit-field has an alignment specifier (C11 6.7.5p2)")
        specified.aligned;
      let name, member_type =
        match field with
        | Some field ->
            let derived = derive_object state specified field in
            (derived.name, derived.declared_type)
        | None -> (None, specified.base_type)
      in
      let bit_field_width = Some (bit_field_width state width) in
      { Ctype.member_name = name; member_type; bit_field_width }

and bit_field_width state width =
  match constant_expression state width with
  | Constant { value = Known width_value; _ } -> (
      match Exact_integer.to_int width_value with
      | Some bits -> bits
      | None ->
          fail state width.span (Ctype.error_message Ctype.Invalid_bit_field))
  | Constant { value = Opaque; _ } ->
      fail state width.span
        "the width of a bit-field is one that typec does not evaluate \
         (design P16)"
  | Not_constant span ->
      fail state span
        "the width of a bit-field is not an integer constant expression \
         (C11 6.7.2.1p4)"

(* Enumerations (6.7.2.2) *)

(* The value of each enumerator is known: one the backend evaluates would
   decide the integer type of the enumeration, and with it the types and
   sizes that follow, which typec would have to guess (design P16). *)
and define_enum state span enum (enumerators : Tree.enumerator list) =
  let declare (previous, declared) (enumerator : Tree.enumerator) =
    let name = enumerator.node.name in
    read_attributes state enumerator.node.attributes;
    let ((integer, value) as typed) =
      enumerator_value state previous enumerator
    in
    let enumerator_type = integer_type state name.span integer in
    let constant = Integer_constant.known state.target integer value in
    let entity =
      declare_ordinary state name.span name.node
        (Enumerator { enumerator_type; value = constant })
    in
    (Some typed, (entity, value) :: declared)
  in
  let _, declared = List.fold_left declare (None, []) enumerators in
  let values = List.map snd declared in
  let integer = enum_integer state span values in
  checked state span (Ctype.define_enum state.tags enum integer);
  (* At the closing brace every enumerator takes its final type (C23
     6.7.2.2): int when all values fit, else the enumerated type. *)
  let final_type, final_integer =
    if List.for_all (Integer_constant.fits state.target Int) values then
      (integer_type state span Int, Integer.Int)
    else (Ctype.enum enum, integer)
  in
  List.iter
    (fun (entity, value) ->
      let value = Integer_constant.known state.target final_integer value in
      let declared = Enumerator { enumerator_type = final_type; value } in
      let entity = { entity with declared } in
      state.scope <- Scope.declare state.scope entity.name entity)
    declared

(* The type and value of an enumerator while its list is read: int when
   the value fits, else the type of its value (C23 6.7.2.2, as in GCC and
   Clang). *)
and enumerator_value state previous (enumerator : Tree.enumerator) =
  let target = state.target in
  match (enumerator.node.value, previous) with
  | Some expression, _ -> (
      match constant_expression state expression with
      | Not_constant span ->
          fail state span
            "an enumerator value is not an integer constant expression \
             (C11 6.7.2.2p2)"
      | Constant { value = Opaque; _ } ->
          fail state expression.span
            "an enumerator value is one that typec does not evaluate \
             (design P16)"
      | Constant { value = Known value; _ }
        when Integer_constant.fits target Int value ->
          (Integer.Int, value)
      | Constant { integer_type; value = Known value } -> (integer_type, value))
  | None, None -> (Integer.Int, Exact_integer.zero)
  | None, Some previous -> successor state enumerator.span previous

(* The previous value plus one in its type, or in the next standard type
   of its signedness that holds it. *)
and successor state span (previous_type, previous) =
  let target = state.target in
  let same_signedness =
    if Target.is_signed target previous_type then
      [ Integer.Int; Long; Long_long ]
    else [ Unsigned_int; Unsigned_long; Unsigned_long_long ]
  in
  let candidates =
    List.filter
      (fun integer -> Integer.rank integer >= Integer.rank previous_type)
      same_signedness
  in
  let next = Exact_integer.add previous Exact_integer.one in
  match
    List.find_opt (fun integer -> Integer_constant.fits target integer next)
      candidates
  with
  | Some integer -> (integer, next)
  | None ->
      fail state span
        "an enumerator value is too large for every integer type \
         (C11 6.7.2.2p2)"

(* The narrowest range of two's complement integers that holds the
   values. *)
and enum_integer state span values =
  let negative = List.exists Exact_integer.is_negative values in
  let width_of value =
    let magnitude =
      if Exact_integer.is_negative value then
        Exact_integer.sub (Exact_integer.neg value) Exact_integer.one
      else value
    in
    let sign_bit = if negative then 1 else 0 in
    Exact_integer.bit_length magnitude + sign_bit
  in
  let width =
    List.fold_left (fun width value -> Int.max width (width_of value)) 0 values
  in
  match Arithmetic.enum_compatible_type state.target { negative; width } with
  | Some integer -> integer
  | None ->
      fail state span
        "no integer type holds the values of the enumeration (C11 6.7.2.2p4)"

(* Static assertions (6.7.10) *)

and static_assert state ({ condition; message } : Tree.static_assertion) =
  match constant_expression state condition with
  | Not_constant span ->
      fail state span
        "the condition of a static assertion is not an integer constant \
         expression (C11 6.7.10p2)"
  | Constant constant -> (
      match Integer_constant.truth constant with
      | Some false ->
          let first = (List.hd message).span in
          fail state condition.span
            ("static assertion failed: " ^ quote (spelling state first))
      | Some true | None -> ())

(* Declarators (6.7.6) *)

and underived specified =
  { name = None; declared_type = specified.base_type;
    parameter_qualifiers = Ctype.no_qualifiers; body = None }

and derive_object state specified declarator =
  derive state ~parameter:false ~definition:None (underived specified)
    declarator

(* Tail recursive, so a long chain of derivations needs no stack.
   [definition] is the declaration list of a function definition, whose
   function derivation applied to the name it belongs to. *)
and derive state ~parameter ~definition derived (declarator : Tree.declarator)
    =
  let continue derived = function
    | Some inner -> derive state ~parameter ~definition derived inner
    | None -> derived
  in
  let span = declarator.span in
  match declarator.node with
  | Name name -> { derived with name = Some name }
  | Parenthesized_declarator inner -> continue derived (Some inner)
  | Pointer { qualifiers; inner } ->
      let pointer =
        checked state span (Ctype.pointer_to derived.declared_type)
      in
      let qualifiers = spanned_qualifiers qualifiers in
      let declared_type =
        checked state span (Ctype.qualify qualifiers pointer)
      in
      continue { derived with declared_type } inner
  | Block_pointer _ -> not_typed state span "a block pointer" "0.7b"
  | Array { inner; qualifiers; size } ->
      let adjusted = parameter && applies_to_name inner in
      let qualified = qualifiers <> [] in
      let is_static = match size with Static_sized _ -> true | _ -> false in
      if (qualified || is_static) && not adjusted then
        fail state span
          "qualifiers or static in an array derivation that is not the \
           outermost of a parameter (C11 6.7.6.2p1)";
      let length = array_length state span size in
      let declared_type =
        checked state span
          (Ctype.array_of state.tags derived.declared_type length)
      in
      let parameter_qualifiers =
        if adjusted then spanned_qualifiers qualifiers
        else derived.parameter_qualifiers
      in
      continue { derived with declared_type; parameter_qualifiers } inner
  | Function { inner; parameters } ->
      let defines = definition <> None && applies_to_name inner in
      let parameters, body =
        read_parameters state
          ~definition:(if defines then definition else None)
          parameters
      in
      let declared_type =
        checked state span
          (Ctype.function_returning derived.declared_type parameters)
      in
      let body = if defines then Some body else derived.body in
      continue { derived with declared_type; body } inner

and array_length state span (size : Tree.array_size) : Ctype.length =
  match size with
  | Unsized -> Unknown
  | Unspecified_variable when state.prototype_scope -> Variable
  | Unspecified_variable ->
      fail state span
        "[*] outside function prototype scope (C11 6.7.6.2p4)"
  | Sized expression | Static_sized expression -> (
      match constant_expression state expression with
      | Constant { value = Known length; _ } -> (
          match Exact_integer.to_int length with
          | Some length -> Constant length
          | None -> fail state expression.span "an array is too large")
      | Constant { value = Opaque; _ } -> Opaque
      | Not_constant _ when not (Scope.is_file_scope state.scope) -> Variable
      | Not_constant span ->
          fail state span
            "an array length that is not an integer constant expression \
             gives a variable length array, which cannot have file scope \
             (C11 6.7.6.2p2)")

(* Parameters (6.7.6.3) *)

(* The parameter types and the scope that the list declares them in;
   [definition] as in [derive]. *)
and read_parameters state ~definition (parameters : Tree.parameters) =
  match (parameters, definition) with
  | Identifier_list [], None -> (Ctype.Unspecified, Scope.enter state.scope)
  | Identifier_list (name :: _), None ->
      fail state name.span
        "an identifier list in a function declarator that is not a \
         definition (C11 6.7.6.3p3)"
  | Identifier_list names, Some declarations ->
      old_style_parameters state names declarations
  | Prototype { parameters; variadic }, _ ->
      let types, scope =
        within_scope state ~prototype:(definition = None) (fun () ->
            List.map (read_parameter state) parameters)
      in
      let types =
        match (parameters, types) with
        | [ { node = { declarator = None; _ }; _ } ], [ only ]
          when only = Ctype.void ->
            []
        | _ -> types
      in
      (Ctype.Prototype { types; variadic }, scope)

and read_parameter state (parameter : Tree.parameter) =
  let span = parameter.span in
  let specified = parameter_specifiers state span parameter.node.specifiers in
  read_attributes state parameter.node.attributes;
  let derived =
    match parameter.node.declarator with
    | Some declarator -> derive_parameter state specified declarator
    | None -> underived specified
  in
  Option.iter (declare_parameter state span derived) derived.name;
  derived.declared_type

and parameter_specifiers state span specifiers =
  let specified = read_specifiers state ~standalone:false specifiers in
  (match (specified.storage, specified.thread_local) with
  | (None | Some Register), false -> ()
  | _ ->
      fail state span
        "a parameter has a storage class other than register (C11 6.7.6.3p2)");
  if specified.inline || specified.noreturn then
    fail state span "a parameter has a function specifier (C11 6.7.4p1)";
  if specified.aligned <> None then
    fail state span "a parameter has an alignment specifier (C11 6.7.5p2)";
  specified

and derive_parameter state specified declarator =
  derive state ~parameter:true ~definition:None (underived specified)
    declarator

and declare_parameter state span derived name =
  let object_type = adjusted_parameter state span derived in
  let declared =
    Object { object_type; linkage = No_linkage; storage = Automatic_storage }
  in
  ignore (declare_ordinary state span name declared)

(* 6.9.1p6: the declaration list declares the names of the identifier list
   and no others, which are the parameters in the order of the list. *)
and old_style_parameters state (names : Tree.identifier list) declarations =
  let types, scope =
    within_scope state ~prototype:false (fun () ->
        List.iter (read_old_style_declaration state names) declarations;
        List.map (old_style_parameter_type state) names)
  in
  (Ctype.Old_style types, scope)

and read_old_style_declaration state names (declaration : Tree.declaration) =
  let span = declaration.span in
  match declaration.node with
  | Static_assert assertion -> static_assert state assertion
  | Declaration { declarators = []; _ } ->
      fail state span
        "a declaration before a function body declares no parameter \
         (C11 6.9.1p6)"
  | Declaration { specifiers; declarators } ->
      let specified = parameter_specifiers state span specifiers in
      let in_list name =
        List.exists (fun (listed : Tree.identifier) -> listed.node = name) names
      in
      List.iter
        (fun (declarator : Tree.init_declarator) ->
          let span = declarator.span in
          read_attributes state declarator.node.attributes;
          let derived =
            derive_parameter state specified declarator.node.declarator
          in
          match derived.name with
          | Some name when in_list name ->
              declare_parameter state span derived name
          | Some _ | None ->
              fail state span
                "a declaration before a function body declares a name that \
                 is not in its identifier list (C11 6.9.1p6)")
        declarators

and old_style_parameter_type state (name : Tree.identifier) =
  match Scope.find_in_innermost state.scope name.node with
  | Some { declared = Object { object_type; _ }; _ } -> object_type
  | Some _ | None ->
      fail state name.span
        (quote name.node
       ^ " in the identifier list is not declared (C11 6.9.1p6)")

(* The type a parameter has in its function (6.7.6.3p7, p8). *)
and adjusted_parameter state span derived =
  let declared_type = derived.declared_type in
  if Ctype.is_array declared_type then
    checked state span
      (Ctype.qualify derived.parameter_qualifiers (Ctype.decay declared_type))
  else Ctype.decay declared_type

(* Type names (6.7.7) *)

and read_type_name state (type_name : Tree.type_name) =
  let span = type_name.span in
  let specified =
    read_specifiers state ~standalone:false type_name.node.specifier_qualifiers
  in
  if specified.aligned <> None then
    fail state span "a type name has an alignment specifier (C11 6.7.5p2)";
  match type_name.node.abstract with
  | Some declarator -> (derive_object state specified declarator).declared_type
  | None -> specified.base_type

(* Constant expressions *)

(* The tags that the expression declares stay declared, as in C: every
   scope it enters it has left, as [Not_integer_constant] is caught at the
   nearest constant expression. *)
and constant_expression state expression =
  let saved_depth = state.expression_depth in
  match evaluate state ~evaluated:true expression with
  | value -> Constant value
  | exception Not_integer_constant span ->
      state.expression_depth <- saved_depth;
      Not_constant span

(* [evaluated] is false in an operand that is not evaluated (6.6p3), where
   an operation that would fail has no value instead. *)
and evaluate state ~evaluated (expression : Tree.expression) =
  if state.expression_depth >= max_expression_depth then
    fail state expression.span "a constant expression is nested too deeply";
  state.expression_depth <- state.expression_depth + 1;
  let value = evaluate_node state ~evaluated expression in
  state.expression_depth <- state.expression_depth - 1;
  value

and evaluate_node state ~evaluated (expression : Tree.expression) =
  let target = state.target and span = expression.span in
  let settled result = constant_checked state span result in
  match expression.node with
  | Identifier name -> identifier_value state expression name
  | Constant (Integer { base; digits; suffix }) ->
      settled (Integer_constant.of_integer_constant target base digits suffix)
  | Constant (Floating _ | Not_a_constant) -> not_constant expression
  | Character encoding ->
      settled
        (Integer_constant.of_character_constant target encoding
           (spelling state span))
  | Parenthesized inner -> evaluate state ~evaluated inner
  | Unary
      (((Unary_plus | Unary_minus | Bitwise_not | Logical_not) as op), operand)
    ->
      let operand = evaluate state ~evaluated operand in
      settled (Integer_constant.unary target ~evaluated op operand)
  | Binary (((Logical_and | Logical_or) as op), left, right) ->
      let left = evaluate state ~evaluated left in
      (* 6.5.13p4, 6.5.14p4: the right operand is evaluated after a left
         one that does not decide the value. *)
      let right_evaluated =
        match (op, Integer_constant.truth left) with
        | Logical_and, Some true | Logical_or, Some false -> evaluated
        | _, (Some _ | None) -> false
      in
      let right = evaluate state ~evaluated:right_evaluated right in
      settled (Integer_constant.binary target ~evaluated op left right)
  | Binary (op, left, right) ->
      let left = evaluate state ~evaluated left in
      let right = evaluate state ~evaluated right in
      settled (Integer_constant.binary target ~evaluated op left right)
  | Conditional { condition; if_true; if_false } ->
      let condition = evaluate state ~evaluated condition in
      let truth = Integer_constant.truth condition in
      let if_true =
        evaluate state ~evaluated:(evaluated && truth = Some true) if_true
      in
      let if_false =
        evaluate state ~evaluated:(evaluated && truth = Some false) if_false
      in
      Integer_constant.conditional target condition if_true if_false
  | Cast { type_name; operand } ->
      cast state ~evaluated expression type_name operand
  | Sizeof_type type_name -> (
      let size_type = target.size_type in
      match size_in_bytes state span (read_type_name state type_name) with
      | Some bytes ->
          Integer_constant.known target size_type (Exact_integer.of_int bytes)
      | None -> Integer_constant.opaque size_type)
  | Alignof type_name ->
      ignore (read_type_name state type_name);
      Integer_constant.opaque target.size_type
  (* [offsetof] expands to it and is an integer constant (C11 7.19p3). *)
  | Offsetof { type_name; _ } ->
      ignore (read_type_name state type_name);
      Integer_constant.opaque target.size_type
  (* The operand is not evaluated and its type is not computed here. *)
  | Sizeof_expression _ -> Integer_constant.opaque target.size_type
  | Comma (left, right) when not evaluated ->
      ignore (evaluate state ~evaluated left);
      evaluate state ~evaluated right
  | Generic _ ->
      fail state span "_Generic in a constant expression is not supported"
  | Comma _ | String _ | Compound_literal _ | Subscript _ | Call _ | Member _
  | Pointer_member _ | Post_increment _ | Post_decrement _
  | Unary ((Address | Indirection | Pre_increment | Pre_decrement), _)
  | Assignment _ | Statement_expression _ | Va_arg _ ->
      not_constant expression

(* 6.6p6: a cast to an integer type, of an integer constant expression or
   of a floating constant, whose value the backend computes. *)
and cast state ~evaluated expression type_name operand =
  let cast_type = read_type_name state type_name in
  match Ctype.as_arithmetic state.tags cast_type with
  | Some (Integer integer) when is_floating_constant operand ->
      Integer_constant.opaque integer
  | Some (Integer integer) ->
      let value = evaluate state ~evaluated operand in
      Integer_constant.convert state.target integer value
  | Some (Real _ | Complex _) | None -> not_constant expression

(* External declarations (6.9) *)

(* The identifier that a file scope declarator declares (6.9p2). *)
let file_scope_declared state span specified name (declared_type : Ctype.t) =
  let function_specifiers () =
    if specified.inline || specified.noreturn then
      fail state span
        "a function specifier in the declaration of an identifier that is \
         not a function (C11 6.7.4p1)"
  in
  let no_alignment what =
    if specified.aligned <> None then
      fail state span ("an alignment specifier for " ^ what ^ " (C11 6.7.5p2)")
  in
  let is_function = Ctype.is_function declared_type in
  match specified.storage with
  | Some Typedef ->
      function_specifiers ();
      no_alignment "a typedef";
      Typedef declared_type
  | Some (Auto | Register | Thread_local) ->
      fail state span "auto or register at file scope (C11 6.9p2)"
  | (None | Some (Static | Extern)) as storage when is_function ->
      if specified.thread_local then
        fail state span "a function declared _Thread_local (C11 6.7.1p4)";
      no_alignment "a function";
      let linkage = file_scope_linkage state name ~is_function storage in
      Function
        {
          function_type = declared_type;
          linkage;
          inline = specified.inline;
          noreturn = specified.noreturn;
        }
  | (None | Some (Static | Extern)) as storage ->
      function_specifiers ();
      let linkage = file_scope_linkage state name ~is_function storage in
      let storage =
        if specified.thread_local then Thread_storage else Static_storage
      in
      Object { object_type = declared_type; linkage; storage }

let declare_file_scope state span specified (derived : derived) =
  match derived.name with
  | Some name ->
      let declared =
        file_scope_declared state span specified name derived.declared_type
      in
      declare_ordinary state span name declared
  | None -> invalid_arg "Declarations: a declarator without a name"

(* The asm label names a symbol, which no type depends on. *)
let read_init_declarator state specified (declarator : Tree.init_declarator) =
  read_attributes state declarator.node.attributes;
  let derived = derive_object state specified declarator.node.declarator in
  declare_file_scope state declarator.span specified derived

let read_declaration state (declaration : Tree.declaration) =
  match declaration.node with
  | Static_assert assertion ->
      static_assert state assertion;
      Static_assertion
  | Declaration { specifiers; declarators } ->
      let standalone = declarators = [] && List.length specifiers = 1 in
      let specified = read_specifiers state ~standalone specifiers in
      Declaration (List.map (read_init_declarator state specified) declarators)

(* 6.9.1. The body is not read. *)
let read_function_definition state (definition : Tree.function_definition) =
  let { Tree.specifiers; declarator; declarations; body = _; attributes } =
    definition.node
  in
  let span = definition.span in
  read_attributes state attributes;
  let specified = read_specifiers state ~standalone:false specifiers in
  (match (specified.storage, specified.thread_local) with
  | (None | Some (Extern | Static)), false -> ()
  | _ ->
      fail state span
        "a function definition has a storage class other than extern or \
         static (C11 6.9.1p4)");
  let derived =
    derive state ~parameter:false ~definition:(Some declarations)
      (underived specified) declarator
  in
  match derived.body with
  | None ->
      fail state span
        "the declarator of a function definition does not end in a \
         function derivation (C11 6.9.1p2)"
  | Some parameters ->
      let function_entity = declare_file_scope state span specified derived in
      let body_scope = Scope.reenter state.scope ~inner:parameters in
      Function_definition { function_entity; body_scope }

let read_external state (external_declaration : Tree.external_declaration) =
  match external_declaration with
  | External_declaration declaration -> read_declaration state declaration
  | Function_definition definition -> read_function_definition state definition
  | Top_level_asm _ | Empty_declaration _ -> Declaration []

let read target text unit =
  let state =
    {
      target;
      text;
      tags = Ctype.create_tags ();
      scope = Scope.file;
      prototype_scope = false;
      next_entity = 0;
      expression_depth = 0;
    }
  in
  match List.map (read_external state) unit with
  | items -> Ok { tags = state.tags; file_scope = state.scope; items }
  | exception Failed error -> Error error
