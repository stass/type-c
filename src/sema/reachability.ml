(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type facts = {
  noreturn : Tree.expression -> bool;
  non_zero : Tree.expression -> bool;
}

type refusal = { span : Tree.span; diagnostic : Rule.diagnostic }

exception Refused of refusal

let refuse span diagnostic = raise (Refused { span; diagnostic })

module Targets = Set.Make (struct
  type t = Tree.jump_target

  let compare (Tree.Statement_at a) (Tree.Statement_at b) = Int.compare a b
end)

(* Every statement that a jump may leave, so that a statement completes
   if it does on any backend's reading (design 4.4). *)
let targets = function
  | Tree.Only target -> Targets.singleton target
  | Either { loop; around } -> Targets.of_list [ loop; around ]

(* What a statement tells the statements around it (design 4.4). *)
type flow = {
  completes : bool;
  (* The loops, switches and matches around it that a reachable break or
     continue in it leaves for, as the parser resolved each. *)
  breaks : Targets.t;
  continues : Targets.t;
  (* It carries or contains a named label outside every guarded
     statement in it, by which a goto from around it may enter it. *)
  has_named_label : bool;
  (* It carries or contains a case or default label of the switch around
     it, by which that switch may enter it. *)
  has_case_label : bool;
  (* It holds a default label of the switch around it, reachable or not. *)
  default : bool;
}

let completes =
  { completes = true; breaks = Targets.empty; continues = Targets.empty;
    has_named_label = false; has_case_label = false; default = false }

let stops = { completes with completes = false }

(* [flow] followed by [next], whose jumps leave only where it is
   reachable. The two complete, as the expressions and declarations that
   combine flows this way do; a statement that may not sets its own
   [completes] on the result. *)
let followed_by flow ~reachable next =
  let jumps leaving =
    if reachable then Targets.union (leaving flow) (leaving next)
    else leaving flow
  in
  {
    completes = true;
    breaks = jumps (fun flow -> flow.breaks);
    continues = jumps (fun flow -> flow.continues);
    has_named_label = flow.has_named_label || next.has_named_label;
    has_case_label = flow.has_case_label || next.has_case_label;
    default = flow.default || next.default;
  }

let both flow next = followed_by flow ~reachable:true next

(* Whether a reachable break in [flow] leaves the statement [target]. *)
let breaks_to target flow = Targets.mem target flow.breaks

let all flow_of parts =
  List.fold_left (fun flow part -> both flow (flow_of part)) completes parts

(* A goto, including an [asm goto], jumps to its label; the address of a
   label lets a computed goto anywhere in the function jump to it. *)
type jump_kind = Goto | Address

(* Where a label or a jump lies among statement expressions, which a
   goto enters only from inside (GCC manual, "Statement Exprs"): in
   none, in the innermost at the span, or in an expression that may not
   be evaluated, such as an array length or a case value, where the
   backends may disagree, so the rule is theirs. GCC refuses a goto into
   or out of a statement expression there; Clang mostly checks no jump
   there and accepts it. *)
type expression_context =
  | Outside_statement_expressions
  | Inside_statement_expression of Tree.span
  | Backends_differ

type jump = {
  target : Tree.label_id;
  site : Tree.span;
  kind : jump_kind;
  jump_context : expression_context;
}

(* A statement that a jump enters only from inside it (design 4.3 rule
   3): a match arm, or the statement of a single-pattern test, which
   only a successful test enters (4.6 rule 6). *)
type guarded = Arm of Tree.span | Tested of Tree.span

(* A labelled statement: its label, the innermost guarded statement
   around it, [None] outside every one, and its context. *)
type definition = {
  label : Tree.label_id;
  site : Tree.span;
  guard : guarded option;
  label_context : expression_context;
}

(* One walk of a body. [guard] and [context] say where the walk is;
   [definitions] and [jumps] hold the labelled statements and the jumps
   in the order of the walk, which is not source order: a loop's body is
   walked before its condition. *)
type walk = {
  facts : facts;
  guard : guarded option;
  context : expression_context;
  definitions : definition Queue.t;
  jumps : jump Queue.t;
}

let record_jump walk kind ({ name; label } : Tree.label_name) =
  Queue.add
    { target = label; site = name.span; kind; jump_context = walk.context }
    walk.jumps

(* A jump may enter a statement at a label it carries or contains. *)
let enterable flow = flow.has_named_label || flow.has_case_label

let rec block walk (b : Tree.block) = sequence walk b.node.items

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
  | Block_type_declaration { declaration; _ } ->
      type_declaration_flow walk declaration
  | Block_statement statement -> statement_flow walk statement

and declaration_flow walk (declaration : Tree.declaration) =
  match declaration.node with
  | Declaration { specifiers; declarators } ->
      let declarator_and_value (declarator : Tree.init_declarator) =
        let value =
          match declarator.node.initialiser with
          | Some value -> initialiser walk value
          | None -> completes
        in
        both (declarator_flow walk declarator.node.declarator) value
      in
      both
        (specifiers_flow walk specifiers)
        (all declarator_and_value declarators)
  | Static_assert { condition; _ } -> unevaluated walk condition

and initialiser walk = function
  | Tree.Expression_initialiser value -> expression walk value
  | Braced values -> initialiser_list walk values

and initialiser_list walk (values : Tree.initialiser_list) =
  all
    (fun (value : Tree.designated_initialiser) ->
      both
        (designators_flow walk value.node.designators)
        (initialiser walk value.node.initialiser))
    values.node

and designators_flow walk designators =
  let designator (designator : Tree.designator) =
    match designator.node with
    | Index index -> unevaluated walk index
    | Index_range { low; high } ->
        both (unevaluated walk low) (unevaluated walk high)
    | Member_designator _ -> completes
  in
  all designator designators

and statement_flow walk (statement : Tree.statement) =
  (* What a break or continue names, if [statement] is one it leaves. *)
  let target = Tree.jump_target_of statement in
  match statement.node with
  | Labeled { label; statement = labelled } ->
      labelled_flow walk label labelled
  | Compound b -> block walk b
  | Expression_statement value -> expression walk value
  | Null_statement | Attribute_statement _ -> completes
  | If { condition; then_branch; else_branch } ->
      if_flow walk condition then_branch else_branch
  | Switch { controlling; body } -> switch_flow walk target controlling body
  | While { condition = Controlling condition; body } ->
      let body = statement_flow walk body in
      let ends = not (walk.facts.non_zero condition) in
      loop target (expression walk condition) body ~completes:ends
  | While { condition = Pattern_test { operand; _ }; body } ->
      loop target (expression walk operand) (tested walk body)
        ~completes:true
  | Do { body; condition } ->
      let body = statement_flow walk body in
      let repeats = walk.facts.non_zero condition in
      let again = body.completes || Targets.mem target body.continues in
      loop target (expression walk condition) body
        ~completes:((not repeats) && again)
  | For { clause; condition; step; body } ->
      for_flow walk target clause condition step body
  | Goto label ->
      record_jump walk Goto label;
      stops
  | Computed_goto target -> { (expression walk target) with completes = false }
  | Continue { loop } -> { stops with continues = targets loop }
  | Break { leaves } -> { stops with breaks = targets leaves }
  | Return value ->
      { (all (expression walk) (Option.to_list value)) with completes = false }
  | Asm assembler -> asm_flow walk assembler
  | Match { scrutinee; arms } -> match_flow walk target scrutinee arms

and labelled_flow walk (label : Tree.label) labelled =
  match label.node with
  | Named_label { label = id; _ } ->
      Queue.add
        { label = id; site = label.span; guard = walk.guard;
          label_context = walk.context }
        walk.definitions;
      { (statement_flow walk labelled) with has_named_label = true }
  | Case_label value ->
      case_flow (unevaluated walk value) (statement_flow walk labelled)
  | Case_range { low; high } ->
      let values = both (unevaluated walk low) (unevaluated walk high) in
      case_flow values (statement_flow walk labelled)
  | Default_label ->
      { (statement_flow walk labelled) with has_case_label = true;
        default = true }

(* A statement with a case label, whose value gives the flow [value]. *)
and case_flow value labelled =
  { (both value labelled) with
    completes = labelled.completes;
    has_case_label = true }

and if_flow walk condition then_branch else_branch =
  let taken =
    match condition with
    | Tree.Controlling _ -> statement_flow walk then_branch
    | Pattern_test _ -> tested walk then_branch
  in
  let other =
    match else_branch with
    | Some branch -> statement_flow walk branch
    | None -> completes
  in
  let condition = expression walk (Tree.condition_value condition) in
  { (both (both condition taken) other) with
    completes = taken.completes || other.completes }

and for_flow walk target clause condition step body =
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
  loop target outside body ~completes:ends

(* The loop [target], whose condition and other expressions give the flow
   [outside]. The loop completes where [completes] says it may end other
   than by a break, or where a break leaves it. The breaks and continues
   for [target] end at the loop, those of [body] and, in C text, those of
   its condition or step (design 4.4). Its labels are those of the
   statements around the loop. *)
and loop target outside body ~completes =
  let flow = both outside body in
  { flow with
    completes = completes || breaks_to target flow;
    breaks = Targets.remove target flow.breaks;
    continues = Targets.remove target flow.continues }

(* The breaks of [body] for the switch [target] end at it, and its case
   and default labels are the switch's own (C11 6.8.4.2p4); its other
   jumps and its named labels are those of the statements around it. *)
and switch_flow walk target controlling body =
  let outside = expression walk controlling in
  let body = statement_flow walk body in
  let inside =
    { body with
      breaks = Targets.remove target body.breaks;
      has_case_label = false;
      default = false }
  in
  { (both outside inside) with
    completes =
      (not body.default) || breaks_to target body || body.completes }

(* Design 4.3 rule 2: a break in an arm leaves the match [target], which
   completes only by one. By rule 3, which [label_refusal] checks over
   each body that holds a match, a label in an arm is entered only from
   the arm, so of the arms only their continues reach the statements
   around the match. *)
and match_flow walk target scrutinee arms =
  let outside = expression walk scrutinee in
  let arms = all (arm walk) arms in
  { outside with
    completes = breaks_to target arms;
    continues = Targets.union outside.continues arms.continues }

and arm walk (arm : Tree.arm) =
  sequence { walk with guard = Some (Arm arm.span) } arm.node.items

(* Design 4.6 rules 5 and 6: the statement of a single-pattern test may
   complete and leave what is around it, as C's does, but a jump enters
   it only from inside it, as an arm, so its labels are not those of the
   statements around it. *)
and tested walk (statement : Tree.statement) =
  let flow =
    statement_flow { walk with guard = Some (Tested statement.span) } statement
  in
  { flow with has_named_label = false; has_case_label = false;
    default = false }

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
   read. *)
and expression walk (value : Tree.expression) =
  let operands = all (expression walk) in
  match value.node with
  | Statement_expression b -> block (entering walk b) b
  | Parenthesized inner -> expression walk inner
  | Call { callee; arguments } ->
      { (operands (callee :: arguments)) with
        completes = not (walk.facts.noreturn callee) }
  | Label_address label ->
      record_jump walk Address label;
      completes
  | Identifier _ | Constant _ | Character _ | String _ | Block_literal _ ->
      completes
  | Qualified_constructor { variant = name; _ } | Sizeof_type name
  | Alignof name ->
      type_name_flow walk name
  | Offsetof { type_name; designators; _ } ->
      both (type_name_flow walk type_name) (designators_flow walk designators)
  | Types_compatible (first, second) ->
      both (type_name_flow walk first) (type_name_flow walk second)
  | Cast { type_name; operand } | Va_arg { type_name; list = operand } ->
      both (type_name_flow walk type_name) (operands [ operand ])
  | Member { operand; _ }
  | Pointer_member { operand; _ }
  | Post_increment operand
  | Post_decrement operand
  | Unary (_, operand)
  | Sizeof_expression operand
  | Alignof_expression operand ->
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
      both (operands [ controlling ]) (all (association walk) associations)
  | Compound_literal { type_name; values } ->
      both (type_name_flow walk type_name) (initialiser_list walk values)

and association walk (association : Tree.generic_association) =
  match association.node with
  | Association (name, value) ->
      both (type_name_flow walk name) (expression walk value)
  | Default_association value -> expression walk value

(* The walk that enters the statement expression [b]. *)
and entering walk (b : Tree.block) =
  match walk.context with
  | Backends_differ -> walk
  | Outside_statement_expressions | Inside_statement_expression _ ->
      { walk with context = Inside_statement_expression b.span }

(* An expression that may not be evaluated: one in a type, which is
   evaluated only where the type is variably modified (6.7.6.2p5), or
   an integer constant expression. Every expression in a type is read
   through here. Its labels and jumps count, and it completes, so that
   the walk errs towards reachable code (design 4.4). *)
and unevaluated walk value =
  let flow = expression { walk with context = Backends_differ } value in
  { flow with completes = true }

and type_name_flow walk (name : Tree.type_name) =
  both
    (specifiers_flow walk name.node.specifier_qualifiers)
    (optional_declarator walk name.node.abstract)

(* The parser keeps the arguments of an attribute as tokens. *)
and specifiers_flow walk (specifiers : Tree.specifiers) =
  let specifier (specifier : Tree.declaration_specifier Tree.spanned) =
    match specifier.node with
    | Type_specifier specifier -> type_specifier_flow walk specifier
    | Alignment_specifier (Alignas_type name) -> type_name_flow walk name
    | Alignment_specifier (Alignas_expression value) -> unevaluated walk value
    | Storage_class _ | Type_qualifier _ | Function_specifier _
    | Attributes _ ->
        completes
  in
  all specifier specifiers

and type_specifier_flow walk = function
  | Tree.Atomic_type name | Typeof_type name -> type_name_flow walk name
  | Typeof_expression value -> unevaluated walk value
  | Struct_or_union specifier -> record_flow walk specifier
  | Enum { underlying; enumerators; _ } ->
      let value (enumerator : Tree.enumerator) =
        all (unevaluated walk) (Option.to_list enumerator.node.value)
      in
      both
        (all (specifiers_flow walk) (Option.to_list underlying))
        (all value (Option.value enumerators ~default:[]))
  | Application { arguments; _ } -> all (type_name_flow walk) arguments
  | Basic _ | Typedef_name _ -> completes

and record_flow walk (specifier : Tree.record_specifier) =
  let member_declarator (member : Tree.member_declarator) =
    match member.node with
    | Field { declarator; _ } -> declarator_flow walk declarator
    | Bit_field { declarator; width; _ } ->
        both (optional_declarator walk declarator) (unevaluated walk width)
  in
  let member (declaration : Tree.member_declaration) =
    match declaration.node with
    | Members { specifiers; declarators } ->
        both
          (specifiers_flow walk specifiers)
          (all member_declarator declarators)
    | Member_static_assert { condition; _ } -> unevaluated walk condition
  in
  match specifier.members with
  | Some members -> all member members.node
  | None -> completes

and optional_declarator walk declarator =
  all (declarator_flow walk) (Option.to_list declarator)

and declarator_flow walk (declarator : Tree.declarator) =
  match declarator.node with
  | Name _ -> completes
  | Parenthesized_declarator { inner; _ } -> declarator_flow walk inner
  | Pointer { inner; _ } | Block_pointer { inner; _ } ->
      optional_declarator walk inner
  | Array { inner; size = Sized length | Static_sized length; _ } ->
      both (unevaluated walk length) (optional_declarator walk inner)
  | Array { inner; size = Unsized | Unspecified_variable; _ } ->
      optional_declarator walk inner
  | Function { inner; parameters } ->
      both (parameters_flow walk parameters) (optional_declarator walk inner)

and parameters_flow walk = function
  | Tree.Prototype { parameters; _ } ->
      let parameter (parameter : Tree.parameter) =
        let declarator =
          match parameter.node.declarator with
          | Named_parameter { declarator; _ } -> Some declarator
          | Abstract_parameter declarator -> declarator
        in
        both
          (specifiers_flow walk parameter.node.specifiers)
          (optional_declarator walk declarator)
      in
      all parameter parameters
  | Identifier_list _ -> completes

and type_declaration_flow walk (declaration : Tree.type_declaration) =
  let field (field : Tree.field) =
    both
      (specifiers_flow walk field.node.specifiers)
      (declarator_flow walk field.node.declarator)
  in
  let constructor (constructor : Tree.constructor) =
    all field constructor.node.fields
  in
  match declaration.node.definition with
  | Incomplete_variant -> completes
  | Variant { constructors; _ } -> all constructor constructors
  | Alias name | Distinct { representation = name; _ } ->
      type_name_flow walk name
  | Record_alias specifier -> record_flow walk specifier.node

let encloses (outer : Tree.span) (inner : Tree.span) =
  outer.first <= inner.first && inner.last <= outer.last

let guarded_span = function Arm span | Tested span -> span

(* What a diagnostic calls a guarded statement, and the same statement
   named again. *)
let guarded_names = function
  | Arm _ -> ("a match arm", "the arm")
  | Tested _ -> ("the statement of a single-pattern test", "the statement")

(* The queued items of a walk in source order, so that a refusal names
   the first breach as GCC and Clang do. Spans are token indices. *)
let in_source_order site queue =
  List.stable_sort
    (fun a b -> Int.compare (site a).Tree.first (site b).Tree.first)
    (List.of_seq (Queue.to_seq queue))

(* The labelled statement of each label, which the parser defines once in
   its scope. *)
let by_label definitions =
  let defined = Hashtbl.create 16 in
  Queue.iter
    (fun (definition : definition) ->
      Hashtbl.replace defined definition.label definition)
    definitions;
  defined

(* GCC manual, "Statement Exprs". The address of a label inside one is
   allowed, and a computed goto to it is left to the backends: GCC
   accepts one from outside the statement expression, Clang refuses it.
   Either end where the backends differ leaves the jump to them. *)
let refuse_statement_expression_entry (definition : definition) jump =
  match (definition.label_context, jump.jump_context, jump.kind) with
  | _, _, Address | _, Backends_differ, Goto -> ()
  | Inside_statement_expression block, _, Goto ->
      if not (encloses block jump.site) then
        refuse jump.site
          (Rule.c_text
             "a goto into a statement expression from outside it (GCC manual, \
              \"Statement Exprs\")")
  | (Outside_statement_expressions | Backends_differ), _, Goto -> ()

(* Design 4.3 rule 3, 4.6 rule 6. A computed goto may jump to any label
   whose address is taken, so a label inside a guarded statement cannot
   have its address taken. *)
let refuse_guarded_entry (definition : definition) jump =
  match (definition.guard, jump.kind) with
  | Some guard, Address ->
      let inside, again = guarded_names guard in
      refuse jump.site
        (Rule.message Arm_entry
           (Printf.sprintf
              "the address of a label inside %s, which a computed goto \
               could jump to from outside %s"
              inside again))
  | Some guard, Goto ->
      if not (encloses (guarded_span guard) jump.site) then
        refuse jump.site
          (Rule.message Arm_entry
             (Printf.sprintf "a jump into %s from outside it"
                (fst (guarded_names guard))))
  | None, (Goto | Address) -> ()

(* The parser resolves every goto to a label defined in its scope. The
   address of one that no statement in the walk defines may be that of
   one in the arguments of an attribute, which the parser keeps as
   tokens: both backends compile [&&b] where [b] is defined in a
   statement expression in [aligned (sizeof (...))] if optimization
   drops the address, so it is left to them. *)
let check_jump definitions jump =
  match Hashtbl.find_opt definitions jump.target with
  | Some definition ->
      refuse_statement_expression_entry definition jump;
      refuse_guarded_entry definition jump
  | None -> ()

let start facts =
  { facts; guard = None; context = Outside_statement_expressions;
    definitions = Queue.create (); jumps = Queue.create () }

(* Design 4.3 rule 1. *)
let arm_refusal facts (matched : Tree.arm) =
  if (arm (start facts) matched).completes then
    Some
      { span = matched.span;
        diagnostic =
          Rule.message Arm_end "the end of the match arm can be reached" }
  else None

let label_refusal facts body =
  let walk = start facts in
  ignore (block walk body);
  match
    let definitions = by_label walk.definitions in
    let site (jump : jump) = jump.site in
    let jumps = in_source_order site walk.jumps in
    List.iter (check_jump definitions) jumps
  with
  | () -> None
  | exception Refused refusal -> Some refusal
