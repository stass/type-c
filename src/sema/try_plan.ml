(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type branch = When_true | When_false
type condition = { truth : int; branch : branch }

type form =
  | Tried of { number : int }
  | Truth of { number : int }
  | Discarded_left

type hoisted = {
  form : form;
  replaced : Tree.span;
  operand : Tree.span;
  conditions : condition list;
}

type place = Hoisted of hoisted | Refused of Rule.t * string

type holder_expression =
  | Expression of Tree.expression
  | Initialiser of Tree.initialiser

type t = {
  hoisted : hoisted list;
  places : (Tree.span, place) Hashtbl.t;
  next_try : int;
  next_truth : int;
}

(* The walk names a first operand by its span until the numbering,
   which follows the order of 5.1 that the walk only finishes. *)
type found_condition = { first : Tree.span; on : branch }

type found_form = Found_try | Found_truth | Found_left

type entry =
  | Hoist of {
      form : found_form;
      replaced : Tree.span;
      operand : Tree.span;
      conditions : found_condition list;
    }
  | Refuse of Tree.span * Rule.t * string

(* What the operators between the holder and the expression being walked
   say of a [try] there: the conditions it stands under, innermost
   first, each list the tail of those of the operands inside; whether C asks
   for an lvalue there (try-lvalue); and the refusal of an initialiser of
   a braced list that is no [try] expression (try-list). *)
type walk = {
  inspects : string -> bool;
  conditions : found_condition list;
  lvalue : bool;
  in_list : (Rule.t * string) option;
}

let lvalue_refusal =
  ( Rule.Try_lvalue,
    "the value of try is no lvalue, which the operand of &, ++ or -- and \
     the left operand of an assignment are; give it an object of its own" )

let list_refusal =
  ( Rule.Try_list,
    "an initialiser of a braced list that holds try is itself a try \
     expression; give the rest of it a declaration of its own" )

let rec without_parentheses (value : Tree.expression) =
  match value.node with
  | Parenthesized inner -> without_parentheses inner
  | _ -> value

(* Design 5.1 rule 3 and 7.1 rule 4: a call takes a [try] in its
   arguments unless it calls a builtin that inspects more than their
   values; a builtin is a name that no declaration in the tree resolves. *)
let evaluates_arguments walk (callee : Tree.expression) =
  match (without_parentheses callee).node with
  | Identifier { name; resolution = Undeclared } -> not (walk.inspects name)
  | _ -> true

let tried walk (whole : Tree.expression) (operand : Tree.expression) =
  let refuse (rule, text) = Refuse (whole.span, rule, text) in
  if walk.lvalue then refuse lvalue_refusal
  else
    match walk.in_list with
    | Some refusal -> refuse refusal
    | None ->
        Hoist
          { form = Found_try;
            replaced = whole.span;
            operand = operand.span;
            conditions = walk.conditions }

let first_operand walk form (operand : Tree.expression) =
  Hoist
    { form; replaced = operand.span; operand = operand.span;
      conditions = walk.conditions }

(* The entries of an expression in the order of 5.1: each [try] after
   its operand, and a first operand after what it holds and before what
   it conditions. Only the operators that rule 3 names are walked into. *)
let rec expression walk (value : Tree.expression) =
  let as_value = expression { walk with lvalue = false } in
  let as_lvalue = expression { walk with lvalue = true } in
  match value.node with
  | Parenthesized inner -> expression walk inner
  | Member { operand; member = _ } -> expression walk operand
  | Try { operand } ->
      as_value operand @ [ tried walk value operand ]
  | Unary ((Address | Pre_increment | Pre_decrement), operand)
  | Post_increment operand
  | Post_decrement operand ->
      as_lvalue operand
  | Assignment (_, left, right) -> as_lvalue left @ as_value right
  | Unary
      ( ( Indirection | Unary_plus | Unary_minus | Bitwise_not | Logical_not
        | Real_part | Imaginary_part ),
        operand )
  | Cast { operand; type_name = _ }
  | Pointer_member { operand; member = _ } ->
      as_value operand
  | Subscript { operand; index } -> as_value operand @ as_value index
  | Binary ({ node = Logical_and; _ }, first, second) ->
      guarded walk first [ (second, When_true) ]
  | Binary ({ node = Logical_or; _ }, first, second) ->
      guarded walk first [ (second, When_false) ]
  | Binary (_, left, right) -> as_value left @ as_value right
  | Conditional { condition; if_true = Some if_true; if_false } ->
      guarded walk condition [ (if_true, When_true); (if_false, When_false) ]
  | Conditional { condition; if_true = None; if_false = _ } ->
      as_value condition
  | Comma (left, right) -> (
      match as_value right with
      | [] -> as_value left
      | after ->
          as_value left
          @ (first_operand walk Found_left left :: after))
  | Call { callee; arguments } ->
      if evaluates_arguments walk callee then
        List.concat_map as_value (callee :: arguments)
      else as_value callee
  | Slice_operation (Slice_from_array operand) -> as_value operand
  | Slice_operation (Slice_sub { slice; low; high }) ->
      List.concat_map as_value [ slice; low; high ]
  | Slice_operation (Slice_unchecked { pointer; count }) ->
      as_value pointer @ as_value count
  | Compound_literal { values; type_name = _ } ->
      braced { walk with lvalue = false } values
  | Identifier _ | Constant _ | Character _ | String _ | Generic _
  | Qualified_constructor _ | Instance _ | Sizeof_expression _
  | Sizeof_type _ | Alignof _ | Alignof_expression _ | Statement_expression _
  | Label_address _ | Va_arg _ | Offsetof _ | Types_compatible _ | Choose _
  | Block_literal _ ->
      []

(* A first operand whose operator holds a hoisted operand in another
   operand is hoisted itself, after what it holds, and conditions those
   operands; where they hold none, the operator stays whole. *)
and guarded walk (first : Tree.expression) branches =
  let under (operand, on) =
    expression
      { walk with
        lvalue = false;
        conditions = { first = first.span; on } :: walk.conditions }
      operand
  in
  let first_entries = expression { walk with lvalue = false } first in
  match List.concat_map under branches with
  | [] -> first_entries
  | conditioned ->
      first_entries @ (first_operand walk Found_truth first :: conditioned)

(* Each initialiser of a braced list is a [try] expression, in
   parentheses or not, or holds none (try-list). *)
and braced walk (list : Tree.initialiser_list) =
  List.concat_map
    (fun (item : Tree.designated_initialiser) ->
      listed walk item.node.initialiser)
    list.node

and listed walk = function
  | Tree.Braced list -> braced walk list
  | Expression_initialiser value -> (
      let whole = without_parentheses value in
      match whole.node with
      | Try { operand } ->
          expression walk operand
          @ [ tried walk whole operand ]
      | _ -> expression { walk with in_list = Some list_refusal } value)

(* The numbers of the order of 5.1: each [try] and each first operand
   take the next of their own count. A list of conditions is numbered
   once, by its innermost, which names its first operand and so the
   whole list; the numbered lists share their tails as the walk's do,
   so a chain of conditionals costs its length, not its square. *)
let numbered ~next_try ~next_truth entries =
  let truths = Hashtbl.create 4 in
  let places = Hashtbl.create 8 in
  let numbered_conditions = Hashtbl.create 4 in
  let rec numbering = function
    | [] -> []
    | { first; on } :: outer -> (
        match Hashtbl.find_opt numbered_conditions (first, on) with
        | Some conditions -> conditions
        | None ->
            let conditions =
              { truth = Hashtbl.find truths first; branch = on }
              :: numbering outer
            in
            Hashtbl.replace numbered_conditions (first, on) conditions;
            conditions)
  in
  let number (hoisted, next_try, next_truth) = function
    | Refuse (span, rule, text) ->
        Hashtbl.replace places span (Refused (rule, text));
        (hoisted, next_try, next_truth)
    | Hoist { form; replaced; operand; conditions } ->
        let form, next_try, next_truth =
          match form with
          | Found_try -> (Tried { number = next_try }, next_try + 1, next_truth)
          | Found_truth ->
              Hashtbl.replace truths operand next_truth;
              (Truth { number = next_truth }, next_try, next_truth + 1)
          | Found_left -> (Discarded_left, next_try, next_truth)
        in
        let made =
          { form; replaced; operand;
            conditions = numbering conditions }
        in
        (match form with
        | Tried _ -> Hashtbl.replace places replaced (Hoisted made)
        | Truth _ | Discarded_left -> ());
        (made :: hoisted, next_try, next_truth)
  in
  let hoisted, next_try, next_truth =
    List.fold_left number ([], next_try, next_truth) entries
  in
  { hoisted = List.rev hoisted; places; next_try; next_truth }

let plan ~inspects ~next_try ~next_truth holder_expression =
  let walk = { inspects; conditions = []; lvalue = false; in_list = None } in
  let entries =
    match holder_expression with
    | Expression value | Initialiser (Expression_initialiser value) ->
        expression walk value
    | Initialiser (Braced list) -> braced walk list
  in
  numbered ~next_try ~next_truth entries

let hoisted plan = plan.hoisted

let place plan span = Hashtbl.find_opt plan.places span
let next_try plan = plan.next_try
let next_truth plan = plan.next_truth
