(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

open Entity

type entity = Entity.t

type tag = Record_tag of Ctype.record_tag | Enum_tag of Ctype.enum_tag

type item =
  | Declaration of entity list
  | Static_assertion
  | Function_definition of entity
  | Type_declaration of entity

type t = {
  tags : Ctype.tags;
  items : item list;
  entities : (Tree.reference, entity) Hashtbl.t;
  tag_types : (Tree.tag_id, tag) Hashtbl.t;
  linked : (string, entity) Hashtbl.t;
  typed : Expressions.t;
  type_declarations : (Tree.declaration_id, Tree.type_declaration) Hashtbl.t;
}

let tags result = result.tags
let items result = result.items

let type_declarations result =
  Hashtbl.to_seq_values result.type_declarations
  |> List.of_seq
  |> List.sort (fun (a : Tree.type_declaration) b ->
         compare a.span.first b.span.first)

let entity result reference = Hashtbl.find_opt result.entities reference
let tag result id = Hashtbl.find_opt result.tag_types id
let linked result name = Hashtbl.find_opt result.linked name
let expression result expression = Expressions.find result.typed expression
let constant result expression = Expressions.constant result.typed expression
let selection result expression = Expressions.selection result.typed expression

let types_compatible result expression =
  Expressions.types_compatible result.typed expression
type error = Reader.error = { location : Location.t; message : string }

(* The reader *)

(* The reader matches every tree record that holds attributes with a
   pattern that names each field, so that a field added to one is warning
   9 wherever the record is read rather than attributes no one checks. *)

(* Where a declarator is read, for the array lengths that 6.7.6.2p2 and
   p4 allow by the scope they are in: no variable length at file scope,
   and [*] only in a parameter list that is not that of a definition. *)
type place = At_file_scope | In_prototype | In_definition | In_block

(* The reader follows the links that the parser records in the tree
   (design 13.3): [entities] holds what each declaration that it has read
   declares, as of that declaration, [tag_types] the tag that each tag
   declaration declares, and [linked] the entity that each name with
   linkage denotes (6.2.2), which no scope hides, as of its last
   declaration, and [at_file_scope] as of its last one at file scope,
   which a block sees unless a declaration without linkage hides it.
   [beside] holds, for each declaration of an overload, the entity that a
   later declaration of its name without [overloadable] redeclares in its
   place, and [overloaded]
   each overload and each declaration with one before it in its scope,
   whose uses name the overload set (design 13.3). [typed] is the typed
   view of the expressions, and [type_names] the type of each type name
   read, which typing and constant evaluation both ask for and whose
   declarations are made once. [type_declarations] holds each type
   declaration read, by the id of its name. *)
type state = {
  target : Target.t;
  text : Reader.t;
  tags : Ctype.tags;
  entities : (Tree.reference, entity) Hashtbl.t;
  tag_types : (Tree.tag_id, tag) Hashtbl.t;
  linked : (string, entity) Hashtbl.t;
  at_file_scope : (string, entity) Hashtbl.t;
  beside : (Tree.reference, entity option) Hashtbl.t;
  overloaded : (Tree.reference, unit) Hashtbl.t;
  typed : Expressions.t;
  type_names : (Tree.span, Ctype.t) Hashtbl.t;
  type_declarations : (Tree.declaration_id, Tree.type_declaration) Hashtbl.t;
  mutable place : place;
  mutable next_entity : int;
}

(* Raised at the first error; caught in [read]. *)
exception Failed of error

let fail state (span : Tree.span) message =
  let location = state.text.tokens.(span.first).location in
  raise (Failed { location; message })

let quote = Expressions.quote

let checked state span = function
  | Ok t -> t
  | Error error -> fail state span (Ctype.error_message error)

let integer_type state span integer =
  checked state span (Ctype.integer state.target integer)

(* Types that typec does not compute (design 13.3) *)

(* What the construct at [span] gives in place of a type. *)
let unknown_of state (span : Tree.span) construct kind : Ctype.unknown =
  let location = state.text.tokens.(span.first).location in
  { construct; location; kind; cause = Not_typed }

let unknown_type state span construct kind =
  Ctype.unknown (unknown_of state span construct kind)

(* The error where [need] depends on an unknown type: the first point that
   needs what typec does not know. *)
let fail_needing state span need unknown =
  fail state span (Expressions.needing need unknown)

let fresh_entity state =
  let entity = state.next_entity in
  state.next_entity <- entity + 1;
  entity

(* [read] with the declarators it reads in [place]. *)
let within state place read =
  let saved = state.place in
  state.place <- place;
  Fun.protect ~finally:(fun () -> state.place <- saved) read

(* Following the links of the tree *)

(* A declaration that the parser resolved a use to, but that the reader
   has not met, is in a place that the reader does not read yet: the body
   of a Clang block literal. *)
let not_read state span name =
  fail state span
    (quote name
   ^ " is declared where typec does not read declarations yet (design \
      13.3)")

(* The entity that [reference] denotes at the use of [name] at [span]. *)
let referenced state span name reference =
  match Hashtbl.find_opt state.entities reference with
  | Some entity -> entity
  | None -> not_read state span name

(* The entity that the declaration of [name] at [span] redeclares: none
   where it is the first in its scope. An overload in between is passed
   over. *)
let earlier_entity state span name (declared : Tree.declared) =
  match declared.earlier with
  | None -> None
  | Some earlier -> (
      match Hashtbl.find_opt state.beside earlier with
      | Some passed_over -> passed_over
      | None -> Some (referenced state span name earlier))

(* Ordinary identifiers (6.2.2, 6.7p3, p4) *)

let linkage_of = function
  | Object { linkage; _ } | Function { linkage; _ } -> linkage
  | Typedef _ | Enumerator _ -> No_linkage

let is_overload = function
  | Function { overload; _ } -> overload
  | Object _ | Typedef _ | Enumerator _ -> false

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
  | Typedef old, Typedef same -> (
      match Ctype.same_type old same with
      | Answer true | Depends_on _ -> next
      | Answer false ->
          fail state span
            (quote name
           ^ " is redefined as a typedef of another type (C11 6.7p3)"))
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
          gnu_inline = old.gnu_inline || next.gnu_inline;
        }
  | (Object _ | Function _ | Typedef _ | Enumerator _), _ ->
      fail state span
        (quote name ^ " is redeclared as a different kind of identifier \
                       (C11 6.7p3)")

(* An overload (design 13.3) is a new entity, which is not linked under
   its name, and stands beside what a declaration in its place would
   redeclare. *)
let bind_overload state span name (declared : Tree.declared) next =
  let entity = { name; entity = fresh_entity state; declared = next } in
  let reference = Tree.In_tree declared.id in
  Hashtbl.replace state.entities reference entity;
  Hashtbl.replace state.beside reference
    (earlier_entity state span name declared);
  Hashtbl.replace state.overloaded reference ();
  entity

let follows_overload state (declared : Tree.declared) =
  match declared.earlier with
  | Some earlier -> Hashtbl.mem state.overloaded earlier
  | None -> false

