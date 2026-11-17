(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type definition = {
  name : Tree.identifier;
  function_type : Ctype.t;
  return_type : Ctype.t Unknown.answer;
  targets : Entity.targets;
  marked : string option;
  declaration_list : Tree.span list;
  scope : Tree.scope_depth;
  owns : Resolution.own list;
  defers : Expressions.function_defers;
}

let form = "the form of a `return e;` in the scope of a `defer` statement"

(* Design 13.5: in a function that returns void, [return e;] becomes
   [{ e; copies return; }], which C's diagnostic of a value returned
   from it would not reach. *)
let void_value typed (statement, operand) =
  let typed_operand =
    match Expressions.find_at typed operand with
    | Some typed_operand -> typed_operand
    | None -> invalid_arg "Return_form: an operand that typing did not type"
  in
  let refused text =
    Some (statement, Rule.message Return_void_value text)
  in
  match Ctype.is_void typed_operand.expression_type with
  | Answer true -> None
  | Answer false ->
      refused
        "a `return e;` of a value in the scope of a `defer` statement, in a \
         function that returns void: lowering writes it as the statement \
         `e;`, which loses C's diagnostic of the return (C11 6.8.6.4p1)"
  | Depends_on (unknown : Unknown.t) ->
      refused
        (Printf.sprintf
           "a `return e;` in the scope of a `defer` statement, in a function \
            that returns void, whose operand depends on %s at %s:%d: typec \
            cannot tell whether it is void, which lowering needs to know"
           unknown.construct unknown.location.file unknown.location.line)

(* The return type, unless typec does not know whether it is void. *)
let unknown_return (return_type : Ctype.t Unknown.answer) =
  match return_type with
  | Depends_on unknown -> Some unknown
  | Answer t -> (
      match Ctype.is_void t with
      | Depends_on unknown -> Some unknown
      | Answer (true | false) -> None)

let quoted (name : Tree.identifier) = Expressions.quote name.node

(* Design 13.5: the call of [f] names one function only where no two
   declarations of it are versions of it and none carries a marked
   attribute. *)
let name_refusal definition =
  let name = quoted definition.name in
  match (definition.targets, definition.marked) with
  | Versioned, _ ->
      Some
        ( definition.name.span,
          Rule.message Return_target_versions
            (name
           ^ " is declared with `target` attributes whose arguments differ, \
              as versions of one function, which the call of " ^ name
           ^ " that " ^ form ^ " writes cannot name") )
  | (Untargeted | Targeted _), Some attribute ->
      Some
        ( definition.name.span,
          Rule.message Return_marked_attribute
            ("a declaration of " ^ name ^ " carries the attribute "
           ^ Expressions.quote attribute
           ^ ", with which the call of " ^ name ^ " that " ^ form
           ^ " writes may name more than one function or be an error") )
  | (Untargeted | Targeted _), None -> None

let holds (outer : Tree.span) (inner : Tree.span) =
  outer.first <= inner.first && inner.last <= outer.last

(* The names that the definition declares in the scope of its parameter
   list, in source order: in the parameter list or the declaration list,
   or in the outermost block of the body. A prototype scope of the head
   outside the parameter list, as that of a returned function pointer,
   has the same depth but is another scope. *)
let scope_owns definition ~declares =
  let in_scope (own : Resolution.own) =
    own.scope = definition.scope && declares own.declared.span
  in
  List.filter in_scope definition.owns
  |> List.sort (fun (a : Resolution.own) (b : Resolution.own) ->
         compare a.declared.span.first b.declared.span.first)

let parameter_owns definition =
  let { Tree.derivation; _ } =
    Tree.defined_function definition.defers.declarator
  in
  let declares span =
    List.exists (fun outer -> holds outer span)
      (derivation :: definition.declaration_list)
  in
  scope_owns definition ~declares

let body_owns definition =
  scope_owns definition ~declares:(holds definition.defers.body)

(* The name space of a declaration (C11 6.2.3). *)
type space = Ordinary_space | Tag_space | Label_space

let space_of : Resolution.declaration -> space = function
  | Ordinary _ -> Ordinary_space
  | Tag _ -> Tag_space
  | Label _ -> Label_space


(* Design 13.5: [__typeof__(f)] in the typedef would name a parameter or
   an enumeration constant of the parameter list called [f]. *)
let own_name_refusal definition parameter_owns =
  let names_function (own : Resolution.own) =
    own.declared.name = definition.name.node
    && space_of own.declared.declaration = Ordinary_space
  in
  match List.find_opt names_function parameter_owns with
  | Some own ->
      Some
        ( own.declared.span,
          Rule.message Return_own_name
            ("the parameter list declares " ^ quoted definition.name
           ^ ", the name of the function, which hides the function from \
              the call of it that " ^ form ^ " writes; rename it") )
  | None -> None

(* [(void)] is a parameter without a name that declares no parameter. *)
let takes_no_parameters (function_type : Ctype.t) =
  match function_type.shape with
  | Function { parameters = Prototype { types = []; variadic = _ }; _ } -> true
  | Function { parameters = Prototype { types = _ :: _; _ }; _ }
  | Function { parameters = Old_style _ | Unspecified; _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Unknown_type _ ->
      false

(* Design 13.5: the call passes an lvalue of each parameter by its
   name. *)
let unnamed_refusal definition =
  let is_unnamed (parameter : Tree.parameter) =
    match parameter.node.declarator with
    | Abstract_parameter _ -> true
    | Named_parameter _ -> false
  in
  let unnamed =
    match (Tree.defined_function definition.defers.declarator).parameters with
    | Identifier_list _ -> None
    | Prototype _ when takes_no_parameters definition.function_type -> None
    | Prototype { parameters; variadic = _ } ->
        List.find_opt is_unnamed parameters
  in
  match unnamed with
  | Some parameter ->
      Some
        ( parameter.span,
          Rule.message Return_unnamed_parameter
            ("a parameter without a name, of which the call of "
           ^ quoted definition.name ^ " that " ^ form
           ^ " writes cannot pass an lvalue; name it") )
  | None -> None

(* Design 13.5: in the block of its own that the body becomes, a
   declaration of a name of the parameter list declares another, where C
   reads it in the scope of the parameter list. C refuses an ordinary
   identifier there (C11 6.7p3) before this is asked, so a tag is
   what reaches it. *)
let redeclared_refusal parameter_owns body_owns =
  (* A name with its name space. *)
  let key (own : Resolution.own) =
    (space_of own.declared.declaration, own.declared.name)
  in
  let declared = Hashtbl.create 16 in
  List.iter (fun own -> Hashtbl.replace declared (key own) ()) parameter_owns;
  let redeclares own = Hashtbl.mem declared (key own) in
  match List.find_opt redeclares body_owns with
  | Some own ->
      Some
        ( own.declared.span,
          Rule.message Return_parameter_redeclared
            ("the outermost block of the body declares "
           ^ Expressions.quote own.declared.name
           ^ " again, which the parameter list declares; " ^ form
           ^ " puts the body in a block of its own, where this would \
              declare another") )
  | None -> None

let first_refusal checks = List.find_map (fun check -> check ()) checks

let value_refusal definition =
  let parameter_owns = parameter_owns definition in
  let body_owns = body_owns definition in
  first_refusal
    [ (fun () -> name_refusal definition);
      (fun () -> own_name_refusal definition parameter_owns);
      (fun () -> unnamed_refusal definition);
      (fun () -> redeclared_refusal parameter_owns body_owns) ]

let refusal typed definition =
  match Reachability.value_returns definition.defers.sites with
  | [] -> None
  | (first, _) :: _ as returns -> (
      match definition.defers.returns with
      | Returns_void -> List.find_map (void_value typed) returns
      | Returns_value -> (
          match unknown_return definition.return_type with
          | Some unknown -> Some (first, Expressions.needing form unknown)
          | None -> value_refusal definition))
