(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type facts = {
  noreturn : Tree.expression -> bool;
  non_zero : Tree.expression -> bool;
}

type refusal = { span : Tree.span; message : string }

exception Refused of refusal

let refuse span rule text =
  raise (Refused { span; message = Rule.message rule text })

(* What a statement tells the statements around it (design 4.4). *)
type flow = {
  completes : bool;
  (* A reachable break or continue in it leaves it, for the loop, switch
     or match around it. *)
  breaks : bool;
  continues : bool;
  (* It carries or contains a named label outside every match arm in it,
     by which a goto from around it may enter it. *)
  has_named_label : bool;
  (* It carries or contains a case or default label of the switch around
     it, by which that switch may enter it. *)
  has_case_label : bool;
  (* It holds a default label of the switch around it, reachable or not. *)
  default : bool;
}

let completes =
  { completes = true; breaks = false; continues = false;
    has_named_label = false; has_case_label = false; default = false }

let stops = { completes with completes = false }

(* [flow] followed by [next], whose jumps leave only where it is
   reachable. The two complete, as the expressions and declarations that
   combine flows this way do; a statement that may not sets its own
   [completes] on the result. *)
let followed_by flow ~reachable next =
  {
    completes = true;
    breaks = flow.breaks || (reachable && next.breaks);
    continues = flow.continues || (reachable && next.continues);
    has_named_label = flow.has_named_label || next.has_named_label;
    has_case_label = flow.has_case_label || next.has_case_label;
    default = flow.default || next.default;
  }

let both flow next = followed_by flow ~reachable:true next

let all flow_of parts =
  List.fold_left (fun flow part -> both flow (flow_of part)) completes parts

(* Where a label is declared: in its function (C11 6.2.1p3), or by a GNU
   [__label__] in the block of the span. *)
type label_scope = Function_label | Local_label of Tree.span

type label = { name : string; scope : label_scope }

(* A goto, including an [asm goto], jumps to its label; the address of a
   label lets a computed goto anywhere in the function jump to it. *)
type jump_kind = Goto | Address

type jump = { target : label; site : Tree.span; kind : jump_kind }

module Names = Map.Make (String)

(* One walk of a body. [arm] is the innermost match arm around the walk
   and [local_labels] the block of each GNU local label in scope;
   [arms_of_labels] gives the innermost arm around each label, [None]
   outside every arm, and [jumps] holds the jumps in source order. *)
type walk = {
  facts : facts;
  arm : Tree.span option;
  local_labels : Tree.span Names.t;
  arms_of_labels : (label, Tree.span option) Hashtbl.t;
  jumps : jump Queue.t;
}

let resolve walk name =
  match Names.find_opt name walk.local_labels with
  | Some block -> { name; scope = Local_label block }
  | None -> { name; scope = Function_label }

let record_jump walk kind (label : Tree.identifier) =
  Queue.add
    { target = resolve walk label.node; site = label.span; kind }
    walk.jumps

(* A jump may enter a statement at a label it carries or contains. *)
let enterable flow = flow.has_named_label || flow.has_case_label

let rec block walk (b : Tree.block) =
  let declare labels (name : Tree.identifier) =
    Names.add name.node b.span labels
  in
  let local_labels =
    List.fold_left
      (fun labels (declaration : Tree.local_label_declaration) ->
        List.fold_left declare labels declaration.node)
      walk.local_labels b.node.local_labels
  in
  sequence { walk with local_labels } b.node.items

(* An item is reachable if it is first, if it follows a reachable item
   that can complete, or if a jump may enter it; a sequence completes if
   it is empty or its last item is reachable and completes. *)
and sequence walk items =
  let step (reaching, flow) item =
    let next = block_item walk item in
    let reachable = reaching || enterable next in
    (reachable && next.completes, followed_by flow ~reachable next)
  in
  let reaching, flow = List.fold_left step (true, completes) items in
  { flow with completes = reaching }

and block_item walk = function
  | Tree.Block_declaration declaration -> declaration_flow walk declaration
  | Block_type_declaration _ -> completes
  | Block_statement statement -> statement_flow walk statement

(* The type names of a declaration are not walked: an array length or a
   [typeof] holding a statement expression that jumps is not modelled. *)
and declaration_flow walk (declaration : Tree.declaration) =
  match declaration.node with
  | Declaration { declarators; _ } ->
      let initialised (declarator : Tree.init_declarator) =
        match declarator.node.initialiser with
        | Some value -> initialiser walk value
        | None -> completes
      in
      all initialised declarators
  | Static_assert _ -> completes

and initialiser walk = function
  | Tree.Expression_initialiser value -> expression walk value
  | Braced values -> initialiser_list walk values

(* A designator's index is an integer constant expression, which holds
   no statement expression. *)
and initialiser_list walk (values : Tree.initialiser_list) =
  all
    (fun (value : Tree.designated_initialiser) ->
      initialiser walk value.node.initialiser)
    values.node

and statement_flow walk (statement : Tree.statement) =
  match statement.node with
  | Labeled { label; statement = labelled } ->
      labelled_flow walk label labelled
  | Compound b -> block walk b
  | Expression_statement value -> expression walk value
  | Null_statement | Attribute_statement _ -> completes
  | If { condition; then_branch; else_branch } ->
      if_flow walk condition then_branch else_branch
  | Switch { controlling; body } -> switch_flow walk controlling body
  | While { condition; body } ->
      let body = statement_flow walk body in
      let ends = not (walk.facts.non_zero condition) in
      loop (expression walk condition) body ~completes:(ends || body.breaks)
  | Do { body; condition } ->
      let body = statement_flow walk body in
      let repeats = walk.facts.non_zero condition in
      let again = body.completes || body.continues in
      loop (expression walk condition) body
        ~completes:(body.breaks || ((not repeats) && again))
  | For { clause; condition; step; body } ->
      for_flow walk clause condition step body
  | Goto label ->
      record_jump walk Goto label;
      stops
  | Computed_goto target -> { (expression walk target) with completes = false }
  | Continue -> { stops with continues = true }
  | Break -> { stops with breaks = true }
  | Return value ->
      { (all (expression walk) (Option.to_list value)) with completes = false }
  | Asm assembler -> asm_flow walk assembler
  | Match { scrutinee; arms } -> match_flow walk scrutinee arms

and labelled_flow walk (label : Tree.label) labelled =
  match label.node with
  | Named_label { name; _ } ->
      Hashtbl.replace walk.arms_of_labels (resolve walk name) walk.arm;
      { (statement_flow walk labelled) with has_named_label = true }
  | Case_label _ | Case_range _ ->
      { (statement_flow walk labelled) with has_case_label = true }
  | Default_label ->
      { (statement_flow walk labelled) with has_case_label = true;
        default = true }

and if_flow walk condition then_branch else_branch =
  let taken = statement_flow walk then_branch in
  let other =
    match else_branch with
    | Some branch -> statement_flow walk branch
    | None -> completes
  in
  let condition = expression walk condition in
  { (both (both condition taken) other) with
    completes = taken.completes || other.completes }

and for_flow walk clause condition step body =
  let body = statement_flow walk body in
  let ends =
    match condition with
    | Some condition -> not (walk.facts.non_zero condition)
    | None -> false
  in
  let clause =
    match clause with
    | None -> completes
    | Some (Tree.Clause_declaration declaration) ->
        declaration_flow walk declaration
    | Some (Clause_expression value) -> expression walk value
  in
  let expressions = Option.to_list condition @ Option.to_list step in
  let outside = both clause (all (expression walk) expressions) in
  loop outside body ~completes:(ends || body.breaks)

(* A loop whose condition and other expressions, which typing reads
   outside the loop, give the flow [outside]: the breaks and continues
   of [body] are the loop's own, and its labels those of the statements
   around the loop. *)
and loop outside body ~completes =
  let inside = { body with breaks = false; continues = false } in
  { (both outside inside) with completes }

(* The breaks and the case and default labels of [body] are the
   switch's own (C11 6.8.4.2p4); its continues and named labels are
   those of the statements around it. *)
and switch_flow walk controlling body =
  let outside = expression walk controlling in
  let body = statement_flow walk body in
  let inside =
    { body with breaks = false; has_case_label = false; default = false }
  in
  { (both outside inside) with
    completes = (not body.default) || body.breaks || body.completes }

(* Design 4.3 rule 2: a break in an arm leaves the match, which completes
   only by one. By rule 3, which [jump_refusal] checks over each body
   that holds a match, a label in an arm is entered only from the arm,
   so of the arms only their continues reach the statements around the
   match. *)
and match_flow walk scrutinee arms =
  let outside = expression walk scrutinee in
  let arms = all (arm walk) arms in
  { outside with
    completes = arms.breaks;
    continues = outside.continues || arms.continues }

and arm walk (arm : Tree.arm) =
  sequence { walk with arm = Some arm.span } arm.node.items

(* An [asm goto] may jump to each of its labels or complete. *)
and asm_flow walk (assembler : Tree.assembler) =
  match assembler.operands with
  | None -> completes
  | Some operands ->
      List.iter (record_jump walk Goto) operands.labels;
      all
        (fun (operand : Tree.asm_operand) -> expression walk operand.node.value)
        (operands.outputs @ operands.inputs)

(* An expression completes unless it is a call to a function that does
   not return; a statement expression is the block it holds. The body
   of a block literal is a function of its own, which typing does not
   read, and a type name is not walked. *)
and expression walk (value : Tree.expression) =
  let operands = all (expression walk) in
  match value.node with
  | Statement_expression b -> block walk b
  | Parenthesized inner -> expression walk inner
  | Call { callee; arguments } ->
      { (operands (callee :: arguments)) with
        completes = not (walk.facts.noreturn callee) }
  | Label_address label ->
      record_jump walk Address label;
      completes
  | Identifier _ | Constant _ | Character _ | String _
  | Qualified_constructor _ | Sizeof_type _ | Alignof _ | Offsetof _
  | Types_compatible _ | Block_literal _ ->
      completes
  | Member { operand; _ }
  | Pointer_member { operand; _ }
  | Post_increment operand
  | Post_decrement operand
  | Unary (_, operand)
  | Sizeof_expression operand
  | Alignof_expression operand
  | Cast { operand; _ }
  | Va_arg { list = operand; _ } ->
      operands [ operand ]
  | Subscript { operand; index } -> operands [ operand; index ]
  | Binary (_, left, right)
  | Assignment (_, left, right)
  | Comma (left, right) ->
      operands [ left; right ]
  | Conditional { condition; if_true; if_false } ->
      operands ((condition :: Option.to_list if_true) @ [ if_false ])
  | Choose { condition; first; second } ->
      operands [ condition; first; second ]
  | Generic { controlling; associations } ->
      operands (controlling :: List.map association associations)
  | Compound_literal { values; _ } -> initialiser_list walk values

and association (association : Tree.generic_association) =
  match association.node with
  | Association (_, value) | Default_association value -> value

let encloses (outer : Tree.span) (inner : Tree.span) =
  outer.first <= inner.first && inner.last <= outer.last

(* Design 4.3 rule 3. A computed goto may jump to any label whose address
   is taken, so a label inside an arm cannot have its address taken. *)
let check_jump arms_of_labels jump =
  match (Hashtbl.find_opt arms_of_labels jump.target, jump.kind) with
  | Some (Some _), Address ->
      refuse jump.site Arm_entry
        "the address of a label inside a match arm, which a computed goto \
         could jump to from outside the arm"
  | Some (Some arm), Goto when not (encloses arm jump.site) ->
      refuse jump.site Arm_entry "a jump into a match arm from outside it"
  | (Some _ | None), (Goto | Address) -> ()

let start facts =
  { facts; arm = None; local_labels = Names.empty;
    arms_of_labels = Hashtbl.create 16; jumps = Queue.create () }

(* Design 4.3 rule 1. *)
let arm_refusal facts (matched : Tree.arm) =
  if (arm (start facts) matched).completes then
    Some
      { span = matched.span;
        message =
          Rule.message Arm_end "the end of the match arm can be reached" }
  else None

let jump_refusal facts body =
  let walk = start facts in
  ignore (block walk body);
  match Queue.iter (check_jump walk.arms_of_labels) walk.jumps with
  | () -> None
  | exception Refused refusal -> Some refusal