let record state name (declared : Tree.declared) entity =
  let reference = Tree.In_tree declared.id in
  Hashtbl.replace state.entities reference entity;
  if follows_overload state declared then
    Hashtbl.replace state.overloaded reference ();
  if linkage_of entity.declared <> No_linkage then
    Hashtbl.replace state.linked name entity;
  entity

(* Records what [declared] declares [name] as: a new entity, or [prior],
   the visible declaration it redeclares, with the composite of their
   types. *)
let bind_to state span name (declared : Tree.declared) prior next =
  if is_overload next then bind_overload state span name declared next
  else
    let entity =
      match prior with
      | None -> { name; entity = fresh_entity state; declared = next }
      | Some prior ->
          { prior with
            declared = redeclared state span name prior.declared next }
    in
    record state name declared entity

(* [bind_to] the declaration before [declared] in its scope. *)
let bind state span name declared next =
  bind_to state span name declared (earlier_entity state span name declared)
    next

(* A declaration with linkage of a name whose declarations with linkage
   it does not see, as one in a block of another function: the same
   entity (6.2.2p4, p5), of a compatible type (6.2.7p2), with its own
   type, as no declaration in scope composes with it (6.2.7p4). *)
let bind_unseen state span name declared (other : entity) next =
  ignore (redeclared state span name other.declared next);
  record state name declared { other with declared = next }

(* Where a declaration of an ordinary identifier stands, for its linkage
   and storage duration (6.2.2, 6.2.4). *)
type scope = File_scope | Block_scope

(* The declaration that a declaration of [name] takes its linkage from
   (6.2.2p4): the one before it in its scope, or for one in a block the
   last with linkage in any scope. The parser links no declaration to one
   of an enclosing scope, so the tables of names with linkage stand for
   the visible one. *)
let linkage_source state scope span name declared =
  match (earlier_entity state span name declared, scope) with
  | Some prior, _ -> Some prior
  | None, Block_scope -> Hashtbl.find_opt state.linked name
  | None, File_scope -> None

(* 6.2.2p4, p5: [extern], or a function without a storage class, takes the
   linkage of the prior declaration where it has one. *)
let prior_linkage state scope span name declared =
  match linkage_source state scope span name declared with
  | Some { declared; _ } when linkage_of declared <> No_linkage ->
      linkage_of declared
  | Some _ | None -> External

(* Declaration specifiers *)

(* What the GNU attributes of a declaration say. [unknown_attribute] is
   the first without an entry in [attribute_effects], [effect_attribute]
   the first with an effect. *)
type attributed = {
  gnu_noreturn : bool;
  gnu_inline : bool;
  overloadable : bool;
  unknown_attribute : Tree.attribute option;
  effect_attribute : Tree.attribute option;
}

(* What a list of declaration specifiers says. [storage] excludes
   [_Thread_local], which [thread_local] records; [noreturn] is
   [_Noreturn] only, which 6.7.4p1 allows on functions alone. *)
