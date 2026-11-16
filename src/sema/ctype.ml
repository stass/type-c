(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Unknown

type record_kind = Struct | Union

type privacy = Public | Private of Typec_cpp.File.t

type instance = {
  generic : Typec_syntax.Spelling.type_name;
  arguments : string list;
  mentions_parameter : bool;
}

type variant_name =
  | Declared of Typec_syntax.Spelling.type_name
  | Applied of instance

type record_tag = {
  record_id : int;
  kind : record_kind;
  record_name : record_name;
  record_at_file_scope : bool;
}

and record_name =
  | Anonymous
  | Named of string
  | Variant_name of variant_name
  | Alias_name of string
  | Instance_name of instance
  | Opaque_name of string

type enum_tag = {
  enum_id : int;
  enum_name : string option;
  enum_at_file_scope : bool;
}
type length = Constant of int | Opaque | Unknown | Variable

type parameters =
  | Prototype of { types : t list; variadic : bool }
  | Unspecified
  | Old_style of t list

and t = { qualifiers : Qualifiers.t; shape : shape; size : int }

and shape =
  | Void
  | Arithmetic of Arithmetic.t
  | Enum of enum_tag
  | Pointer of t
  | Record of record_tag
  | Distinct of distinct
  | Va_list
  | Array of { element : t; length : length }
  | Function of { return : t; parameters : parameters }
  | Unknown_type of Unknown.t

and distinct = {
  distinct_id : int;
  distinct_name : string;
  distinct_instance : instance option;
  distinct_privacy : privacy;
  distinct_at_file_scope : bool;
  representation : t;
}

type member = {
  member_name : string option;
  member_type : t;
  bit_field_width : int option;
}

module Names = Map.Make (String)

type found_member = {
  member : member;
  path : int list;
  anonymous_qualifiers : Qualifiers.t;
}

type held = Const_member | Flexible_array_member

(* The members in order; those with a position, which are those that an
   initialiser reaches; every member by name, those of anonymous members
   included; the first member, at any depth, of a kind that [held]
   names; whether it holds a variant at any depth; and the first variant
   on the chain of its first subobjects (see [first_variant]). The last
   three are found from the answers stored for the records among the
   members, so that no question walks the members of a record again and
   a record held twice costs once. *)
type record_definition = {
  members : member list;
  positions : member array;
  by_name : found_member Names.t;
  holds : held option Unknown.answer;
  holds_variant : bool;
  first_variant : t option;
}

type constructor = {
  constructor_name : Typec_syntax.Spelling.constructor;
  fields : member list;
  void_fields : string list;
}

(* An enumeration with a fixed type is complete from the first
   declaration that states the type (C23 6.7.2.2); [listed] says whether
   its list has been read. One without a fixed type is complete at its
   list. *)
type enum_definition =
  | Fixed of { fixed : Integer.t Unknown.answer; listed : bool }
  | Unfixed of Integer.t Unknown.answer

(* What the definition of a variant adds to its structure. *)
type variant_definition = {
  privacy : privacy;
  scope : Typec_syntax.Tree.span option;
      (* none for an instance (design 10.3) *)
  constructors : constructor list;
}

module Ids = Map.Make (Int)

module Instances = Map.Make (struct
  type t = instance

  let compare = compare
end)

module Record_instances = Map.Make (struct
  type t = record_kind * instance

  let compare = compare
end)

type typedef_name = { name : string; declared : Typec_syntax.Tree.reference }

(* The typedef names of an untagged record or enum, and the qualifiers
   of the type that they denote, those of the declaration's specifiers. *)
type untagged_names = {
  names : typedef_name list;
  named_qualifiers : Qualifiers.t;
}

(* What declarations and definitions have added to the tags, as one
   persistent value, so that a trial restores all of it at once and no
   write made within the trial outlives it. *)
type facts = {
  records : record_definition Ids.t;
  enums : enum_definition Ids.t;
  variants : variant_definition Ids.t;
  typedef_names : untagged_names Ids.t;
      (* the typedef names of each untagged record or enum, by id *)
  instances : record_tag Record_instances.t;
  deferred : (unit -> unit) Ids.t;
      (* the definition of each instance that no point has needed
         complete yet, by record id *)
  readings : t Instances.t;
      (* the type of each instance read as a whole, not as a record *)
  has_distinct : bool;
}

(* [next_id] stays outside [facts]: a tag that a trial declares outlives
   it in the tables of Declarations, unreachable, and an id handed out
   again would make a later tag equal to it. *)
type tags = { mutable next_id : int; mutable facts : facts }

type error =
  | Too_large
  | Qualified_function
  | Atomic_array
  | Restrict_without_object_pointer
  | Atomic_of_unsuitable_type
  | Array_of_function
  | Array_of_incomplete
  | Negative_length
  | Function_returning_array
  | Function_returning_function
  | Void_parameter
  | Redefinition
  | Fixed_and_unfixed
  | Another_fixed_type
  | Duplicate_member of string
  | Incomplete_member
  | Misplaced_flexible_array
  | Variably_modified_member
  | Invalid_bit_field
  | Incompatible
  | Int128_unavailable
  | Invalid_representation

let max_size = 4096

(* A function type stays one node below the limit, so that the pointer it
   decays to is within it. *)
let max_function_size = max_size - 1

let parameter_types = function
  | Prototype { types; _ } | Old_style types -> types
  | Unspecified -> []

let total_size types = List.fold_left (fun size t -> size + t.size) 0 types

let shape_size = function
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list | Unknown_type _ -> 1
  | Pointer referenced | Distinct { representation = referenced; _ } ->
      referenced.size + 1
  | Array { element; _ } -> element.size + 1
  | Function { return; parameters } ->
      total_size (return :: parameter_types parameters) + 1

(* Every type is made here, so its size is always that of its shape. *)
let make qualifiers shape = { qualifiers; shape; size = shape_size shape }
let of_shape shape = make Qualifiers.none shape
let unqualified t = { t with qualifiers = Qualifiers.none }

let as_variant t =
  match t.shape with
  | Record { record_name = Variant_name name; _ } -> Some name
  | Record
      { record_name =
          ( Anonymous | Named _ | Alias_name _ | Instance_name _
          | Opaque_name _ );
        _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      None

(* No generic of a unit has a universe name (design 3.6), so an instance
   of a generic of this name is one of the universe's result. *)
let universe_result = "result"

let as_result t =
  match as_variant t with
  | Some (Applied instance)
    when (instance.generic :> string) = universe_result ->
      Some instance
  | Some (Applied _ | Declared _) | None -> None

let rec top_qualifiers t =
  match t.shape with
  | Array { element; _ } -> top_qualifiers element
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
  | Va_list | Function _
  | Unknown_type _ ->
      t.qualifiers

let rec without_top_qualifiers t =
  match t.shape with
  | Array array ->
      let element = without_top_qualifiers array.element in
      { t with shape = Array { array with element } }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
  | Va_list | Function _
  | Unknown_type _ ->
      let atomic = t.qualifiers.atomic in
      { t with qualifiers = { Qualifiers.none with atomic } }

let is_function t =
  match t.shape with
  | Function _ | Unknown_type { kind = Unknown_function; _ } -> Answer true
  | Unknown_type ({ kind = Object_or_function; _ } as unknown) ->
      Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
  | Va_list | Array _
  | Unknown_type { kind = Unknown_object; _ } ->
      Answer false

let is_array t =
  match t.shape with
  | Array _ -> Answer true
  | Unknown_type ({ kind = Unknown_object | Object_or_function; _ } as unknown)
    ->
      Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
  | Va_list | Function _
  | Unknown_type { kind = Unknown_function; _ } ->
      Answer false

(* A type known to be a function or an array type, for the constraints
   that only such a type breaks. *)
let surely_function t = is_function t = Answer true
let surely_array t = is_array t = Answer true

(* The funnel of every type that can grow: the limit, lower for a
   function, bounds the work of every walk over a type, not just its
   depth, since a typedef shares a type that a walk visits once for each
   use. *)
let within_limit t =
  let limit = if surely_function t then max_function_size else max_size in
  if t.size > limit then Error Too_large else Ok t

let void = of_shape Void
(* The only way to make an arithmetic type, so that no type names
   [__int128] on a target without it, where the target has no width for
   it. *)
let arithmetic target (a : Arithmetic.t) =
  match a with
  | Integer (Int128 | Unsigned_int128)
    when target.Target.sizeof_int128 = None ->
      Error Int128_unavailable
  | Integer _ | Real _ | Complex _ -> Ok (of_shape (Arithmetic a))

let integer target i = arithmetic target (Integer i)
let enum tag = of_shape (Enum tag)
let record tag = of_shape (Record tag)
let va_list = of_shape Va_list
let unknown unknown = of_shape (Unknown_type unknown)
let pointer_to referenced = within_limit (of_shape (Pointer referenced))

(* An array decays to a pointer of its size, a function to one of one
   more, which max_function_size keeps within max_size. *)
let decay t =
  match t.shape with
  | Array { element; _ } -> of_shape (Pointer element)
  | Function _ | Unknown_type { kind = Unknown_function; _ } ->
      of_shape (Pointer t)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
      t

(* An unknown object type loses its qualifiers whether it decays, as an
   array, or not. *)
let lvalue_conversion t =
  match t.shape with
  | Array _ | Function _ | Unknown_type { kind = Unknown_function; _ } ->
      decay t
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
      unqualified t

(* 6.7.6.3p7, p8 and p15: a parameter has the type of the value it
   receives, which is the type of an lvalue conversion. *)
let adjust_parameters = function
  | Prototype { types; variadic } ->
      Prototype { types = List.map lvalue_conversion types; variadic }
  | Old_style types -> Old_style (List.map lvalue_conversion types)
  | Unspecified -> Unspecified

let has_void_parameter parameters =
  List.exists (fun t -> t.shape = Void) (parameter_types parameters)

let function_returning return parameters =
  let parameters = adjust_parameters parameters in
  match return.shape with
  | Array _ -> Error Function_returning_array
  | Function _ | Unknown_type { kind = Unknown_function; _ } ->
      Error Function_returning_function
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
      if has_void_parameter parameters then Error Void_parameter
      else within_limit (of_shape (Function { return; parameters }))

(* 6.7.3p2: restrict needs a pointer to an object type. A va_list may be
   one, which the backend checks. *)
let rec restrict_allowed t =
  match t.shape with
  | Pointer referenced -> not (surely_function referenced)
  | Distinct { representation; _ } -> restrict_allowed representation
  | Va_list -> true
  | Void | Arithmetic _ | Enum _ | Record _ | Array _ | Function _
  | Unknown_type _ ->
      false

let rec qualify qualifiers t =
  if qualifiers = Qualifiers.none then Ok t
  else
    match t.shape with
    | Function _ | Unknown_type { kind = Unknown_function; _ } ->
        Error Qualified_function
    (* The backend checks restrict and _Atomic on an unknown type. *)
    | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
        Ok { t with qualifiers = Qualifiers.union t.qualifiers qualifiers }
    | Array _ when qualifiers.atomic -> Error Atomic_array
    | Array { element; length } ->
        Result.map
          (fun element -> of_shape (Array { element; length }))
          (qualify qualifiers element)
    | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
    | Va_list ->
        if qualifiers.restrict && not (restrict_allowed t) then
          Error Restrict_without_object_pointer
        else
          Ok { t with qualifiers = Qualifiers.union t.qualifiers qualifiers }

let atomic t =
  if surely_array t || surely_function t || t.qualifiers <> Qualifiers.none then
    Error Atomic_of_unsuitable_type
  else qualify { Qualifiers.none with atomic = true } t

(* Tags *)

let create_tags () =
  { next_id = 0;
    facts =
      { records = Ids.empty;
        enums = Ids.empty;
        variants = Ids.empty;
        typedef_names = Ids.empty;
        instances = Record_instances.empty;
        deferred = Ids.empty;
        readings = Instances.empty;
        has_distinct = false } }

let fresh_id tags =
  let id = tags.next_id in
  tags.next_id <- id + 1;
  id

let new_record tags kind record_name ~at_file_scope =
  { record_id = fresh_id tags;
    kind;
    record_name;
    record_at_file_scope = at_file_scope }

let declare_record tags kind name ~at_file_scope =
  let record_name =
    match name with Some name -> Named name | None -> Anonymous
  in
  new_record tags kind record_name ~at_file_scope

let declare_variant tags name ~at_file_scope =
  new_record tags Struct (Variant_name (Declared name)) ~at_file_scope

let declare_alias_record tags kind name ~at_file_scope =
  new_record tags kind (Alias_name name) ~at_file_scope

(* Design 3.5 rule 3: one application is one type, wherever it is
   written. Design 10.3: an instance is emitted at file scope. *)
let new_instance tags kind record_name instance ~define =
  match Record_instances.find_opt (kind, instance) tags.facts.instances with
  | Some record -> record
  | None ->
      let record = new_record tags kind record_name ~at_file_scope:true in
      let deferred () = define record in
      let facts = tags.facts in
      tags.facts <-
        { facts with
          instances =
            Record_instances.add (kind, instance) record facts.instances;
          deferred = Ids.add record.record_id deferred facts.deferred };
      record

let declare_instance tags kind instance ~define =
  new_instance tags kind (Instance_name instance) instance ~define

let declare_variant_instance tags instance ~define =
  new_instance tags Struct (Variant_name (Applied instance)) instance ~define

let add_record_definition tags id definition =
  tags.facts <-
    { tags.facts with records = Ids.add id definition tags.facts.records }

let add_enum_definition tags id definition =
  tags.facts <-
    { tags.facts with enums = Ids.add id definition tags.facts.enums }

(* A type parameter in the definition check of a generic (design 3.5
   rule 4): a complete structure without members, so that it is a value
   type of which nothing else is known. *)
let declare_opaque tags name =
  let record = new_record tags Struct (Opaque_name name) ~at_file_scope:true in
  add_record_definition tags record.record_id
    { members = []; positions = [||]; by_name = Names.empty;
      holds = Answer None; holds_variant = false; first_variant = None };
  record

let trial tags read =
  let before = tags.facts in
  Fun.protect ~finally:(fun () -> tags.facts <- before) read

let set_deferred tags deferred = tags.facts <- { tags.facts with deferred }

(* The instance that a record is, whose definition may be deferred. *)
let instance_of_record (tag : record_tag) =
  match tag.record_name with
  | Instance_name instance | Variant_name (Applied instance) -> Some instance
  | Anonymous | Named _ | Variant_name (Declared _) | Alias_name _
  | Opaque_name _ ->
      None

(* The record that a need of [t] complete asks for: an array needs its
   element complete. *)
let rec needed_record t =
  match t.shape with
  | Record tag -> Some tag
  | Array { element; _ } -> needed_record element
  | Void | Arithmetic _ | Enum _ | Pointer _ | Function _ | Distinct _
  | Va_list | Unknown_type _ ->
      None

(* The definition runs when the record is first needed complete (design
   10.3); it is removed first, so that a need of the record from within
   its own definition finds it incomplete (design 3.5 rule 7). One that
   leaves the record incomplete, of a generic not complete yet, stays
   deferred. *)
let define_instance tags t =
  match needed_record t with
  | None -> None
  | Some tag -> (
      let id = tag.record_id in
      match Ids.find_opt id tags.facts.deferred with
      | None -> None
      | Some define ->
          set_deferred tags (Ids.remove id tags.facts.deferred);
          define ();
          if Ids.mem id tags.facts.records then instance_of_record tag
          else (
            set_deferred tags (Ids.add id define tags.facts.deferred);
            None))

let read_instance tags instance ~read =
  match Instances.find_opt instance tags.facts.readings with
  | Some t -> t
  | None ->
      let t = read () in
      let readings = Instances.add instance t tags.facts.readings in
      tags.facts <- { tags.facts with readings };
      t

let end_deferral tags = set_deferred tags Ids.empty

(* Ids grow in the order of declaration, enumerations included. *)
type moment = int

let now tags = tags.next_id
let record_declared_before (tag : record_tag) moment = tag.record_id < moment
let enum_declared_before tag moment = tag.enum_id < moment

type named_tag = Named_record of record_tag | Named_enum of enum_tag

let rec named_tags t =
  match t.shape with
  | Pointer referenced | Array { element = referenced; _ } ->
      named_tags referenced
  | Function { return; parameters } ->
      List.concat_map named_tags (return :: parameter_types parameters)
  | Record tag -> [ Named_record tag ]
  | Enum tag -> [ Named_enum tag ]
  | Void | Arithmetic _ | Distinct _ | Va_list | Unknown_type _ -> []

let named_type = function
  | Named_record tag -> record tag
  | Named_enum tag -> enum tag

let rec needed_tag t =
  match t.shape with
  | Record tag -> Some (Named_record tag)
  | Enum tag -> Some (Named_enum tag)
  | Array { element; _ } -> needed_tag element
  | Void | Arithmetic _ | Pointer _ | Function _ | Distinct _ | Va_list
  | Unknown_type _ ->
      None

let declare_enum tags enum_name ~at_file_scope =
  { enum_id = fresh_id tags; enum_name; enum_at_file_scope = at_file_scope }

(* Only an untagged specifier is named by its typedefs (design 3.5
   rule 2); a tagged one has its tag. *)
let untagged_id t =
  match t.shape with
  | Record { record_name = Anonymous; record_id; _ } -> Some record_id
  | Enum { enum_name = None; enum_id; _ } -> Some enum_id
  | Record
      { record_name =
          ( Named _ | Variant_name _ | Alias_name _ | Instance_name _
          | Opaque_name _ );
        _ }
  | Enum { enum_name = Some _; _ }
  | Void | Arithmetic _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      None

(* A name repeated in one declaration, as in [typedef struct {...} n, n;],
   is one name, given by its first declarator: a later one may add an
   attribute, which the type that typec reads lacks. A stable sort keeps
   the declarators of one name in their order, so the first of each run
   is the first declarator, and one pass keeps it. *)
let first_of_each_name names =
  let by_name (a : typedef_name) (b : typedef_name) =
    String.compare a.name b.name
  in
  let add kept (named : typedef_name) =
    match kept with
    | (last : typedef_name) :: _ when last.name = named.name -> kept
    | _ -> named :: kept
  in
  List.stable_sort by_name names |> List.fold_left add [] |> List.rev

let name_untagged tags t names =
  match untagged_id t with
  | Some id ->
      let named =
        { names = first_of_each_name names; named_qualifiers = t.qualifiers }
      in
      tags.facts <-
        { tags.facts with
          typedef_names = Ids.add id named tags.facts.typedef_names }
  | None -> ()

let untagged_names tags t =
  Option.bind (untagged_id t) (fun id ->
      Ids.find_opt id tags.facts.typedef_names)

let typedef_names tags t =
  match untagged_names tags t with
  | Some named -> named.names
  | None -> []

let typedef_qualifiers tags t =
  match untagged_names tags t with
  | Some named -> named.named_qualifiers
  | None -> Qualifiers.none

(* Design 3.4: an unqualified arithmetic or pointer type. An unknown type
   may be one; the casts that depend on what it is answer as unknown. *)
let declare_distinct ?instance tags distinct_name distinct_privacy
    representation ~at_file_scope =
  let representable =
    match representation.shape with
    | Arithmetic _ | Enum _ | Pointer _ | Unknown_type _ -> true
    | Void | Record _ | Distinct _ | Va_list | Array _ | Function _ -> false
  in
  if representable && representation.qualifiers = Qualifiers.none then
    let distinct =
      { distinct_id = fresh_id tags;
        distinct_name;
        distinct_instance = instance;
        distinct_privacy;
        distinct_at_file_scope = at_file_scope;
        representation }
    in
    let t = of_shape (Distinct distinct) in
    tags.facts <- { tags.facts with has_distinct = true };
    if t.size > max_size then Error Too_large else Ok t
  else Error Invalid_representation

let has_distinct tags = tags.facts.has_distinct

let as_distinct t =
  match t.shape with
  | Distinct distinct -> Some distinct
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      None

let is_opaque t =
  match t.shape with
  | Record { record_name = Opaque_name _; _ } -> true
  | Record
      { record_name =
          Anonymous | Named _ | Variant_name _ | Alias_name _ | Instance_name _;
        _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      false

let rec mentions_opaque t =
  match t.shape with
  | Pointer referenced | Array { element = referenced; _ } ->
      mentions_opaque referenced
  | Function { return; parameters } ->
      List.exists mentions_opaque (return :: parameter_types parameters)
  | Record
      { record_name = Instance_name instance | Variant_name (Applied instance);
        _ }
  | Distinct { distinct_instance = Some instance; _ } ->
      instance.mentions_parameter
  | Record { record_name = Opaque_name _; _ } -> true
  | Record
      { record_name =
          Anonymous | Named _ | Variant_name (Declared _) | Alias_name _;
        _ }
  | Distinct { distinct_instance = None; _ }
  | Void | Arithmetic _ | Enum _ | Va_list | Unknown_type _ ->
      false

let rec mentions_distinct t =
  match t.shape with
  | Distinct _ -> true
  | Pointer referenced | Array { element = referenced; _ } ->
      mentions_distinct referenced
  | Function { return; parameters } ->
      List.exists mentions_distinct (return :: parameter_types parameters)
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list | Unknown_type _ -> false

(* One walk over [t], so the cost is linear in its size. *)
let rec replace_distinct t =
  match t.shape with
  | Distinct distinct ->
      make t.qualifiers (replace_distinct distinct.representation).shape
  | Pointer referenced ->
      make t.qualifiers (Pointer (replace_distinct referenced))
  | Array { element; length } ->
      make t.qualifiers (Array { element = replace_distinct element; length })
  | Function { return; parameters } ->
      make t.qualifiers
        (Function
           { return = replace_distinct return;
             parameters = replace_in_parameters parameters })
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list | Unknown_type _ -> t

and replace_in_parameters = function
  | Prototype { types; variadic } ->
      Prototype { types = List.map replace_distinct types; variadic }
  | Old_style types -> Old_style (List.map replace_distinct types)
  | Unspecified -> Unspecified

(* A type with no distinct type in it stays the same value. *)
let representation t = if mentions_distinct t then replace_distinct t else t

let enum_integer tags tag =
  match Ids.find_opt tag.enum_id tags.facts.enums with
  | Some (Fixed { fixed; listed = _ }) -> Some fixed
  | Some (Unfixed integer) -> Some integer
  | None -> None

(* A record is complete once defined; only [define_instance] defines a
   deferred instance (design 10.3). *)
let record_definition tags tag = Ids.find_opt tag.record_id tags.facts.records

let record_members tags tag =
  Option.map (fun definition -> definition.members) (record_definition tags tag)

let find_member tags tag name =
  Option.bind (record_definition tags tag) (fun definition ->
      Names.find_opt name definition.by_name)

let member_at tags tag position =
  Option.bind (record_definition tags tag) (fun definition ->
      if position < Array.length definition.positions then
        Some definition.positions.(position)
      else None)

let rec innermost_element t =
  match t.shape with
  | Array { element; _ } -> innermost_element element
  | _ -> t

(* Pointed-to types are not held, nor the representation of a distinct
   type. A definition is final, so its [holds] stays true. *)
let holds tags t =
  let element = innermost_element t in
  match element.shape with
  | Record tag -> (
      match record_definition tags tag with
      | Some definition -> definition.holds
      | None -> Answer None)
  | Unknown_type unknown -> Depends_on unknown
  (* [Array] is not an innermost element. *)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ ->
      Answer None

(* A member holds what it is, a flexible array member or const-qualified
   (an array's qualifiers are its element's), or else what its type
   holds. *)
let member_holds tags member =
  let element = innermost_element member.member_type in
  match member.member_type.shape with
  | Array { length = Unknown; _ } -> Answer (Some Flexible_array_member)
  | _ when element.qualifiers.const -> Answer (Some Const_member)
  | _ -> holds tags element

let rec first_held tags = function
  | [] -> Answer None
  | member :: rest -> (
      match member_holds tags member with
      | Answer None -> first_held tags rest
      | found -> found)

(* As for [holds], pointed-to types are not held, nor the representation
   of a distinct type. A definition is final, so its [holds_variant]
   never goes stale. *)
let holds_variant tags t =
  let element = innermost_element t in
  match (as_variant element, element.shape) with
  | Some _, _ -> true
  | None, Record tag -> (
      match record_definition tags tag with
      | Some definition -> definition.holds_variant
      | None -> false)
  (* [Array] is not an innermost element. *)
  | ( None,
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
      | Array _ | Function _ | Unknown_type _ ) ) ->
      false

let members_hold_variant tags members =
  List.exists (fun member -> holds_variant tags member.member_type) members

(* A definition is final, so its [first_variant] never goes stale. *)
let rec first_variant tags t =
  match (as_variant t, t.shape) with
  | Some _, _ -> Some t
  | None, Array { length = Constant 0; _ } -> None
  | None, Array { element; _ } -> first_variant tags element
  | None, Record tag -> (
      match record_definition tags tag with
      | Some definition -> definition.first_variant
      | None -> None)
  | ( None,
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
      | Function _ | Unknown_type _ ) ) ->
      None

(* The first member with a position is the one that an initialiser
   reaches first (see [member_at]). *)
let first_member_variant tags = function
  | first :: _ -> first_variant tags first.member_type
  | [] -> None

let rec is_complete tags t =
  match t.shape with
  | Void | Function _ | Unknown_type { kind = Unknown_function; _ } ->
      Answer false
  | Arithmetic _ | Pointer _ | Distinct _ | Va_list -> Answer true
  | Unknown_type ({ kind = Unknown_object | Object_or_function; _ } as unknown)
    ->
      Depends_on unknown
  | Enum tag -> Answer (Ids.mem tag.enum_id tags.facts.enums)
  | Record tag -> Answer (record_definition tags tag <> None)
  | Array { length = Unknown; _ } -> Answer false
  (* The element type was complete when the array type was built, unless
     it is unknown, and a type never becomes incomplete again. *)
  | Array { length = Constant _ | Opaque | Variable; element } ->
      is_complete tags element

let array_of tags element length =
  match length with
  | _ when surely_function element -> Error Array_of_function
  | _ when is_complete tags element = Answer false -> Error Array_of_incomplete
  | Constant count when count < 0 -> Error Negative_length
  | Constant _ | Opaque | Unknown | Variable ->
      within_limit (of_shape (Array { element; length }))

let rec is_variably_modified t =
  match t.shape with
  | Array { length = Variable; _ } -> Answer true
  | Array { element = referenced; _ }
  | Pointer referenced
  | Distinct { representation = referenced; _ } ->
      is_variably_modified referenced
  | Function { return; _ } -> is_variably_modified return
  | Unknown_type unknown -> Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list -> Answer false

let check_unfixed_list tags tag =
  match Ids.find_opt tag.enum_id tags.facts.enums with
  | Some (Fixed _) -> Error Fixed_and_unfixed
  | Some (Unfixed _) -> Error Redefinition
  | None -> Ok ()

let define_enum tags tag integer =
  Result.map
    (fun () -> add_enum_definition tags tag.enum_id (Unfixed integer))
    (check_unfixed_list tags tag)

(* The first fixed type stays: a later fixed type that typec does not
   know may be any integer type, so only the backend, which knows both,
   can tell them apart, and both backends refuse a different one. *)
let fix_enum tags tag stated ~listed =
  let record fixed listed =
    add_enum_definition tags tag.enum_id (Fixed { fixed; listed });
    Ok fixed
  in
  match (Ids.find_opt tag.enum_id tags.facts.enums, stated) with
  | None, _ -> record stated listed
  | Some (Unfixed _), _ -> Error Fixed_and_unfixed
  | Some (Fixed { fixed = Answer before; _ }), Answer now when before <> now
    ->
      Error Another_fixed_type
  | Some (Fixed { listed = true; _ }), _ when listed -> Error Redefinition
  | Some (Fixed { fixed; listed = was_listed }), _ ->
      record fixed (was_listed || listed)

(* Classification *)

(* What [known] says of the shape of an object type that typec computes;
   [known] never sees an unknown type. An unknown function type is of
   none of the classes of object types. *)
let classify known t =
  match t.shape with
  | Unknown_type { kind = Unknown_function; _ } -> Answer false
  | Unknown_type ({ kind = Unknown_object | Object_or_function; _ } as unknown)
    ->
      Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _
  | Va_list | Array _
  | Function _ ->
      Answer (known t.shape)

let is_void = classify (fun shape -> shape = Void)

let is_integer =
  classify (function
    | Arithmetic (Integer _) | Enum _ -> true
    | Arithmetic (Real _ | Complex _)
    | Void | Pointer _ | Record _ | Distinct _ | Va_list | Array _ | Function _
    | Unknown_type _ ->
        false)

let is_real =
  classify (function
    | Arithmetic (Integer _ | Real _) | Enum _ -> true
    | Arithmetic (Complex _)
    | Void | Pointer _ | Record _ | Distinct _ | Va_list | Array _ | Function _
    | Unknown_type _ ->
        false)

let is_arithmetic =
  classify (function
    | Arithmetic _ | Enum _ -> true
    | Void | Pointer _ | Record _ | Distinct _ | Va_list | Array _ | Function _
    | Unknown_type _ ->
        false)

let is_pointer =
  classify (function
    | Pointer _ -> true
    | Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list | Array _
    | Function _ | Unknown_type _ ->
        false)

let is_record =
  classify (function
    | Record _ -> true
    | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
    | Array _ | Function _ | Unknown_type _ ->
        false)

let is_scalar =
  classify (function
    | Arithmetic _ | Enum _ | Pointer _ | Distinct _ -> true
    | Void | Record _ | Va_list | Array _ | Function _ | Unknown_type _ ->
        false)

let is_object t =
  match is_function t with
  | Answer is_function -> Answer (not is_function)
  | Depends_on unknown -> Depends_on unknown

let as_arithmetic tags t =
  match t.shape with
  | Arithmetic arithmetic -> Answer (Some arithmetic)
  | Enum tag -> (
      match enum_integer tags tag with
      | Some (Answer integer) -> Answer (Some (Arithmetic.Integer integer))
      | Some (Depends_on unknown) -> Depends_on unknown
      | None -> Answer None)
  | Unknown_type ({ kind = Unknown_object | Object_or_function; _ } as unknown)
    ->
      Depends_on unknown
  | Void | Pointer _ | Record _ | Distinct _ | Va_list | Array _ | Function _
  | Unknown_type { kind = Unknown_function; _ } ->
      Answer None

(* Structure and union definitions *)

(* Raised at the first defect of a definition; caught in define_record. *)
exception Invalid of error

let add_name name found names =
  if Names.mem name names then raise (Invalid (Duplicate_member name));
  Names.add name found names

(* The members of an anonymous member are members of the containing type
   (6.7.2.1p13), and keep its const and volatile on the side. Its _Atomic
   does not pass on, since a member of an atomic structure is not
   accessed on its own (6.5.2.3p5). *)
let add_anonymous_members tags ~index anonymous tag names =
  let { Qualifiers.const; volatile; _ } = anonymous.member_type.qualifiers in
  let through_anonymous _ found =
    let q = found.anonymous_qualifiers in
    let anonymous_qualifiers =
      { q with const = q.const || const; volatile = q.volatile || volatile }
    in
    { found with path = index :: found.path; anonymous_qualifiers }
  in
  match record_definition tags tag with
  | Some definition ->
      let inner = Names.mapi through_anonymous definition.by_name in
      Names.fold add_name inner names
  | None -> raise (Invalid Incomplete_member)

let add_member_names tags names (index, member) =
  match (member.member_name, member.member_type.shape) with
  | Some name, _ ->
      let found =
        { member; path = [ index ]; anonymous_qualifiers = Qualifiers.none }
      in
      add_name name found names
  | None, Record tag when member.bit_field_width = None ->
      add_anonymous_members tags ~index member tag names
  | None, _ -> names

(* 6.7.9p9: an unnamed member other than an anonymous one, which is an
   unnamed bit-field, takes no initialiser. *)
let has_position member =
  Option.is_some member.member_name || member.bit_field_width = None

let is_flexible_array member =
  match member.member_type.shape with
  | Array { length = Unknown; _ } -> true
  | Array { length = Constant _ | Opaque | Variable; _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Function _ | Unknown_type _ ->
      false

(* 6.7.2.1p4: an integer type and a width from 0 to that of the type, 0
   only for an unnamed bit-field; design 3.4: a distinct type where its
   representation is one. The backend checks a width against a type that
   typec does not know. *)
let check_bit_field target tags member width =
  let fits =
    match as_arithmetic tags (representation member.member_type) with
    | Answer (Some (Integer integer)) ->
        width <= Target.integer_width target integer
    | Answer (Some (Real _ | Complex _) | None) -> false
    | Depends_on _ -> true
  in
  let named = Option.is_some member.member_name in
  if (not fits) || width < 0 || (width = 0 && named) then
    raise (Invalid Invalid_bit_field)

(* 6.7.2.1p3 also asks a flexible array member for a structure with
   another named member; GCC and Clang accept it alone and in a union, so
   only its place is checked. *)
let check_member target tags ~last member =
  let member_type = member.member_type in
  let flexible = is_flexible_array member in
  if flexible && not last then raise (Invalid Misplaced_flexible_array);
  if (not flexible) && is_complete tags member_type = Answer false then
    raise (Invalid Incomplete_member);
  if is_variably_modified member_type = Answer true then
    raise (Invalid Variably_modified_member);
  Option.iter (check_bit_field target tags member) member.bit_field_width

let definition_of target tags tag members =
  if Ids.mem tag.record_id tags.facts.records then raise (Invalid Redefinition);
  let last = List.length members - 1 in
  List.iteri
    (fun index member -> check_member target tags ~last:(index = last) member)
    members;
  let with_position = List.filter has_position members in
  let positions = Array.of_list with_position in
  let indexed =
    List.mapi (fun index member -> (index, member)) (Array.to_list positions)
  in
  let by_name = List.fold_left (add_member_names tags) Names.empty indexed in
  { members;
    positions;
    by_name;
    holds = first_held tags members;
    holds_variant = members_hold_variant tags members;
    first_variant = first_member_variant tags with_position }

let define_record target tags tag members =
  match definition_of target tags tag members with
  | definition ->
      add_record_definition tags tag.record_id definition;
      Ok ()
  | exception Invalid error -> Error error

(* The scope is that of a declared variant and none of an instance, as
   its record name says, so no caller chooses it. *)
let set_variant target tags tag privacy scope constructors members =
  Result.map
    (fun () ->
      let variant = { privacy; scope; constructors } in
      tags.facts <-
        { tags.facts with
          variants = Ids.add tag.record_id variant tags.facts.variants })
    (define_record target tags tag members)

let define_variant target tags tag privacy ~scope constructors members =
  match tag.record_name with
  | Variant_name (Declared _) ->
      set_variant target tags tag privacy (Some scope) constructors members
  | Variant_name (Applied _)
  | Anonymous | Named _ | Alias_name _ | Instance_name _ | Opaque_name _ ->
      invalid_arg "Ctype: a declared variant of no declared variant tag"

let define_variant_instance target tags tag privacy constructors members =
  match tag.record_name with
  | Variant_name (Applied _) ->
      set_variant target tags tag privacy None constructors members
  | Variant_name (Declared _)
  | Anonymous | Named _ | Alias_name _ | Instance_name _ | Opaque_name _ ->
      invalid_arg "Ctype: a variant instance of no instance tag"

(* An instance has constructors once a need of it complete has defined
   it ([define_instance]). *)
let variant_definition tags t =
  match t.shape with
  | Record ({ record_name = Variant_name _; _ } as tag) ->
      Option.bind (record_definition tags tag) (fun _ ->
          Ids.find_opt tag.record_id tags.facts.variants)
  | Record
      { record_name =
          ( Anonymous | Named _ | Alias_name _ | Instance_name _
          | Opaque_name _ );
        _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Array _
  | Function _ | Unknown_type _ ->
      None

let constructors tags t =
  Option.map
    (fun (variant : variant_definition) -> variant.constructors)
    (variant_definition tags t)

let variant_scope tags t =
  Option.bind (variant_definition tags t) (fun (variant : variant_definition) ->
      variant.scope)

let privacy tags t =
  match (as_distinct t, variant_definition tags t) with
  | Some distinct, _ -> distinct.distinct_privacy
  | None, Some variant -> variant.privacy
  | None, None -> Public

(* Compatible and composite types *)

(* Raised where two types are not compatible; caught in composite and
   compatible. *)
exception Not_compatible

let require condition = if not condition then raise Not_compatible

let merge_length a b =
  match (a, b) with
  | Constant x, Constant y ->
      require (x = y);
      a
  (* The backend compares an opaque length with any other constant. *)
  | Constant _, (Opaque | Unknown | Variable) -> a
  | (Opaque | Unknown | Variable), Constant _ -> b
  | Opaque, (Opaque | Unknown | Variable) -> a
  | (Unknown | Variable), Opaque -> b
  | Variable, (Unknown | Variable) | Unknown, Variable -> Variable
  | Unknown, Unknown -> Unknown

(* The type of an argument passed for a parameter of this type without a
   prototype in scope (6.5.2.2p6). *)
let promoted target tags parameter =
  match as_arithmetic tags parameter with
  | Answer (Some a) ->
      let promoted = Arithmetic.default_argument_promotion target a in
      Answer (of_shape (Arithmetic promoted))
  | Answer None -> Answer parameter
  | Depends_on unknown -> Depends_on unknown

(* The first unknown type that a comparison of two types passed over: the
   verdict that their known parts leave open depends on it. *)
type dependence = { mutable first_unknown : Unknown.t option }

let no_dependence () = { first_unknown = None }

let passed_over dependence unknown =
  if dependence.first_unknown = None then
    dependence.first_unknown <- Some unknown

let verdict dependence =
  match dependence.first_unknown with
  | Some unknown -> Depends_on unknown
  | None -> Answer true

(* [location] is where the comparison is asked, for the unknown type that
   the backend may give a part of it or its verdict (Backend_difference). *)
type comparison = {
  target : Target.t;
  tags : tags;
  dependence : dependence;
  location : Typec_cpp.Location.t;
}

(* Whether the qualifiers of two return types make their function types
   incompatible: in Clang, which keeps them, where they differ, and in
   GCC, which drops all but _Atomic of them, where that differs
   (Backend_difference.Return_qualifiers). The qualifiers of an unknown
   type are part of what is unknown, which the comparison passes over. *)
let return_qualifiers_differ comparison a b =
  match (a.shape, b.shape) with
  | Unknown_type _, _ | _, Unknown_type _ -> Answer false
  | _ ->
      if a.qualifiers = b.qualifiers then Answer false
      else
        Backend_difference.answer comparison.target
          (Return_qualifiers (a.qualifiers, b.qualifiers))
          comparison.location true

let qualified_as like t = { t with qualifiers = like.qualifiers }

(* Whether one type is known to be a function type and the other known
   not to be one, which no unknown part of them changes. *)
let different_kinds a b =
  match (is_function a, is_function b) with
  | Answer a_is_function, Answer b_is_function ->
      a_is_function <> b_is_function
  | (Answer _ | Depends_on _), (Answer _ | Depends_on _) -> false

(* An unknown type is the composite of itself and any type of its kind,
   which the backend compares with it. *)
let rec merge comparison a b =
  require (not (different_kinds a b));
  match (a.shape, b.shape) with
  | Unknown_type unknown, _ ->
      passed_over comparison.dependence unknown;
      a
  | _, Unknown_type unknown ->
      passed_over comparison.dependence unknown;
      b
  | _ -> merge_known comparison a b

and merge_known comparison a b =
  require (a.qualifiers = b.qualifiers);
  let merge = merge comparison in
  match (a.shape, b.shape) with
  | Void, Void -> a
  | Arithmetic x, Arithmetic y ->
      require (x = y);
      a
  | Enum x, Enum y ->
      require (x.enum_id = y.enum_id);
      a
  | Enum tag, Arithmetic (Integer integer) ->
      require_enum_integer comparison tag integer;
      enum_integer_composite comparison b
  | Arithmetic (Integer integer), Enum tag ->
      require_enum_integer comparison tag integer;
      enum_integer_composite comparison a
  | Record x, Record y ->
      require (x.record_id = y.record_id);
      a
  (* Design 3.4: a distinct type is compatible only with itself. *)
  | Distinct x, Distinct y ->
      require (x.distinct_id = y.distinct_id);
      a
  | Va_list, Va_list -> a
  | Pointer x, Pointer y -> make a.qualifiers (Pointer (merge x y))
  | Array x, Array y ->
      let element = merge x.element y.element in
      let length = merge_length x.length y.length in
      of_shape (Array { element; length })
  | Function x, Function y ->
      let parameters = merge_parameters comparison x.parameters y.parameters in
      merge_function comparison x.return y.return parameters
  | ( ( Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list
      | Pointer _ | Array _ | Function _ | Unknown_type _ ),
      _ ) ->
      raise Not_compatible

and require_enum_integer comparison tag integer =
  match enum_integer comparison.tags tag with
  | Some (Answer compatible) -> require (compatible = integer)
  | Some (Depends_on unknown) -> passed_over comparison.dependence unknown
  | None -> raise Not_compatible

(* Clang gives an enumerated type and its compatible integer type the
   integer type as their composite whatever the order, and GCC the
   enumerated type. *)
and enum_integer_composite comparison integer_type =
  match
    Backend_difference.answer comparison.target Enum_integer_composite
      comparison.location integer_type
  with
  | Answer t -> t
  | Depends_on unknown -> make integer_type.qualifiers (Unknown_type unknown)

(* 6.7.6.3p15: the return types [a] and [b] are compatible. Where the
   backend decides whether their qualifiers are, the composite returns an
   unknown type, and the returns are compared as if equally qualified,
   so that a difference elsewhere still decides. *)
and merge_function comparison a b parameters =
  match return_qualifiers_differ comparison a b with
  | Answer false ->
      of_shape (Function { return = merge comparison a b; parameters })
  | Answer true -> raise Not_compatible
  | Depends_on backend ->
      passed_over comparison.dependence backend;
      ignore (merge comparison (qualified_as b a) b);
      of_shape (Function { return = unknown backend; parameters })

(* 6.7.6.3p15 and 6.2.7p3: a prototype gives the composite its parameter
   types; without one the parameters are not compared, except that an
   old-style definition must match a prototype in count and promoted
   types. *)
and merge_parameters comparison a b =
  let merge = merge comparison in
  (* A parameter is compared with its promoted type, which may depend on
     an unknown integer type of an enumeration. *)
  let promoted t =
    match promoted comparison.target comparison.tags t with
    | Answer promoted -> promoted
    | Depends_on unknown ->
        passed_over comparison.dependence unknown;
        t
  in
  match (a, b) with
  | Prototype x, Prototype y ->
      require (x.variadic = y.variadic);
      require (List.compare_lengths x.types y.types = 0);
      let types = List.map2 merge x.types y.types in
      Prototype { types; variadic = x.variadic }
  | Prototype prototype, Unspecified | Unspecified, Prototype prototype ->
      require (not prototype.variadic);
      List.iter (fun t -> ignore (merge t (promoted t))) prototype.types;
      Prototype prototype
  | Prototype prototype, Old_style types
  | Old_style types, Prototype prototype ->
      require (not prototype.variadic);
      require (List.compare_lengths prototype.types types = 0);
      List.iter2
        (fun t old -> ignore (merge t (promoted old)))
        prototype.types types;
      Prototype prototype
  | Old_style _, (Unspecified | Old_style _) | Unspecified, Unspecified -> a
  | Unspecified, Old_style _ -> b

(* A composite can exceed both types in size, as when each gives
   parameter types the other lacks, so it passes the limit again. *)
let composite target tags location a b =
  let comparison = { target; tags; dependence = no_dependence (); location } in
  match merge comparison a b with
  | t -> within_limit t
  | exception Not_compatible -> Error Incompatible

let compatible target tags location a b =
  let dependence = no_dependence () in
  let comparison = { target; tags; dependence; location } in
  match merge comparison a b with
  | _ -> verdict dependence
  | exception Not_compatible -> Answer false

(* The opaque lengths match as [merge_length] matches them. *)
let same_length a b =
  let is_constant = function
    | Constant _ | Opaque -> true
    | Unknown | Variable -> false
  in
  let merges () =
    match merge_length a b with _ -> true | exception Not_compatible -> false
  in
  a = b || (is_constant a && is_constant b && merges ())

(* Whether the known parts of two types are the same; the dependence of
   [comparison] notes the unknown parts. *)
let rec same comparison a b =
  (not (different_kinds a b))
  &&
  match (a.shape, b.shape) with
  | Unknown_type unknown, _ | _, Unknown_type unknown ->
      passed_over comparison.dependence unknown;
      true
  | _ -> a.qualifiers = b.qualifiers && same_shape comparison a b

(* [same] has passed over the unknown types. *)
and same_shape comparison a b =
  let same = same comparison in
  match (a.shape, b.shape) with
  | Pointer x, Pointer y -> same x y
  | Array x, Array y ->
      same_length x.length y.length && same x.element y.element
  | Function x, Function y ->
      same_return comparison x.return y.return
      && same_parameters comparison x.parameters y.parameters
  | ( ( Void | Arithmetic _ | Enum _ | Record _ | Distinct _ | Va_list
      | Unknown_type _ ),
      _ ) ->
      a.shape = b.shape
  | (Pointer _ | Array _ | Function _), _ -> false

and same_return comparison a b =
  match return_qualifiers_differ comparison a b with
  | Answer false -> same comparison a b
  | Answer true -> false
  | Depends_on backend ->
      passed_over comparison.dependence backend;
      same comparison (qualified_as b a) b

and same_parameters comparison a b =
  let same_types x y =
    List.compare_lengths x y = 0 && List.for_all2 (same comparison) x y
  in
  match (a, b) with
  | Prototype x, Prototype y ->
      x.variadic = y.variadic && same_types x.types y.types
  | Old_style x, Old_style y -> same_types x y
  | Unspecified, Unspecified -> true
  | (Prototype _ | Old_style _ | Unspecified), _ -> false

let same_type target tags location a b =
  let dependence = no_dependence () in
  let comparison = { target; tags; dependence; location } in
  if same comparison a b then verdict dependence else Answer false
let error_message = function
  | Too_large ->
      Printf.sprintf "type has more than %d parts, counting each use of a \
                      typedef" max_size
  | Void_parameter -> "parameter has type void"
  | Invalid_bit_field ->
      "bit-field has a type other than an integer type, or a width outside \
       that type or zero with a name"
  | Incompatible -> "types are not compatible"
  | Int128_unavailable -> "__int128 is not available on this target"
  | Invalid_representation ->
      "a distinct type is not over an unqualified arithmetic or pointer \
       type"
  | Qualified_function -> "function type has qualifiers"
  | Atomic_array -> "_Atomic qualifies an array type"
  | Restrict_without_object_pointer ->
      "restrict qualifies a type that is not a pointer to an object type"
  | Atomic_of_unsuitable_type ->
      "_Atomic(T) names an array, function, atomic or qualified type"
  | Array_of_function -> "array of functions"
  | Array_of_incomplete -> "array has an incomplete element type"
  | Negative_length -> "array has a negative length"
  | Function_returning_array -> "function returns an array"
  | Function_returning_function -> "function returns a function"
  | Redefinition -> "tag is defined twice"
  | Fixed_and_unfixed ->
      "an enumeration is declared both with and without a fixed type (C23 \
       6.7.2.2)"
  | Another_fixed_type ->
      "an enumeration is declared with another fixed type (C23 6.7.2.2)"
  | Duplicate_member name -> Printf.sprintf "duplicate member %S" name
  | Incomplete_member -> "member has an incomplete or function type"
  | Misplaced_flexible_array ->
      "flexible array member is not the last member"
  | Variably_modified_member -> "member has a variably modified type"
