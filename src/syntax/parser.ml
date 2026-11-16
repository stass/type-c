(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Tree
module P = Punctuator

type error = Reader.error = { location : Location.t; message : string }

(* Input-dependent recursion is bounded (design 13.7). The parser recurses
   only inside a bracket or the [?] of a conditional that it has read and
   not yet closed; prefixes, postfixes, chains of operators, the
   derivations of a declarator and the statements that end in a
   substatement are read in loops, so between two such tokens the
   recursion has a constant depth: the ten precedences of
   [binary_expression] and a few frames of declarations and statements.
   A specifier holds another only inside a bracket (a structure body,
   [_Atomic (], [typeof (], the [(] of a type application), and the fixed
   type of an enumeration takes no specifier that holds another outside
   such a bracket (see [allowed]). So [advance] bounds
   the recursion by bounding the brackets open. C11
   5.2.4.1 asks for 63 levels of parentheses in an expression; 256 is the
   bracket depth Clang accepts by default, enough for real code, and
   keeps the stack small. *)
let max_nesting = 256

(* The deepest tree that the parser gives, in nodes on a path, so that
   the stages after it, which recurse over the tree, need no bound of
   their own (design 13.7). A chain that the parser reads in a loop, such
   as [a + b + c] or an else-if, is a level for each link. The deepest
   tree of the corpus programs is 139 nodes, a Csmith program; of the
   programs people wrote, 92, SQLite's shell.c, whose longest else-if
   chain has 66 links. 10000 is seventy times the deepest, and a tree
   that deep needs under 140K words (1.1 MiB) of stack in the later
   stages, on macOS and Linux, against the runtime's default limit of
   128M words; test_deep_trees holds them to 256K. *)
let max_depth = 10_000

(* How much of a token's spelling an error message quotes, so that a long
   string literal does not make a long message. *)
let max_quoted_spelling = 40

(* A grammar token as the grammar sees it. Identifiers that spell a C11
   keyword are keywords; constants are classified where one is read. *)
type lexeme =
  | Keyword_token of Keyword.t
  | Identifier_token of string
  | Punctuator_token of P.t
  | Number_token
  | Character_token of Token.encoding
  | String_token of Token.encoding
  | End_of_input

(* A token the grammar reads and its index in [Reader.t.tokens]. *)
type grammar_token = { lexeme : lexeme; index : int }

(* What the cursor holds open: a bracket and the bracket that closes it,
   or the [?] of a conditional, which its [:] closes. *)
type opening = Open_bracket of P.t | Open_conditional

(* [stage], [kind] and [ordinary] are public; parser.mli says what they
   mean. *)
type stage = Defining | Defined | Awaiting_variant

type kind =
  | Not_a_type
  | Typedef_name
  | Declared_type of { stage : stage; parameters : int }
  | Type_parameter
  | Derived_enumerator

type ordinary = { declaration : reference; kind : kind }

(* What the definition of a generic type allows at the cursor (design 3.5
   rule 4): a structure or union body only where the definition of an
   instance holds it, and no type parameter inside an [_Alignas]. The
   scope of its type parameters, at [parameter_depth], stands where file
   scope stands in the C that the text lowers to (rule 8). *)
type generic_place = {
  bodies_allowed : bool;
  in_alignment : bool;
  parameter_depth : int;
}

(* A tag in scope: its declaration, and whether a type declaration
   claims it for the C that it lowers to (design 10.1 rule 6, 10.2). *)
type tag_entry = { tag : tag_id; claimed : bool }

(* The scopes open at a point, in the two name spaces that scopes hold
   (6.2.3): ordinary identifiers, and tags. The universe scope (design
   2.3), which encloses file scope, holds names that no declaration
   makes, so it is not among them: a name that no scope declares is
   looked up in {!Universe}. *)
type scope = (ordinary, tag_entry) Scope.t

(* Values by the index of a token in [Reader.t.tokens]. *)
module Places = Map.Make (Int)

(* The scopes that unread text stands in (design 13.5), by the index of
   a token: at the [(] of the arguments of each attribute, and at each
   pragma token. *)
type views = { attributes : scope Places.t; pragmas : scope Places.t }

(* The innermost statement around the cursor that a break or continue
   may leave. A break leaves a loop, switch or match, and a continue the
   innermost loop, which may be around a switch or match (C11 6.8.6.2p1,
   6.8.6.3p1, design 4.3 rule 2). *)
type jump_scope =
  | Function_body  (* also a block literal, a function of its own *)
  | Loop of jump_target
  | Switch_or_match of { target : jump_target; around : jump_scope }
  | Disputed of { loop : jump_target; around : jump_scope }
      (* The condition of a [loop] or its step if a for, outside every
         loop, switch and match within it, where Clang leaves the loop
         and GCC reads the scope [around] the loop (design 4.4). *)

(* The innermost match arm around the cursor: the match it belongs to,
   and the breaks in Type-C text read in it so far that leave that
   match, by the first token of each, latest first. Design 4.3 rule 5
   judges them where the arm ends. *)
type arm_breaks = { matched : jump_target; mutable leaving : int list }

(* A label of the body being read, and whether a statement has defined
   it so far. *)
type label_entry = { identity : label_id; mutable defined : bool }

module Names = Map.Make (String)

(* The labels of the function body or block literal being read, which is
   their scope (C11 6.2.1p3): the function's by name, the GNU local
   labels visible at the cursor by name, and the label of each goto and
   [asm goto] read so far, by the token of its name, latest first, which
   the end of the body checks for a definition (6.8.6.1p1). *)
type body_labels = {
  mutable function_labels : label_entry Names.t;
  mutable local_labels : label_entry Names.t;
  mutable gotos : (int * label_entry) list;
}

(* A constructor's name that the lookahead read and checked, at the token
   [at]. *)
type constructor_ahead = { at : int; checked : Spelling.constructor }

(* The cursor. [scope] is persistent, so leaving a scope restores the
   value saved on entering it, and so is [jumps]; leaving an arm restores
   [arm], leaving a body [labels] and leaving a block the local labels of
   [labels]. An error abandons the state, so it needs no restoring on
   one. *)
type state = {
  reader : Reader.t;
  grammar : grammar_token array;
  mutable position : int;  (** in [grammar] *)
  mutable open_brackets : opening list;
      (** read and not yet closed, innermost first *)
  mutable scope : scope;
  mutable jumps : jump_scope;
  mutable arm : arm_breaks option;
  mutable labels : body_labels option;  (** [None] outside every body *)
  mutable generic : generic_place option;
      (** [None] outside the definition of a generic type *)
  mutable in_type_argument : bool;  (** design 3.5 rule 2 *)
  mutable views : views;  (** taken so far *)
  counter : Spanned.counter;  (** of the nodes made so far *)
}

(* The function derivation applied to the name that a declarator
   declares: its parameters, and the scope at their [)], which the body of
   a definition continues (6.2.1p4). *)
type named_function = { parameters : parameters; parameter_scope : scope }

(* Raised at the first token that the grammar does not accept. *)
exception Failed of error

(* Reading the grammar tokens. *)

(* The lexeme of a token, or None for a pragma: C gives a pragma no place
   in the grammar and one may stand between any two tokens, so the
   grammar passes over it. A [#pragma typec] line is passed over the same
   way until Stage 5 gives it a meaning. *)
let lexeme_of keywords (token : Token.t) =
  match token.kind with
  | Token.Identifier name -> (
      match Keyword.of_spelling keywords name with
      | Some keyword -> Some (Keyword_token keyword)
      | None -> Some (Identifier_token name))
  | Token.Number -> Some Number_token
  | Token.Character encoding -> Some (Character_token encoding)
  | Token.String encoding -> Some (String_token encoding)
  | Token.Punctuator punctuator -> Some (Punctuator_token punctuator)
  | Token.Pragma _ | Token.Typec_pragma -> None

let grammar_tokens keywords (reader : Reader.t) =
  Array.to_seqi reader.tokens
  |> Seq.filter_map (fun (index, token) ->
         Option.map
           (fun lexeme -> { lexeme; index })
           (lexeme_of keywords token))
  |> Array.of_seq

let peek_at state offset =
  let position = state.position + offset in
  if position < Array.length state.grammar then
    state.grammar.(position).lexeme
  else End_of_input

let peek state = peek_at state 0

(* Spans. A node starts at a grammar position taken before it is read and
   ends at the last token read, so every node holds at least one token.
   [spanned] is the only way to give a node that holds another its span,
   as only a name is built outside it: [finish] for a node read from
   [start], or [spanned] itself for one that wraps another in the same
   span. *)

(* The index in [Reader.t.tokens] of the last grammar token read. *)
let last_read state = state.grammar.(state.position - 1).index

(* The index in [Reader.t.tokens] of the grammar token at [start]. *)
let first_token state start = state.grammar.(start).index

let span_from state start =
  { first = first_token state start; last = last_read state }


(* The target of the loop, switch or match statement that begins at
   [start], as {!Tree.jump_target_of} reads it from the statement that
   [finish] makes. *)
let target_at state start = Statement_at (first_token state start)

(* The condition or step of the loop that begins at [start], in the
   scope [around]. *)
let disputed_scope state start around =
  Disputed { loop = target_at state start; around }

(* Runs [parse] with [state.jumps] set to [jumps], then restores it. An
   error abandons the state, so it needs no restoring on one. *)
let with_jumps state jumps parse =
  let saved = state.jumps in
  state.jumps <- jumps;
  let result = parse () in
  state.jumps <- saved;
  result

(* Errors. *)

let token_at state position =
  state.reader.tokens.(state.grammar.(position).index)

(* The spelling of the next token, which is not the end of input. *)
let next_spelling state =
  Reader.spelling state.reader (token_at state state.position)

(* Where an error is reported: at the next token, or at the last one at
   the end of the input. A parse of no grammar tokens never fails, so
   there is a last one. *)
let error_location state =
  let last = Array.length state.grammar - 1 in
  (token_at state (min state.position last)).location

let fail state diagnostic =
  raise
    (Failed
       { location = error_location state; message = Rule.text diagnostic })

(* An error at the token [index] of [Reader.t.tokens], which the cursor
   has passed. *)
let fail_at_token state index diagnostic =
  let location = state.reader.tokens.(index).location in
  raise (Failed { location; message = Rule.text diagnostic })

(* The depth bound. *)

let too_deep =
  Printf.sprintf
    "a construct nested more than %d levels deep, where each link of a \
     chain such as `a + b + c` or `else if` is a level (a translation \
     limit, C11 5.2.4.1)"
    max_depth

(* Counts and makes a node with [span], or refuses it where it is too
   deep. *)
let spanned state (span : span) node =
  match Spanned.make state.counter span node with
  | Some made -> made
  | None -> fail_at_token state span.first (Rule.c_text too_deep)

let finish state start node = spanned state (span_from state start) node

(* The refusal of the break or continue at [start]. *)
let fail_jump state start diagnostic =
  fail_at_token state (first_token state start) diagnostic

let fail_disputed_jump state start keyword =
  fail_jump state start
    (Rule.message Disputed_jump
       (Printf.sprintf
          "a %s in the condition of a loop or the step of a for, which \
           Clang takes to leave the loop and GCC the statement around it"
          keyword))

(* Labels. *)

let label_outside_body =
  Rule.c_text "a label outside a function body (C11 6.2.1p3)"

(* The labels of the body around the cursor. Outside every body, in a GNU
   statement expression or the labels of a file-scope [asm], no label
   has scope. *)
let body_labels state (name : identifier) =
  match state.labels with
  | Some labels -> labels
  | None -> fail_at_token state name.span.first label_outside_body

(* The function's label [name], which the first mention that resolves
   to it declares. *)
let function_label labels (name : identifier) =
  match Names.find_opt name.node labels.function_labels with
  | Some entry -> entry
  | None ->
      let entry = { identity = Label_at name.span.first; defined = false } in
      labels.function_labels <-
        Names.add name.node entry labels.function_labels;
      entry

(* The label that [name] names at the cursor: the innermost GNU local
   label of its name, or else the function's. *)
let label_named labels (name : identifier) =
  match Names.find_opt name.node labels.local_labels with
  | Some entry -> entry
  | None -> function_label labels name

(* The label of a goto or an [asm goto], which the end of the body
   checks. *)
let jump_label state name : label_name =
  let labels = body_labels state name in
  let entry = label_named labels name in
  labels.gotos <- (name.span.first, entry) :: labels.gotos;
  { name; label = entry.identity }

(* The label of the [&&] at [start]. GNU C takes the address of a label
   in a function body only. *)
let address_label state start name : label_name =
  match state.labels with
  | Some labels -> { name; label = (label_named labels name).identity }
  | None ->
      fail_at_token state (first_token state start)
        (Rule.c_text
           "the address of a label outside a function body (GCC manual, \
            \"Labels as Values\")")

(* The label that a labelled statement defines, once in its scope
   (6.8.1p3). *)
let define_label state name =
  let entry = label_named (body_labels state name) name in
  if entry.defined then
    fail_at_token state name.span.first
      (Rule.c_text "a second definition of a label in its scope (C11 6.8.1p3)");
  entry.defined <- true;
  entry.identity

(* GNU [__label__]: [name] declares a local label of the block, which
   declares each of its [declared] names once (GCC manual, "Local
   Labels"). *)
let declare_local_label state declared name : label_name =
  let labels = body_labels state name in
  if Hashtbl.mem declared name.node then
    fail_at_token state name.span.first
      (Rule.c_text
         "a local label declared twice in its block (GCC manual, \"Local \
          Labels\")");
  Hashtbl.add declared name.node ();
  let entry = { identity = Label_at name.span.first; defined = false } in
  labels.local_labels <- Names.add name.node entry labels.local_labels;
  { name; label = entry.identity }

(* Runs [parse], a block, which is the scope of the GNU local labels that
   it declares. *)
let in_local_label_scope state parse =
  match state.labels with
  | None -> parse ()
  | Some labels ->
      let saved = labels.local_labels in
      let result = parse () in
      labels.local_labels <- saved;
      result

(* 6.8.6.1p1: the first goto, in source order, to a label that its scope
   does not define. *)
let refuse_undefined_jump state labels =
  let undefined (_, entry) = not entry.defined in
  match List.find_opt undefined (List.rev labels.gotos) with
  | Some (token, _) ->
      fail_at_token state token
        (Rule.c_text
           "a goto to a label that is not defined in its scope (C11 \
            6.8.6.1p1)")
  | None -> ()

(* Runs [parse], a function body or a block literal: a function of its
   own, whose labels are its own and which no break or continue in it
   leaves. *)
let as_function state parse =
  let saved = state.labels in
  let labels =
    { function_labels = Names.empty; local_labels = Names.empty; gotos = [] }
  in
  state.labels <- Some labels;
  let result = with_jumps state Function_body parse in
  refuse_undefined_jump state labels;
  state.labels <- saved;
  result

let quoted spelling =
  if String.length spelling <= max_quoted_spelling then "`" ^ spelling ^ "`"
  else "`" ^ String.sub spelling 0 max_quoted_spelling ^ "...`"

(* Whether the token [index] of [Reader.t.tokens] is Type-C text. *)
let is_type_c_text_at state index =
  File.is_type_c_text state.reader.tokens.(index).owner

(* Whether the token [index] of [Reader.t.tokens] is C text of a system
   header, the one text that is written for its own compiler. *)
let is_system_c_text_at state index =
  let owner = state.reader.tokens.(index).owner in
  owner.system_header && not (File.is_type_c_text owner)

(* The first token in [span], an index of [Reader.t.tokens], for which
   [holds] is true. Every token counts, a [#pragma] line's among them, as
   unread text is emitted whole (design 13.3). *)
let find_in_span (span : span) holds =
  Seq.init (span.last - span.first + 1) (fun i -> span.first + i)
  |> Seq.find holds

(* Clang's blocks are C text only (design 13.3): typing does not read the
   body of a block literal, so a Type-C construct there would reach the
   backend unlowered. The literal that begins at [start] and ends at the
   last token read is refused at its first token of Type-C text, whether
   Type-C text writes it or an include puts Type-C text inside it. *)
let refuse_type_c_text_in_block state start =
  match find_in_span (span_from state start) (is_type_c_text_at state) with
  | Some index ->
      fail_at_token state index
        (Rule.message Block_literal_text
           "a block literal is C text only, so Type-C text cannot write one \
            or be included in one")
  | None -> ()

(* The two readings of a disputed scope (design 4.4): Clang takes a jump
   there to leave the loop, and GCC reads the scope around the loop. *)
type reading = Clang_reading | Gcc_reading

(* The statement that a break in [jumps] leaves on [reading], if any. *)
let rec break_leaves reading = function
  | Loop target | Switch_or_match { target; _ } -> Some target
  | Disputed { loop; around } -> (
      match reading with
      | Clang_reading -> Some loop
      | Gcc_reading -> break_leaves reading around)
  | Function_body -> None

(* The loop that a continue in [jumps] continues on [reading], if any:
   the innermost loop, through any switch or match inside it. *)
let rec continue_leaves reading = function
  | Loop target -> Some target
  | Switch_or_match { around; _ } -> continue_leaves reading around
  | Disputed { loop; around } -> (
      match reading with
      | Clang_reading -> Some loop
      | Gcc_reading -> continue_leaves reading around)
  | Function_body -> None

(* What the [keyword] at [start] leaves, by [leaves]. The two readings
   differ only where the jump is in a disputed scope, which Type-C text
   refuses and C text leaves to the backend; where Clang finds nothing,
   GCC does not either, as no disputed scope is in the way. *)
let jump_targets state start keyword leaves ~no_target =
  match (leaves Clang_reading state.jumps, leaves Gcc_reading state.jumps) with
  | None, _ -> fail_jump state start no_target
  | Some clang, Some gcc when clang = gcc -> Only clang
  | Some loop, gcc -> (
      if is_type_c_text_at state (first_token state start) then
        fail_disputed_jump state start keyword;
      match gcc with
      | None -> Only loop (* GCC refuses it *)
      | Some around -> Either { loop; around })

(* Notes the break at [start], which leaves [leaves], for design 4.3
   rule 5 if it is Type-C text that leaves the match of the arm around
   it. A Type-C break is never disputed, so it leaves [Only] one. *)
let note_arm_break state start leaves =
  let token = first_token state start in
  match state.arm with
  | Some arm when leaves = Only arm.matched && is_type_c_text_at state token
    ->
      arm.leaving <- token :: arm.leaving
  | Some _ | None -> ()

(* What the break at [start] leaves. *)
let break_target state start =
  let leaves =
    jump_targets state start "break" break_leaves
      ~no_target:
        (Rule.message Break_outside "break outside a loop, switch or match")
  in
  note_arm_break state start leaves;
  leaves

(* Tokens of [Reader.t.tokens], by index. *)
module Token_set = Set.Make (Int)

(* The breaks in tail position of the arm whose block items are [items]
   (design 4.3 rule 5), by the first token of each. Tail position passes
   inward only through the cases below, so a break in a statement
   expression or in the control of a statement is never in it. The walk
   keeps a list of statements to visit, not the stack, as the parser
   reads a chain of [if] or labels without recursing; the result is a
   set, as such a chain may hold as many tail breaks as it is long. *)
let tail_breaks (items : block_item list) =
  let last_statement items =
    match List.rev items with
    | Block_statement last :: _ -> [ last ]
    | (Block_declaration _ | Block_type_declaration _) :: _ | [] -> []
  in
  let rec visit found = function
    | [] -> found
    | (statement : statement) :: rest -> (
        match statement.node with
        | Break _ -> visit (Token_set.add statement.span.first found) rest
        | Labeled { statement = labelled; _ } -> visit found (labelled :: rest)
        | Compound b -> visit found (last_statement b.node.items @ rest)
        | If { then_branch; else_branch; condition = _ } ->
            visit found ((then_branch :: Option.to_list else_branch) @ rest)
        | Expression_statement _ | Null_statement | Attribute_statement _
        | Switch _ | While _ | Do _ | For _ | Goto _ | Computed_goto _
        | Continue _ | Return _ | Asm _ | Match _ ->
            visit found rest)
  in
  visit Token_set.empty (last_statement items)

(* Design 4.3 rule 5: refuses the first break of [breaks] that is not in
   tail position of the arm whose block items are [items]. *)
let refuse_early_breaks state breaks items =
  let tail = tail_breaks items in
  let early token = not (Token_set.mem token tail) in
  match List.find_opt early (List.rev breaks.leaving) with
  | None -> ()
  | Some token ->
      fail_at_token state token
        (Rule.message Early_break
           "a break that leaves the match before the end of its arm; put \
            the `break` last in the arm, or leave the loop with `goto` or \
            `return`, or use a single-pattern test (design 4.6)")

(* What the continue at [start] leaves. *)
let continue_target state start =
  jump_targets state start "continue" continue_leaves
    ~no_target:(Rule.c_text "continue outside a loop (C11 6.8.6.2p1)")

(* The names that typec generates begin with this (design 13.5). *)
let generated_prefix = "__tc_"

(* A Type-C translation unit holds no identifier that lowering may
   generate (design 2.3), in C text as in Type-C text, so neither a
   declaration nor a use can meet a generated name. Every identifier is
   one of the grammar tokens, read or not. *)
let refuse_generated_name state ~at spelling =
  if String.starts_with ~prefix:generated_prefix spelling then
    fail_at_token state at
      (Rule.message Generated_name
         (Printf.sprintf
            "%s begins with `%s`, which is reserved for the names that \
             typec generates"
            (quoted spelling) generated_prefix))

let refuse_generated_names state =
  Array.iter
    (fun { lexeme; index } ->
      match lexeme with
      | Identifier_token spelling ->
          refuse_generated_name state ~at:index spelling
      | Keyword_token _ | Punctuator_token _ | Number_token
      | Character_token _ | String_token _ | End_of_input ->
          ())
    state.grammar

(* A rule looks at the identifiers of every pragma in Type-C text (design
   13.5), so there a pragma line needs some: one that is no sequence of
   tokens is refused. In C text it passes on whole. *)
let refuse_pragma_without_tokens state index (token : Token.t) =
  match token.kind with
  | Token.Pragma (Not_tokens reason) when is_type_c_text_at state index ->
      fail_at_token state index
        (Rule.message Pragma_tokens
           ("a `#pragma` line whose text is no sequence of preprocessing \
             tokens: " ^ reason))
  | Token.Pragma (Not_tokens _ | Identifiers _) | Typec_pragma | Identifier _
  | Number | Character _ | String _ | Punctuator _ ->
      ()

let refuse_pragmas_without_tokens state =
  Array.iteri (refuse_pragma_without_tokens state) state.reader.tokens

(* A construct that a later work package implements, at the cursor. *)
let fail_not_implemented state ~section ~package text =
  fail state
    (Rule.message Not_implemented
       (Printf.sprintf "%s (design %s; work package %s)" text section package))

let found state =
  match peek state with
  | End_of_input -> "end of input"
  | Keyword_token _ | Identifier_token _ | Punctuator_token _ | Number_token
  | Character_token _ | String_token _ ->
      quoted (next_spelling state)

let fail_expected state expected =
  fail state
    (Rule.c_text
       (Printf.sprintf "expected %s, found %s" expected (found state)))

let open_one state opening =
  if List.length state.open_brackets = max_nesting then
    fail state
      (Rule.c_text
         (Printf.sprintf "more than %d nested brackets or conditionals"
            max_nesting));
  state.open_brackets <- opening :: state.open_brackets

let closer_of = function
  | P.Left_paren -> P.Right_paren
  | P.Left_bracket -> P.Right_bracket
  | P.Left_brace -> P.Right_brace
  | _ -> invalid_arg "Parser.closer_of"

let quoted_closer = function
  | P.Right_paren -> "`)`"
  | P.Right_bracket -> "`]`"
  | P.Right_brace -> "`}`"
  | _ -> invalid_arg "Parser.quoted_closer"

(* A closing bracket that is not the one the innermost opening needs is
   an error here, so that no skip of unread tokens can end at the wrong
   bracket or let a closer end a [?]. *)
let close state closer =
  match state.open_brackets with
  | Open_bracket expected :: outer when expected = closer ->
      state.open_brackets <- outer
  | Open_bracket expected :: _ -> fail_expected state (quoted_closer expected)
  | Open_conditional :: _ -> fail_expected state "`:` of a conditional"
  | [] -> fail_expected state "a token that opens no bracket"

(* The index in [Reader.t.tokens] after the last grammar token read. *)
let after_last_read state =
  if state.position = 0 then 0 else last_read state + 1

(* Keeps the scope at each pragma token after the last grammar token read
   and before the token at [before], none of which the grammar reads.
   The parser takes the scope that holds at a place before it moves past
   the next grammar token, so a pragma token gets the scope in front of
   the grammar token after it (design 13.5). *)
let take_pragma_views state ~before =
  for index = after_last_read state to before - 1 do
    state.views <-
      {
        state.views with
        pragmas = Places.add index state.scope state.views.pragmas;
      }
  done

(* The one way the cursor moves, called only after [peek] has matched a
   token. A [:] closes a [?] and nothing else. *)
let advance state =
  take_pragma_views state ~before:(first_token state state.position);
  (match (peek state, state.open_brackets) with
  | Punctuator_token
      ((P.Left_paren | P.Left_bracket | P.Left_brace) as opener), _ ->
      open_one state (Open_bracket (closer_of opener))
  | Punctuator_token P.Question, _ -> open_one state Open_conditional
  | Punctuator_token
      ((P.Right_paren | P.Right_bracket | P.Right_brace) as closer), _ ->
      close state closer
  | Punctuator_token P.Colon, Open_conditional :: outer ->
      state.open_brackets <- outer
  | _ -> ());
  state.position <- state.position + 1

let accept state punctuator =
  if peek state = Punctuator_token punctuator then begin
    advance state;
    true
  end
  else false

let accept_keyword state keyword =
  if peek state = Keyword_token keyword then begin
    advance state;
    true
  end
  else false

let expect state punctuator expected =
  if not (accept state punctuator) then fail_expected state expected

(* Scopes (C11 6.2.1). Only these functions look a name up or declare
   one, so every declaration gets its {!declared} and every use its
   resolution here, from the scope at its own point. The parser leaves a
   scope by restoring the value it saved on entering it. *)

(* File scope before the first token, which holds the typedef names that
   GCC and Clang declare there for a backend with [keywords]. *)
let initial_scope keywords =
  List.fold_left
    (fun scope (name, builtin) ->
      if Builtin_typedef.declared keywords builtin then
        let entry = { declaration = Builtin name; kind = Typedef_name } in
        Scope.declare scope name entry
      else scope)
    Scope.file Builtin_typedef.table

let names_type = function
  | Not_a_type | Derived_enumerator -> false
  | Typedef_name | Declared_type _ | Type_parameter -> true

(* The number of type parameters of the type that a name of [kind]
   names, which is not zero for a generic type (design 3.5 rule 1). *)
let type_parameters_of = function
  | Declared_type { parameters; _ } -> parameters
  | Not_a_type | Typedef_name | Type_parameter | Derived_enumerator -> 0

let is_generic kind = type_parameters_of kind > 0

(* The visible declaration of [name] where it is a typedef name. *)
let typedef_declaration state name =
  match Scope.find state.scope name with
  | Some ordinary when names_type ordinary.kind -> Some ordinary
  | Some _ | None -> None

let is_typedef_name state name = typedef_declaration state name <> None

(* An identifier is the only token that a declaration is made at, and
   the cursor reads each token once, so the token is a unique id. *)
let token_of (name : identifier) = name.span.first

let is_type_declared = function
  | Declared_type _ -> true
  | Not_a_type | Typedef_name | Type_parameter | Derived_enumerator -> false

let fail_claimed state (name : identifier) what text =
  fail_at_token state (token_of name)
    (Rule.message Claimed_name
       (Printf.sprintf "the %s %s %s, as a type declaration claims it" what
          (quoted name.node) text))

(* A name that a type declaration claims for C is claimed in its whole
   scope, nested blocks included (design 10.1 rule 6): a constructor
   lowers to the structure tag and the enumerators, which must denote
   the variant wherever it is in scope. As no declaration hides a
   claimed name, the visible declaration of the name is the claim. *)
let claims_enumerator state name =
  match Scope.find state.scope name with
  | Some { kind = Derived_enumerator; _ } -> true
  | Some _ | None -> false

let claims_tag state name =
  match Scope.find_tag state.scope name with
  | Some { claimed; _ } -> claimed
  | None -> false

(* A type declaration is the only declaration of its name in its scope
   (design 3.1 rule 5): unlike [typedef], it is not repeated. *)
let refuse_second_definition state (name : identifier) kind earlier =
  match earlier with
  | Some (earlier : ordinary)
    when is_type_declared kind || is_type_declared earlier.kind ->
      fail_at_token state (token_of name)
        (Rule.message One_definition
           (quoted name.node
          ^ " is declared twice in one scope, and one of them is a type \
             declaration"))
  | Some _ | None -> ()

(* Declares the ordinary identifier [name] in the innermost scope, where
   its scope begins. *)
let declare state ~kind (name : identifier) =
  let id = Ordinary_at (token_of name) in
  if claims_enumerator state name.node then
    fail_claimed state name "enumerator" "is declared again";
  let earlier = Scope.find_in_innermost state.scope name.node in
  refuse_second_definition state name kind earlier;
  state.scope <-
    Scope.declare state.scope name.node { declaration = In_tree id; kind };
  { id; earlier = Option.map (fun ordinary -> ordinary.declaration) earlier }

(* The kind of the name of a type declaration with [parameters] type
   parameters at [stage]. *)
let declared_type ~parameters stage = Declared_type { stage; parameters }

(* The name of a type declaration as of the end of its definition, which
   may use it from there on. *)
let end_definition state (name : identifier) (declared : declared)
    ~parameters =
  state.scope <-
    Scope.declare state.scope name.node
      {
        declaration = In_tree declared.id;
        kind = declared_type ~parameters Defined;
      }

(* A name that no scope declares may be one of the universe scope,
   which no work package has given a meaning yet. *)
let refuse_universe_name state name =
  match Universe.find name with
  | Some { section; package; _ } ->
      fail_not_implemented state ~section ~package
        (quoted name ^ " is a universe name that typec does not implement yet")
  | None -> ()

(* At [defer] or [_Defer], which the cursor has not passed. *)
let fail_defer state =
  fail_not_implemented state ~section:"6" ~package:"2.5"
    (quoted (next_spelling state) ^ " is not implemented yet")

(* The identifiers that are words of Type-C text where no declaration
   hides them (design 2.3). *)
type type_c_word = Try | Defer

let type_c_word = function
  | "try" -> Some Try
  | "defer" -> Some Defer
  | _ -> None

(* In Type-C text, [try] and [defer] where no declaration of the same
   identifier hides them, as one hides a universe name (design 2.3), are
   the operator and the statement of Type-C. *)
let refuse_type_c_word state name =
  if is_type_c_text_at state state.grammar.(state.position).index then
    match type_c_word name with
    | Some Try ->
        fail_not_implemented state ~section:"5.1" ~package:"2.4"
          "`try` is not implemented yet"
    | Some Defer -> fail_defer state
    | None -> ()

(* A variant declares its enumerators for C clients (design 10.1 rule
   6), so Type-C text cannot name them. *)
let refuse_derived_enumerator state name =
  let token = state.grammar.(state.position).index in
  if is_type_c_text_at state token then
    fail_at_token state token
      (Rule.message Claimed_name
         (Printf.sprintf
            "the enumerator %s is not available to Type-C text, as a type \
             declaration claims it"
            (quoted name)))

(* At the identifier [name], which the cursor has not passed. *)
let resolve state name =
  match Scope.find state.scope name with
  | Some { declaration; kind = Derived_enumerator } ->
      refuse_derived_enumerator state name;
      Resolved declaration
  | Some { declaration; _ } -> Resolved declaration
  | None ->
      refuse_type_c_word state name;
      refuse_universe_name state name;
      Undeclared

(* Whether the innermost scope is file scope in the C that the text
   lowers to, where the scope of a generic's type parameters is not. *)
let at_file_level state =
  match state.generic with
  | Some { parameter_depth; _ } -> Scope.depth state.scope = parameter_depth
  | None -> Scope.is_file state.scope

(* The definition of a generic type declares no tag in the scope around
   its structure, which is file scope: lowering writes the definition in
   each instance, so text after it would name a tag that the lowered C
   declares later (design 3.5 rule 8). *)
let refuse_generic_tag state (name : identifier) =
  if Option.is_some state.generic && at_file_level state then
    fail_at_token state (token_of name)
      (Rule.message Generic_first_mention
         (Printf.sprintf
            "the definition of a generic type is the first to mention the \
             tag %s at file scope; declare the tag before the definition"
            (quoted name.node)))

(* A tag that a type argument declares has one name only at file scope
   (design 3.5 rule 2). *)
let refuse_argument_tag state (name : identifier) =
  if state.in_type_argument && not (at_file_level state) then
    fail_at_token state (token_of name)
      (Rule.message Argument_tag
         (Printf.sprintf
            "a type argument declares the tag %s in a parameter list or a \
             block (C11 6.7.2.3p8); declare the tag at file scope before it"
            (quoted name.node)))

(* A C declaration of a tag that a type declaration claims is an error
   (design 10.1 rule 6). *)
let declare_tag state (name : identifier) =
  let id = Tag_at (token_of name) in
  refuse_generic_tag state name;
  refuse_argument_tag state name;
  if claims_tag state name.node then
    fail_claimed state name "tag" "is declared again";
  let earlier = Scope.find_tag_in_innermost state.scope name.node in
  state.scope <-
    Scope.declare_tag state.scope name.node { tag = id; claimed = false };
  Declares { id; earlier = Option.map (fun entry -> entry.tag) earlier }

(* The name of a type declaration, which its spelling lets derive names
   for C (design 3.1 rules 6 and 7). [name] is the node made last, which
   the checked name replaces: it counts as a part, a level too many. *)
let checked_type_name state (name : identifier) =
  let at_file_scope = Scope.is_file state.scope in
  match Spelling.type_name ~at_file_scope name.node with
  | Ok checked -> spanned state name.span checked
  | Error reason ->
      fail_at_token state (token_of name)
        (Rule.message Type_name_spelling
           (Printf.sprintf "%s cannot name a type declaration%s"
              (quoted name.node) reason))

(* The end of a refused claim's message: what holds the name already. *)
let already_taken_by ~declared_here =
  if declared_here then "this scope declares already"
  else "an enclosing scope claims already"

(* The tag [tag] that the type declaration of [name] lowers to, which it
   claims in the current scope (design 10.1 rule 6, 10.2): no other
   declaration of the tag may be in that scope, and it hides no claim. *)
let claim_tag state (name : identifier) ~tag id =
  let declared_here = Scope.find_tag_in_innermost state.scope tag <> None in
  if declared_here || claims_tag state tag then
    fail_at_token state (token_of name)
      (Rule.message Claimed_name
         (Printf.sprintf
            "the type declaration of %s claims the tag %s, which %s"
            (quoted name.node) (quoted tag)
            (already_taken_by ~declared_here)));
  state.scope <-
    Scope.declare_tag state.scope tag { tag = id; claimed = true }

(* The tag of the structure that a type declaration of [name] lowers to
   is its name. *)
let claim_own_tag state (name : identifier) =
  claim_tag state name ~tag:name.node
    (claimed_tag (Ordinary_at (token_of name)))

(* The enumerator that the variant [variant] declares for its
   constructor [constructor] at the token [at], which it claims as it
   claims a tag. *)
let claim_enumerator state ~(variant : Spelling.type_name spanned) ~at
    constructor =
  let enumerator =
    enumerator_name ~variant:(Spelling.declared variant.node) constructor
  in
  let declared_here = Scope.find_in_innermost state.scope enumerator <> None in
  if declared_here || claims_enumerator state enumerator then
    fail_at_token state at
      (Rule.message Claimed_name
         (Printf.sprintf "the variant %s claims the enumerator %s, which %s"
            (quoted (variant.node :> string)) (quoted enumerator)
            (already_taken_by ~declared_here)));
  let id = derived_enumerator at in
  state.scope <-
    Scope.declare state.scope enumerator
      { declaration = In_tree id; kind = Derived_enumerator }

(* [count] of [noun], as text. *)
let counted count noun =
  if count = 1 then "1 " ^ noun else Printf.sprintf "%d %ss" count noun

(* The definition that completes an incomplete variant has as many type
   parameters (design 3.1 rule 4). *)
let refuse_completion state (name : identifier) ~parameters ~awaited =
  if parameters <> awaited then
    fail_at_token state (token_of name)
      (Rule.message Completion_parameters
         (Printf.sprintf
            "the variant %s has %s, and the incomplete variant that it \
             completes has %s"
            (quoted name.node)
            (counted parameters "type parameter")
            (counted awaited "type parameter")))

(* A variant definition with [parameters] type parameters completes the
   incomplete variant of its name in the current scope, which has as
   many and claims the tag of the name already (design 3.1 rule 4);
   elsewhere it declares the name and claims the tag. Either claims the
   enumeration tag of its constructors (10.1 rule 6). A generic variant
   claims nothing: its instances claim their names (10.3). *)
let declare_variant state (checked : Spelling.type_name spanned)
    ~type_keyword ~parameters =
  let name = (checked :> identifier) in
  let generic = parameters > 0 in
  let kind = declared_type ~parameters Defined in
  let declared =
    match Scope.find_in_innermost state.scope name.node with
    | Some
        {
          kind =
            Declared_type { stage = Awaiting_variant; parameters = awaited };
          declaration;
        } ->
        refuse_completion state name ~parameters ~awaited;
        let id = Ordinary_at (token_of name) in
        let completed = { declaration = In_tree id; kind } in
        state.scope <- Scope.declare state.scope name.node completed;
        { id; earlier = Some declaration }
    | Some _ | None ->
        let declared = declare state ~kind name in
        if not generic then claim_own_tag state name;
        declared
  in
  if not generic then
    claim_tag state name ~tag:(enum_tag_name (Spelling.declared checked.node))
      (derived_enum_tag ~type_keyword);
  declared


(* A tag that a type declaration claims exists for C (design 10.1 rule
   6), so Type-C text cannot name it. *)
let named_tag state (name : identifier) entry =
  if entry.claimed && is_type_c_text_at state (token_of name) then
    fail_claimed state name "tag" "is not available to Type-C text";
  Names entry.tag

(* A tag that [declares] by its form declares itself in the current
   scope (6.7.2.3p6, p7); any other names the visible tag (p9), or
   declares one where none is visible (p8). *)
let bound_tag state (name : identifier) ~declares =
  let binding =
    if declares then declare_tag state name
    else
      match Scope.find_tag state.scope name.node with
      | Some entry -> named_tag state name entry
      | None -> declare_tag state name
  in
  { name; binding }

(* Scopes made from the current one, which the caller runs in. *)
let inner_scope state = Scope.enter state.scope
let reentered_scope state ~inner = Scope.reenter state.scope ~inner

(* Moves the cursor into a scope nested in the current one. *)
let enter_scope state = state.scope <- inner_scope state

(* Runs [parse] in [scope] and returns its result with the scope as
   [parse] left it. An error abandons the state, so the scope needs no
   restoring on one. *)
let run_in_scope state scope parse =
  let saved = state.scope in
  state.scope <- scope;
  let result = parse () in
  let left = state.scope in
  state.scope <- saved;
  (result, left)

let in_scope state scope parse = fst (run_in_scope state scope parse)

(* Runs [parse] with [state.generic] set to [generic] and
   [state.in_type_argument] to [in_type_argument], then restores them.
   An error abandons the state, so it needs no restoring on one. *)
let with_generic state ?(in_type_argument = state.in_type_argument) generic
    parse =
  let saved_generic = state.generic in
  let saved_in_type_argument = state.in_type_argument in
  state.generic <- generic;
  state.in_type_argument <- in_type_argument;
  let result = parse () in
  state.generic <- saved_generic;
  state.in_type_argument <- saved_in_type_argument;
  result

(* Runs [parse] on a type argument, which no definition of an instance
   holds, so a body inside it is not where design 3.5 rule 4 allows
   one. *)
let read_type_argument state parse =
  let generic =
    Option.map
      (fun place -> { place with bodies_allowed = false })
      state.generic
  in
  with_generic state ~in_type_argument:true generic parse

(* Runs [parse] on the operand of an [_Alignas]. *)
let read_alignment_operand state parse =
  let generic =
    Option.map (fun place -> { place with in_alignment = true }) state.generic
  in
  with_generic state generic parse

(* A block item or external declaration as read. One that holds a type
   declaration is complete only where the scope that holds it closes,
   which gives it the last token of the scope (design 10.1 rule 6). *)
type 'item scoped = Complete of 'item | Until_scope_end of (int -> 'item)

(* The items of a scope that closes at [scope_end], from [read], the
   items in reverse order of reading. *)
let close_scope ~scope_end read =
  List.rev_map
    (function
      | Complete item -> item
      | Until_scope_end complete -> complete scope_end)
    read

(* What a token begins among declaration specifiers: the one place that
   says which tokens are specifiers. *)
type specifier_word =
  | Storage_word of storage_class
  | Qualifier_word of type_qualifier
  | Function_word of function_specifier
  | Basic_word of basic_type_specifier
  | Atomic_type_word  (** [_Atomic] followed by [(] (6.7.2.4p4) *)
  | Struct_word of struct_or_union
  | Enum_word
  | Alignas_word
  | Typedef_word of string * ordinary
  | Typeof_word
  | Attribute_word

let keyword_specifier_word state offset keyword =
  match (keyword : Keyword.t) with
  | Typedef -> Some (Storage_word Typedef)
  | Extern -> Some (Storage_word Extern)
  | Static -> Some (Storage_word Static)
  | Thread_local -> Some (Storage_word Thread_local)
  | Auto -> Some (Storage_word Auto)
  | Register -> Some (Storage_word Register)
  | Const -> Some (Qualifier_word Const)
  | Restrict -> Some (Qualifier_word Restrict)
  | Volatile -> Some (Qualifier_word Volatile)
  | Nonnull -> Some (Qualifier_word (Nullability Nonnull))
  | Nullable -> Some (Qualifier_word (Nullability Nullable))
  | Nullable_result -> Some (Qualifier_word (Nullability Nullable_result))
  | Null_unspecified -> Some (Qualifier_word (Nullability Null_unspecified))
  | Atomic ->
      if peek_at state (offset + 1) = Punctuator_token P.Left_paren then
        Some Atomic_type_word
      else Some (Qualifier_word Atomic)
  | Inline -> Some (Function_word Inline)
  | Noreturn -> Some (Function_word Noreturn)
  | Void -> Some (Basic_word Void)
  | Char -> Some (Basic_word Char)
  | Short -> Some (Basic_word Short)
  | Int -> Some (Basic_word Int)
  | Long -> Some (Basic_word Long)
  | Float -> Some (Basic_word Float)
  | Double -> Some (Basic_word Double)
  | Signed -> Some (Basic_word Signed)
  | Unsigned -> Some (Basic_word Unsigned)
  | Bool -> Some (Basic_word Bool)
  | Complex -> Some (Basic_word Complex)
  | Int128 -> Some (Basic_word Int128)
  | Optional_float optional -> Some (Basic_word (Optional_float optional))
  | Struct -> Some (Struct_word Struct)
  | Union -> Some (Struct_word Union)
  | Enum -> Some Enum_word
  | Alignas -> Some Alignas_word
  | Typeof -> Some Typeof_word
  | Attribute -> Some Attribute_word
  | Break | Case | Continue | Default | Do | Else | For | Goto | If | Return
  | Sizeof | Switch | While | Alignof | Generic | Imaginary | Static_assert
  | Asm | Extension | Label | Builtin_va_arg | Builtin_offsetof
  | Builtin_types_compatible_p | Builtin_choose_expr | Real | Imag | Defer ->
      None

(* The offset after the bracketed group that [opener] opens [offset]
   tokens ahead, or of the end of the input if it does not close;
   [offset] if no [opener] opens there. The lookahead only decides; the
   parse that follows matches every bracket. *)
let past_group state opener offset =
  let closer = closer_of opener in
  let rec loop offset depth =
    match peek_at state offset with
    | Punctuator_token p when p = opener -> loop (offset + 1) (depth + 1)
    | Punctuator_token p when p = closer && depth = 1 -> offset + 1
    | Punctuator_token p when p = closer -> loop (offset + 1) (depth - 1)
    | End_of_input -> offset
    | _ -> loop (offset + 1) depth
  in
  if peek_at state offset = Punctuator_token opener then loop offset 0
  else offset

(* A type name [offset] tokens ahead, of the type that [ordinary] names,
   followed by [.] begins a postfix expression in Type-C text only, where
   it names a constructor (design 2.2, 3.3); C rejects it. So that every
   check for a type name agrees, it is no specifier. The type name of a
   generic type is an application, which ends at its [)]. *)
let begins_qualified_constructor state offset (ordinary : ordinary) =
  let after_name = offset + 1 in
  let after_type_name =
    if is_generic ordinary.kind then
      past_group state P.Left_paren after_name
    else after_name
  in
  peek_at state after_type_name = Punctuator_token P.Dot
  && is_type_c_text_at state state.grammar.(state.position + offset).index

(* The specifier that the token [offset] places ahead begins. A typedef
   name is one only where no other type specifier precedes it, which the
   caller decides. *)
let specifier_word state offset =
  match peek_at state offset with
  | Keyword_token keyword -> keyword_specifier_word state offset keyword
  | Identifier_token name -> (
      match typedef_declaration state name with
      | Some ordinary when begins_qualified_constructor state offset ordinary
        ->
          None
      | Some ordinary -> Some (Typedef_word (name, ordinary))
      | None -> None)
  | Punctuator_token _ | Number_token | Character_token _ | String_token _
  | End_of_input ->
      None

(* C23's [[ ]] begins an attribute specifier, which GCC and Clang read in
   C11 as well; no other C construct has two [[] in a row. *)
let opens_standard_attributes state offset =
  peek_at state offset = Punctuator_token P.Left_bracket
  && peek_at state (offset + 1) = Punctuator_token P.Left_bracket

let rec past_standard_attributes state offset =
  if opens_standard_attributes state offset then
    past_standard_attributes state (past_group state P.Left_bracket offset)
  else offset

(* A declaration's specifiers may follow C23 attribute specifiers. *)
let starts_declaration state offset =
  specifier_word state (past_standard_attributes state offset) <> None

(* GNU [__extension__] may come before a declaration or an expression. It
   only silences pedantic warnings about what follows it, so the tree
   keeps it only in the span of the node around it. *)

let rec extensions_ahead state offset =
  if peek_at state offset = Keyword_token Keyword.Extension then
    extensions_ahead state (offset + 1)
  else offset

let skip_extensions state =
  while accept_keyword state Keyword.Extension do
    ()
  done

(* A declaration begins with a specifier or with [_Static_assert], after
   any [__extension__]. *)
let begins_declaration state =
  let offset = extensions_ahead state 0 in
  starts_declaration state offset
  || peek_at state offset = Keyword_token Keyword.Static_assert

(* A label begins a labeled statement (6.8.1): [case], [default], or an
   identifier and a [:], whatever the identifier names, since labels have
   a name space of their own (6.2.3). *)
let begins_label state =
  match peek state with
  | Keyword_token (Keyword.Case | Keyword.Default) -> true
  | Identifier_token _ -> peek_at state 1 = Punctuator_token P.Colon
  | Keyword_token _ | Punctuator_token _ | Number_token | Character_token _
  | String_token _ | End_of_input ->
      false

(* A specifier-qualifier list begins a type name (6.7.7). It may hold an
   alignment specifier, as in C17 (DR 444), and GNU attributes. *)
let starts_type_name state offset =
  match specifier_word state offset with
  | Some (Storage_word _ | Function_word _) | None -> false
  | Some
      ( Qualifier_word _ | Basic_word _ | Atomic_type_word | Struct_word _
      | Enum_word | Alignas_word | Typedef_word _ | Typeof_word
      | Attribute_word ) ->
      true

(* [(] followed by a type name, [offset] tokens ahead: a cast, a compound
   literal or the operand of [sizeof]. *)
let opens_type_name_at state offset =
  peek_at state offset = Punctuator_token P.Left_paren
  && starts_type_name state (offset + 1)

(* Which specifiers a context takes: a specifier-qualifier list has no
   storage class or function specifier. The fixed type of an enumeration
   is an integer type that is not an enumeration (C23 6.7.2.2p5), so it
   takes only the specifiers that hold no other specifier outside a
   bracket: a qualifier, a basic type or a typedef name, whose type
   arguments, where it is a generic type, are in the [(] that bounds
   their recursion. *)
type specifier_context =
  | Declaration_specifiers
  | Specifier_qualifiers
  | Enumeration_type

let allowed context word =
  match (context, word) with
  | Specifier_qualifiers, Some (Storage_word _ | Function_word _) -> None
  | Enumeration_type, Some (Basic_word _ | Qualifier_word _ | Typedef_word _)
    ->
      word
  | Enumeration_type, _ -> None
  | (Declaration_specifiers | Specifier_qualifiers), _ -> word

let is_type_specifier = function
  | Type_specifier _ -> true
  | Storage_class _ | Type_qualifier _ | Function_specifier _
  | Alignment_specifier _ | Attributes _ ->
      false

let is_attributes = function
  | Attributes _ -> true
  | Storage_class _ | Type_specifier _ | Type_qualifier _
  | Function_specifier _ | Alignment_specifier _ ->
      false

(* The kind of the names that a C declaration with [specifiers]
   declares. *)
let declared_kind specifiers =
  if List.exists (fun specifier -> specifier.node = Storage_class Typedef)
      specifiers
  then Typedef_name
  else Not_a_type

let is_identifier = function
  | Identifier_token _ -> true
  | Keyword_token _ | Punctuator_token _ | Number_token | Character_token _
  | String_token _ | End_of_input ->
      false

let fail_type_name state expected name =
  fail state
    (Rule.c_text
       (Printf.sprintf "expected %s, found the type name %s" expected
          (quoted name)))

(* A generic type's name alone is not a type (design 3.5 rule 1). At the
   name, the token [at]. *)
let fail_bare_generic state ~at name =
  fail_at_token state at
    (Rule.message Generic_name
       (Printf.sprintf
          "the generic type %s names a type only in a type application, \
           %s"
          (quoted name) (quoted (name ^ "(...)"))))

(* The alignment of an instance would depend on a type argument, which
   design 3.5 rule 4 rules out. At the type parameter, the token [at]. *)
let refuse_parameter_in_alignment state ~at name =
  match state.generic with
  | Some { in_alignment = true; _ } ->
      fail_at_token state at
        (Rule.message Generic_definition
           (Printf.sprintf "the type parameter %s is used in `_Alignas`"
              (quoted name)))
  | Some { in_alignment = false; _ } | None -> ()

(* A type declaration names its type only inside a structure or union
   specifier of its definition (design 3.1 rule 2). At the name, the
   token [at]. *)
let fail_own_name state ~at name =
  fail_at_token state at
    (Rule.message Own_name
       (quoted name
       ^ " is used in its own definition, which is not a structure or \
          union specifier"))

let identifier state expected =
  match peek state with
  | Identifier_token name ->
      let start = state.position in
      advance state;
      finish state start name
  | Keyword_token _ | Punctuator_token _ | Number_token | Character_token _
  | String_token _ | End_of_input ->
      fail_expected state expected

let optional_identifier state =
  match peek state with
  | Identifier_token _ -> Some (identifier state "an identifier")
  | Keyword_token _ | Punctuator_token _ | Number_token | Character_token _
  | String_token _ | End_of_input ->
      None

let type_qualifiers state =
  let rec loop qualifiers =
    match specifier_word state 0 with
    | Some (Qualifier_word qualifier) ->
        let start = state.position in
        advance state;
        loop (finish state start qualifier :: qualifiers)
    | Some
        ( Storage_word _ | Function_word _ | Basic_word _ | Atomic_type_word
        | Struct_word _ | Enum_word | Alignas_word | Typedef_word _
        | Typeof_word | Attribute_word )
    | None ->
        List.rev qualifiers
  in
  loop []

let string_literal state =
  let rec loop pieces =
    match peek state with
    | String_token encoding ->
        let start = state.position in
        advance state;
        loop (finish state start encoding :: pieces)
    | Keyword_token _ | Identifier_token _ | Punctuator_token _ | Number_token
    | Character_token _ | End_of_input ->
        List.rev pieces
  in
  match loop [] with
  | [] -> fail_expected state "a string literal"
  | pieces -> pieces

(* One or more items that commas separate. *)
let one_or_more state read =
  let rec loop items =
    let items = read state :: items in
    if accept state P.Comma then loop items else List.rev items
  in
  loop []

(* Items that commas separate, none where a [:] or a [)] follows: the
   sections of extended assembler. *)
let comma_separated state read =
  match peek state with
  | Punctuator_token (P.Colon | P.Right_paren) -> []
  | _ -> one_or_more state read

(* Consumes the tokens from an opening bracket to the one that closes it,
   unread, and returns their span; [expected] names the closer for the
   end of input. The cursor matches every bracket, so the skip ends at
   the right one, and the bound on nesting holds here too. *)
let skip_balanced state expected =
  let start = state.position in
  let outside = List.length state.open_brackets in
  advance state;
  let rec loop () =
    if List.length state.open_brackets > outside then begin
      if peek state = End_of_input then fail_expected state expected;
      advance state;
      loop ()
    end
  in
  loop ();
  span_from state start

(* GNU attributes (GCC manual 6.39). *)

(* The arguments of an attribute, if the cursor is at their [(]. The
   parser does not read them, so it keeps the scope there, under the
   token where their span starts, which says what each identifier among
   them denotes (design 13.5). A scope is persistent, so keeping one
   copies nothing. *)
let attribute_arguments state =
  if peek state = Punctuator_token P.Left_paren then begin
    let scope = state.scope in
    let arguments =
      skip_balanced state "`)` to end the arguments of an attribute"
    in
    state.views <-
      {
        state.views with
        attributes = Places.add arguments.first scope state.views.attributes;
      };
    Some arguments
  end
  else None

(* GCC takes [__name__] for the attribute [name], so that a header can
   name one that a macro of the program would replace. *)
let attribute_name state =
  let start = state.position in
  match peek state with
  | Identifier_token _ | Keyword_token _ ->
      let spelling = next_spelling state in
      let length = String.length spelling in
      let name =
        if
          length > 4
          && String.starts_with ~prefix:"__" spelling
          && String.ends_with ~suffix:"__" spelling
        then String.sub spelling 2 (length - 4)
        else spelling
      in
      advance state;
      finish state start name
  | Punctuator_token _ | Number_token | Character_token _ | String_token _
  | End_of_input ->
      fail_expected state "an attribute name"

let attribute state =
  let start = state.position in
  let name = attribute_name state in
  let arguments = attribute_arguments state in
  finish state start { name; arguments }

(* After the [__attribute__], up to and including its [))]: attributes
   separated by commas, where an empty one is allowed. *)
let attribute_list state =
  expect state P.Left_paren "`((` after `__attribute__`";
  expect state P.Left_paren "`((` after `__attribute__`";
  let rec loop attributes =
    if accept state P.Comma then loop attributes
    else if peek state = Punctuator_token P.Right_paren then
      List.rev attributes
    else
      let attributes = attribute state :: attributes in
      if accept state P.Comma then loop attributes else List.rev attributes
  in
  let attributes = loop [] in
  expect state P.Right_paren "`,` or `)` after an attribute";
  expect state P.Right_paren "`))` to end `__attribute__`";
  attributes

(* Any number of [__attribute__((...))] in a row, as one list. *)
let attributes state =
  let rec loop reversed =
    if accept_keyword state Keyword.Attribute then
      loop (List.rev_append (attribute_list state) reversed)
    else List.rev reversed
  in
  loop []

(* C23 attribute specifiers (C23 6.7.13), which typec reads where GCC and
   Clang both do in C11: before the specifiers of a declaration, a
   parameter or a member, and before the [;] of a null statement. Each
   attribute is read as the GNU attribute it means, so that one table of
   effects serves both forms: [gnu::name] is the GNU attribute [name], a
   standard attribute is the GNU attribute of the same meaning, and
   Clang's or another vendor's keeps its prefix, as only the table of
   effects knows which GNU attributes Clang also spells [clang::name].
   An attribute without a prefix that C23 does not define is left out, as
   GCC and Clang ignore it. *)

(* The C23 attributes and the GNU attributes they mean; [unsequenced] and
   [reproducible] have none and keep their own names, which make the type
   they apply to unknown, as an attribute that typec does not know
   does. *)
let standard_attribute_meanings =
  [ ("deprecated", "deprecated"); ("fallthrough", "fallthrough");
    ("maybe_unused", "unused"); ("nodiscard", "warn_unused_result");
    ("noreturn", "noreturn"); ("_Noreturn", "noreturn");
    ("unsequenced", "unsequenced"); ("reproducible", "reproducible") ]

(* The prefix of a vendor as Clang reads it, which takes [_Clang] for
   [clang]. *)
let vendor_prefix prefix = if prefix = "_Clang" then "clang" else prefix

(* The name that a C23 attribute has as a GNU attribute, if any; the
   prefix and its [::], two [:] tokens in C11, are read here. *)
let standard_attribute_name state =
  let start = state.position in
  let first = attribute_name state in
  let meaning =
    if accept state P.Colon then begin
      expect state P.Colon "`::` in an attribute name";
      let name = attribute_name state in
      if first.node = "gnu" then Some name.node
      else Some (vendor_prefix first.node ^ "::" ^ name.node)
    end
    else List.assoc_opt first.node standard_attribute_meanings
  in
  Option.map (fun meaning -> finish state start meaning) meaning

let standard_attribute state =
  let start = state.position in
  let name = standard_attribute_name state in
  let arguments = attribute_arguments state in
  Option.map (fun name -> finish state start { name; arguments }) name

(* From the [[[] to the []]]: attributes separated by commas, where an
   empty one is allowed. *)
let standard_attribute_list state =
  expect state P.Left_bracket "`[[`";
  expect state P.Left_bracket "`[[`";
  let rec loop attributes =
    if accept state P.Comma then loop attributes
    else if peek state = Punctuator_token P.Right_bracket then attributes
    else
      let attributes =
        match standard_attribute state with
        | Some attribute -> attribute :: attributes
        | None -> attributes
      in
      if accept state P.Comma then loop attributes else attributes
  in
  let attributes = List.rev (loop []) in
  expect state P.Right_bracket "`,` or `]]` after an attribute";
  expect state P.Right_bracket "`]]` to end the attributes";
  attributes

(* Any number of C23 attribute specifiers in a row, as one list. *)
let standard_attributes state =
  let rec loop reversed =
    if opens_standard_attributes state 0 then
      loop (List.rev_append (standard_attribute_list state) reversed)
    else List.rev reversed
  in
  loop []

(* The C23 attribute specifiers before the specifiers of a declaration,
   each a specifier of the attributes it holds. *)
let leading_attributes state =
  let rec loop reversed =
    if opens_standard_attributes state 0 then
      let start = state.position in
      let attributes = standard_attribute_list state in
      loop (finish state start (Attributes attributes) :: reversed)
    else List.rev reversed
  in
  loop []

(* The qualifiers after a [*] or [^], and the attributes among them, each
   in source order. *)
let pointer_qualifiers state =
  let rec loop qualifiers attributes =
    let qualifiers = List.rev_append (type_qualifiers state) qualifiers in
    if accept_keyword state Keyword.Attribute then
      loop qualifiers (List.rev_append (attribute_list state) attributes)
    else (List.rev qualifiers, List.rev attributes)
  in
  loop [] []

(* The offset after the GNU attributes that begin [offset] tokens ahead:
   each [__attribute__] and the parentheses after it. The lookahead only
   decides; the parse that follows matches every bracket. *)
let rec past_attributes state offset =
  if peek_at state offset = Keyword_token Keyword.Attribute then
    past_attributes state (past_group state P.Left_paren (offset + 1))
  else offset

(* Attributes and the [;] after them, which in a block are a null
   statement with attributes rather than C23's attribute declaration. *)
let begins_attribute_statement state =
  let after = past_attributes state (past_standard_attributes state 0) in
  after > 0 && peek_at state after = Punctuator_token P.Semicolon

(* A tag specifier without a body is alone in its declaration
   (6.7.2.3p7) where only attributes come before it, which the caller
   says in [alone], and only attributes and the [;] after it. That is
   GCC's reading for qualifiers and storage classes, which Clang also
   takes before it; both declare a tag after a function specifier, which
   they refuse there, as typec's reader must. A member declaration is no
   declaration, so [struct s;] among members names a tag, as in GCC,
   where Clang declares one. *)
let ends_alone state ~alone =
  alone
  && peek_at state (past_attributes state 0) = Punctuator_token P.Semicolon

(* GNU assembler (GCC manual 6.11). *)

(* An optional asm label after a declarator. *)
let asm_label state =
  if accept_keyword state Keyword.Asm then begin
    expect state P.Left_paren "`(` after `asm`";
    let label = string_literal state in
    expect state P.Right_paren "`)` after an asm label";
    Some label
  end
  else None

let asm_qualifiers state =
  let rec loop qualifiers =
    let start = state.position in
    let qualifier =
      match peek state with
      | Keyword_token Keyword.Volatile -> Some Asm_volatile
      | Keyword_token Keyword.Inline -> Some Asm_inline
      | Keyword_token Keyword.Goto -> Some Asm_goto
      | _ -> None
    in
    match qualifier with
    | Some qualifier ->
        advance state;
        loop (finish state start qualifier :: qualifiers)
    | None -> List.rev qualifiers
  in
  loop []

(* Operators. *)

(* The binary operators and their precedence, from 10 for the
   multiplicative ones, which bind tightest, to 1 for [||] (C11 6.5.5 to
   6.5.14). All are left-associative. *)
let binary_operator = function
  | Punctuator_token P.Star -> Some (Multiply, 10)
  | Punctuator_token P.Slash -> Some (Divide, 10)
  | Punctuator_token P.Percent -> Some (Remainder, 10)
  | Punctuator_token P.Plus -> Some (Add, 9)
  | Punctuator_token P.Minus -> Some (Subtract, 9)
  | Punctuator_token P.Less_less -> Some (Shift_left, 8)
  | Punctuator_token P.Greater_greater -> Some (Shift_right, 8)
  | Punctuator_token P.Less -> Some (Less_than, 7)
  | Punctuator_token P.Greater -> Some (Greater_than, 7)
  | Punctuator_token P.Less_equal -> Some (Less_or_equal, 7)
  | Punctuator_token P.Greater_equal -> Some (Greater_or_equal, 7)
  | Punctuator_token P.Equal_equal -> Some (Equal_to, 6)
  | Punctuator_token P.Exclaim_equal -> Some (Not_equal_to, 6)
  | Punctuator_token P.Ampersand -> Some (Bitwise_and, 5)
  | Punctuator_token P.Caret -> Some (Bitwise_xor, 4)
  | Punctuator_token P.Pipe -> Some (Bitwise_or, 3)
  | Punctuator_token P.Ampersand_ampersand -> Some (Logical_and, 2)
  | Punctuator_token P.Pipe_pipe -> Some (Logical_or, 1)
  | _ -> None

let lowest_precedence = 1

let assignment_operator = function
  | Punctuator_token P.Equal -> Some Assign
  | Punctuator_token P.Star_equal -> Some (Compound_assign Multiply)
  | Punctuator_token P.Slash_equal -> Some (Compound_assign Divide)
  | Punctuator_token P.Percent_equal -> Some (Compound_assign Remainder)
  | Punctuator_token P.Plus_equal -> Some (Compound_assign Add)
  | Punctuator_token P.Minus_equal -> Some (Compound_assign Subtract)
  | Punctuator_token P.Less_less_equal -> Some (Compound_assign Shift_left)
  | Punctuator_token P.Greater_greater_equal ->
      Some (Compound_assign Shift_right)
  | Punctuator_token P.Ampersand_equal -> Some (Compound_assign Bitwise_and)
  | Punctuator_token P.Caret_equal -> Some (Compound_assign Bitwise_xor)
  | Punctuator_token P.Pipe_equal -> Some (Compound_assign Bitwise_or)
  | _ -> None

(* The operators of C11 6.5.3 that take a cast-expression. *)
let unary_operator = function
  | Punctuator_token P.Ampersand -> Some Address
  | Punctuator_token P.Star -> Some Indirection
  | Punctuator_token P.Plus -> Some Unary_plus
  | Punctuator_token P.Minus -> Some Unary_minus
  | Punctuator_token P.Tilde -> Some Bitwise_not
  | Punctuator_token P.Exclaim -> Some Logical_not
  | Keyword_token Keyword.Real -> Some Real_part
  | Keyword_token Keyword.Imag -> Some Imaginary_part
  | _ -> None

(* The operators whose operand is a unary-expression or a type name in
   parentheses: [sizeof] and [_Alignof], whose operand GNU C allows to
   be an expression. Each gives the node of either operand. *)
let measure_operator = function
  | Keyword_token Keyword.Sizeof ->
      Some
        ( (fun operand -> Sizeof_expression operand),
          fun type_name -> Sizeof_type type_name )
  | Keyword_token Keyword.Alignof ->
      Some
        ( (fun operand -> Alignof_expression operand),
          fun type_name -> Alignof type_name )
  | _ -> None

(* The left operand of an assignment is a unary-expression (6.5.16); any
   other expression ends before the assignment operator. *)
let is_unary_expression expression =
  match expression.node with
  | Binary _ | Conditional _ | Cast _ | Assignment _ | Comma _ -> false
  | Identifier _ | Constant _ | Character _ | String _ | Parenthesized _
  | Generic _ | Compound_literal _ | Qualified_constructor _ | Subscript _
  | Call _ | Member _ | Pointer_member _ | Post_increment _
  | Post_decrement _ | Unary _
  | Sizeof_expression _ | Sizeof_type _ | Alignof _ | Alignof_expression _
  | Statement_expression _ | Label_address _ | Va_arg _ | Offsetof _
  | Types_compatible _ | Choose _ | Block_literal _ ->
      true

(* Which declarators a context takes: a declaration names what it
   declares, a type name does not, and a parameter may do either. *)
type declarator_form = Named | Abstract | Named_or_abstract

(* In a declarator, [(] begins a parameter list rather than a nested
   declarator where the declarator may be abstract and the [(] is
   followed by [)] or a declaration specifier, a typedef name included
   (6.7.6.3p11). GNU attributes may begin either, so GCC decides at the
   token after them, and so does the parser. *)
let opens_nested_declarator state form =
  match form with
  | Named -> true
  | Abstract | Named_or_abstract ->
      let next = past_attributes state 1 in
      not
        (peek_at state next = Punctuator_token P.Right_paren
        || starts_declaration state next)

(* Whether a declarator is its name, in parentheses or not: a derivation
   around it applies to the name. *)
let rec is_name declarator =
  match declarator.node with
  | Name _ -> true
  | Parenthesized_declarator { inner; _ } -> is_name inner
  | Pointer _ | Block_pointer _ | Array _ | Function _ -> false

(* A declarator with the asm label and attributes after it, which belong
   to it, read up to where its identifier enters scope (6.2.1p7): before
   an initialiser or the body of a function definition. *)
type scoped_declarator = {
  declarator_start : int;
  declarator : declarator;
  declared : declared;
  named_function : named_function option;
  asm_label : string_literal option;
  attributes : attribute list;
}

(* A declaration read up to the end of its first declarator, where a
   function definition parts from it, or read whole if it has no
   declarator. *)
type declaration_start =
  | Complete of declaration
  | First_declarator of {
      start : int;
      specifiers : specifiers;
      first : scoped_declarator;
    }

(* A statement read up to its substatement, which ends it or, for [if]
   and [do], which more tokens may follow. [outer] is the scope around
   the statement, which closing it restores: a selection or iteration
   statement is a block, and so is each of its substatements (6.8.4p3,
   6.8.5p5). A label opens no scope, so its [outer] is None.
   [outer_jumps] is the jump scope around the statement, which closing
   it restores too. *)
type open_statement = {
  start : int;
  outer : scope option;
  outer_jumps : jump_scope;
  kind : open_kind;
}

(* [statement_scope] is the scope of the whole statement after its head;
   the [else] branch and the condition of a [do] are read in it. *)
and open_kind =
  | Open_labeled of label
  | Open_if of { condition : condition; statement_scope : scope }
  | Open_else of { condition : condition; then_branch : statement }
  | Open_switch of expression
  | Open_while of condition
  | Open_do of { statement_scope : scope }
  | Open_for of {
      clause : for_clause option;
      condition : expression option;
      step : expression option;
    }

(* A pattern as read, before its bindings enter scope where its block
   scope begins: its constructor and its sub-patterns, each an
   identifier, which may be [_]. *)
type pattern_words = {
  constructor : identifier;
  sub_patterns : identifier list option;
}

(* What the substatement of an open statement leaves: the statement
   closed, or, after the [else] of an [if], open again. *)
type closing = Closed of statement_node | Reopened of open_kind

(* Type declarations (design 3.1, Appendix A) are recognised by
   position: [type] is an identifier everywhere else (design 2.3). *)

let type_word = "type"

(* A type declaration begins with [type] and an identifier where an
   external declaration or a block item begins, except where [type] is
   visible as a typedef name: there the same tokens begin the C
   declaration (design 2.2, 2.3). C rejects them anywhere else. *)
let begins_type_declaration state =
  peek state = Identifier_token type_word
  && is_identifier (peek_at state 1)
  && not (is_typedef_name state type_word)

(* A match statement (design 4.1) is recognised by position: [match] is
   an identifier everywhere else (design 2.3). It begins where a
   statement begins, with [match], a parenthesised group and [{]. In C
   the tokens [match (] ... [)] at the start of a statement begin a call,
   which no [{] can follow, or, where [match] is a typedef name, a
   declaration that a [{] makes a function definition in a block, which
   the GNU profile excludes; so no C statement begins this way (design
   2.2). *)
let match_word = "match"

(* The sub-pattern that matches without binding (design 4.1 rule 3). *)
let wildcard_word = "_"

let begins_match state =
  peek state = Identifier_token match_word
  && peek_at state 1 = Punctuator_token P.Left_paren
  && peek_at state (past_group state P.Left_paren 1)
     = Punctuator_token P.Left_brace

(* Whether the definition at the cursor, after the [=] of a type
   declaration, is a structure or union specifier with a body and
   nothing else: the one definition that may use the name it defines
   (design 3.1 rule 2), which [record_specifier] then reads. *)
let defines_record_alone state =
  match peek state with
  | Keyword_token (Keyword.Struct | Keyword.Union) ->
      let before_tag = past_attributes state 1 in
      let before_body =
        if is_identifier (peek_at state before_tag) then before_tag + 1
        else before_tag
      in
      let after_body = past_group state P.Left_brace before_body in
      peek_at state before_body = Punctuator_token P.Left_brace
      && peek_at state (past_attributes state after_body)
         = Punctuator_token P.Semicolon
  | _ -> false

(* The names of the constructors of the definition at the cursor, in
   order: the identifier after each [|], past the fields in parentheses.
   Where the definition is malformed, the list ends where the grammar
   then fails. *)
let constructor_names state =
  let rec loop offset names =
    match (peek_at state offset, peek_at state (offset + 1)) with
    | Punctuator_token P.Pipe, Identifier_token name ->
        let token = state.grammar.(state.position + offset + 1).index in
        let next = past_group state P.Left_paren (offset + 2) in
        let name = Spanned.identifier { first = token; last = token } name in
        loop next (name :: names)
    | _ -> List.rev names
  in
  loop 0 []

(* Unqualified, a constructor named for a word of Type-C or a universe
   name would read as that word or name; and its name joins the variant's
   with one [_] in the enumerator it derives, so that the enumerator holds
   no [__] (design 3.2 rule 2). *)
let checked_constructor state (constructor : identifier) =
  let refuse why =
    fail_at_token state (token_of constructor)
      (Rule.message Reserved_constructor
         (Printf.sprintf "%s cannot name a constructor, as %s"
            (quoted constructor.node) why))
  in
  match (type_c_word constructor.node, Universe.find constructor.node) with
  | Some _, _ -> refuse "it is a word of Type-C"
  | None, Some _ -> refuse "it is a universe name"
  | None, None -> (
      match Spelling.constructor constructor.node with
      | Ok checked -> checked
      | Error why -> refuse why)

(* A field names a member of its constructor's structure, so its name
   may not be one C reserves for any use (design 3.2 rule 2). *)
let refuse_reserved_field state (field : identifier) =
  if Spelling.is_reserved_for_any_use field.node then
    fail_at_token state (token_of field)
      (Rule.message Reserved_constructor
         (Printf.sprintf "%s cannot name a field, as C reserves it for any use"
            (quoted field.node)))

(* The enumerators of the variant [variant], claimed before any field is
   read: the C it lowers to declares them before the structure, so a
   field names them as C does (design 10.1 rule 6). Names within one
   variant are unique (design 3.2 rule 2). Gives the names of the
   constructors, which the tree takes as [constructor] reads them. A
   [generic] variant claims none (design 10.3). *)
let claim_enumerators state ~variant ~generic =
  let seen = Hashtbl.create 8 in
  let claim (name : identifier) =
    let checked = checked_constructor state name in
    let at = token_of name in
    if Hashtbl.mem seen name.node then
      fail_at_token state at
        (Rule.message Duplicate_constructor
           (quoted name.node ^ " names two constructors of one variant"));
    Hashtbl.replace seen name.node ();
    if not generic then claim_enumerator state ~variant ~at checked;
    { at; checked }
  in
  (* In source order, so that the first refused name is the one
     reported. *)
  let rec loop names claimed =
    match names with
    | name :: names -> loop names (claim name :: claimed)
    | [] -> List.rev claimed
  in
  loop (constructor_names state) []

let word_at state offset word = peek_at state offset = Identifier_token word

(* [distinct] is the word only before a token that begins a type name. *)
let begins_distinct_at state offset =
  word_at state offset "distinct" && starts_type_name state (offset + 1)

let begins_distinct state = begins_distinct_at state 0

(* [private] is the word only before the [|] of a variant or before the
   word [distinct] (design 2.3, 9.2); elsewhere after the [=] it may name
   a type. Takes the word, if it is one. *)
let accept_private state =
  let is_private =
    word_at state 0 "private"
    && (peek_at state 1 = Punctuator_token P.Pipe || begins_distinct_at state 1)
  in
  if is_private then advance state;
  is_private

(* The definition of a generic type (design 3.5 rule 4). *)

(* A type parameter used where design 3.5 rule 4 rules it out, which
   [use] says. *)
type parameter_use = { parameter : string; at : int }

(* The use of a type parameter that a specifier among [specifiers] is,
   if one is: only the definition of a generic declares one. *)
let type_parameter_among state (specifiers : specifiers) =
  let use (specifier : declaration_specifier spanned) =
    match specifier.node with
    | Type_specifier (Typedef_name { name; declaration }) -> (
        match Scope.find state.scope name with
        | Some { kind = Type_parameter; declaration = visible }
          when visible = declaration ->
            Some { parameter = name; at = specifier.span.first }
        | Some _ | None -> None)
    | Type_specifier _ | Storage_class _ | Type_qualifier _
    | Function_specifier _ | Alignment_specifier _ | Attributes _ ->
        None
  in
  List.find_map use specifiers

let fail_type_parameter_use state { parameter; at } use =
  fail_at_token state at
    (Rule.message Generic_definition
       (Printf.sprintf "the type parameter %s %s" (quoted parameter) use))

(* A bit-field of a parameter's type would have the type of an argument,
   which may be any value type. *)
let refuse_parameter_bit_field state specifiers declarators =
  let is_bit_field (declarator : member_declarator) =
    match declarator.node with
    | Bit_field _ -> true
    | Field _ -> false
  in
  if List.exists is_bit_field declarators then
    Option.iter
      (fun parameter ->
        fail_type_parameter_use state parameter "is the type of a bit-field")
      (type_parameter_among state specifiers)

(* An instance of a generic type is defined after typedef expansion
   (design 10.3), where a body with a tag would define the tag again in
   every instance, and a body stands only where the definition of an
   instance holds it. At the [{], after the tag [tag_name], if any. *)
let refuse_generic_body state ~tag_name =
  match (state.generic, tag_name) with
  | None, _ | Some { bodies_allowed = true; _ }, None -> ()
  | Some _, Some (tag : identifier) ->
      fail_at_token state (token_of tag)
        (Rule.message Generic_definition
           (Printf.sprintf
              "the structure or union %s has a body in the definition of \
               a generic type, where a body has no tag"
              (quoted tag.node)))
  | Some { bodies_allowed = false; _ }, None ->
      fail state
        (Rule.message Generic_definition
           "a structure or union body stands in the definition of a \
            generic type only as the whole definition or in a field of a \
            variant, or inside either, and not in a type argument")

(* Every instance would declare the enumerators again. At the [{]. *)
let refuse_generic_enumerators state =
  if Option.is_some state.generic then
    fail state
      (Rule.message Generic_definition
         "an enumeration specifier has a body in the definition of a \
          generic type, so that every instance would declare its \
          enumerators again")

(* A distinct generic type's representation is not one of its type
   parameters, qualified or not (design 3.5 rule 4). *)
let refuse_distinct_parameter state (representation : type_name) =
  if Option.is_none representation.node.abstract then
    Option.iter
      (fun parameter ->
        fail_type_parameter_use state parameter
          "is the representation after `distinct`")
      (type_parameter_among state representation.node.specifier_qualifiers)

(* The form of the definition after the [=] of a type declaration and
   any [private] (design 3.1 rule 3), which says where the declared name
   is in scope (rule 2). *)
type definition_form =
  | Variant_form
  | Record_form of struct_or_union
      (** a structure or union specifier with a body and nothing else *)
  | Distinct_form
  | Alias_form

let definition_form state =
  if peek state = Punctuator_token P.Pipe then Variant_form
  else
    match specifier_word state 0 with
    | Some (Struct_word kind) when defines_record_alone state ->
        Record_form kind
    | _ when begins_distinct state -> Distinct_form
    | _ -> Alias_form

(* The type parameters of a generic type, and the scope that declares
   them, which its definition is read in. *)
type generic_head = {
  parameter_names : parameter_name list;
  parameter_frame : scope;
}

let type_parameter_count = function
  | Some head -> List.length head.parameter_names
  | None -> 0

(* Type parameters have distinct names. *)
let declare_type_parameter state (name : identifier) : parameter_name =
  if Scope.find_in_innermost state.scope name.node <> None then
    fail_at_token state (token_of name)
      (Rule.message One_definition
         (quoted name.node ^ " names two type parameters of one generic type"));
  { name; declared = declare state ~kind:Type_parameter name }

(* At the [(] after the name of a generic type, which is declared at file
   scope only, where its instances are emitted (design 3.1), and has no
   universe name (3.6): its type parameters, which a scope of their own
   declares. *)
let generic_head state (checked : Spelling.type_name spanned) =
  let name = (checked :> identifier) in
  if not (Scope.is_file state.scope) then
    fail_at_token state (token_of name)
      (Rule.message Generic_scope
         (Printf.sprintf
            "the generic type %s is declared in a block; a generic type is \
             declared at file scope only"
            (quoted name.node)));
  if Universe.find name.node <> None then
    fail_at_token state (token_of name)
      (Rule.message Generic_universe_name
         (quoted name.node ^ " is a universe name, which no generic type has"));
  advance state;
  let rec parameters declared =
    let name = identifier state "the name of a type parameter" in
    let declared = declare_type_parameter state name :: declared in
    if accept state P.Comma then parameters declared
    else begin
      expect state P.Right_paren "`,` or `)` after a type parameter";
      List.rev declared
    end
  in
  let parameter_names, parameter_frame =
    run_in_scope state (inner_scope state) (fun () -> parameters [])
  in
  { parameter_names; parameter_frame }

(* Runs [parse] on the definition of a type declaration with the type
   parameters of [head] visible around it, if it is generic, where
   [bodies_allowed] says whether a structure or union body may stand
   (design 3.5
   rule 4). *)
let in_definition state head ~bodies_allowed parse =
  match head with
  | None -> parse ()
  | Some { parameter_frame; _ } ->
      let scope = reentered_scope state ~inner:parameter_frame in
      let parameter_depth = Scope.depth scope in
      let generic =
        Some { bodies_allowed; in_alignment = false; parameter_depth }
      in
      in_scope state scope (fun () ->
          with_generic state ~in_type_argument:false generic parse)

(* The grammar: declarations, expressions and statements, which nest in
   each other through statement expressions. *)

(* [only_attributes] holds while every specifier read is attributes, so
   that a tag specifier can tell whether it is alone in its declaration. *)
let rec specifiers state context =
  let leading =
    match context with
    | Declaration_specifiers -> leading_attributes state
    | Specifier_qualifiers | Enumeration_type -> []
  in
  let rec loop ~seen_type_specifier ~only_attributes specifiers =
    match allowed context (specifier_word state 0) with
    | Some (Typedef_word _) when seen_type_specifier -> List.rev specifiers
    | Some word ->
        let alone = context = Declaration_specifiers && only_attributes in
        let specifier = specifier state word ~alone in
        loop
          ~seen_type_specifier:
            (seen_type_specifier || is_type_specifier specifier.node)
          ~only_attributes:(only_attributes && is_attributes specifier.node)
          (specifier :: specifiers)
    | None -> List.rev specifiers
  in
  leading @ loop ~seen_type_specifier:false ~only_attributes:true []

(* [alone] says that only attributes come before the specifier in the
   specifiers of a declaration, for {!ends_alone}. *)
and specifier state word ~alone =
  let start = state.position in
  advance state;
  let node =
    match word with
    | Storage_word storage_class -> Storage_class storage_class
    | Qualifier_word qualifier -> Type_qualifier qualifier
    | Function_word function_specifier -> Function_specifier function_specifier
    | Basic_word basic -> Type_specifier (Basic basic)
    | Typedef_word (name, ordinary) ->
        let at = first_token state start in
        Type_specifier (named_type state name ordinary ~at)
    | Atomic_type_word ->
        expect state P.Left_paren "`(` after `_Atomic`";
        let type_name = type_name state in
        expect state P.Right_paren "`)` after the type name of `_Atomic`";
        Type_specifier (Atomic_type type_name)
    | Alignas_word -> Alignment_specifier (alignment state)
    | Struct_word kind -> Type_specifier (struct_or_union state kind ~alone)
    | Enum_word -> Type_specifier (enum_specifier state ~alone)
    | Typeof_word -> Type_specifier (typeof_specifier state)
    | Attribute_word -> Attributes (attribute_list state)
  in
  finish state start node

(* After the typedef name [name] at the token [at], which [ordinary]
   declares: its specifier, which for a generic type is an application
   of it. *)
and named_type state name (ordinary : ordinary) ~at =
  (match ordinary.kind with
  | Declared_type { stage = Defining; _ } -> fail_own_name state ~at name
  | Type_parameter -> refuse_parameter_in_alignment state ~at name
  | Not_a_type | Typedef_name | Declared_type _ | Derived_enumerator -> ());
  let declaration = ordinary.declaration in
  match type_parameters_of ordinary.kind with
  | 0 -> Typedef_name { name; declaration }
  | parameters ->
      let arguments = type_arguments state name ~at ~parameters in
      Application { name; generic = declaration; arguments }

(* After the name of a generic type at the token [at]: its arguments,
   one type name for each of its [parameters] (design 3.5 rule 1). *)
and type_arguments state name ~at ~parameters =
  if peek state <> Punctuator_token P.Left_paren then
    fail_bare_generic state ~at name;
  advance state;
  let rec loop arguments =
    let argument = read_type_argument state (fun () -> type_name state) in
    if accept state P.Comma then loop (argument :: arguments)
    else begin
      expect state P.Right_paren "`,` or `)` after a type argument";
      List.rev (argument :: arguments)
    end
  in
  let arguments = loop [] in
  let count = List.length arguments in
  if count <> parameters then
    fail_at_token state at
      (Rule.message Generic_name
         (Printf.sprintf "the generic type %s takes %s, not %d"
            (quoted name)
            (counted parameters "type argument")
            count));
  arguments

(* Where a declaration must begin and does not. A universe name there may
   be a type that typec does not implement yet, which the error says. *)
and refuse_declaration state =
  (match peek state with
  | Identifier_token name when Scope.find state.scope name = None ->
      refuse_universe_name state name
  | Identifier_token _ | Keyword_token _ | Punctuator_token _ | Number_token
  | Character_token _ | String_token _ | End_of_input ->
      ());
  fail_expected state "a declaration"

(* After the [typeof]. *)
and typeof_specifier state =
  expect state P.Left_paren "`(` after `typeof`";
  let specifier =
    if starts_type_name state 0 then Typeof_type (type_name state)
    else Typeof_expression (expression state)
  in
  expect state P.Right_paren "`)` after the operand of `typeof`";
  specifier

and alignment state =
  expect state P.Left_paren "`(` after `_Alignas`";
  let alignment =
    read_alignment_operand state (fun () ->
        if starts_type_name state 0 then Alignas_type (type_name state)
        else Alignas_expression (constant_expression state))
  in
  expect state P.Right_paren "`)` after the operand of `_Alignas`";
  alignment

and struct_or_union state kind ~alone =
  Struct_or_union (record_specifier state kind ~alone ~claimed_by:None)

(* After the keyword. The attributes after it and after a body apply to
   the type (GCC manual 6.39.5). [claimed_by] is the type declaration
   whose definition the specifier is, which claims its tag where it has
   none of its own (design 10.2). *)
and record_specifier state kind ~alone ~claimed_by =
  let leading = attributes state in
  let tag_name = optional_identifier state in
  let has_body = peek state = Punctuator_token P.Left_brace in
  if has_body then refuse_generic_body state ~tag_name;
  let declares = has_body || ends_alone state ~alone in
  let tag = Option.map (fun name -> bound_tag state name ~declares) tag_name in
  if tag = None then Option.iter (claim_own_tag state) claimed_by;
  let body_start = state.position in
  let members =
    if accept state P.Left_brace then
      Some (finish state body_start (member_declarations state))
    else None
  in
  if tag = None && members = None then
    fail_expected state "a tag or `{` after `struct` or `union`";
  let trailing = if members = None then [] else attributes state in
  ({ kind; attributes = leading @ trailing; tag; members } : record_specifier)

(* After the [{]: the member declarations, which GNU C allows to be none
   and to have a [;] alone among them, and the [}]. *)
and member_declarations state =
  let rec loop members =
    if accept state P.Right_brace then List.rev members
    else if accept state P.Semicolon then loop members
    else loop (member_declaration state :: members)
  in
  loop []

and member_declaration state =
  let start = state.position in
  skip_extensions state;
  if accept_keyword state Keyword.Static_assert then
    finish state start (Member_static_assert (static_assertion state))
  else
    let leading = leading_attributes state in
    let specifiers = leading @ specifiers state Specifier_qualifiers in
    if specifiers = [] then fail_expected state "a member declaration";
    let declarators =
      if peek state = Punctuator_token P.Semicolon then []
      else member_declarators state
    in
    refuse_parameter_bit_field state specifiers declarators;
    expect state P.Semicolon "`;` after a member declaration";
    finish state start (Members { specifiers; declarators })

and member_declarators state =
  let rec loop declarators =
    let declarators = member_declarator state :: declarators in
    if accept state P.Comma then loop declarators else List.rev declarators
  in
  loop []

and member_declarator state =
  let start = state.position in
  let bit_field declarator =
    let width = constant_expression state in
    let attributes = attributes state in
    finish state start (Bit_field { declarator; width; attributes })
  in
  if accept state P.Colon then bit_field None
  else
    let declarator = member_name_declarator state in
    if accept state P.Colon then bit_field (Some declarator)
    else
      let attributes = attributes state in
      finish state start (Field { declarator; attributes })

(* A [:] after the tag is a fixed underlying type where a type name
   follows it; in a member declaration, where an expression follows it,
   it begins the width of a bit-field. Alone in its declaration, only an
   enumeration with a fixed type declares its tag (C23 6.7.2.3); C11's
   [enum e;] names the visible tag (6.7.2.3p9), as GCC reads it, where
   Clang declares a new one. *)
and enum_specifier state ~alone =
  let leading = attributes state in
  let tag_name = optional_identifier state in
  let underlying =
    if
      peek state = Punctuator_token P.Colon && starts_type_name state 1
    then begin
      advance state;
      match specifiers state Enumeration_type with
      | [] -> fail_expected state "an integer type after `:`"
      | list -> Some list
    end
    else None
  in
  let after_type = if underlying = None then [] else attributes state in
  let has_body = peek state = Punctuator_token P.Left_brace in
  if has_body then refuse_generic_enumerators state;
  let declares = has_body || (underlying <> None && ends_alone state ~alone) in
  let tag = Option.map (fun name -> bound_tag state name ~declares) tag_name in
  let enumerators =
    if accept state P.Left_brace then Some (enumerators state) else None
  in
  if tag = None && enumerators = None then
    fail_expected state "a tag or `{` after `enum`";
  let trailing = if enumerators = None then [] else attributes state in
  Enum
    {
      attributes = leading @ after_type @ trailing;
      tag;
      underlying;
      enumerators;
    }

(* After the [{]: at least one enumerator, an optional [,] and the [}]. *)
and enumerators state =
  let rec loop enumerators =
    let enumerators = enumerator state :: enumerators in
    if accept state P.Right_brace then List.rev enumerators
    else begin
      expect state P.Comma "`,` or `}` after an enumerator";
      if accept state P.Right_brace then List.rev enumerators
      else loop enumerators
    end
  in
  loop []

(* An enumeration constant is in scope from the end of its enumerator
   (6.2.1p7). *)
and enumerator state =
  let start = state.position in
  let name = identifier state "an enumerator" in
  let attributes = attributes state in
  let value =
    if accept state P.Equal then Some (constant_expression state) else None
  in
  let declared = declare state ~kind:Not_a_type name in
  finish state start { name; declared; attributes; value }

(* After the [_Static_assert]. *)
and static_assertion state =
  expect state P.Left_paren "`(` after `_Static_assert`";
  let condition = constant_expression state in
  expect state P.Comma "`,` after the condition of `_Static_assert`";
  let message = string_literal state in
  expect state P.Right_paren "`)` after the message of `_Static_assert`";
  expect state P.Semicolon "`;` after `_Static_assert`";
  { condition; message }

and type_name state =
  let start = state.position in
  let specifiers = specifiers state Specifier_qualifiers in
  if specifiers = [] then fail_expected state "a type name";
  let abstract = declarator state Abstract in
  finish state start { specifier_qualifiers = specifiers; abstract }

(* [(] type-name [)]. *)
and parenthesized_type_name state =
  expect state P.Left_paren "`(`";
  let type_name = type_name state in
  expect state P.Right_paren "`)` after a type name";
  type_name

(* Declarators. *)

(* A member's declarator, which declares nothing in scope: every other
   named declarator is read by [scoped_declarator], which declares it. *)
and member_name_declarator state =
  fst (named_declarator_and_function state)

(* The identifier of a declarator read [Named], which always has one. *)
and named_identifier state declarator =
  match declared_identifier declarator with
  | Some name -> name
  | None -> fail_expected state "a declarator"

and named_declarator_and_function state =
  match declarator_and_function state Named with
  | Some declarator, named_function -> (declarator, named_function)
  | None, _ -> fail_expected state "a declarator"

and declarator state form = fst (declarator_and_function state form)

(* A declarator, None where an abstract one is empty, and its
   {!named_function} if a function derivation applies to its name. The
   leftmost [*] or [^] is the outermost node (6.7.6.1). *)
and declarator_and_function state form =
  let rec pointers innermost_first =
    let start = state.position in
    match peek state with
    | Punctuator_token P.Star ->
        advance state;
        let qualifiers, attributes = pointer_qualifiers state in
        let pointer inner = Pointer { qualifiers; attributes; inner } in
        pointers ((start, pointer) :: innermost_first)
    | Punctuator_token P.Caret ->
        advance state;
        let qualifiers, attributes = pointer_qualifiers state in
        let block_pointer inner =
          Block_pointer { qualifiers; attributes; inner }
        in
        pointers ((start, block_pointer) :: innermost_first)
    | _ -> innermost_first
  in
  let innermost_first = pointers [] in
  let direct, named_function = direct_declarator state form in
  let derive inner (start, pointer) =
    Some (finish state start (pointer inner))
  in
  (List.fold_left derive direct innermost_first, named_function)

and direct_declarator state form =
  let start = state.position in
  let base, named_function =
    match peek state with
    | Identifier_token name when form <> Abstract ->
        advance state;
        (Some (finish state start (Name name)), None)
    | Punctuator_token P.Left_paren when opens_nested_declarator state form ->
        advance state;
        let attributes = attributes state in
        let inner, named_function =
          match declarator_and_function state form with
          | Some inner, named_function -> (inner, named_function)
          | None, _ -> fail_expected state "a declarator"
        in
        expect state P.Right_paren "`)` after a declarator";
        let parenthesized = Parenthesized_declarator { attributes; inner } in
        (Some (finish state start parenthesized), named_function)
    | _ -> (None, None)
  in
  if form = Named && base = None then fail_expected state "a declarator";
  declarator_suffixes state form start base named_function

(* The array and function suffixes, the leftmost innermost. Only the
   first can apply to the name. *)
and declarator_suffixes state form start inner named_function =
  match peek state with
  | Punctuator_token P.Left_bracket ->
      advance state;
      let qualifiers, size = array_suffix state in
      let array = Array { inner; qualifiers; size } in
      declarator_suffixes state form start
        (Some (finish state start array))
        named_function
  | Punctuator_token P.Left_paren ->
      advance state;
      let parameters, parameter_scope =
        run_in_scope state (inner_scope state) (fun () ->
            parameters state form)
      in
      let function_ = Function { inner; parameters } in
      let named_function =
        match inner with
        | Some inner when is_name inner -> Some { parameters; parameter_scope }
        | Some _ | None -> named_function
      in
      declarator_suffixes state form start
        (Some (finish state start function_))
        named_function
  | _ -> (inner, named_function)

(* After the [[], up to and including the []] (6.7.6.2). *)
and array_suffix state =
  let leading_static = accept_keyword state Keyword.Static in
  let qualifiers = type_qualifiers state in
  let size =
    if leading_static then Static_sized (assignment_expression state)
    else if qualifiers <> [] && accept_keyword state Keyword.Static then
      Static_sized (assignment_expression state)
    else if
      peek state = Punctuator_token P.Star
      && peek_at state 1 = Punctuator_token P.Right_bracket
    then begin
      advance state;
      Unspecified_variable
    end
    else if peek state = Punctuator_token P.Right_bracket then Unsized
    else Sized (assignment_expression state)
  in
  expect state P.Right_bracket "`]` after an array size";
  (qualifiers, size)

(* After the [(], up to and including the [)], in the prototype scope
   that the caller opens (6.2.1p4). An identifier list belongs to a
   declarator with a name. A [...] alone is C23's, which Clang accepts
   and the SDK's [tgmath.h] uses. *)
and parameters state form =
  if accept state P.Right_paren then Identifier_list []
  else if accept state P.Ellipsis then begin
    expect state P.Right_paren "`)` after `...`";
    Prototype { parameters = []; variadic = true }
  end
  else if starts_declaration state 0 then begin
    let parameters, variadic = parameter_list state in
    expect state P.Right_paren "`,` or `)` after a parameter";
    Prototype { parameters; variadic }
  end
  else if form <> Abstract && is_identifier (peek state) then begin
    let identifiers = identifier_list state in
    expect state P.Right_paren "`,` or `)` after a parameter name";
    Identifier_list identifiers
  end
  else fail_expected state "a parameter declaration"

and parameter_list state =
  let rec loop parameters =
    let parameters = parameter state :: parameters in
    if accept state P.Comma then
      if accept state P.Ellipsis then (List.rev parameters, true)
      else loop parameters
    else (List.rev parameters, false)
  in
  loop []

and parameter state =
  let start = state.position in
  let specifiers = specifiers state Declaration_specifiers in
  if specifiers = [] then fail_expected state "a parameter declaration";
  let declarator = declarator state Named_or_abstract in
  let attributes = attributes state in
  let declarator = parameter_declarator state declarator in
  finish state start ({ specifiers; declarator; attributes } : parameter_node)

(* A parameter with a name declares it, after its attributes. *)
and parameter_declarator state = function
  | None -> Abstract_parameter None
  | Some declarator -> (
      match declared_identifier declarator with
      | Some name ->
          let declared = declare state ~kind:Not_a_type name in
          Named_parameter { declarator; declared }
      | None -> Abstract_parameter (Some declarator))

(* A typedef name is refused in an identifier list: it would begin a
   parameter declaration. *)
and identifier_list state =
  let rec loop identifiers =
    (match peek state with
    | Identifier_token name when is_typedef_name state name ->
        fail_type_name state "a parameter name" name
    | _ -> ());
    let name = identifier state "a parameter name" in
    let declared = declare state ~kind:Not_a_type name in
    let identifiers = { name; declared } :: identifiers in
    if accept state P.Comma then loop identifiers else List.rev identifiers
  in
  loop []

(* Initialisers. *)

and initialiser state =
  if peek state = Punctuator_token P.Left_brace then
    Braced (initialiser_list state)
  else Expression_initialiser (assignment_expression state)

(* From the [{] to the [}]: values, which GNU C allows to be none, and an
   optional [,] after the last. *)
and initialiser_list state =
  let start = state.position in
  expect state P.Left_brace "`{`";
  let rec loop values =
    let values = designated_initialiser state :: values in
    if accept state P.Right_brace then List.rev values
    else begin
      expect state P.Comma "`,` or `}` in an initialiser list";
      if accept state P.Right_brace then List.rev values else loop values
    end
  in
  let values = if accept state P.Right_brace then [] else loop [] in
  finish state start values

and designated_initialiser state =
  let start = state.position in
  let designators =
    if begins_obsolete_designator state then [ obsolete_designator state ]
    else begin
      let designators = designators state in
      if designators <> [] then expect state P.Equal "`=` after a designator";
      designators
    end
  in
  let initialiser = initialiser state in
  finish state start { designators; initialiser }

(* GNU's obsolete [member:], which means [.member =] (GCC manual,
   "Designated Initializers"). The member's name may also be a typedef
   name, as members have a name space of their own. *)
and begins_obsolete_designator state =
  match peek state with
  | Identifier_token _ ->
      peek_at state 1 = Punctuator_token P.Colon
  | Keyword_token _ | Punctuator_token _ | Number_token | Character_token _
  | String_token _ | End_of_input ->
      false

and obsolete_designator state =
  let start = state.position in
  let member = identifier state "a member name" in
  expect state P.Colon "`:` after a member name";
  finish state start (Member_designator member)

(* Any number of designators in a row. *)
and designators state =
  let rec loop reversed =
    match peek state with
    | Punctuator_token (P.Left_bracket | P.Dot) ->
        loop (designator state :: reversed)
    | _ -> List.rev reversed
  in
  loop []

and designator state =
  let start = state.position in
  if accept state P.Dot then
    let member = identifier state "a member name after `.`" in
    finish state start (Member_designator member)
  else begin
    expect state P.Left_bracket "`[` or `.`";
    let index = constant_expression state in
    let node =
      if accept state P.Ellipsis then
        let high = constant_expression state in
        Index_range { low = index; high }
      else Index index
    in
    expect state P.Right_bracket "`]` after a designator";
    finish state start node
  end

(* Expressions (C11 6.5). *)

and expression state =
  let start = state.position in
  let rec loop left =
    if accept state P.Comma then
      let right = assignment_expression state in
      loop (finish state start (Comma (left, right)))
    else left
  in
  loop (assignment_expression state)

and constant_expression state = conditional_expression state

(* Assignment is right-associative: the targets are collected in a loop
   and the nodes made from the right. *)
and assignment_expression state =
  let rec collect targets =
    let start = state.position in
    let operand = conditional_expression state in
    match assignment_operator (peek state) with
    | Some operator when is_unary_expression operand ->
        advance state;
        collect ((start, operator, operand) :: targets)
    | Some _ ->
        fail state
          (Rule.c_text
             (Printf.sprintf "the left operand of %s is not a unary expression"
                (found state)))
    | None -> (operand, targets)
  in
  let value, targets = collect [] in
  List.fold_left
    (fun right (start, operator, left) ->
      finish state start (Assignment (operator, left, right)))
    value targets

(* Right-associative like assignment: [a ? b : c ? d : e] groups as
   [a ? b : (c ? d : e)]. GNU [a ?: b] omits the middle operand. *)
and conditional_expression state =
  let rec collect branches =
    let start = state.position in
    let condition = binary_expression state lowest_precedence in
    if accept state P.Question then begin
      let if_true = middle_operand state in
      expect state P.Colon "`:` in a conditional expression";
      collect ((start, condition, if_true) :: branches)
    end
    else (condition, branches)
  in
  let last, branches = collect [] in
  List.fold_left
    (fun if_false (start, condition, if_true) ->
      finish state start (Conditional { condition; if_true; if_false }))
    last branches

and middle_operand state =
  if peek state = Punctuator_token P.Colon then None
  else Some (expression state)

(* Precedence climbing. Each recursive call has a higher [minimum] than
   its caller, so the recursion is at most as deep as there are
   precedences. *)
and binary_expression state minimum =
  let start = state.position in
  let rec loop left =
    match binary_operator (peek state) with
    | Some (operator, precedence) when precedence >= minimum ->
        advance state;
        let right = binary_expression state (precedence + 1) in
        loop (finish state start (Binary (operator, left, right)))
    | Some _ | None -> left
  in
  loop (cast_expression state)

(* A cast-expression (6.5.4) is read as a loop over its prefixes (casts,
   unary operators, [++], [--], [sizeof] and [_Alignof]) up to the
   operand they apply to, and the nodes are made from the innermost
   prefix out. After [++], [--], [sizeof] and [_Alignof] comes a
   unary-expression, where [(] type-name [)] can only begin a compound
   literal; GNU [__extension__] makes no node and takes a
   cast-expression. GNU [&&] label is a whole unary-expression. *)
and cast_expression state =
  let rec collect prefixes ~cast_allowed =
    let start = state.position in
    match peek state with
    | Keyword_token Keyword.Extension ->
        advance state;
        collect prefixes ~cast_allowed:true
    | Punctuator_token P.Left_paren when opens_type_name_at state 0 ->
        let type_name = parenthesized_type_name state in
        if peek state = Punctuator_token P.Left_brace then
          (prefixes, compound_literal state start type_name)
        else if cast_allowed then
          let cast operand = Cast { type_name; operand } in
          collect ((start, cast) :: prefixes) ~cast_allowed:true
        else fail_expected state "`{` of a compound literal"
    | Punctuator_token P.Plus_plus ->
        advance state;
        let increment operand = Unary (Pre_increment, operand) in
        collect ((start, increment) :: prefixes) ~cast_allowed:false
    | Punctuator_token P.Minus_minus ->
        advance state;
        let decrement operand = Unary (Pre_decrement, operand) in
        collect ((start, decrement) :: prefixes) ~cast_allowed:false
    | Punctuator_token P.Ampersand_ampersand ->
        advance state;
        let name = identifier state "a label after `&&`" in
        let label = address_label state start name in
        (prefixes, finish state start (Label_address label))
    | lexeme -> (
        match (unary_operator lexeme, measure_operator lexeme) with
        | Some operator, _ ->
            advance state;
            let apply operand = Unary (operator, operand) in
            collect ((start, apply) :: prefixes) ~cast_allowed:true
        | None, Some measure ->
            advance state;
            measured prefixes start measure
        | None, None -> (prefixes, postfix_expression state))
  (* After [sizeof] or [_Alignof]: a type name in parentheses or a
     unary-expression, which is a compound literal where a [{] follows
     the type name. *)
  and measured prefixes start (of_expression, of_type) =
    if opens_type_name_at state 0 then begin
      let operand_start = state.position in
      let type_name = parenthesized_type_name state in
      if peek state = Punctuator_token P.Left_brace then
        ( (start, of_expression) :: prefixes,
          compound_literal state operand_start type_name )
      else (prefixes, finish state start (of_type type_name))
    end
    else collect ((start, of_expression) :: prefixes) ~cast_allowed:false
  in
  let prefixes, operand = collect [] ~cast_allowed:true in
  List.fold_left
    (fun operand (start, prefix) -> finish state start (prefix operand))
    operand prefixes

and postfix_expression state =
  let start = state.position in
  postfix_operators state start (primary_expression state)

(* At the [{] after [(] type-name [)] (6.5.2.5): the literal and the
   postfix operators after it. *)
and compound_literal state start type_name =
  let values = initialiser_list state in
  let literal = finish state start (Compound_literal { type_name; values }) in
  postfix_operators state start literal

and postfix_operators state start operand =
  let continue_with node =
    postfix_operators state start (finish state start node)
  in
  match peek state with
  | Punctuator_token P.Left_bracket ->
      advance state;
      let index = expression state in
      expect state P.Right_bracket "`]` after a subscript";
      continue_with (Subscript { operand; index })
  | Punctuator_token P.Left_paren ->
      advance state;
      let arguments = arguments state in
      continue_with (Call { callee = operand; arguments })
  | Punctuator_token P.Dot ->
      advance state;
      let member = identifier state "a member name after `.`" in
      continue_with (Member { operand; member })
  | Punctuator_token P.Arrow ->
      advance state;
      let member = identifier state "a member name after `->`" in
      continue_with (Pointer_member { operand; member })
  | Punctuator_token P.Plus_plus ->
      advance state;
      continue_with (Post_increment operand)
  | Punctuator_token P.Minus_minus ->
      advance state;
      continue_with (Post_decrement operand)
  | _ -> operand

(* At the type name of [T.C]: the constructor, and the postfix operators
   after it, such as the arguments of [T.C(...)]. *)
and qualified_constructor state name ordinary =
  let start = state.position in
  advance state;
  let at = first_token state start in
  let specifier =
    finish state start (Type_specifier (named_type state name ordinary ~at))
  in
  let variant =
    finish state start { specifier_qualifiers = [ specifier ]; abstract = None }
  in
  expect state P.Dot "`.` after the type name";
  let constructor = identifier state "a constructor name after `.`" in
  let named =
    finish state start (Qualified_constructor { variant; constructor })
  in
  postfix_operators state start named

(* After the [(] of a call, up to and including the [)]. *)
and arguments state =
  if accept state P.Right_paren then []
  else
    let rec loop arguments =
      let arguments = assignment_expression state :: arguments in
      if accept state P.Comma then loop arguments
      else begin
        expect state P.Right_paren "`,` or `)` after an argument";
        List.rev arguments
      end
    in
    loop []

(* At an identifier where an expression begins. *)
and name_operand state name =
  let start = state.position in
  let resolution = resolve state name in
  advance state;
  finish state start (Identifier { name; resolution })

(* At a typedef name where an expression begins, which C's grammar has
   not taken as beginning a type name. In Type-C text it is the variant
   of a qualified constructor before [.], and otherwise a name that
   typing reads as an unqualified constructor where the target type has
   one and refuses elsewhere (design 3.3). C text has no constructors,
   and a type's own definition has no target type that could have one.
   A generic type has constructors only in an application, which
   begins a type name. *)
and typedef_name_operand state name (ordinary : ordinary) =
  let at = state.grammar.(state.position).index in
  match ordinary.kind with
  | Declared_type { stage = Defining; _ } -> fail_own_name state ~at name
  | _ when begins_qualified_constructor state 0 ordinary ->
      qualified_constructor state name ordinary
  | kind when is_generic kind ->
      if peek_at state 1 = Punctuator_token P.Left_paren then
        fail_type_name state "an expression" name
      else fail_bare_generic state ~at name
  | _ when is_type_c_text_at state at -> name_operand state name
  | _ -> fail_type_name state "an expression" name

and primary_expression state =
  let start = state.position in
  match peek state with
  | Identifier_token name -> (
      match typedef_declaration state name with
      | Some ordinary -> typedef_name_operand state name ordinary
      | None -> name_operand state name)
  | Number_token -> (
      match Number.classify (next_spelling state) with
      | Number.Not_a_constant ->
          fail state
            (Rule.c_text
               (Printf.sprintf
                  "expected a constant, found the preprocessing number %s"
                  (found state)))
      | constant ->
          advance state;
          finish state start (Constant constant))
  | Character_token encoding ->
      advance state;
      finish state start (Character encoding)
  | String_token _ ->
      let pieces = string_literal state in
      finish state start (String pieces)
  | Punctuator_token P.Left_paren
    when peek_at state 1 = Punctuator_token P.Left_brace ->
      advance state;
      let body = block state in
      expect state P.Right_paren "`)` after a statement expression";
      finish state start (Statement_expression body)
  | Punctuator_token P.Left_paren ->
      advance state;
      let inner = expression state in
      expect state P.Right_paren "`)` after an expression";
      finish state start (Parenthesized inner)
  | Keyword_token Keyword.Generic ->
      advance state;
      generic_selection state start
  | Keyword_token Keyword.Builtin_va_arg ->
      advance state;
      va_arg state start
  | Keyword_token Keyword.Builtin_offsetof ->
      advance state;
      offsetof state start
  | Keyword_token Keyword.Builtin_types_compatible_p ->
      advance state;
      types_compatible state start
  | Keyword_token Keyword.Builtin_choose_expr ->
      advance state;
      choose state start
  | Punctuator_token P.Caret ->
      advance state;
      block_literal state start
  | Keyword_token Keyword.Defer -> fail_defer state
  | _ -> fail_expected state "an expression"

(* After the [__builtin_va_arg]. *)
and va_arg state start =
  expect state P.Left_paren "`(` after `__builtin_va_arg`";
  let list = assignment_expression state in
  expect state P.Comma "`,` after the list of `__builtin_va_arg`";
  let type_name = type_name state in
  expect state P.Right_paren "`)` after the type name of `__builtin_va_arg`";
  finish state start (Va_arg { list; type_name })

(* After the [__builtin_offsetof]. *)
and offsetof state start =
  expect state P.Left_paren "`(` after `__builtin_offsetof`";
  let type_name = type_name state in
  expect state P.Comma "`,` after the type name of `__builtin_offsetof`";
  let member = identifier state "a member name" in
  let designators = designators state in
  expect state P.Right_paren "`)` after the member of `__builtin_offsetof`";
  finish state start (Offsetof { type_name; member; designators })

(* After the [__builtin_types_compatible_p]. *)
and types_compatible state start =
  let builtin = "`__builtin_types_compatible_p`" in
  expect state P.Left_paren ("`(` after " ^ builtin);
  let first = type_name state in
  expect state P.Comma ("`,` after the first type name of " ^ builtin);
  let second = type_name state in
  expect state P.Right_paren ("`)` after the type names of " ^ builtin);
  finish state start (Types_compatible (first, second))

(* After the [__builtin_choose_expr]. *)
and choose state start =
  let builtin = "`__builtin_choose_expr`" in
  expect state P.Left_paren ("`(` after " ^ builtin);
  let condition = assignment_expression state in
  expect state P.Comma ("`,` after the condition of " ^ builtin);
  let first = assignment_expression state in
  expect state P.Comma ("`,` after the second operand of " ^ builtin);
  let second = assignment_expression state in
  expect state P.Right_paren ("`)` after the operands of " ^ builtin);
  finish state start (Choose { condition; first; second })

(* After the [^]: the body, after the parameters if it has them. The
   body continues their scope, as a function's does (6.2.1p4). *)
and block_literal state start =
  (* The literal is a function of its own, from its parameters to the end
     of its body. *)
  let literal = as_function state (fun () -> literal_after_caret state start) in
  refuse_type_c_text_in_block state start;
  literal

and literal_after_caret state start =
  match peek state with
  | Punctuator_token P.Left_brace ->
      let body = block state in
      finish state start (Block_literal { parameters = None; body })
  | Punctuator_token P.Left_paren ->
      advance state;
      (* Clang takes no identifier list here, which [Abstract] refuses. *)
      let parameters, parameter_scope =
        run_in_scope state (inner_scope state) (fun () ->
            parameters state Abstract)
      in
      if peek state <> Punctuator_token P.Left_brace then
        fail_expected state "`{` of a block literal";
      let body =
        in_scope state (reentered_scope state ~inner:parameter_scope)
          (fun () -> compound_statement state)
      in
      finish state start
        (Block_literal { parameters = Some parameters; body })
  | _ -> fail_expected state "`{` or `(` after `^`"

(* After the [_Generic] (6.5.1.1). *)
and generic_selection state start =
  expect state P.Left_paren "`(` after `_Generic`";
  let controlling = assignment_expression state in
  expect state P.Comma "`,` after the controlling expression of `_Generic`";
  let rec loop associations =
    let associations = generic_association state :: associations in
    if accept state P.Comma then loop associations else List.rev associations
  in
  let associations = loop [] in
  expect state P.Right_paren "`,` or `)` after a generic association";
  finish state start (Generic { controlling; associations })

and generic_association state =
  let start = state.position in
  if accept_keyword state Keyword.Default then begin
    expect state P.Colon "`:` after `default`";
    let value = assignment_expression state in
    finish state start (Default_association value)
  end
  else
    let type_name = type_name state in
    expect state P.Colon "`:` after the type name of a generic association";
    let value = assignment_expression state in
    finish state start (Association (type_name, value))

(* Declarations (C11 6.7). *)

(* The only way the parser reads the declarator of a declaration, so
   that each one enters scope at the same point. GNU attributes may come
   before a declarator after the first; before the first, the specifiers
   hold them. *)
and scoped_declarator state specifiers =
  let declarator_start = state.position in
  let leading = attributes state in
  let declarator, named_function = named_declarator_and_function state in
  let asm_label = asm_label state in
  let trailing = attributes state in
  let declared =
    declare state
      ~kind:(declared_kind specifiers)
      (named_identifier state declarator)
  in
  {
    declarator_start;
    declarator;
    declared;
    named_function;
    asm_label;
    attributes = leading @ trailing;
  }

and init_declarator state scoped =
  let initialiser =
    if accept state P.Equal then Some (initialiser state) else None
  in
  finish state scoped.declarator_start
    ({
       declarator = scoped.declarator;
       declared = scoped.declared;
       asm_label = scoped.asm_label;
       attributes = scoped.attributes;
       initialiser;
     }
      : init_declarator_node)

and declaration_start state =
  let start = state.position in
  skip_extensions state;
  if accept_keyword state Keyword.Static_assert then
    Complete (finish state start (Static_assert (static_assertion state)))
  else begin
    let specifiers = specifiers state Declaration_specifiers in
    if specifiers = [] then refuse_declaration state;
    if accept state P.Semicolon then
      Complete
        (finish state start (Declaration { specifiers; declarators = [] }))
    else
      let first = scoped_declarator state specifiers in
      First_declarator { start; specifiers; first }
  end

and declaration state = declaration_of_start state (declaration_start state)

(* The declaration that [declaration_start] began: the first declarator's
   initialiser and the declarators after it. *)
and declaration_of_start state = function
  | Complete declaration -> declaration
  | First_declarator { start; specifiers; first } ->
      let next_declarator () =
        init_declarator state (scoped_declarator state specifiers)
      in
      let rec loop declarators =
        if accept state P.Comma then loop (next_declarator () :: declarators)
        else List.rev declarators
      in
      let declarators = loop [ init_declarator state first ] in
      expect state P.Semicolon "`;` after a declaration";
      finish state start (Declaration { specifiers; declarators })

(* At the [type] that [begins_type_declaration] recognises. *)
and type_declaration state : type_declaration =
  let start = state.position in
  let type_keyword = state.grammar.(start).index in
  advance state;
  let name =
    checked_type_name state (identifier state "the name of a type declaration")
  in
  let head =
    if peek state = Punctuator_token P.Left_paren then
      Some (generic_head state name)
    else None
  in
  let declared, definition =
    if accept state P.Semicolon then incomplete_variant state name head
    else begin
      expect state P.Equal "`=` or `;` after the name of a type declaration";
      let declared_definition = type_definition state name head ~type_keyword in
      expect state P.Semicolon "`;` after a type declaration";
      declared_definition
    end
  in
  let type_parameters =
    match head with Some head -> head.parameter_names | None -> []
  in
  finish state start
    ({ name; type_parameters; declared; definition } : type_declaration_node)

and incomplete_variant state checked head =
  let name = (checked :> identifier) in
  let parameters = type_parameter_count head in
  let kind = declared_type ~parameters Awaiting_variant in
  let declared = declare state ~kind name in
  if Option.is_none head then claim_own_tag state name;
  (declared, Incomplete_variant)

(* After the [=]: the declaration of [checked], which is in scope from
   the end of its identifier, and the definition, which the type
   parameters of [head] are visible in. A generic type claims no name
   (design 10.3). *)
and type_definition state checked head ~type_keyword =
  let name = (checked :> identifier) in
  let parameters = type_parameter_count head in
  let generic = Option.is_some head in
  let definition_part ~bodies_allowed parse =
    in_definition state head ~bodies_allowed parse
  in
  let is_private, form =
    definition_part ~bodies_allowed:false (fun () ->
        let is_private = accept_private state in
        (is_private, definition_form state))
  in
  match form with
  | Variant_form ->
      let declared = declare_variant state checked ~type_keyword ~parameters in
      let names = claim_enumerators state ~variant:checked ~generic in
      let constructors =
        definition_part ~bodies_allowed:true (fun () ->
            constructors state names)
      in
      (declared, Variant { is_private; constructors })
  | Record_form kind ->
      let kind_of_name = declared_type ~parameters Defined in
      let declared = declare state ~kind:kind_of_name name in
      let claimed_by = if generic then None else Some name in
      let specifier =
        definition_part ~bodies_allowed:true (fun () ->
            let start = state.position in
            advance state;
            finish state start
              (record_specifier state kind ~alone:false ~claimed_by))
      in
      (declared, Record_alias specifier)
  | Distinct_form ->
      advance state;
      let kind = declared_type ~parameters Defining in
      let declared = declare state ~kind name in
      let representation =
        definition_part ~bodies_allowed:false (fun () ->
            let representation = type_name state in
            refuse_distinct_parameter state representation;
            representation)
      in
      end_definition state name declared ~parameters;
      (declared, Distinct { is_private; representation })
  | Alias_form ->
      let kind = declared_type ~parameters Defining in
      let declared = declare state ~kind name in
      let type_name =
        definition_part ~bodies_allowed:false (fun () -> type_name state)
      in
      end_definition state name declared ~parameters;
      (declared, Alias type_name)

(* The constructors of a variant, each after a [|], with the [names]
   that {!claim_enumerators} read ahead. Those end at the first [|] with
   no identifier after it, where the grammar fails. *)
and constructors state names =
  let rec loop names constructors =
    match names with
    | name :: names -> loop names (constructor state name :: constructors)
    | [] -> List.rev constructors
  in
  let constructors = loop names [] in
  if peek state = Punctuator_token P.Pipe then begin
    advance state;
    fail_expected state "the name of a constructor"
  end;
  constructors

(* At the [|] before [name], which is the next token: the lookahead of
   [constructor_names] skips the fields as [fields] reads them, so the
   two agree on every token where the grammar has not failed. *)
and constructor state (ahead : constructor_ahead) =
  let start = state.position in
  advance state;
  let name_start = state.position in
  if first_token state name_start <> ahead.at then
    invalid_arg "Parser.constructor: the lookahead lost its constructor";
  advance state;
  let name = finish state name_start ahead.checked in
  let fields = if accept state P.Left_paren then fields state else [] in
  finish state start ({ name; fields } : constructor_node)

and fields state =
  let rec loop fields =
    let fields = field state :: fields in
    if accept state P.Comma then loop fields
    else begin
      expect state P.Right_paren "`,` or `)` after a field";
      List.rev fields
    end
  in
  loop []

and field state =
  let start = state.position in
  let specifiers = specifiers state Specifier_qualifiers in
  if specifiers = [] then fail_expected state "a field";
  let declarator = member_name_declarator state in
  refuse_reserved_field state (named_identifier state declarator);
  finish state start ({ specifiers; declarator } : field_node)

(* Statements (C11 6.8). *)

(* [(] expression [)] after the keyword [keyword]. *)
and controlling_expression state keyword =
  expect state P.Left_paren (Printf.sprintf "`(` after `%s`" keyword);
  let value = expression state in
  expect state P.Right_paren
    (Printf.sprintf "`)` after the controlling expression of `%s`" keyword);
  value

(* After [if] or [while]: the parenthesised condition, C's controlling
   expression read in the jump scope [controlling_jumps], or, after
   [case], a single-pattern test read in [test_jumps] (design 4.4, 4.6).
   The result makes the condition in the scope of the substatement,
   which the test's bindings begin, after its operand. *)
and condition state keyword ~controlling_jumps ~test_jumps =
  if peek_at state 1 = Keyword_token Keyword.Case then
    with_jumps state test_jumps (fun () -> pattern_test state keyword)
  else
    let value =
      with_jumps state controlling_jumps (fun () ->
          controlling_expression state keyword)
    in
    fun () -> Controlling value

(* [(] [case] pattern [=] operand [)] after [keyword]. *)
and pattern_test state keyword =
  expect state P.Left_paren (Printf.sprintf "`(` after `%s`" keyword);
  let start = state.position in
  advance state;
  let words = pattern_words state in
  let pattern_span = span_from state start in
  expect state P.Equal "`=` after the pattern of a single-pattern test";
  let operand = expression state in
  expect state P.Right_paren
    (Printf.sprintf "`)` after the operand of the test of `%s`" keyword);
  fun () ->
    Pattern_test
      { pattern_span; pattern = bound_pattern state words; operand }

(* The controlling expression of a [do] after [keyword], in the
   disputed scope of the loop [disputed]. *)
and loop_condition state keyword disputed =
  with_jumps state disputed (fun () -> controlling_expression state keyword)

(* An optional expression and the token [closing] after it. *)
and optional_expression state closing expected =
  if accept state closing then None
  else
    let value = expression state in
    expect state closing expected;
    Some value

(* After the [for]: the three clauses in their parentheses, the
   condition and step in the disputed scope of the loop [disputed]. *)
and for_clauses state disputed =
  expect state P.Left_paren "`(` after `for`";
  let clause =
    if accept state P.Semicolon then None
    else if begins_declaration state then
      Some (Clause_declaration (declaration state))
    else begin
      let value = expression state in
      expect state P.Semicolon "`;` after the first clause of `for`";
      Some (Clause_expression value)
    end
  in
  let condition =
    with_jumps state disputed (fun () ->
        optional_expression state P.Semicolon
          "`;` after the condition of `for`")
  in
  let step =
    with_jumps state disputed (fun () ->
        optional_expression state P.Right_paren
          "`)` after the clauses of `for`")
  in
  (clause, condition, step)

(* A label and its [:], where [begins_label] holds. *)
and label state =
  let start = state.position in
  let node =
    if accept_keyword state Keyword.Case then begin
      let value = constant_expression state in
      let node =
        if accept state P.Ellipsis then
          let high = constant_expression state in
          Case_range { low = value; high }
        else Case_label value
      in
      expect state P.Colon "`:` after the value of `case`";
      node
    end
    else if accept_keyword state Keyword.Default then begin
      expect state P.Colon "`:` after `default`";
      Default_label
    end
    else begin
      let name = identifier state "a label" in
      expect state P.Colon "`:` after a label";
      let label = define_label state name in
      let attributes = attributes state in
      Named_label { name = name.node; label; attributes }
    end
  in
  finish state start node

(* A statement is read in two loops: one over the statements that end in
   a substatement, which it keeps open innermost first, down to a
   statement that does not, and one that closes them from the innermost
   out. Only a compound statement recurses, inside the brace that the
   cursor counts, so a chain of [if], [else], loops and labels needs no
   stack: the calls between the loops are tail calls, which [@tailcall]
   keeps so. *)
and statement state = open_statements state []

and open_statements state opened =
  let start = state.position in
  let outer = state.scope in
  let outer_jumps = state.jumps in
  (* A selection or iteration statement is a block, which [read_head]
     reads in, and so is its substatement, read in [body_jumps]. What
     [read_head] returns makes the open statement in the scope of the
     substatement, where the bindings of a test begin (design 4.6). *)
  let open_block_statement ~body_jumps read_head =
    enter_scope state;
    let open_kind = read_head () in
    state.jumps <- body_jumps;
    enter_scope state;
    let kind = open_kind () in
    (open_statements [@tailcall]) state
      ({ start; outer = Some outer; outer_jumps; kind } :: opened)
  in
  (* Called only in a branch where [peek] has matched a keyword at
     [start], which is then a token. *)
  let target () = target_at state start in
  let disputed () = disputed_scope state start outer_jumps in
  match peek state with
  | _ when begins_label state ->
      let label = label state in
      (open_statements [@tailcall]) state
        ({ start; outer = None; outer_jumps; kind = Open_labeled label }
        :: opened)
  | Keyword_token Keyword.If ->
      advance state;
      open_block_statement ~body_jumps:outer_jumps (fun () ->
          let condition =
            condition state "if" ~controlling_jumps:outer_jumps
              ~test_jumps:outer_jumps
          in
          let statement_scope = state.scope in
          fun () -> Open_if { condition = condition (); statement_scope })
  | Keyword_token Keyword.Switch ->
      advance state;
      open_block_statement
        ~body_jumps:
          (Switch_or_match { target = target (); around = outer_jumps })
        (fun () ->
          let controlling = controlling_expression state "switch" in
          fun () -> Open_switch controlling)
  | Keyword_token Keyword.While ->
      advance state;
      open_block_statement ~body_jumps:(Loop (target ())) (fun () ->
          let condition =
            condition state "while" ~controlling_jumps:(disputed ())
              ~test_jumps:(Loop (target ()))
          in
          fun () -> Open_while (condition ()))
  | Keyword_token Keyword.Do ->
      advance state;
      open_block_statement ~body_jumps:(Loop (target ())) (fun () ->
          let statement_scope = state.scope in
          fun () -> Open_do { statement_scope })
  | Keyword_token Keyword.For ->
      advance state;
      open_block_statement ~body_jumps:(Loop (target ())) (fun () ->
          let clause, condition, step = for_clauses state (disputed ()) in
          fun () -> Open_for { clause; condition; step })
  | Punctuator_token P.Left_brace when binds_substatement opened ->
      let body = compound_statement state in
      (close_statements [@tailcall]) state opened
        (spanned state body.span (Compound body))
  | _ ->
      let statement = simple_statement state in
      (close_statements [@tailcall]) state opened statement

(* Whether the substatement about to be read is the statement of a
   single-pattern test, whose bindings and compound statement are one
   block scope (design 4.6 rule 4). *)
and binds_substatement = function
  | { kind = Open_if { condition = Pattern_test _; _ }; _ } :: _
  | { kind = Open_while (Pattern_test _); _ } :: _ ->
      true
  | _ -> false

(* [statement] has been read: it is the substatement of the innermost
   open statement. Closing a statement restores the scope around it. *)
and close_statements state opened statement =
  match opened with
  | [] -> statement
  | innermost :: outside -> (
      match close_one state innermost statement with
      | Reopened kind ->
          (open_statements [@tailcall]) state
            ({ innermost with kind } :: outside)
      | Closed node ->
          Option.iter (fun outer -> state.scope <- outer) innermost.outer;
          state.jumps <- innermost.outer_jumps;
          (close_statements [@tailcall]) state outside
            (finish state innermost.start node))

(* The rest of [opened] after its substatement [statement]. The scope of
   the substatement ends with it. *)
and close_one state opened statement =
  match opened.kind with
  | Open_labeled label -> Closed (Labeled { label; statement })
  | Open_if { condition; statement_scope } ->
      state.scope <- statement_scope;
      if accept_keyword state Keyword.Else then begin
        enter_scope state;
        Reopened (Open_else { condition; then_branch = statement })
      end
      else
        Closed (If { condition; then_branch = statement; else_branch = None })
  | Open_else { condition; then_branch } ->
      Closed (If { condition; then_branch; else_branch = Some statement })
  | Open_switch controlling -> Closed (Switch { controlling; body = statement })
  | Open_while condition -> Closed (While { condition; body = statement })
  | Open_do { statement_scope } ->
      state.scope <- statement_scope;
      if not (accept_keyword state Keyword.While) then
        fail_expected state "`while` after the body of `do`";
      let condition =
        loop_condition state "while"
          (disputed_scope state opened.start opened.outer_jumps)
      in
      expect state P.Semicolon "`;` after `do` ... `while`";
      Closed (Do { body = statement; condition })
  | Open_for { clause; condition; step } ->
      Closed (For { clause; condition; step; body = statement })

(* C23 attributes before GNU ones, as GCC and Clang read them, then the
   [;]. *)
and attribute_statement state start =
  let standard = standard_attributes state in
  let attributes = standard @ attributes state in
  expect state P.Semicolon "`;` after the attributes of a statement";
  finish state start (Attribute_statement attributes)

(* A statement without a substatement. *)
and simple_statement state =
  let start = state.position in
  match peek state with
  | Punctuator_token P.Left_brace ->
      let body = block state in
      spanned state body.span (Compound body)
  | Punctuator_token P.Semicolon ->
      advance state;
      finish state start Null_statement
  | Keyword_token Keyword.Attribute ->
      attribute_statement state start
  | Punctuator_token P.Left_bracket when opens_standard_attributes state 0 ->
      attribute_statement state start
  | Keyword_token Keyword.Goto ->
      advance state;
      if accept state P.Star then begin
        let target = expression state in
        expect state P.Semicolon "`;` after `goto *`";
        finish state start (Computed_goto target)
      end
      else
        let name = identifier state "a label after `goto`" in
        let target = jump_label state name in
        expect state P.Semicolon "`;` after `goto`";
        finish state start (Goto target)
  | Keyword_token Keyword.Continue ->
      advance state;
      let loop = continue_target state start in
      expect state P.Semicolon "`;` after `continue`";
      finish state start (Continue { loop })
  | Keyword_token Keyword.Break ->
      advance state;
      let leaves = break_target state start in
      expect state P.Semicolon "`;` after `break`";
      finish state start (Break { leaves })
  | Keyword_token Keyword.Return ->
      advance state;
      let value =
        optional_expression state P.Semicolon "`;` after `return`"
      in
      finish state start (Return value)
  | Identifier_token _ when begins_match state -> match_statement state start
  | Keyword_token Keyword.Asm ->
      advance state;
      let assembler = assembler state in
      expect state P.Semicolon "`;` after `asm`";
      finish state start (Asm assembler)
  | _ ->
      let value = expression state in
      expect state P.Semicolon "`;` after an expression";
      finish state start (Expression_statement value)

(* Design 4.1, Appendix A: at the [match] that [begins_match]
   recognises. The whole statement is a block, as a [switch] is (C11
   6.8.4p3) and as its lowering is, so what the scrutinee declares ends
   with it. *)
and match_statement state start =
  in_scope state (inner_scope state) (fun () ->
      advance state;
      expect state P.Left_paren "`(` after `match`";
      let scrutinee = expression state in
      expect state P.Right_paren "`)` after the scrutinee of `match`";
      expect state P.Left_brace "`{` after the scrutinee of `match`";
      let matched = target_at state start in
      let rec loop arms =
        if begins_arm_label state then loop (arm state ~matched :: arms)
        else if arms <> [] && accept state P.Right_brace then List.rev arms
        else
          fail state
            (Rule.message Arm_form
               ("expected `case` or `default` to begin an arm of `match`, \
                 found " ^ found state))
      in
      let arm_jumps =
        Switch_or_match { target = matched; around = state.jumps }
      in
      let arms = with_jumps state arm_jumps (fun () -> loop []) in
      finish state start (Match { scrutinee; arms }))

and begins_arm_label state =
  match peek state with
  | Keyword_token (Keyword.Case | Keyword.Default) -> true
  | _ -> false

(* An arm of the match [matched] is a block of its own (design 4.1 rule
   5): its bindings and declarations end with it. Its breaks that leave
   the match end it (4.3 rule 5). *)
and arm state ~matched =
  let start = state.position in
  let around = state.arm in
  let breaks = { matched; leaving = [] } in
  state.arm <- Some breaks;
  let (read : arm) = arm_body state start in
  state.arm <- around;
  refuse_early_breaks state breaks read.node.items;
  read

and arm_body state start =
  in_scope state (inner_scope state) (fun () ->
      let rec labels read =
        if begins_arm_label state then labels (arm_label state :: read)
        else List.rev read
      in
      let labels = labels [] in
      let rec items read =
        if begins_arm_label state || peek state = Punctuator_token P.Right_brace
        then read
        else items (block_item state :: read)
      in
      match items [] with
      | [] ->
          fail state
            (Rule.message Arm_form
               ("an arm of `match` has no block item after its labels, found "
                ^ found state))
      | read ->
          let items = close_scope ~scope_end:(last_read state) read in
          finish state start { labels; items })

and arm_label state =
  let start = state.position in
  let node =
    if accept_keyword state Keyword.Default then Default_arm_label
    else begin
      advance state;
      Pattern_label (bound_pattern state (pattern_words state))
    end
  in
  expect state P.Colon "`:` after the label of an arm";
  finish state start node

(* After the [case]: a constructor and its sub-patterns. *)
and pattern_words state =
  let constructor = identifier state "a constructor after `case`" in
  let sub_patterns =
    if accept state P.Left_paren then begin
      let read =
        one_or_more state (fun state -> identifier state "a binding or `_`")
      in
      expect state P.Right_paren "`)` after the sub-patterns of a pattern";
      Some read
    end
    else None
  in
  { constructor; sub_patterns }

(* The pattern [words], whose bindings enter the current scope here: the
   one place that declares a binding (design 4.1 rule 4). *)
and bound_pattern state (words : pattern_words) : pattern =
  let sub_pattern (name : identifier) =
    if name.node = wildcard_word then Wildcard name.span
    else Binding { name; declared = declare state ~kind:Not_a_type name }
  in
  { constructor = words.constructor;
    sub_patterns = Option.map (List.map sub_pattern) words.sub_patterns }

(* After the [asm]: its qualifiers, and its template and operands in
   parentheses. *)
and assembler state =
  let qualifiers = asm_qualifiers state in
  expect state P.Left_paren "`(` after `asm`";
  let template = string_literal state in
  let operands =
    if peek state = Punctuator_token P.Colon then Some (asm_operands state)
    else None
  in
  expect state P.Right_paren "`:` or `)` in `asm`";
  { qualifiers; template; operands }

(* At the first [:] after the template. *)
and asm_operands state =
  let section read = if accept state P.Colon then read () else [] in
  let outputs = section (fun () -> comma_separated state asm_operand) in
  let inputs = section (fun () -> comma_separated state asm_operand) in
  let clobbers = section (fun () -> comma_separated state string_literal) in
  let labels =
    section (fun () ->
        comma_separated state (fun state ->
            jump_label state (identifier state "a label")))
  in
  { outputs; inputs; clobbers; labels }

and asm_operand state =
  let start = state.position in
  let symbolic_name =
    if accept state P.Left_bracket then begin
      let name = identifier state "an operand name" in
      expect state P.Right_bracket "`]` after an operand name";
      Some name
    end
    else None
  in
  let constraint_ = string_literal state in
  expect state P.Left_paren "`(` after the constraint of an operand";
  let value = expression state in
  expect state P.Right_paren "`)` after the value of an operand";
  finish state start { symbolic_name; constraint_; value }

(* From the [{] to the [}], in a block scope of its own. *)
and block state =
  in_scope state (inner_scope state) (fun () -> compound_statement state)

(* From the [{] to the [}], in the current scope: the body of a function
   definition is in the block scope of its parameters (6.2.1p4), so that
   a declaration in it cannot hide one of them (6.7p3). *)
and compound_statement state =
  let start = state.position in
  expect state P.Left_brace "`{`";
  in_local_label_scope state (fun () ->
      let local_labels = local_label_declarations state in
      let items = block_items state in
      finish state start { local_labels; items })

and local_label_declarations state =
  let declared = Hashtbl.create 1 in
  let local_label state =
    declare_local_label state declared (identifier state "a label name")
  in
  let rec loop declarations =
    let start = state.position in
    if accept_keyword state Keyword.Label then
      let labels = one_or_more state local_label in
      expect state P.Semicolon "`;` after the labels of `__label__`";
      loop (finish state start labels :: declarations)
    else List.rev declarations
  in
  loop []

(* After the [{], up to and including the [}], which closes the scope. *)
and block_items state =
  let rec loop read =
    match peek state with
    | Punctuator_token P.Right_brace ->
        advance state;
        close_scope ~scope_end:(last_read state) read
    | End_of_input -> fail_expected state "`}` to end a compound statement"
    | _ -> loop (block_item state :: read)
  in
  loop []

(* A label comes first: [T:] begins one where [T] is a typedef name. Then
   attributes before a [;], which begin a declaration elsewhere. *)
and block_item state =
  if begins_label state || begins_attribute_statement state then
    Complete (Block_statement (statement state))
  else if begins_type_declaration state then
    let declaration = type_declaration state in
    Until_scope_end
      (fun scope_end -> Block_type_declaration { declaration; scope_end })
  (* Before a declaration: where [match] is a typedef name, the tokens of
     a match would otherwise begin a declaration (design 2.2). *)
  else if begins_match state then Complete (Block_statement (statement state))
  else if begins_declaration state then
    Complete (Block_declaration (block_declaration state))
  else Complete (Block_statement (statement state))

(* GCC's nested functions are outside the profile, as Clang has none; a
   [{] after the first declarator names them rather than the [;]. *)
and block_declaration state =
  match declaration_start state with
  | First_declarator { first = { named_function = Some _; _ }; _ }
    when peek state = Punctuator_token P.Left_brace ->
      fail state
        (Rule.message Profile
           "a function definition in a block (a GNU nested function) is \
            outside the GNU profile (design 13.3)")
  | start -> declaration_of_start state start

(* External declarations (C11 6.9). *)

(* At the [{] of a body that C text of a system header opens. The body is
   passed through unread, so every token of it must be such text: the
   reason for the skip holds for that text alone (design 13.3). *)
let skipped_body state =
  let body = skip_balanced state "`}` to end the function body" in
  let is_other_text index = not (is_system_c_text_at state index) in
  match find_in_span body is_other_text with
  | Some index ->
      fail_at_token state index
        (Rule.message System_body_text
           "a function body that C text of a system header opens is \
            passed through unread, so it holds C text of system headers \
            only")
  | None -> Skipped body

(* At the [{]. A body whose [{] is C text of a system header is not parsed
   (design 13.3): it is written for its own compiler and may use any of
   its extensions. Any other body is read, each token as the text it
   is. *)
let function_body state =
  if is_system_c_text_at state (first_token state state.position) then
    skipped_body state
  else Parsed (as_function state (fun () -> compound_statement state))

(* The declaration list of an old-style definition, up to the [{]. GCC
   and Clang take no C23 attributes before a declaration there. *)
let parameter_declarations state =
  let rec loop declarations =
    if peek state = Punctuator_token P.Left_brace then List.rev declarations
    else if opens_standard_attributes state 0 then
      fail_expected state "a parameter declaration or `{`"
    else loop (declaration state :: declarations)
  in
  loop []

let takes_declaration_list = function
  | Identifier_list _ -> true
  | Prototype _ -> false

(* The scope of a function's body (6.2.1p4), which [declaration_start]
   has declared the function in. *)
let body_scope state named_function =
  reentered_scope state ~inner:named_function.parameter_scope

(* A declarator whose name is a function begins a definition at a [{],
   or, after an identifier list, at a declaration (6.9.1p1), read in the
   scope of the body as the declaration list will be. *)
let begins_definition state named_function =
  peek state = Punctuator_token P.Left_brace
  || takes_declaration_list named_function.parameters
     && in_scope state (body_scope state named_function) (fun () ->
            starts_declaration state 0)

(* After the declarator of a function and its attributes. Its parameters
   and its body are in one block scope, which continues the scope of the
   parameter list (6.2.1p4). *)
let function_definition state start specifiers (first : scoped_declarator)
    named_function =
  let declarations, body =
    in_scope state (body_scope state named_function) (fun () ->
        let declarations = parameter_declarations state in
        (declarations, function_body state))
  in
  Function_definition
    (finish state start
       {
         specifiers;
         declarator = first.declarator;
         declared = first.declared;
         attributes = first.attributes;
         declarations;
         body;
       })

(* [__extension__] may come before every external declaration of C; the
   node holds it in its span. A function definition has no asm label: GCC
   and Clang take one only in a declaration. *)
let c_external_declaration state =
  let start = state.position in
  match peek_at state (extensions_ahead state 0) with
  | Punctuator_token P.Semicolon ->
      skip_extensions state;
      advance state;
      Empty_declaration (span_from state start)
  | Keyword_token Keyword.Asm ->
      skip_extensions state;
      advance state;
      let assembler = assembler state in
      expect state P.Semicolon "`;` after `asm`";
      Top_level_asm (finish state start assembler)
  | _ -> (
      match declaration_start state with
      | First_declarator
          {
            start;
            specifiers;
            first =
              { named_function = Some named; asm_label = None; _ } as first;
          }
        when begins_definition state named ->
          function_definition state start specifiers first named
      | declaration_start ->
          External_declaration (declaration_of_start state declaration_start))

(* An external declaration and the scope in front of it, which is
   persistent, so keeping it copies nothing (design 13.5). *)
let external_declaration state =
  let view = state.scope in
  if begins_type_declaration state then
    let declaration = type_declaration state in
    Until_scope_end
      (fun scope_end -> (Type_declaration { declaration; scope_end }, view))
  else Complete (c_external_declaration state, view)

(* The external declarations, each with the scope in front of it. File
   scope closes with the text, whose last tokens may be pragma tokens,
   which stand in it. *)
let translation_unit state =
  let rec loop read =
    if peek state = End_of_input then begin
      let tokens = Array.length state.reader.tokens in
      take_pragma_views state ~before:tokens;
      close_scope ~scope_end:(tokens - 1) read
    end
    else loop (external_declaration state :: read)
  in
  loop []

type file_scope = {
  ordinary : (string * reference) list;
  tags : (string * tag_id) list;
}

let file_scope_declarations scope =
  {
    ordinary =
      List.map
        (fun (name, (entry : ordinary)) -> (name, entry.declaration))
        (Scope.declared_in_innermost scope);
    tags =
      List.map
        (fun (name, entry) -> (name, entry.tag))
        (Scope.tags_declared_in_innermost scope);
  }

module View = struct
  type t = scope

  let find view name = Scope.find view name

  let find_tag view name =
    Option.map (fun (entry : tag_entry) -> entry.tag) (Scope.find_tag view name)
end

type scopes = {
  file_scope : file_scope;
  declarations : (external_declaration * View.t) list;
  views : views;
}

(* [attribute_arguments] keeps a view under the first token of each span
   of arguments that it makes, which is the only way a parsed attribute
   gets one, so [Places.find] finds it. *)
let attribute_view (views : views) (attribute : attribute) =
  Option.map
    (fun (arguments : span) -> Places.find arguments.first views.attributes)
    attribute.node.arguments

let pragma_view (views : views) token = Places.find_opt token views.pragmas

let parse_with_scopes ~keywords reader =
  let state =
    {
      reader;
      grammar = grammar_tokens keywords reader;
      position = 0;
      open_brackets = [];
      scope = initial_scope keywords;
      jumps = Function_body;
      arm = None;
      labels = None;
      generic = None;
      in_type_argument = false;
      views = { attributes = Places.empty; pragmas = Places.empty };
      counter = Spanned.counter ~max_depth;
    }
  in
  match
    refuse_generated_names state;
    refuse_pragmas_without_tokens state;
    translation_unit state
  with
  | declarations ->
      (* Every scope the unit opens is closed, so [state.scope] is file
         scope as the unit leaves it. *)
      let file_scope = file_scope_declarations state.scope in
      let scopes = { file_scope; declarations; views = state.views } in
      Ok (List.map fst declarations, scopes)
  | exception Failed error -> Error error

let parse ~keywords reader =
  Result.map fst (parse_with_scopes ~keywords reader)

let error_message = Reader.error_message
