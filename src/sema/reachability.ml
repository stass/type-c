(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type facts = {
  noreturn : Tree.expression -> bool;
  non_zero : Tree.expression -> bool;
  pragma_before : int -> bool;
}

type refusal = { span : Tree.span; diagnostic : Rule.diagnostic }

type exit =
  | Jump of Tree.span
  | Value_return of { statement : Tree.span; operand : Tree.span }
  | Error_path of Tree.span

type place = Block_end of int | Trap of int | Left_by of exit

let place_token = function
  | Block_end closing | Trap closing -> closing
  | Left_by (Jump statement) -> statement.first
  | Left_by (Value_return { statement; operand = _ }) -> statement.first
  | Left_by (Error_path try_span) -> try_span.first

type defer_site = {
  keyword : Tree.span;
  deferred : Tree.span;
  places : place list;
  scope_tokens : Tree.span;
  annotated : Tree.span list;
}

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

(* What a jump enters only from inside it: a match arm (design 4.3 rule
   3), the statement of a single-pattern test, which only a successful
   test enters (4.6 rule 6), or the scope of a defer statement, the
   items after it in its block (6 rules 1 and 5), with the exits of the
   scope and the statements and items in it with a pragma line directly
   before them that the walk has read. *)
type guarded =
  | Arm of Tree.span
  | Tested of Tree.span
  | Defer_scope of {
      scope : Tree.span;
      scope_exits : exit Queue.t;
      scope_annotated : Tree.span Queue.t;
    }

(* A defer statement that a sequence of items holds, with the exits and
   the annotated statements and items of its scope, which fill as the
   walk reads the items after it. *)
type read_defer = {
  defer_keyword : Tree.span;
  defer_statement : Tree.span;
  defer_exits : exit Queue.t;
  defer_annotated : Tree.span Queue.t;
}

(* Where the scope of a defer statement ends: at the [}], token
   [closing], of a block that can complete, which is an exit; of one
   that cannot, which is none (design 6 rule 1); or at the end of a
   match arm, which cannot complete (4.3 rule 1) and holds no [}]. *)
type ending = Completes of int | Cannot_complete of int | Arm_end

(* A defer statement whose scope the walk has read: where the scope
   ends, and its tokens after the deferred statement. *)
type read_scope = { read : read_defer; ending : ending; tokens : Tree.span }

(* A goto statement, after its labels, with the guarded statements and
   scopes around it, the innermost first, and the operands around it. It
   leaves those that do not hold its label; the label may come later in
   the source, so this is decided once the walk has read every label. *)
type goto = {
  goto_statement : Tree.span;
  goto_target : Tree.label_id;
  goto_guards : guarded list;
  goto_operands : Tree.span list;
}

(* A labelled statement: its label, the innermost guarded statement
   around it, [None] outside every one, and its context. *)
type definition = {
  label : Tree.label_id;
  site : Tree.span;
  guard : guarded option;
  label_context : expression_context;
}

(* One walk of a body. [guards] and [context] say where the walk is:
   [guards] holds every guarded statement and scope around it, the
   innermost first. The queues fill in the order of the walk, which is
   not source order, as a loop's body is walked before its condition:
   [definitions] and [jumps] hold the labelled statements and the
   jumps, [gotos] the goto statements, [breaches] the refusals of
   design 6 rules 10 and 12, and [defers] the defer statements whose
   scopes the walk has read. [operands] are the
   operands of the returns in the scope of a defer statement around the
   walk, which no jump leaves (design 6 rule 12). *)
type walk = {
  facts : facts;
  guards : guarded list;
  operands : Tree.span list;
  context : expression_context;
  definitions : definition Queue.t;
  jumps : jump Queue.t;
  gotos : goto Queue.t;
  breaches : refusal Queue.t;
  defers : read_scope Queue.t;
}

(* The walk inside the guarded statement or scope [guard]. *)
let guarded_by guard walk = { walk with guards = guard :: walk.guards }

let innermost_guard walk =
  match walk.guards with guard :: _ -> Some guard | [] -> None

let in_defer_scope walk =
  List.exists
    (function Defer_scope _ -> true | Arm _ | Tested _ -> false)
    walk.guards

