(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Each type parameter is paired with its deduced type, by the id of its
   opaque record. *)
type t = (Ctype.record_tag * Ctype.t option) list

let start parameters = List.map (fun record -> (record, None)) parameters

let explicit parameters arguments =
  List.map2 (fun record argument -> (record, Some argument)) parameters
    arguments

type failure =
  | Mismatch of { parameter_part : Ctype.t; argument_part : Ctype.t }
  | Twice of { first : Ctype.t; second : Ctype.t }
  | Unknown_part of Unknown.t
  | Not_built of Ctype.error

exception Failed of failure

let fail failure = raise (Failed failure)

let mismatch parameter_part argument_part =
  fail (Mismatch { parameter_part; argument_part })

(* The binding of the type parameter that [t], qualified or not, is. *)
let parameter_of (bindings : t) (t : Ctype.t) =
  match t.shape with
  | Record tag ->
      List.find_opt
        (fun ((record : Ctype.record_tag), _) ->
          record.record_id = tag.record_id)
        bindings
  | _ -> None

(* The instance of a generic type that [t] is, whose argument types a
   type parameter may stand in. *)
let applied_instance (t : Ctype.t) =
  match t.shape with
  | Record
      { record_name = Instance_name instance | Variant_name (Applied instance);
        _ }
  | Distinct { distinct_instance = Some instance; _ } ->
      Some instance
  | _ -> None

(* The instance that [t] is, where an argument of it mentions a type
   parameter. *)
let parameterized_instance t =
  match applied_instance t with
  | Some instance when instance.mentions_parameter -> Some instance
  | Some _ | None -> None

let rec mentions_undeduced bindings (t : Ctype.t) =
  let mentions = mentions_undeduced bindings in
  match (parameter_of bindings t, t.shape) with
  | Some (_, deduced), _ -> deduced = None
  | None, (Pointer referenced | Array { element = referenced; _ }) ->
      mentions referenced
  | None, Function { return; parameters } ->
      mentions return || List.exists mentions (parameter_types parameters)
  | None, _ -> (
      match parameterized_instance t with
      | Some instance -> List.exists mentions instance.argument_types
      | None -> false)

and parameter_types : Ctype.parameters -> Ctype.t list = function
  | Prototype { types; _ } | Old_style types -> types
  | Unspecified -> []

let is_deduced_in bindings t = not (mentions_undeduced bindings t)

let includes (outer : Qualifiers.t) (inner : Qualifiers.t) =
  Qualifiers.union outer inner = outer

let without (t : Qualifiers.t) (removed : Qualifiers.t) : Qualifiers.t =
  { const = t.const && not removed.const;
    volatile = t.volatile && not removed.volatile;
    restrict = t.restrict && not removed.restrict;
    atomic = t.atomic && not removed.atomic }

let requalified (t : Ctype.t) qualifiers =
  match Ctype.qualify qualifiers (Ctype.unqualified t) with
  | Ok requalified -> requalified
  | Error _ -> invalid_arg "Deduction: removing qualifiers failed"

(* Rule 2: the qualifiers of a part outside every type parameter are the
   argument's, but that [adds], the referenced type of a pointer
   parameter, may hold more, as C assignment allows. *)
let match_qualifiers ~adds (parameter : Ctype.t) (argument : Ctype.t) =
  let agree =
    if adds then includes parameter.qualifiers argument.qualifiers
    else parameter.qualifiers = argument.qualifiers
  in
  if not agree then mismatch parameter argument

(* Matches [parameter] against [argument] part by part and gives the
   bindings with what the type parameters met deduce. *)
let rec matched bindings ~adds (parameter : Ctype.t) (argument : Ctype.t) =
  match parameter_of bindings parameter with
  | Some (record, deduced) ->
      deduce_parameter bindings ~adds record deduced parameter argument
  | None ->
      (match argument.shape with
      | Unknown_type unknown -> fail (Unknown_part unknown)
      | _ -> ());
      match_qualifiers ~adds parameter argument;
      matched_shape bindings parameter argument

(* The type parameter [record] with qualifiers [Q] meets a part with
   qualifiers [R]: it is the part with [R] less [Q], where [Q] lies
   within [R] or [adds] lets the parameter add qualifiers. *)
and deduce_parameter bindings ~adds record deduced (parameter : Ctype.t)
    (argument : Ctype.t) =
  (match argument.shape with
  | Unknown_type unknown -> fail (Unknown_part unknown)
  | _ -> ());
  if (not adds) && not (includes argument.qualifiers parameter.qualifiers)
  then mismatch parameter argument;
  let part =
    requalified argument (without argument.qualifiers parameter.qualifiers)
  in
  match deduced with
  | None ->
      List.map
        (fun ((other : Ctype.record_tag), deduced) ->
          if other.record_id = record.Ctype.record_id then (other, Some part)
          else (other, deduced))
        bindings
  | Some first ->
      if not (identical first part) then fail (Twice { first; second = part });
      bindings

(* An instance whose arguments mention a type parameter matches an
   instance of the same generic argument by argument; any other part
   matches by its shape. *)
and matched_shape bindings (parameter : Ctype.t) (argument : Ctype.t) =
  match (parameterized_instance parameter, applied_instance argument) with
  | Some p, Some a when p.generic = a.generic ->
      List.fold_left2
        (fun bindings p a -> matched bindings ~adds:false p a)
        bindings p.argument_types a.argument_types
  | _ -> matched_structure bindings parameter argument