type specified = {
  storage : Tree.storage_class option;
  thread_local : bool;
  base_type : Ctype.t;
  inline : bool;
  noreturn : bool;
  aligned : Tree.span option;  (** The first alignment specifier. *)
  attributed : attributed;
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
  { sorted with
    alignments = List.rev sorted.alignments;
    attributes = List.rev sorted.attributes }

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
  | None, [ Complex ] -> Some (Complex Double) (* GNU *)
  | None, _ -> None

let is_optional_float : Tree.basic_type_specifier -> bool = function
  | Optional_float _ -> true
  | Void | Char | Short | Int | Long | Float | Double | Signed | Unsigned
  | Bool | Complex | Int128 ->
      false

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

(* Constant expressions (6.6) *)

(* The outcome of reading an expression as an integer constant
   expression. *)
type evaluation =
  | Constant of Integer_constant.t
  | Not_constant of Tree.span
      (** The operand or operator that 6.6p3 and p6 do not allow. *)

let spelling state (span : Tree.span) =
  Reader.spelling state.text state.text.tokens.(span.first)

(* Declarators *)

(* A declarator applied to a type, outside in. [parameter_qualifiers]
   are those between the brackets of the derivation that a parameter
   adjusts to a pointer (6.7.6.3p7); [defines] says that a function
   derivation is the one that a definition defines. *)
type derived = {
  name : string option;
  declared_type : Ctype.t;
  parameter_qualifiers : Ctype.qualifiers;
  defines : bool;
  inner_effect : Tree.attribute option;
      (* The first attribute with an effect inside the declarator, which
         GCC and Clang move to a function that the declarator declares. *)
}

(* What a GNU attribute does to the declarations: [Neutral] changes
   nothing they compute, [Sets_noreturn] marks a function that does not
   return, as [_Noreturn] does (design 4.4), [Sets_gnu_inline] gives a
   function the GNU89 meaning of [inline] and [extern inline], and
   [Makes_overload] makes a function one of a Clang overload set. *)
type attribute_effect =
  | Neutral
  | Sets_noreturn
  | Sets_gnu_inline
  | Makes_overload

(* The GNU attributes that the declarations accept, each with its effect.
   [aligned] is neutral because typec leaves [_Alignof] and the sizes of
   records and arrays to the backend (design P16) and the attribute does
   not change the size of a scalar; it leaves this table once typec
   computes a layout. The rest shape diagnostics or code. Any other
   attribute may change a type, as [mode] and [vector_size] do, so the
   type it applies to is unknown (design 13.3). *)
let attribute_effects =
  [ ("alloc_align", Neutral); ("alloc_size", Neutral); ("aligned", Neutral);
    ("always_inline", Neutral); ("availability", Neutral); ("cold", Neutral);
    ("const", Neutral); ("constructor", Neutral); ("deprecated", Neutral);
    ("destructor", Neutral); ("disable_tail_calls", Neutral);
    ("enum_extensibility", Neutral); ("flag_enum", Neutral);
    ("format", Neutral); ("format_arg", Neutral);
    ("gnu_inline", Sets_gnu_inline); ("hot", Neutral);
    ("leaf", Neutral); ("malloc", Neutral); ("noescape", Neutral);
    ("noinline", Neutral); ("nonnull", Neutral); ("noreturn", Sets_noreturn);
    ("not_tail_called", Neutral); ("nothrow", Neutral);
    ("overloadable", Makes_overload); ("pure", Neutral);
    ("returns_nonnull", Neutral); ("section", Neutral); ("sentinel", Neutral);
    ("swift_attr", Neutral); ("swift_name", Neutral);
    ("unavailable", Neutral); ("unused", Neutral);
    ("used", Neutral); ("visibility", Neutral);
    ("warn_unused_result", Neutral); ("weak", Neutral) ]

let no_attributes =
  { gnu_noreturn = false; gnu_inline = false; overloadable = false;
    unknown_attribute = None; effect_attribute = None }

(* [onto] with the effects of [attributes] applied in source order. *)
let read_attributes ~onto (attributes : Tree.attribute list) =
  let first found attribute = if found = None then Some attribute else found in
  let with_effect attributed attribute =
    { attributed with
      effect_attribute = first attributed.effect_attribute attribute }
  in
  let apply attributed (attribute : Tree.attribute) =
    match List.assoc_opt attribute.node.name.node attribute_effects with
    | Some Neutral -> attributed
    | Some Sets_noreturn ->
        with_effect { attributed with gnu_noreturn = true } attribute
    | Some Sets_gnu_inline ->
        with_effect { attributed with gnu_inline = true } attribute
    | Some Makes_overload ->
        with_effect { attributed with overloadable = true } attribute
    | None ->
        { attributed with
          unknown_attribute = first attributed.unknown_attribute attribute }
  in
  List.fold_left apply onto attributes

(* An attribute whose effect is not recorded where it stands, as only the
   declaration of a function at file scope records [noreturn],
   [gnu_inline] and [overloadable]: it makes the type it applies to
   unknown. One without an entry in the table is named before one with an
   effect. *)
let unrecorded attributed =
  match attributed.unknown_attribute with
  | Some attribute -> Some attribute
  | None -> attributed.effect_attribute

let first_unrecorded_attribute attributes =
  unrecorded (read_attributes ~onto:no_attributes attributes)

let attribute_unknown state (attribute : Tree.attribute) kind =
  let construct = "the attribute " ^ quote attribute.node.name.node in
  unknown_of state attribute.span construct kind

(* [t] as an attribute leaves it whose effect typec does not record
   there: unknown, but a function type still, as no attribute makes a
   function of an object or an object of a function. *)
let obscured state attribute (t : Ctype.t) =
  let kind_of t : Ctype.unknown_kind =
    match Ctype.is_function t with
    | Answer true -> Unknown_function
    | Answer false -> Unknown_object
    | Depends_on _ -> Object_or_function
  in
  match attribute with
  | Some attribute ->
      Ctype.unknown (attribute_unknown state attribute (kind_of t))
  | None -> t

let obscured_by state attributes t =
  obscured state (first_unrecorded_attribute attributes) t

let with_inner_effect derived attributes =
  match derived.inner_effect with
  | Some _ -> derived
  | None ->
      let read = read_attributes ~onto:no_attributes attributes in
      { derived with inner_effect = read.effect_attribute }

(* [specified] for one declarator: its attributes extend those of the
   specifiers. *)
let for_declarator specified attributes =
  let onto = specified.attributed in
  { specified with attributed = read_attributes ~onto attributes }

(* Identifiers declared at file scope or in a block *)

let no_function_specifiers state span specified =
  if specified.inline || specified.noreturn then
    fail state span
      "a function specifier in the declaration of an identifier that is \
       not a function (C11 6.7.4p1)"

let no_alignment state span specified what =
  if specified.aligned <> None then
    fail state span ("an alignment specifier for " ^ what ^ " (C11 6.7.5p2)")

(* 6.2.2p3-p5, 6.7.1p7: the linkage of a function. [storage] is not
   [typedef], and at file scope neither [auto] nor [register]. *)
let function_linkage state scope span name declared storage =
  match ((storage : Tree.storage_class option), scope) with
  | Some Static, File_scope -> Internal
  | (None | Some Extern), _ -> prior_linkage state scope span name declared
  | Some (Static | Auto | Register | Typedef | Thread_local), Block_scope ->
      fail state span
        "a function declared in a block has a storage class other than \
         extern (C11 6.7.1p7)"
  | Some (Auto | Register | Typedef | Thread_local), File_scope ->
      invalid_arg "Declarations: a storage class refused at file scope"

let function_declared state scope span specified name declared
    (derived : derived) storage =
  (* Its noreturn, gnu_inline and overload would be guessed false. *)
  Option.iter
    (fun attribute ->
      fail_needing state span
        ("the declaration of the function " ^ quote name)
        (attribute_unknown state attribute Unknown_function))
    derived.inner_effect;
  if specified.thread_local then
    fail state span "a function declared _Thread_local (C11 6.7.1p4)";
  no_alignment state span specified "a function";
  (* An overload redeclares nothing, so it has no visible declaration to
     take a linkage from. *)
  let declared =
    if specified.attributed.overloadable then
      { declared with Tree.earlier = None }
    else declared
  in
  Function
    {
      function_type = derived.declared_type;
      linkage = function_linkage state scope span name declared storage;
      inline = specified.inline;
      noreturn = specified.noreturn || specified.attributed.gnu_noreturn;
      (* GCC and Clang ignore it on a declaration without inline. *)
      gnu_inline = specified.inline && specified.attributed.gnu_inline;
      overload = specified.attributed.overloadable;
    }

(* 6.2.2p3-p6, 6.2.4, 6.7.1p3: the linkage and storage duration of an
   object. [storage] is as for [function_linkage]. *)
let object_declared state scope span specified name declared
    (derived : derived) storage =
  no_function_specifiers state span specified;
  let duration =
    if specified.thread_local then Thread_storage else Static_storage
  in
  let linkage, storage =
    match ((storage : Tree.storage_class option), scope) with
    | Some Static, File_scope -> (Internal, duration)
    | Some Static, Block_scope -> (No_linkage, duration)
    | Some Extern, _ ->
        (prior_linkage state scope span name declared, duration)
    | None, File_scope -> (External, duration)
    | (None | Some (Auto | Register)), Block_scope ->
        if specified.thread_local then
          fail state span
            "_Thread_local in a block without static or extern (C11 \
             6.7.1p3)";
        (No_linkage, Automatic_storage)
    | Some (Auto | Register | Typedef | Thread_local), File_scope
    | Some (Typedef | Thread_local), Block_scope ->
        invalid_arg "Declarations: a storage class refused before"
  in
  Object { object_type = derived.declared_type; linkage; storage }

(* What a declarator declares [name] as in [scope] (6.2.2, 6.2.4, 6.7.1,
   6.9p2). *)
let declared_as state scope span specified name declared (derived : derived) =
  match (specified.storage, scope) with
  | Some Typedef, _ ->
      no_function_specifiers state span specified;
      no_alignment state span specified "a typedef";
      Typedef derived.declared_type
  | Some (Auto | Register | Thread_local), File_scope ->
      fail state span "auto or register at file scope (C11 6.9p2)"
  | storage, _ -> (
      match Ctype.is_function derived.declared_type with
      | Answer true ->
          function_declared state scope span specified name declared derived
            storage
      | Answer false ->
          object_declared state scope span specified name declared derived
            storage
      | Depends_on unknown ->
          fail_needing state span
            ("whether " ^ quote name ^ " is a function or an object")
            unknown)

let has_linkage declared =
  linkage_of declared <> No_linkage && not (is_overload declared)

(* A block sees the last declaration at file scope of a name with
   linkage. *)
let note_at_file_scope state scope (entity : entity) =
  if scope = File_scope && has_linkage entity.declared then
    Hashtbl.replace state.at_file_scope entity.name entity

(* Records what a declarator declares in [scope]. *)
let declare_in state scope span specified declared (derived : derived) =
  match derived.name with
  | Some name -> (
      let next =
        declared_as state scope span specified name declared derived
      in
      let has_linkage = has_linkage next in
      let entity =
        match (earlier_entity state span name declared, scope) with
        | Some prior, _ -> bind_to state span name declared (Some prior) next
        | None, _ when not has_linkage ->
            bind_to state span name declared None next
        | None, Block_scope when Hashtbl.mem state.at_file_scope name ->
            bind_to state span name declared
              (Hashtbl.find_opt state.at_file_scope name)
              next
        | None, (File_scope | Block_scope) -> (
            match Hashtbl.find_opt state.linked name with
            | Some other -> bind_unseen state span name declared other next
            | None -> bind_to state span name declared None next)
      in
      note_at_file_scope state scope entity;
      entity)
  | None -> invalid_arg "Declarations: a declarator without a name"

let rec read_specifiers state (specifiers : Tree.specifiers) =
  let span = (List.hd specifiers).span in
  let sorted = sort_specifiers specifiers in
  let attributed = read_attributes ~onto:no_attributes sorted.attributes in
  let storage = storage_class state span sorted.storage_classes in
  let base = base_type state span sorted in
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
    attributed;
  }