(* Records the statement or item at [span] in the innermost defer scope
   around the walk if a pragma line stands directly before it. A jump
   that leaves an outer scope from inside the statement leaves the
   innermost one too, which the outer holds. *)
let note_annotated walk (span : Tree.span) =
  let innermost_scope =
    List.find_opt
      (function Defer_scope _ -> true | Arm _ | Tested _ -> false)
      walk.guards
  in
  match innermost_scope with
  | Some (Defer_scope { scope_annotated; _ })
    when walk.facts.pragma_before span.first ->
      Queue.add span scope_annotated
  | Some (Defer_scope _ | Arm _ | Tested _) | None -> ()

(* Records the refusal of a jump that design 6 rule 10 forbids, if the
   walk is in the scope of a defer statement: lowering could not tell
   which scopes the jump leaves, so which deferred statements to run. *)
let breach walk span diagnostic =
  if in_defer_scope walk then Queue.add { span; diagnostic } walk.breaches

(* A [goto *] chooses its target when it runs, and an [asm goto] jumps
   from inside the assembly. *)
let unknown_target_jump walk span what =
  breach walk span
    (Rule.message Defer_scope_jump
       (what
      ^ " in the scope of a defer statement, which may leave the scope \
         where lowering cannot run the deferred statement first"))

(* A break or continue that the parser resolved to two statements, one
   on each backend's reading (design 4.4). *)
let disputed_jump walk span keyword = function
  | Tree.Only _ -> ()
  | Either { loop = _; around = _ } ->
      breach walk span (Parser.disputed_jump keyword)

(* Design 6 rule 12: lowering writes a return in the scope of a defer
   statement as a block, which a jump out of its operand would leave. *)
let operand_jump span what =
  { span;
    diagnostic =
      Rule.message Return_operand_jump
        (what
       ^ " that leaves the operand of a `return` in the scope of a defer \
          statement, which lowering writes in a block of its own") }

(* The walk of the operand [value] of a return: one in the scope of a
   defer statement is among the operands that no jump leaves. *)
let in_operand walk (value : Tree.expression option) =
  match value with
  | Some operand when in_defer_scope walk ->
      { walk with operands = operand.span :: walk.operands }
  | Some _ | None -> walk

let record_jump walk kind ({ name; label } : Tree.label_name) =
  Queue.add
    { target = label; site = name.span; kind; jump_context = walk.context }
    walk.jumps

let item_span : Tree.block_item -> Tree.span = function
  | Block_declaration declaration -> declaration.span
  | Block_type_declaration { declaration; scope_end = _ } -> declaration.span
  | Block_statement statement -> statement.span
  | Block_defer { keyword; statement } ->
      { first = keyword.first; last = statement.span.last }

(* An exit and where it goes: out of the function, as a return and
   the error path of a try do, or a jump, named by its [keyword], to the
   token [target]: the label that a goto names, or the first token of
   the statement that a break or continue leaves, which lies in a
   region around the jump if and only if that statement does. *)
type leaving =
  | Returns of exit
  | Jumps of { statement : Tree.span; keyword : string; target : int }

(* Whether [leaving] leaves [region], a defer scope or an operand. *)
let leaves leaving (region : Tree.span) =
  match leaving with
  | Returns _ -> true
  | Jumps { target; statement = _; keyword = _ } ->
      target < region.first || region.last < target

let exit_of = function
  | Returns exit -> exit
  | Jumps { statement; keyword = _; target = _ } -> Jump statement

(* The one funnel that decides what an exit leaves: it records the exit
   in the scopes of the defer statements among [guards] that it leaves,
   and adds to [breaches] a jump that leaves one of [operands] (design 6
   rule 12). A return in an operand leaves the function, and is no such
   jump. *)
let record_exit ~guards ~operands breaches leaving =
  List.iter
    (function
      | Defer_scope { scope; scope_exits; scope_annotated = _ }
        when leaves leaving scope ->
          Queue.add (exit_of leaving) scope_exits
      | Defer_scope _ | Arm _ | Tested _ -> ())
    guards;
  match leaving with
  | Jumps { statement; keyword; target = _ }
    when List.exists (leaves leaving) operands ->
      Queue.add
        (operand_jump statement (Printf.sprintf "a `%s`" keyword))
        breaches
  | Jumps _ | Returns _ -> ()

(* An exit from where the walk is. *)
let record_exit_here walk leaving =
  record_exit ~guards:walk.guards ~operands:walk.operands walk.breaches
    leaving

(* A break or continue leaves for the statement that the parser resolved
   it to. A disputed one is refused in a defer scope (design 6 rule 10),
   which holds every operand that it could leave. *)
let record_leaving walk (statement : Tree.statement) keyword = function
  | Tree.Only (Statement_at target) ->
      record_exit_here walk
        (Jumps { statement = statement.span; keyword; target })
  | Either _ -> ()

(* A return leaves every scope around it (design 6 rule 1). *)
let record_return walk (statement : Tree.statement) value =
  let exit =
    match (value : Tree.expression option) with
    | Some operand ->
        Value_return { statement = statement.span; operand = operand.span }
    | None -> Jump statement.span
  in
  record_exit_here walk (Returns exit)

(* A jump may enter a statement at a label it carries or contains. *)
let enterable flow = flow.has_named_label || flow.has_case_label

let rec block walk (b : Tree.block) =
  let ending (flow : flow) =
    if flow.completes then Completes b.span.last
    else Cannot_complete b.span.last
  in
  sequence walk b.node.items ~ending

(* An item is reachable if it is first, if it follows a reachable item
   that can complete, or if a jump may enter it; a sequence completes if
   it is empty or its last item is reachable and completes. The walk
   records the defer statements of [items], in source order, with the
   [ending] of the sequence's flow, where their scopes end. *)
and sequence walk items ~ending =
  let scope_end =
    match List.rev items with last :: _ -> (item_span last).last | [] -> 0
  in
  let rec step walk (reaching, flow, defers) = function
    | [] -> (reaching, flow, defers)
    | item :: rest ->
        let next = block_item walk item in
        let reachable = reaching || enterable next in
        let after, defers = after_item walk item rest ~scope_end defers in
        step after
          (reachable && next.completes, followed_by flow ~reachable next,
           defers)
          rest
  in
  let reaching, flow, defers = step walk (true, completes, []) items in
  let flow = { flow with completes = reaching } in
  let scope_ending = ending flow in
  (* The last token of each scope: before the [}] of a block, so that a
     pragma line there is in the scope, or the last of an arm's items. *)
  let scope_last =
    match scope_ending with
    | Completes closing | Cannot_complete closing -> closing - 1
    | Arm_end -> scope_end
  in
  let add read =
    let tokens =
      { Tree.first = read.defer_statement.last + 1; last = scope_last }
    in
    Queue.add { read; ending = scope_ending; tokens } walk.defers
  in
  List.iter add (List.rev defers);
  flow

(* The walk of the items [rest] that follow [item], which are the scope
   of [item] if it is a defer, up to the token [scope_end], and
   [defers] with such an [item]. *)
and after_item walk item rest ~scope_end defers =
  match item with
  | Tree.Block_defer { keyword; statement } ->
      let read =
        { defer_keyword = keyword; defer_statement = statement.span;
          defer_exits = Queue.create (); defer_annotated = Queue.create () }
      in
      (in_scope walk read rest ~scope_end, read :: defers)
  | Block_declaration _ | Block_type_declaration _ | Block_statement _ ->
      (walk, defers)

(* The walk of the items [rest] after the defer statement [read]. *)
and in_scope walk read rest ~scope_end =
  match rest with
  | first :: _ ->
      let scope = { Tree.first = (item_span first).first; last = scope_end } in
      guarded_by
        (Defer_scope
           { scope; scope_exits = read.defer_exits;
             scope_annotated = read.defer_annotated })
        walk
  | [] -> walk

and block_item walk = function
  | Tree.Block_declaration declaration ->
      note_annotated walk declaration.span;
      declaration_flow walk declaration
  | Block_type_declaration { declaration; _ } ->
      note_annotated walk declaration.span;
      type_declaration_flow walk declaration
  | Block_statement statement -> statement_flow walk statement
  (* The statement runs at the exits of the scope, not here (design 6
     rule 1). It holds no label of the function (rule 9), and its case
     and default labels belong to its own switches, as typing refuses
     any other (rule 5), so nothing enters it. The walk reads it for the
     jumps into its statement expressions. *)
  | Block_defer { statement; _ } ->
      ignore (statement_flow walk statement);
      completes

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
  note_annotated walk statement.span;
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
      Queue.add
        { goto_statement = statement.span; goto_target = label.label;
          goto_guards = walk.guards; goto_operands = walk.operands }
        walk.gotos;
      stops
  | Computed_goto target ->
      unknown_target_jump walk statement.span "a `goto *`";
      { (expression walk target) with completes = false }
  | Continue { loop } ->
      disputed_jump walk statement.span "continue" loop;
      record_leaving walk statement "continue" loop;
      { stops with continues = targets loop }
  | Break { leaves } ->
      disputed_jump walk statement.span "break" leaves;
      record_leaving walk statement "break" leaves;
      { stops with breaks = targets leaves }
  | Return value ->
      record_return walk statement value;
      let operand_walk = in_operand walk value in
      { (all (expression operand_walk) (Option.to_list value)) with
        completes = false }
  | Asm assembler -> asm_flow walk assembler
  | Match { scrutinee; arms } -> match_flow walk target scrutinee arms

and labelled_flow walk (label : Tree.label) labelled =
  match label.node with
  | Named_label { label = id; _ } ->
      Queue.add
        { label = id; site = label.span; guard = innermost_guard walk;
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
  let arm_end (_ : flow) = Arm_end in
  sequence (guarded_by (Arm arm.span) walk) arm.node.items ~ending:arm_end

(* Design 4.6 rules 5 and 6: the statement of a single-pattern test may
   complete and leave what is around it, as C's does, but a jump enters
   it only from inside it, as an arm, so its labels are not those of the
   statements around it. *)
and tested walk (statement : Tree.statement) =
  let flow =
    statement_flow (guarded_by (Tested statement.span) walk) statement
  in
  { flow with has_named_label = false; has_case_label = false;
    default = false }

(* An [asm goto] may jump to each of its labels or complete. *)
and asm_flow walk (assembler : Tree.assembler) =
  let asm_goto (qualifier : Tree.asm_qualifier Tree.spanned) =
    match qualifier.node with
    | Asm_goto -> unknown_target_jump walk qualifier.span "an `asm goto`"
    | Asm_volatile | Asm_inline -> ()
  in
  List.iter asm_goto assembler.qualifiers;
  match assembler.operands with
  | None -> completes
  | Some operands ->
      List.iter (record_jump walk Goto) operands.labels;
      all
        (fun (operand : Tree.asm_operand) -> expression walk operand.node.value)
        (operands.outputs @ operands.inputs)

(* An expression completes unless it is a call to a function that does
   not return; a statement expression is the block it holds. A [try]
   completes in any form (design 4.4). The body of a block literal is a
   function of its own, which typing does not read. *)
and expression walk (value : Tree.expression) =
  let operands = all (expression walk) in
  match value.node with
  | Statement_expression b -> block (entering walk b) b
  | Parenthesized inner -> expression walk inner
  | Try { operand; scope = _ } ->
      (* The error path returns, so it leaves every scope around it
         (design 6 rule 1). *)
      record_exit_here walk (Returns (Error_path value.span));
      { (expression walk operand) with completes = true }
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

let guarded_span = function
  | Arm span | Tested span | Defer_scope { scope = span; _ } -> span

let guarded_rule : guarded -> Rule.t = function
  | Arm _ | Tested _ -> Arm_entry
  | Defer_scope _ -> Deferred_entry

(* What a diagnostic calls a guarded statement, and the same statement
   named again. *)
let guarded_names = function
  | Arm _ -> ("a match arm", "the arm")
  | Tested _ -> ("the statement of a single-pattern test", "the statement")
  | Defer_scope _ -> ("the scope of a defer statement", "the scope")

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

(* Design 4.3 rule 3, 4.6 rule 6, 6 rule 5. A computed goto may jump to
   any label whose address is taken, so a label inside a guarded
   statement or scope cannot have its address taken. *)
let refuse_guarded_entry (definition : definition) jump =
  match (definition.guard, jump.kind) with
  | Some guard, Address ->
      let inside, again = guarded_names guard in
      refuse jump.site
        (Rule.message (guarded_rule guard)
           (Printf.sprintf
              "the address of a label inside %s, which a computed goto \
               could jump to from outside %s"
              inside again))
  | Some guard, Goto ->
      if not (encloses (guarded_span guard) jump.site) then
        refuse jump.site
          (Rule.message (guarded_rule guard)
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
  { facts; guards = []; operands = []; context = Outside_statement_expressions;
    definitions = Queue.create (); jumps = Queue.create ();
    gotos = Queue.create (); breaches = Queue.create ();
    defers = Queue.create () }

(* Design 4.3 rule 1. *)
let arm_refusal facts (matched : Tree.arm) =
  if (arm (start facts) matched).completes then
    Some
      { span = matched.span;
        diagnostic =
          Rule.message Arm_end "the end of the match arm can be reached" }
  else None

(* The labels and jumps that a walk records do not depend on the facts,
   which decide only whether a statement completes and which statements
   of a defer scope are annotated, so this walk, which reads neither,
   needs none, and a body may be checked before typing has read it. *)
let no_facts =
  { noreturn = (fun _ -> false); non_zero = (fun _ -> false);
    pragma_before = (fun _ -> false) }

(* The first jump of the walk, in source order, that enters what it may
   not. *)
let entry_refusal walk definitions =
  match
    let site (jump : jump) = jump.site in
    let jumps = in_source_order site walk.jumps in
    List.iter (check_jump definitions) jumps
  with
  | () -> None
  | exception Refused refusal -> Some refusal

(* Records each goto as an exit, once the walk has read every label: it
   leaves the scopes and operands around it that do not hold its label
   (design 6 rules 1 and 12). The parser resolves every goto to a label
   that a statement in its scope defines, and the walk reads every
   statement. *)
let record_gotos walk definitions =
  let record goto =
    match Hashtbl.find_opt definitions goto.goto_target with
    | Some (definition : definition) ->
        record_exit ~guards:goto.goto_guards ~operands:goto.goto_operands
          walk.breaches
          (Jumps
             { statement = goto.goto_statement; keyword = "goto";
               target = definition.site.first })
    | None -> invalid_arg "Reachability.record_gotos: a label that none defines"
  in
  Queue.iter record walk.gotos

(* The first refusal in source order, of an entry or of design 6 rules
   10 and 12, as GCC and Clang name the first error. *)
let label_refusal body =
  let walk = start no_facts in
  ignore (block walk body);
  let definitions = by_label walk.definitions in
  record_gotos walk definitions;
  let refusals = Queue.copy walk.breaches in
  Option.iter
    (fun entry -> Queue.add entry refusals)
    (entry_refusal walk definitions);
  let span (refusal : refusal) = refusal.span in
  match in_source_order span refusals with
  | first :: _ -> Some first
  | [] -> None

(* The place of the end of a scope, none at the end of a match arm. *)
let end_places = function
  | Completes closing -> [ Block_end closing ]
  | Cannot_complete closing -> [ Trap closing ]
  | Arm_end -> []

let defer_site { read; ending; tokens } =
  let exits = List.of_seq (Queue.to_seq read.defer_exits) in
  { keyword = read.defer_keyword; deferred = read.defer_statement;
    places = List.map (fun exit -> Left_by exit) exits @ end_places ending;
    scope_tokens = tokens;
    annotated = List.of_seq (Queue.to_seq read.defer_annotated) }

let defers facts body =
  let walk = start facts in
  ignore (block walk body);
  record_gotos walk (by_label walk.definitions);
  let keyword { read; _ } = read.defer_keyword in
  List.map defer_site (in_source_order keyword walk.defers)

let value_returns sites =
  let value_return = function
    | Left_by (Value_return { statement; operand }) -> Some (statement, operand)
    | Block_end _ | Trap _ | Left_by (Jump _ | Error_path _) -> None
  in
  List.concat_map (fun site -> List.filter_map value_return site.places) sites
  |> List.sort_uniq (fun ((a : Tree.span), _) ((b : Tree.span), _) ->
         Int.compare a.first b.first)
