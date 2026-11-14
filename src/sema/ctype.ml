(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Unknown

type record_kind = Struct | Union

type record_tag = {
  record_id : int;
  kind : record_kind;
  record_name : string option;
  variant : bool;
}

type enum_tag = { enum_id : int; enum_name : string option }
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
  | Va_list
  | Array of { element : t; length : length }
  | Function of { return : t; parameters : parameters }
  | Unknown_type of Unknown.t

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

(* The members in order; those with a position, which are those that an
   initialiser reaches; and every member by name, those of anonymous
   members included. *)
type record_definition = {
  members : member list;
  positions : member array;
  by_name : found_member Names.t;
}

type tags = {
  mutable next_id : int;
  records : (int, record_definition) Hashtbl.t;
  enums : (int, Integer.t Unknown.answer) Hashtbl.t;
}

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
  | Duplicate_member of string
  | Incomplete_member
  | Misplaced_flexible_array
  | Variably_modified_member
  | Invalid_bit_field
  | Incompatible
  | Int128_unavailable

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
  | Pointer referenced -> referenced.size + 1
  | Array { element; _ } -> element.size + 1
  | Function { return; parameters } ->
      total_size (return :: parameter_types parameters) + 1

(* Every type is made here, so its size is always that of its shape. *)
let make qualifiers shape = { qualifiers; shape; size = shape_size shape }
let of_shape shape = make Qualifiers.none shape
let unqualified t = { t with qualifiers = Qualifiers.none }

let as_variant t =
  match t.shape with
  | Record { variant = true; record_name; _ } -> record_name
  | Record { variant = false; _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Va_list | Array _ | Function _
  | Unknown_type _ ->
      None

let rec top_qualifiers t =
  match t.shape with
  | Array { element; _ } -> top_qualifiers element
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Function _
  | Unknown_type _ ->
      t.qualifiers

let rec without_top_qualifiers t =
  match t.shape with
  | Array array ->
      let element = without_top_qualifiers array.element in
      { t with shape = Array { array with element } }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Function _
  | Unknown_type _ ->
      let atomic = t.qualifiers.atomic in
      { t with qualifiers = { Qualifiers.none with atomic } }

let is_function t =
  match t.shape with
  | Function _ | Unknown_type { kind = Unknown_function; _ } -> Answer true
  | Unknown_type ({ kind = Object_or_function; _ } as unknown) ->
      Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
  | Unknown_type { kind = Unknown_object; _ } ->
      Answer false

let is_array t =
  match t.shape with
  | Array _ -> Answer true
  | Unknown_type ({ kind = Unknown_object | Object_or_function; _ } as unknown)
    ->
      Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Function _
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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
  | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
      t

(* An unknown object type loses its qualifiers whether it decays, as an
   array, or not. *)
let lvalue_conversion t =
  match t.shape with
  | Array _ | Function _ | Unknown_type { kind = Unknown_function; _ } ->
      decay t
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
  | Unknown_type { kind = Unknown_object | Object_or_function; _ } ->
      if has_void_parameter parameters then Error Void_parameter
      else
        let return = unqualified return in
        within_limit (of_shape (Function { return; parameters }))

(* 6.7.3p2: restrict needs a pointer to an object type. A va_list may be
   one, which the backend checks. *)
let restrict_allowed t =
  match t.shape with
  | Pointer referenced -> not (surely_function referenced)
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
    | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list ->
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
  { next_id = 0; records = Hashtbl.create 16; enums = Hashtbl.create 16 }

let fresh_id tags =
  let id = tags.next_id in
  tags.next_id <- id + 1;
  id

let declare_record tags kind record_name =
  { record_id = fresh_id tags; kind; record_name; variant = false }

let declare_variant tags name =
  { record_id = fresh_id tags;
    kind = Struct;
    record_name = Some name;
    variant = true }

let declare_enum tags enum_name = { enum_id = fresh_id tags; enum_name }

let enum_integer tags tag = Hashtbl.find_opt tags.enums tag.enum_id

let record_definition tags tag = Hashtbl.find_opt tags.records tag.record_id

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

let rec is_complete tags t =
  match t.shape with
  | Void | Function _ | Unknown_type { kind = Unknown_function; _ } ->
      Answer false
  | Arithmetic _ | Pointer _ | Va_list -> Answer true
  | Unknown_type ({ kind = Unknown_object | Object_or_function; _ } as unknown)
    ->
      Depends_on unknown
  | Enum tag -> Answer (Hashtbl.mem tags.enums tag.enum_id)
  | Record tag -> Answer (Hashtbl.mem tags.records tag.record_id)
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
  | Array { element = referenced; _ } | Pointer referenced ->
      is_variably_modified referenced
  | Function { return; _ } -> is_variably_modified return
  | Unknown_type unknown -> Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Record _ | Va_list -> Answer false

let define_enum tags tag integer =
  if Hashtbl.mem tags.enums tag.enum_id then Error Redefinition
  else (
    Hashtbl.replace tags.enums tag.enum_id integer;
    Ok ())

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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
  | Function _ ->
      Answer (known t.shape)

let is_void = classify (fun shape -> shape = Void)

let is_integer =
  classify (function
    | Arithmetic (Integer _) | Enum _ -> true
    | Arithmetic (Real _ | Complex _)
    | Void | Pointer _ | Record _ | Va_list | Array _ | Function _
    | Unknown_type _ ->
        false)

let is_real =
  classify (function
    | Arithmetic (Integer _ | Real _) | Enum _ -> true
    | Arithmetic (Complex _)
    | Void | Pointer _ | Record _ | Va_list | Array _ | Function _
    | Unknown_type _ ->
        false)

let is_arithmetic =
  classify (function
    | Arithmetic _ | Enum _ -> true
    | Void | Pointer _ | Record _ | Va_list | Array _ | Function _
    | Unknown_type _ ->
        false)

let is_pointer =
  classify (function
    | Pointer _ -> true
    | Void | Arithmetic _ | Enum _ | Record _ | Va_list | Array _
    | Function _ | Unknown_type _ ->
        false)

let is_scalar =
  classify (function
    | Arithmetic _ | Enum _ | Pointer _ -> true
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
  | Void | Pointer _ | Record _ | Va_list | Array _ | Function _
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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
  | Function _ | Unknown_type _ ->
      false

(* 6.7.2.1p4: an integer type and a width from 0 to that of the type, 0
   only for an unnamed bit-field. The backend checks a width against a
   type that typec does not know. *)
let check_bit_field target tags member width =
  let fits =
    match as_arithmetic tags member.member_type with
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
  if Hashtbl.mem tags.records tag.record_id then raise (Invalid Redefinition);
  let last = List.length members - 1 in
  List.iteri
    (fun index member -> check_member target tags ~last:(index = last) member)
    members;
  let positions = Array.of_list (List.filter has_position members) in
  let indexed =
    List.mapi (fun index member -> (index, member)) (Array.to_list positions)
  in
  let by_name = List.fold_left (add_member_names tags) Names.empty indexed in
  { members; positions; by_name }

let define_record target tags tag members =
  match definition_of target tags tag members with
  | definition ->
      Hashtbl.replace tags.records tag.record_id definition;
      Ok ()
  | exception Invalid error -> Error error

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

(* [composite_location] is where the composite is formed, for the unknown
   type that the backend may give a part of it (Backend_difference); there
   is none where only compatibility is asked, which drops the composite. *)
type comparison = {
  target : Target.t;
  tags : tags;
  dependence : dependence;
  composite_location : Typec_cpp.Location.t option;
}

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
  | Va_list, Va_list -> a
  | Pointer x, Pointer y -> make a.qualifiers (Pointer (merge x y))
  | Array x, Array y ->
      let element = merge x.element y.element in
      let length = merge_length x.length y.length in
      of_shape (Array { element; length })
  | Function x, Function y ->
      let return = merge x.return y.return in
      let parameters = merge_parameters comparison x.parameters y.parameters in
      of_shape (Function { return; parameters })
  | ( ( Void | Arithmetic _ | Enum _ | Record _ | Va_list | Pointer _
      | Array _ | Function _ | Unknown_type _ ),
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
  match comparison.composite_location with
  | None -> integer_type
  | Some location -> (
      match
        Backend_difference.answer comparison.target Enum_integer_composite
          location integer_type
      with
      | Answer t -> t
      | Depends_on unknown ->
          make integer_type.qualifiers (Unknown_type unknown))

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
  let comparison =
    { target;
      tags;
      dependence = no_dependence ();
      composite_location = Some location }
  in
  match merge comparison a b with
  | t -> within_limit t
  | exception Not_compatible -> Error Incompatible

let compatible target tags a b =
  let dependence = no_dependence () in
  let comparison = { target; tags; dependence; composite_location = None } in
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

(* Whether the known parts of two types are the same; [dependence] notes
   the unknown parts. *)
let rec same dependence a b =
  (not (different_kinds a b))
  &&
  match (a.shape, b.shape) with
  | Unknown_type unknown, _ | _, Unknown_type unknown ->
      passed_over dependence unknown;
      true
  | _ -> a.qualifiers = b.qualifiers && same_shape dependence a b

(* [same] has passed over the unknown types. *)
and same_shape dependence a b =
  let same = same dependence in
  match (a.shape, b.shape) with
  | Pointer x, Pointer y -> same x y
  | Array x, Array y ->
      same_length x.length y.length && same x.element y.element
  | Function x, Function y ->
      same x.return y.return
      && same_parameters dependence x.parameters y.parameters
  | (Void | Arithmetic _ | Enum _ | Record _ | Va_list | Unknown_type _), _ ->
      a.shape = b.shape
  | (Pointer _ | Array _ | Function _), _ -> false

and same_parameters dependence a b =
  let same_types x y =
    List.compare_lengths x y = 0 && List.for_all2 (same dependence) x y
  in
  match (a, b) with
  | Prototype x, Prototype y ->
      x.variadic = y.variadic && same_types x.types y.types
  | Old_style x, Old_style y -> same_types x y
  | Unspecified, Unspecified -> true
  | (Prototype _ | Old_style _ | Unspecified), _ -> false

let same_type a b =
  let dependence = no_dependence () in
  if same dependence a b then verdict dependence else Answer false
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
  | Duplicate_member name -> Printf.sprintf "duplicate member %S" name
  | Incomplete_member -> "member has an incomplete or function type"
  | Misplaced_flexible_array ->
      "flexible array member is not the last member"
  | Variably_modified_member -> "member has a variably modified type"