and matched_structure bindings (parameter : Ctype.t) (argument : Ctype.t) =
  let exact = matched bindings ~adds:false in
  match (parameter.shape, argument.shape) with
  | Pointer p, Pointer a -> exact p a
  | Array { element = p; length = pl }, Array { element = a; length = al }
    when pl = al ->
      exact p a
  | ( Function { return = pr; parameters = pp },
      Function { return = ar; parameters = ap } ) ->
      matched_parameters (exact pr ar) parameter argument pp ap
  | Record p, Record a when p.record_id = a.record_id -> bindings
  | Enum p, Enum a when p.enum_id = a.enum_id -> bindings
  | Distinct p, Distinct a when p.distinct_id = a.distinct_id -> bindings
  | Arithmetic p, Arithmetic a when p = a -> bindings
  | Void, Void | Va_list, Va_list -> bindings
  | _ -> mismatch parameter argument

and matched_parameters bindings parameter argument
    (pp : Ctype.parameters) (ap : Ctype.parameters) =
  let pairwise ps as_ =
    if List.compare_lengths ps as_ <> 0 then mismatch parameter argument;
    List.fold_left2
      (fun bindings p a -> matched bindings ~adds:false p a)
      bindings ps as_
  in
  match (pp, ap) with
  | Prototype p, Prototype a when p.variadic = a.variadic ->
      pairwise p.types a.types
  | Old_style ps, Old_style as_ -> pairwise ps as_
  | Unspecified, Unspecified -> bindings
  | _ -> mismatch parameter argument

(* Two types are identical where each matches the other with no type
   parameter in either. *)
and identical first second =
  match matched [] ~adds:false first second with
  | _ -> true
  | exception Failed _ -> false

(* Rule 2: the top-level qualifiers of a parameter are no part of the
   function's type, and those of the argument go with its lvalue
   conversion, so the referenced type of a pointer parameter is the one
   part that may add qualifiers. *)
let deduce bindings ~parameter ~argument =
  let parameter = Ctype.unqualified parameter
  and argument = Ctype.unqualified argument in
  match
    match (parameter_of bindings parameter, parameter.shape, argument.shape)
    with
    | None, Pointer p, Pointer a -> matched bindings ~adds:true p a
    | _ -> matched bindings ~adds:false parameter argument
  with
  | bindings -> Ok bindings
  | exception Failed failure -> Error failure

(* Where [slice] is a slice type [slice(P)], whether a slice of a given
   element type meets it as one instance meets another in
   [matched_shape]: [P] matches the element exactly. *)
let slice_meets bindings ~slice =
  match applied_instance (Ctype.unqualified slice) with
  | Some { generic; argument_types = [ element_parameter ]; _ }
    when (generic :> string) = Ctype.universe_slice ->
      Some
        (fun element ->
          match matched bindings ~adds:false element_parameter element with
          | _ -> true
          | exception Failed _ -> false)
  | Some _ | None -> None

let arguments bindings =
  let argument (record, deduced) =
    match deduced with Some t -> Ok t | None -> Error record
  in
  List.fold_right
    (fun binding arguments ->
      Result.bind arguments (fun rest ->
          Result.map (fun t -> t :: rest) (argument binding)))
    bindings (Ok [])

let built = function Ok t -> t | Error error -> fail (Not_built error)

(* A substituted type may be refused where the type parameter was not: a
   type argument makes it larger, or an instance that it holds in an
   array is not complete, which [complete] asks for as a declarator
   does. [reapply] gives the substituted type of an instance. *)
let rec substituted tags ~complete ~reapply bindings (t : Ctype.t) =
  let substitute = substituted tags ~complete ~reapply bindings in
  let unqualified =
    match (parameter_of bindings t, parameterized_instance t) with
    | Some (_, Some argument), _ -> argument
    | Some (_, None), _ -> Ctype.unqualified t
    | None, Some instance -> reapply instance
    | None, None -> substituted_shape tags ~complete substitute t
  in
  built (Ctype.qualify t.qualifiers unqualified)

and substituted_shape tags ~complete substitute (t : Ctype.t) =
  match t.shape with
  | Pointer referenced -> built (Ctype.pointer_to (substitute referenced))
  | Array { element; length } ->
      let element = substitute element in
      complete element;
      built (Ctype.array_of tags element length)
  | Function { return; parameters } ->
      built
        (Ctype.function_returning (substitute return)
           (substituted_parameters substitute parameters))
  | _ -> Ctype.unqualified t

and substituted_parameters substitute : Ctype.parameters -> Ctype.parameters =
  function
  | Prototype { types; variadic } ->
      Prototype { types = List.map substitute types; variadic }
  | Old_style types -> Old_style (List.map substitute types)
  | Unspecified -> Unspecified

(* Each instance is applied again once, however often the type holds it:
   an instance may hold another at each of its arguments, so applying
   at each occurrence costs the product of their counts. *)
let substitute tags ~apply ~complete bindings t =
  let applied = ref Ctype.Instances.empty in
  let rec substitute_type t =
    substituted tags ~complete ~reapply bindings t
  and reapply (instance : Ctype.instance) =
    match Ctype.Instances.find_opt instance !applied with
    | Some t -> t
    | None ->
        let arguments = List.map substitute_type instance.argument_types in
        let t = Ctype.unqualified (apply instance.generic arguments) in
        applied := Ctype.Instances.add instance t !applied;
        t
  in
  match substitute_type t with
  | t -> Ok t
  | exception Failed failure -> Error failure

let newly_deduced ~before ~after =
  List.concat
    (List.map2
       (fun (_, earlier) (_, later) ->
         match (earlier, later) with
         | None, Some t -> [ t ]
         | _ -> [])
       before after)
