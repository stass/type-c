(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type qualifiers = {
  const : bool;
  volatile : bool;
  restrict : bool;
  atomic : bool;
}

let no_qualifiers =
  { const = false; volatile = false; restrict = false; atomic = false }

type record_kind = Struct | Union

type record_tag = {
  record_id : int;
  kind : record_kind;
  record_name : string option;
}

type enum_tag = { enum_id : int; enum_name : string option }
type length = Constant of int | Unknown | Variable

type parameters =
  | Prototype of { types : t list; variadic : bool }
  | Unspecified
  | Old_style of t list

and t = { qualifiers : qualifiers; shape : shape; size : int }

and shape =
  | Void
  | Arithmetic of Arithmetic.t
  | Enum of enum_tag
  | Pointer of t
  | Record of record_tag
  | Array of { element : t; length : length }
  | Function of { return : t; parameters : parameters }

type member = {
  member_name : string option;
  member_type : t;
  bit_field_width : int option;
}

module Names = Map.Make (String)

(* The members in order, and every member by name, those of anonymous
   members included. *)
type record_definition = { members : member list; by_name : member Names.t }

type tags = {
  mutable next_id : int;
  records : (int, record_definition) Hashtbl.t;
  enums : (int, Integer.t) Hashtbl.t;
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

let max_size = 4096

(* A function type stays one node below the limit, so that the pointer it
   decays to is within it. *)
let max_function_size = max_size - 1

let parameter_types = function
  | Prototype { types; _ } | Old_style types -> types
  | Unspecified -> []

let total_size types = List.fold_left (fun size t -> size + t.size) 0 types

let shape_size = function
  | Void | Arithmetic _ | Enum _ | Record _ -> 1
  | Pointer referenced -> referenced.size + 1
  | Array { element; _ } -> element.size + 1
  | Function { return; parameters } ->
      total_size (return :: parameter_types parameters) + 1

(* Every type is made here, so its size is always that of its shape. *)
let make qualifiers shape = { qualifiers; shape; size = shape_size shape }
let of_shape shape = make no_qualifiers shape
let unqualified t = { t with qualifiers = no_qualifiers }

let is_function t =
  match t.shape with
  | Function _ -> true
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Array _ -> false

let is_array t =
  match t.shape with
  | Array _ -> true
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Function _ -> false

(* The funnel of every type that can grow: the limit, lower for a
   function, bounds the work of every walk over a type, not just its
   depth, since a typedef shares a type that a walk visits once for each
   use. *)
let within_limit t =
  let limit = if is_function t then max_function_size else max_size in
  if t.size > limit then Error Too_large else Ok t

let void = of_shape Void
let arithmetic a = of_shape (Arithmetic a)
let integer i = arithmetic (Integer i)
let enum tag = of_shape (Enum tag)
let record tag = of_shape (Record tag)
let pointer_to referenced = within_limit (of_shape (Pointer referenced))

(* An array decays to a pointer of its size, a function to one of one
   more, which max_function_size keeps within max_size. *)
let decay t =
  match t.shape with
  | Array { element; _ } -> of_shape (Pointer element)
  | Function _ -> of_shape (Pointer t)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ -> t

let lvalue_conversion t =
  if is_array t || is_function t then decay t else unqualified t

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
  | Function _ -> Error Function_returning_function
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ ->
      if has_void_parameter parameters then Error Void_parameter
      else
        let return = unqualified return in
        within_limit (of_shape (Function { return; parameters }))

let add_qualifiers a b =
  {
    const = a.const || b.const;
    volatile = a.volatile || b.volatile;
    restrict = a.restrict || b.restrict;
    atomic = a.atomic || b.atomic;
  }

(* 6.7.3p2: restrict needs a pointer to an object type. *)
let restrict_allowed t =
  match t.shape with
  | Pointer referenced -> not (is_function referenced)
  | Void | Arithmetic _ | Enum _ | Record _ | Array _ | Function _ -> false

let rec qualify qualifiers t =
  if qualifiers = no_qualifiers then Ok t
  else
    match t.shape with
    | Function _ -> Error Qualified_function
    | Array _ when qualifiers.atomic -> Error Atomic_array
    | Array { element; length } ->
        Result.map
          (fun element -> of_shape (Array { element; length }))
          (qualify qualifiers element)
    | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ ->
        if qualifiers.restrict && not (restrict_allowed t) then
          Error Restrict_without_object_pointer
        else Ok { t with qualifiers = add_qualifiers t.qualifiers qualifiers }

let atomic t =
  if is_array t || is_function t || t.qualifiers <> no_qualifiers then
    Error Atomic_of_unsuitable_type
  else qualify { no_qualifiers with atomic = true } t

(* Tags *)

let create_tags () =
  { next_id = 0; records = Hashtbl.create 16; enums = Hashtbl.create 16 }

let fresh_id tags =
  let id = tags.next_id in
  tags.next_id <- id + 1;
  id

let declare_record tags kind record_name =
  { record_id = fresh_id tags; kind; record_name }

let declare_enum tags enum_name = { enum_id = fresh_id tags; enum_name }

let enum_integer tags tag = Hashtbl.find_opt tags.enums tag.enum_id

let record_definition tags tag = Hashtbl.find_opt tags.records tag.record_id

let record_members tags tag =
  Option.map (fun definition -> definition.members) (record_definition tags tag)

let find_member tags tag name =
  Option.bind (record_definition tags tag) (fun definition ->
      Names.find_opt name definition.by_name)

let is_complete tags t =
  match t.shape with
  | Void | Function _ -> false
  | Arithmetic _ | Pointer _ -> true
  | Enum tag -> Hashtbl.mem tags.enums tag.enum_id
  | Record tag -> Hashtbl.mem tags.records tag.record_id
  | Array { length = Unknown; _ } -> false
  (* The element type was complete when the array type was built, and a
     type never becomes incomplete again. *)
  | Array { length = Constant _ | Variable; _ } -> true

let array_of tags element length =
  match length with
  | _ when is_function element -> Error Array_of_function
  | _ when not (is_complete tags element) -> Error Array_of_incomplete
  | Constant count when count < 0 -> Error Negative_length
  | Constant _ | Unknown | Variable ->
      within_limit (of_shape (Array { element; length }))

let rec is_variably_modified t =
  match t.shape with
  | Array { length = Variable; _ } -> true
  | Array { element = referenced; _ } | Pointer referenced ->
      is_variably_modified referenced
  | Function { return; _ } -> is_variably_modified return
  | Void | Arithmetic _ | Enum _ | Record _ -> false

let define_enum tags tag integer =
  if Hashtbl.mem tags.enums tag.enum_id then Error Redefinition
  else (
    Hashtbl.replace tags.enums tag.enum_id integer;
    Ok ())

(* Classification *)

let is_void t = t.shape = Void

let is_integer t =
  match t.shape with
  | Arithmetic (Integer _) | Enum _ -> true
  | Arithmetic (Real _ | Complex _)
  | Void | Pointer _ | Record _ | Array _ | Function _ ->
      false

let is_real t =
  match t.shape with
  | Arithmetic (Integer _ | Real _) | Enum _ -> true
  | Arithmetic (Complex _)
  | Void | Pointer _ | Record _ | Array _ | Function _ ->
      false

let is_arithmetic t =
  match t.shape with
  | Arithmetic _ | Enum _ -> true
  | Void | Pointer _ | Record _ | Array _ | Function _ -> false

let is_pointer t =
  match t.shape with
  | Pointer _ -> true
  | Void | Arithmetic _ | Enum _ | Record _ | Array _ | Function _ -> false
let is_scalar t = is_arithmetic t || is_pointer t
let is_object t = not (is_function t)

let as_arithmetic tags t =
  match t.shape with
  | Arithmetic arithmetic -> Some arithmetic
  | Enum tag ->
      Option.map (fun integer -> Arithmetic.Integer integer)
        (enum_integer tags tag)
  | Void | Pointer _ | Record _ | Array _ | Function _ -> None

(* Structure and union definitions *)

(* Raised at the first defect of a definition; caught in define_record. *)
exception Invalid of error

let add_name name member names =
  if Names.mem name names then raise (Invalid (Duplicate_member name));
  Names.add name member names

(* The members of an anonymous member are members of the containing type
   (6.7.2.1p13), const and volatile as the anonymous member is. Its
   _Atomic does not pass on, since a member of an atomic structure is not
   accessed on its own (6.5.2.3p5). *)
let add_anonymous_members tags anonymous tag names =
  let { const; volatile; _ } = anonymous.member_type.qualifiers in
  let qualifiers = { no_qualifiers with const; volatile } in
  let qualify_inner _ inner =
    match qualify qualifiers inner.member_type with
    | Ok member_type -> { inner with member_type }
    | Error error -> raise (Invalid error)
  in
  match record_definition tags tag with
  | Some definition ->
      Names.fold add_name (Names.mapi qualify_inner definition.by_name) names
  | None -> raise (Invalid Incomplete_member)

let add_member_names tags names member =
  match (member.member_name, member.member_type.shape) with
  | Some name, _ -> add_name name member names
  | None, Record tag when member.bit_field_width = None ->
      add_anonymous_members tags member tag names
  | None, _ -> names

let is_flexible_array member =
  match member.member_type.shape with
  | Array { length = Unknown; _ } -> true
  | Array { length = Constant _ | Variable; _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Function _ ->
      false

(* 6.7.2.1p4: an integer type and a width from 0 to that of the type, 0
   only for an unnamed bit-field. *)
let check_bit_field target tags member width =
  let fits =
    match as_arithmetic tags member.member_type with
    | Some (Integer integer) -> width <= Target.integer_width target integer
    | Some (Real _ | Complex _) | None -> false
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
  if (not flexible) && not (is_complete tags member_type) then
    raise (Invalid Incomplete_member);
  if is_variably_modified member_type then
    raise (Invalid Variably_modified_member);
  Option.iter (check_bit_field target tags member) member.bit_field_width

let definition_of target tags tag members =
  if Hashtbl.mem tags.records tag.record_id then raise (Invalid Redefinition);
  let last = List.length members - 1 in
  List.iteri
    (fun index member -> check_member target tags ~last:(index = last) member)
    members;
  let by_name = List.fold_left (add_member_names tags) Names.empty members in
  { members; by_name }

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
  | Constant _, (Unknown | Variable) -> a
  | (Unknown | Variable), Constant _ -> b
  | Variable, (Unknown | Variable) | Unknown, Variable -> Variable
  | Unknown, Unknown -> Unknown

(* The type of an argument passed for a parameter of this type without a
   prototype in scope (6.5.2.2p6). *)
let promoted target tags parameter =
  match as_arithmetic tags parameter with
  | Some a -> arithmetic (Arithmetic.default_argument_promotion target a)
  | None -> parameter

let rec merge target tags a b =
  require (a.qualifiers = b.qualifiers);
  let merge = merge target tags in
  match (a.shape, b.shape) with
  | Void, Void -> a
  | Arithmetic x, Arithmetic y ->
      require (x = y);
      a
  | Enum x, Enum y ->
      require (x.enum_id = y.enum_id);
      a
  (* The enumerated type is the composite whatever the order, as in GCC. *)
  | Enum tag, Arithmetic (Integer integer) ->
      require (enum_integer tags tag = Some integer);
      a
  | Arithmetic (Integer integer), Enum tag ->
      require (enum_integer tags tag = Some integer);
      b
  | Record x, Record y ->
      require (x.record_id = y.record_id);
      a
  | Pointer x, Pointer y -> make a.qualifiers (Pointer (merge x y))
  | Array x, Array y ->
      let element = merge x.element y.element in
      let length = merge_length x.length y.length in
      of_shape (Array { element; length })
  | Function x, Function y ->
      let return = merge x.return y.return in
      let parameters = merge_parameters target tags x.parameters y.parameters in
      of_shape (Function { return; parameters })
  | ( ( Void | Arithmetic _ | Enum _ | Record _ | Pointer _ | Array _
      | Function _ ),
      _ ) ->
      raise Not_compatible

(* 6.7.6.3p15 and 6.2.7p3: a prototype gives the composite its parameter
   types; without one the parameters are not compared, except that an
   old-style definition must match a prototype in count and promoted
   types. *)
and merge_parameters target tags a b =
  let merge = merge target tags in
  match (a, b) with
  | Prototype x, Prototype y ->
      require (x.variadic = y.variadic);
      require (List.compare_lengths x.types y.types = 0);
      let types = List.map2 merge x.types y.types in
      Prototype { types; variadic = x.variadic }
  | Prototype prototype, Unspecified | Unspecified, Prototype prototype ->
      require (not prototype.variadic);
      List.iter
        (fun t -> ignore (merge t (promoted target tags t)))
        prototype.types;
      Prototype prototype
  | Prototype prototype, Old_style types
  | Old_style types, Prototype prototype ->
      require (not prototype.variadic);
      require (List.compare_lengths prototype.types types = 0);
      List.iter2
        (fun t old -> ignore (merge t (promoted target tags old)))
        prototype.types types;
      Prototype prototype
  | Old_style _, (Unspecified | Old_style _) | Unspecified, Unspecified -> a
  | Unspecified, Old_style _ -> b

(* A composite can exceed both types in size, as when each gives
   parameter types the other lacks, so it passes the limit again. *)
let composite target tags a b =
  match merge target tags a b with
  | t -> within_limit t
  | exception Not_compatible -> Error Incompatible

let compatible target tags a b =
  match merge target tags a b with
  | _ -> true
  | exception Not_compatible -> false

let error_message = function
  | Too_large ->
      Printf.sprintf "type has more than %d parts, counting each use of a \
                      typedef" max_size
  | Void_parameter -> "parameter has type void"
  | Invalid_bit_field ->
      "bit-field has a type other than an integer type, or a width outside \
       that type or zero with a name"
  | Incompatible -> "types are not compatible"
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