and base_type state span sorted =
  match (sorted.basic, sorted.others) with
  | [], [] ->
      fail state span "a declaration has no type specifier (C11 6.7.2p2)"
  | [ Void ], [] -> Ctype.void
  | basic, [] when List.exists is_optional_float basic ->
      optional_float_type state span basic
  | basic, [] -> (
      match basic_type basic with
      | Some arithmetic ->
          checked state span (Ctype.arithmetic state.target arithmetic)
      | None -> complex_integer_type state span basic)
  | [], [ other ] -> other_type state span other
  | _ -> fail state span "type specifiers that do not combine (C11 6.7.2p2)"

(* An optional floating type, such as [_Float16], real or complex, for
   which the target model has no size. The specifiers are sorted in the
   order of [Tree.basic_type_specifier], as in [basic_type]. *)
and optional_float_type state span basic =
  match List.sort compare basic with
  | [ Optional_float optional ] ->
      let name = Optional_float.spelling optional in
      unknown_type state span (quote name) Unknown_object
  | [ Complex; Optional_float optional ] ->
      let name = "_Complex " ^ Optional_float.spelling optional in
      unknown_type state span (quote name) Unknown_object
  | _ -> fail state span "type specifiers that do not combine (C11 6.7.2p2)"

(* GNU's complex integer types, such as [_Complex int], which typec does
   not type: one for each standard integer type, which GCC and Clang
   both have. Neither has [_Complex _Bool], and Clang has no
   [_Complex __int128]. *)
and complex_integer_type state span basic =
  let complex, real = List.partition (fun s -> s = Tree.Complex) basic in
  let excluded = [ Integer.Bool; Int128; Unsigned_int128 ] in
  match (complex, Integer.of_specifiers real) with
  | [ _ ], Some integer when not (List.mem integer excluded) ->
      let name = "_Complex " ^ Integer.name integer in
      unknown_type state span (quote name) Unknown_object
  | _ -> fail state span "type specifiers that do not combine (C11 6.7.2p2)"

(* An attribute of a structure, union or enumeration specifier that typec
   does not know makes the type it gives unknown. The tag is declared and
   defined as written: no attribute changes the identity, members or
   completeness of a record, the facts that typec computes of it, while
   one may change the integer type of an enumeration, which is then
   unknown wherever the tag names it. *)
and other_type state span (specifier : Tree.type_specifier) =
  match specifier with
  | Basic _ -> invalid_arg "Declarations.other_type"
  | Atomic_type type_name ->
      checked state span (Ctype.atomic (read_type_name state type_name))
  | Struct_or_union { kind; tag; members; attributes } ->
      let record = record_type state span (record_kind kind) tag members in
      let attribute = first_unrecorded_attribute attributes in
      obscured state attribute (Ctype.record record)
  | Enum { tag; enumerators; underlying; attributes } ->
      let attribute = first_unrecorded_attribute attributes in
      let fixed = Option.map (fixed_type state span) underlying in
      let enum = enum_type state span ~attribute ~fixed tag enumerators in
      obscured state attribute (Ctype.enum enum)
  | Typeof_type type_name -> read_type_name state type_name
  | Typeof_expression expression -> typeof_expression state expression
  | Typedef_name { name; declaration } -> (
      match Hashtbl.find_opt state.entities declaration with
      | Some { declared = Typedef t; _ } -> t
      | Some _ | None ->
          fail state span (quote name ^ " is not a typedef name"))

(* GNU [typeof] of an expression is its type, unconverted. *)
and typeof_expression state expression =
  (Expressions.expression (typing state) expression).expression_type

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

(* The tag that [tag] names (p9) or redeclares (p4), as the parser has
   decided; none where it declares the first tag of its name in its
   scope. *)
and prior_tag state (tag : Tree.tag) =
  let known id =
    match Hashtbl.find_opt state.tag_types id with
    | Some found -> found
    | None -> not_read state tag.name.span tag.name.node
  in
  match tag.binding with
  | Declares { earlier; id = _ } -> Option.map known earlier
  | Names id -> Some (known id)

(* [tag] is a declaration of [found] where it declares one. *)
and bind_tag state (tag : Tree.tag) found =
  match tag.binding with
  | Declares { id; earlier = _ } -> Hashtbl.replace state.tag_types id found
  | Names _ -> ()

and record_type state span kind (tag : Tree.tag option) members =
  let record =
    match tag with
    | None -> Ctype.declare_record state.tags kind None
    | Some tag ->
        let record =
          match prior_tag state tag with
          | Some (Record_tag record) when record.kind = kind -> record
          | Some (Record_tag _ | Enum_tag _) -> wrong_kind_of_tag state tag.name
          | None -> Ctype.declare_record state.tags kind (Some tag.name.node)
        in
        bind_tag state tag (Record_tag record);
        record
  in
  Option.iter (define_record state span record) members;
  record

(* [span] is the specifier's: GNU C allows a body without members. *)
and define_record state span record
    (members : Tree.member_declaration list Tree.spanned) =
  let members = List.concat_map (read_member state) members.node in
  checked state span
    (Ctype.define_record state.target state.tags record members)

(* [fixed] is the fixed type of the specifier (C23 6.7.2.2), [attribute]
   its first attribute that typec does not know. *)
and enum_type state span ~attribute ~fixed (tag : Tree.tag option)
    enumerators =
  (* GNU: an enumeration declared before its list, which 6.7.2.3p3 does
     not allow, as both backends accept it. *)
  let enum =
    match tag with
    | None -> Ctype.declare_enum state.tags None
    | Some tag ->
        let enum =
          match prior_tag state tag with
          | Some (Enum_tag enum) -> enum
          | Some (Record_tag _) -> wrong_kind_of_tag state tag.name
          | None -> Ctype.declare_enum state.tags (Some tag.name.node)
        in
        bind_tag state tag (Enum_tag enum);
        enum
  in
  (match (fixed, enumerators) with
  | Some fixed, _ ->
      let integer = attributed_integer state attribute fixed in
      fix_enum state span enum integer;
      Option.iter (define_fixed_enum state span enum integer) enumerators
  | None, Some _ when Ctype.enum_integer state.tags enum <> None ->
      fail state span (Ctype.error_message Ctype.Redefinition)
  | None, Some enumerators -> define_enum state span ~attribute enum enumerators
  | None, None -> ());
  enum

(* The integer type of an enumeration, unknown where an attribute that
   typec does not know may change it, as [packed] and [mode] do. *)
and attributed_integer state attribute (integer : Integer.t Ctype.answer) :
    Integer.t Ctype.answer =
  match attribute with
  | Some attribute ->
      Depends_on (attribute_unknown state attribute Unknown_object)
  | None -> integer

(* C23 6.7.2.2: the fixed type of an enumeration names an integer type
   other than an enumerated type; its qualifiers do not count. *)
and fixed_type state span specifiers : Integer.t Ctype.answer =
  let specified = read_specifiers state specifiers in
  let fixed = declare_type state ~parameter:false specified None in
  match fixed.declared_type.shape with
  | Arithmetic (Integer integer) -> Answer integer
  | Unknown_type unknown -> Depends_on unknown
  | Void | Arithmetic (Real _ | Complex _) | Enum _ | Pointer _ | Record _
  | Va_list | Array _ | Function _ ->
      fail state span
        "the fixed type of an enumeration is not an integer type (C23 6.7.2.2)"

(* An enumeration with a fixed type is complete from its type on, and each
   of its declarations repeats the type (C23 6.7.2.2). *)
and fix_enum state span enum integer =
  match (Ctype.enum_integer state.tags enum, integer) with
  | None, _ -> checked state span (Ctype.define_enum state.tags enum integer)
  | Some (Answer before), Answer fixed when before <> fixed ->
      fail state span
        "an enumeration is declared with another fixed type (C23 6.7.2.2)"
  | Some (Answer _ | Depends_on _), (Answer _ | Depends_on _) -> ()

(* Members (6.7.2.1) *)

and read_member state (member : Tree.member_declaration) =
  match member.node with
  | Member_static_assert assertion ->
      static_assert state assertion;
      []
  | Members { specifiers; declarators = [] } ->
      let specified = read_specifiers state specifiers in
      if is_anonymous_record specifiers then
        let derived = declare_type state ~parameter:false specified None in
        [ { Ctype.member_name = None; member_type = derived.declared_type;
            bit_field_width = None } ]
      else []
  | Members { specifiers; declarators } ->
      let specified = read_specifiers state specifiers in
      List.map (read_member_declarator state specified) declarators

(* 6.7.2.1p13: an unnamed member whose type is a structure or union
   specifier without a tag. *)
and is_anonymous_record (specifiers : Tree.specifiers) =
  List.exists
    (fun (specifier : Tree.declaration_specifier Tree.spanned) ->
      match specifier.node with
      | Type_specifier
          (Struct_or_union
            { tag = None; members = Some _; kind = _; attributes = _ }) ->
          true
      | _ -> false)
    specifiers

and read_member_declarator state specified
    (declarator : Tree.member_declarator) =
  match declarator.node with
  | Field { declarator = field; attributes } ->
      let specified = for_declarator specified attributes in
      let derived =
        declare_type state ~parameter:false specified (Some field)
      in
      { Ctype.member_name = derived.name; member_type = derived.declared_type;
        bit_field_width = None }
  | Bit_field { declarator = field; width; attributes } ->
      let specified = for_declarator specified attributes in
      Option.iter
        (fun span ->
          fail state span
            "a bit-field has an alignment specifier (C11 6.7.5p2)")
        specified.aligned;
      let derived = declare_type state ~parameter:false specified field in
      let bit_field_width = Some (bit_field_width state width) in
      { Ctype.member_name = derived.name; member_type = derived.declared_type;
        bit_field_width }

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

(* An enumerator has a type and a value, which an attribute that typec
   does not know might change. Its declaration needs both: an opaque
   value needs its integer type. *)
and check_enumerator_attributes state (name : Tree.identifier) attributes =
  Option.iter
    (fun attribute ->
      fail_needing state name.span
        ("the enumerator " ^ quote name.node)
        (attribute_unknown state attribute Unknown_object))
    (first_unrecorded_attribute attributes)

(* The value of each enumerator is known: one the backend evaluates would
   decide the integer type of the enumeration, and with it the types and
   sizes that follow, which typec would have to guess (design P16). *)
and define_enum state span ~attribute enum (enumerators : Tree.enumerator list)
    =
  let declare (previous, read) (enumerator : Tree.enumerator) =
    let { Tree.name; declared; attributes; value } = enumerator.node in
    check_enumerator_attributes state name attributes;
    let ((integer, value) as typed) =
      enumerator_value state previous enumerator.span value
    in
    let enumerator_type = integer_type state name.span integer in
    let constant = Integer_constant.known state.target integer value in
    let entity =
      bind state name.span name.node declared
        (Enumerator { enumerator_type; value = constant })
    in
    (Some typed, (declared.id, entity, value) :: read)
  in
  let _, read = List.fold_left declare (None, []) enumerators in
  let values = List.map (fun (_, _, value) -> value) read in
  let integer =
    attributed_integer state attribute (Answer (enum_integer state span values))
  in
  checked state span (Ctype.define_enum state.tags enum integer);
  (* At the closing brace every enumerator takes its final type (C23
     6.7.2.2): int when all values fit, else the enumerated type. *)
  let all_int = List.for_all (Integer_constant.fits state.target Int) values in
  let final_type, final_integer =
    match (all_int, integer) with
    | true, _ -> (integer_type state span Int, Integer.Int)
    | false, Answer integer -> (Ctype.enum enum, integer)
    | false, Depends_on unknown ->
        fail_needing state span
          "the type of enumerators that int does not hold" unknown
  in
  List.iter
    (fun (id, entity, value) ->
      let value = Integer_constant.known state.target final_integer value in
      let declared = Enumerator { enumerator_type = final_type; value } in
      Hashtbl.replace state.entities (In_tree id) { entity with declared })
    read

(* The enumerators of an enumeration with a fixed type have the enumerated
   type and values that the fixed type holds (C23 6.7.2.2). A value that
   the backend evaluates decides no type here, so it may be opaque. *)
and define_fixed_enum state span enum (integer : Integer.t Ctype.answer)
    enumerators =
  let integer =
    match integer with
    | Answer integer -> integer
    | Depends_on unknown ->
        fail_needing state span "the value of each enumerator" unknown
  in
  let declare previous (enumerator : Tree.enumerator) =
    let { Tree.name; declared; attributes; value } = enumerator.node in
    check_enumerator_attributes state name attributes;
    let value =
      fixed_enumerator_value state integer previous enumerator.span value
    in
    let enumerator = Enumerator { enumerator_type = Ctype.enum enum; value } in
    ignore (bind state name.span name.node declared enumerator);
    Some value
  in
  ignore (List.fold_left declare None enumerators)

and fixed_enumerator_value state integer previous span
    (value : Tree.expression option) =
  let target = state.target in
  let held span value =
    if not (Integer_constant.fits target integer value) then
      fail state span
        "an enumerator value is not representable in the fixed type of its \
         enumeration (C23 6.7.2.2)";
    Integer_constant.known target integer value
  in
  match (value, previous) with
  | Some expression, _ -> (
      match constant_expression state expression with
      | Not_constant span ->
          fail state span
            "an enumerator value is not an integer constant expression \
             (C11 6.7.2.2p2)"
      | Constant { value = Opaque; _ } -> Integer_constant.opaque integer
      | Constant { value = Known value; _ } -> held expression.span value)
  | None, None -> held span Exact_integer.zero
  | None, Some { Integer_constant.value = Opaque; _ } ->
      Integer_constant.opaque integer
  | None, Some { value = Known previous; _ } ->
      held span (Exact_integer.add previous Exact_integer.one)

(* The type and value of an enumerator while its list is read: int when
   the value fits, else the type of its value (C23 6.7.2.2, as in GCC and
   Clang). *)
and enumerator_value state previous span (value : Tree.expression option) =
  let target = state.target in
  match (value, previous) with
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
  | None, Some previous -> successor state span previous

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

(* The one way from specifiers and a declarator to the name and type they
   declare: the derivations of the declarator applied to the type of the
   specifiers, then the attributes of both. [definition] is as in
   [derive]; [records_effects] says that the caller records the effects
   of the attributes for a function it declares. *)
and declare_type state ?definition ?(records_effects = false) ~parameter
    specified declarator =
  let underived =
    { name = None; declared_type = specified.base_type;
      parameter_qualifiers = Ctype.no_qualifiers; defines = false;
      inner_effect = None }
  in
  let derived =
    match declarator with
    | Some declarator ->
        derive state ~parameter ~definition underived declarator
    | None -> underived
  in
  let attributed = specified.attributed in
  let attribute =
    match Ctype.is_function derived.declared_type with
    | Answer true when records_effects -> attributed.unknown_attribute
    | Answer (true | false) | Depends_on _ -> unrecorded attributed
  in
  let declared_type = obscured state attribute derived.declared_type in
  { derived with declared_type }

(* The derivations of [declarator] applied to [underived], outside in,
   though they are read from the name outward, in the order of the text,
   as an array length or a parameter list may declare what a later one
   uses (6.2.1p7). Both walks are loops, so a long chain needs no stack.
   [definition] is the declaration list of a function definition, whose
   function derivation is the one nearest the name. *)
and derive state ~parameter ~definition underived declarator =
  let rec inward outer (declarator : Tree.declarator) =
    let outer = declarator :: outer in
    match declarator.node with
    | Name _ -> outer
    | Parenthesized_declarator { inner; attributes = _ } -> inward outer inner
    | Pointer { inner; _ }
    | Block_pointer { inner; _ }
    | Array { inner; _ }
    | Function { inner; _ } -> (
        match inner with Some inner -> inward outer inner | None -> outer)
  in
  (* [nearest] until a derivation other than a parenthesis is read. *)
  let read (nearest, applications) (declarator : Tree.declarator) =
    let apply =
      read_derivation state ~parameter ~definition ~nearest declarator
    in
    let nearest =
      match declarator.node with
      | Name _ | Parenthesized_declarator _ -> nearest
      | Pointer _ | Block_pointer _ | Array _ | Function _ -> false
    in
    (nearest, apply :: applications)
  in
  let _, applications =
    List.fold_left read (true, []) (inward [] declarator)
  in
  List.fold_left (fun derived apply -> apply derived) underived applications

(* Reads what a derivation holds that is not a type, and returns what
   applies the derivation to the type that the declarator around it
   derives. [nearest] says that no derivation but a parenthesis stands
   between it and the name, so that it derives the outermost type. The
   attributes of a derivation apply to the type it derives. *)
and read_derivation state ~parameter ~definition ~nearest
    (declarator : Tree.declarator) =
  let span = declarator.span in
  match declarator.node with
  | Name name -> fun derived -> { derived with name = Some name }
  | Parenthesized_declarator { attributes; inner = _ } ->
      fun derived ->
        let declared_type =
          obscured_by state attributes derived.declared_type
        in
        { (with_inner_effect derived attributes) with declared_type }
  | Pointer { qualifiers; attributes; inner = _ } ->
      fun derived ->
        let pointer =
          checked state span (Ctype.pointer_to derived.declared_type)
        in
        let qualifiers = spanned_qualifiers qualifiers in
        let declared_type =
          checked state span (Ctype.qualify qualifiers pointer)
        in
        let declared_type = obscured_by state attributes declared_type in
        { (with_inner_effect derived attributes) with declared_type }
  (* Clang's block pointer, whose type typec does not model. *)
  | Block_pointer { qualifiers = _; attributes; inner = _ } ->
      fun derived ->
        let declared_type =
          unknown_type state span "a block pointer" Unknown_object
        in
        let declared_type = obscured_by state attributes declared_type in
        { (with_inner_effect derived attributes) with declared_type }
  | Array { inner = _; qualifiers; size } ->
      let adjusted = parameter && nearest in
      let qualified = qualifiers <> [] in
      let is_static = match size with Static_sized _ -> true | _ -> false in
      if (qualified || is_static) && not adjusted then
        fail state span
          "qualifiers or static in an array derivation that is not the \
           outermost of a parameter (C11 6.7.6.2p1)";
      let length = array_length state span size in
      fun derived ->
        let declared_type =
          checked state span
            (Ctype.array_of state.tags derived.declared_type length)
        in
        let parameter_qualifiers =
          if adjusted then spanned_qualifiers qualifiers
          else derived.parameter_qualifiers
        in
        { derived with declared_type; parameter_qualifiers }
  | Function { inner = _; parameters } ->
      let defines = definition <> None && nearest in
      let parameters =
        read_parameters state
          ~definition:(if defines then definition else None)
          parameters
      in
      fun derived ->
        let declared_type =
          checked state span
            (Ctype.function_returning derived.declared_type parameters)
        in
        { derived with declared_type; defines = derived.defines || defines }

and array_length state span (size : Tree.array_size) : Ctype.length =
  match size with
  | Unsized -> Unknown
  | Unspecified_variable when state.place = In_prototype -> Variable
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
      | Not_constant _ when state.place <> At_file_scope -> Variable
      | Not_constant span ->
          fail state span
            "an array length that is not an integer constant expression \
             gives a variable length array, which cannot have file scope \
             (C11 6.7.6.2p2)")

(* Parameters (6.7.6.3) *)

(* The parameter types; [definition] as in [derive]. *)
and read_parameters state ~definition (parameters : Tree.parameters) =
  match (parameters, definition) with
  | Identifier_list [], None -> Ctype.Unspecified
  | Identifier_list (first :: _), None ->
      fail state first.name.span
        "an identifier list in a function declarator that is not a \
         definition (C11 6.7.6.3p3)"
  | Identifier_list names, Some declarations ->
      old_style_parameters state names declarations
  | Prototype { parameters; variadic }, _ ->
      let place = if definition = None then In_prototype else In_definition in
      let types =
        within state place (fun () ->
            List.map (read_parameter state) parameters)
      in
      let types =
        match (parameters, types) with
        | ( [
              {
                node =
                  {
                    declarator = Abstract_parameter None;
                    specifiers = _;
                    attributes = _;
                  };
                _;
              };
            ],
            [ only ] )
          when only = Ctype.void ->
            []
        | _ -> types
      in
      Ctype.Prototype { types; variadic }

and read_parameter state (parameter : Tree.parameter) =
  let span = parameter.span in
  let ({ specifiers; declarator; attributes } : Tree.parameter_node) =
    parameter.node
  in
  let specified =
    for_declarator (parameter_specifiers state span specifiers) attributes
  in
  match declarator with
  | Named_parameter { declarator; declared } ->
      let derived =
        declare_type state ~parameter:true specified (Some declarator)
      in
      Option.iter
        (fun name ->
          ignore (declare_parameter state span derived name declared))
        derived.name;
      derived.declared_type
  | Abstract_parameter declarator ->
      (declare_type state ~parameter:true specified declarator).declared_type

and parameter_specifiers state span specifiers =
  let specified = read_specifiers state specifiers in
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

(* Records the parameter and returns its type. *)
and declare_parameter state span derived name declared =
  let object_type = adjusted_parameter state span derived in
  let parameter =
    Object
      {
        object_type = parameter_object_type state span object_type;
        linkage = No_linkage;
        storage = Automatic_storage;
      }
  in
  ignore (bind state span name declared parameter);
  object_type

(* Design P20: a va_list parameter is adjusted as the target's va_list
   is, to a pointer where it is an array (x86-64), so in the body the
   parameter has a type that typec does not know. *)
and parameter_object_type state span (t : Ctype.t) =
  match t.shape with
  | Va_list -> unknown_type state span "a va_list parameter" Unknown_object
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Array _
  | Function _ | Unknown_type _ ->
      t

(* 6.9.1p6: the declaration list declares the names of the identifier list
   and no others, which are the parameters in the order of the list. A
   name of the list is no entity: [types] maps each to the type that the
   declarator that redeclares it gives, [None] until one does. *)
and old_style_parameters state (names : Tree.parameter_name list)
    declarations =
  let types = Hashtbl.create (List.length names) in
  List.iter
    (fun (listed : Tree.parameter_name) ->
      Hashtbl.replace types listed.declared.id None)
    names;
  within state In_definition (fun () ->
      List.iter (read_old_style_declaration state types) declarations);
  Ctype.Old_style (List.map (old_style_parameter_type state types) names)

and read_old_style_declaration state types
    (declaration : Tree.declaration) =
  let span = declaration.span in
  match declaration.node with
  | Static_assert assertion -> static_assert state assertion
  | Declaration { declarators = []; specifiers = _ } ->
      fail state span
        "a declaration before a function body declares no parameter \
         (C11 6.9.1p6)"
  | Declaration { specifiers; declarators } ->
      let specified = parameter_specifiers state span specifiers in
      List.iter (read_old_style_declarator state types specified) declarators

and read_old_style_declarator state types specified
    (init_declarator : Tree.init_declarator) =
  let span = init_declarator.span in
  let { Tree.declarator; declared; asm_label = _; attributes; initialiser } =
    init_declarator.node
  in
  if initialiser <> None then
    fail state span
      "a declaration before a function body has an initializer \
       (C11 6.9.1p6)";
  let specified = for_declarator specified attributes in
  let derived =
    declare_type state ~parameter:true specified (Some declarator)
  in
  match (derived.name, declared.earlier) with
  | Some name, Some (In_tree listed) when Hashtbl.mem types listed ->
      let first = { declared with earlier = None } in
      let object_type = declare_parameter state span derived name first in
      Hashtbl.replace types listed (Some object_type)
  (* What it redeclares is a parameter or an enumerator of the list's
     scope, so [bind] refuses it (6.7p3). *)
  | Some name, Some _ ->
      ignore (declare_parameter state span derived name declared)
  | Some _, None | None, _ ->
      fail state span
        "a declaration before a function body declares a name that is not \
         in its identifier list (C11 6.9.1p6)"

and old_style_parameter_type state types (name : Tree.parameter_name) =
  match Hashtbl.find_opt types name.declared.id with
  | Some (Some object_type) -> object_type
  | Some None | None ->
      fail state name.name.span
        (quote name.name.node
       ^ " in the identifier list is not declared (C11 6.9.1p6)")

(* The type a parameter has in its function (6.7.6.3p7, p8). *)
and adjusted_parameter state span derived =
  let declared_type = derived.declared_type in
  match Ctype.is_array declared_type with
  | Answer true ->
      checked state span
        (Ctype.qualify derived.parameter_qualifiers (Ctype.decay declared_type))
  | Answer false | Depends_on _ -> Ctype.decay declared_type

(* Type names (6.7.7) *)

and read_type_name state (type_name : Tree.type_name) =
  match Hashtbl.find_opt state.type_names type_name.span with
  | Some t -> t
  | None ->
      let t = read_new_type_name state type_name in
      Hashtbl.replace state.type_names type_name.span t;
      t

and read_new_type_name state (type_name : Tree.type_name) =
  let span = type_name.span in
  let specified =
    read_specifiers state type_name.node.specifier_qualifiers
  in
  if specified.aligned <> None then
    fail state span "a type name has an alignment specifier (C11 6.7.5p2)";
  let derived =
    declare_type state ~parameter:false specified type_name.node.abstract
  in
  derived.declared_type

(* Constant expressions *)

(* What the expression declares stays declared, as in C, though it is
   not a constant. *)
and constant_expression state expression =
  match Expressions.integer_constant (typing state) expression with
  | Ok value -> Constant value
  | Error span -> Not_constant span

(* Declarations in blocks and what typing asks of the reader *)

(* The asm label names a symbol, which no type depends on. The
   initialiser is read after the declarator, whose identifier it sees
   (6.2.1p7). *)
and read_init_declarator state scope specified
    (init_declarator : Tree.init_declarator) =
  let { Tree.declarator; declared; asm_label = _; attributes; initialiser } =
    init_declarator.node
  in
  let specified = for_declarator specified attributes in
  (* The effects of attributes are recorded where design 13.3 places
     them: on a function declared at file scope, not on a typedef. *)
  let records_effects =
    scope = File_scope && specified.storage <> Some Typedef
  in
  let derived =
    declare_type state ~records_effects ~parameter:false specified
      (Some declarator)
  in
  let entity =
    declare_in state scope init_declarator.span specified declared derived
  in
  match initialiser with
  | None -> entity
  | Some initialiser ->
      initialised state scope init_declarator.span declared entity initialiser

(* 6.7.9: an initialised object, of static or thread storage duration
   with a constant initialiser (p4). The initialiser completes the type of
   an array of unknown size (p22), as a later declaration with the length
   would. *)
and initialised state scope span declared (entity : entity) initialiser =
  match entity.declared with
  | Object { object_type; linkage; storage } -> (
      if scope = Block_scope && linkage <> No_linkage then
        fail state span
          "a declaration in a block of an identifier with linkage has an \
           initialiser (C11 6.7.9p5)";
      let constant = storage <> Automatic_storage in
      let completed =
        Expressions.initialiser (typing state) ~constant object_type
          initialiser
      in
      match object_type.shape with
      | Array { length = Unknown; _ } ->
          let completed_object =
            Object { object_type = completed; linkage; storage }
          in
          let entity =
            record state entity.name declared
              { entity with declared = completed_object }
          in
          note_at_file_scope state scope entity;
          entity
      | _ -> entity)
  | Function _ | Typedef _ | Enumerator _ ->
      fail state span "an initialiser for what is not an object (C11 6.7.9p3)"

and read_block_declaration state (declaration : Tree.declaration) =
  match declaration.node with
  | Static_assert assertion -> static_assert state assertion
  | Declaration { specifiers; declarators } ->
      let specified = read_specifiers state specifiers in
      List.iter
        (fun declarator ->
          ignore (read_init_declarator state Block_scope specified declarator))
        declarators

(* Type declarations (design 3.1). The parser has made each the only
   declaration of its name in its scope (rule 5), so it declares a new
   entity: a typedef name of the type that it defines. *)

and read_type_declaration state (declaration : Tree.type_declaration) =
  let { Tree.name; declared; definition } = declaration.node in
  Hashtbl.replace state.type_declarations declared.id declaration;
  let bind t =
    record state name.node declared
      { name = name.node; entity = fresh_entity state; declared = Typedef t }
  in
  match definition with
  | Incomplete_variant ->
      (* Until variants (work package 1.2), an incomplete variant is the
         incomplete structure that it lowers to (design 10.1). *)
      let record =
        Ctype.declare_record state.tags (record_kind Struct) (Some name.node)
      in
      Hashtbl.replace state.tag_types (Tree.claimed_tag name)
        (Record_tag record);
      bind (Ctype.record record)
  | Alias type_name -> bind (read_type_name state type_name)
  | Record_alias specifier -> read_record_alias state name specifier bind

(* The name denotes the record before its members are read, so that they
   may use it (rule 2). A specifier without a tag of its own declares the
   tag that the declaration claims. *)
and read_record_alias state name
    (specifier : Tree.record_specifier Tree.spanned) bind =
  let { Tree.kind; attributes; tag; members } = specifier.node in
  let claimed : Tree.tag =
    { name; binding = Declares { id = Tree.claimed_tag name; earlier = None } }
  in
  let tag = Option.value tag ~default:claimed in
  let span = specifier.span in
  let record = record_type state span (record_kind kind) (Some tag) None in
  let entity = bind (obscured_by state attributes (Ctype.record record)) in
  Option.iter (define_record state span record) members;
  entity

and typing state : Expressions.context =
  {
    typed = state.typed;
    target = state.target;
    text = state.text;
    tags = state.tags;
    fail = (fun span message -> fail state span message);
    entity = referenced state;
    overloaded = Hashtbl.mem state.overloaded;
    type_name = read_type_name state;
    declaration = read_block_declaration state;
    type_declaration =
      (fun declaration -> ignore (read_type_declaration state declaration));
  }

(* External declarations (6.9) *)

let read_declaration state (declaration : Tree.declaration) =
  match declaration.node with
  | Static_assert assertion ->
      static_assert state assertion;
      Static_assertion
  | Declaration { specifiers; declarators } ->
      let specified = read_specifiers state specifiers in
      Declaration
        (List.map (read_init_declarator state File_scope specified) declarators)

(* 6.9.1. The body is typed where the definition stands, so that it sees
   the unit as of that point. *)
let read_function_definition state (definition : Tree.function_definition) =
  let {
    Tree.specifiers;
    declarator;
    declared;
    declarations;
    body;
    attributes;
  } =
    definition.node
  in
  let span = definition.span in
  let specified =
    for_declarator (read_specifiers state specifiers)
      attributes
  in
  (match (specified.storage, specified.thread_local) with
  | (None | Some (Extern | Static)), false -> ()
  | _ ->
      fail state span
        "a function definition has a storage class other than extern or \
         static (C11 6.9.1p4)");
  let derived =
    declare_type state ~definition:declarations ~records_effects:true
      ~parameter:false specified (Some declarator)
  in
  if not derived.defines then
    fail state span
      "the declarator of a function definition does not end in a function \
       derivation (C11 6.9.1p2)";
  let entity = declare_in state File_scope span specified declared derived in
  (match body with
  | Parsed block ->
      within state In_block (fun () ->
          Expressions.function_body (typing state) ~name:entity.name block)
  | Skipped _ -> ());
  Function_definition entity

let read_external state (external_declaration : Tree.external_declaration) =
  match external_declaration with
  | External_declaration declaration -> read_declaration state declaration
  | Function_definition definition -> read_function_definition state definition
  | Type_declaration declaration ->
      Type_declaration (read_type_declaration state declaration)
  | Top_level_asm _ | Empty_declaration _ -> Declaration []

let builtin_type target : Builtin_typedef.t -> (Ctype.t, Ctype.error) result =
  function
  | Va_list -> Ok Ctype.va_list
  | Int128 -> Ctype.integer target Integer.Int128
  | Unsigned_int128 -> Ctype.integer target Integer.Unsigned_int128

(* The builtin typedef names whose type the target has are entities: the
   names that the parser declares for the target's keywords
   ({!Builtin_typedef.declared}). No other error can come from a table
   that names no derived type. *)
let declare_builtin_typedefs state =
  List.iter
    (fun (name, builtin) ->
      match builtin_type state.target builtin with
      | Ok t ->
          let entity =
            { name; entity = fresh_entity state; declared = Typedef t }
          in
          Hashtbl.replace state.entities (Builtin name) entity
      | Error Int128_unavailable -> ()
      | Error error -> invalid_arg (Ctype.error_message error))
    Builtin_typedef.table

let read target text unit =
  let state =
    {
      target;
      text;
      tags = Ctype.create_tags ();
      entities = Hashtbl.create 1024;
      tag_types = Hashtbl.create 256;
      linked = Hashtbl.create 1024;
      at_file_scope = Hashtbl.create 1024;
      beside = Hashtbl.create 64;
      overloaded = Hashtbl.create 64;
      typed = Expressions.create ();
      type_names = Hashtbl.create 256;
      type_declarations = Hashtbl.create 16;
      place = At_file_scope;
      next_entity = 0;
    }
  in
  declare_builtin_typedefs state;
  match List.map (read_external state) unit with
  | items ->
      let { tags; entities; tag_types; linked; typed; type_declarations; _ } =
        state
      in
      Ok { tags; items; entities; tag_types; linked; typed; type_declarations }
  | exception Failed error -> Error error
