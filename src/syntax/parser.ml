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
   stages, on amd64 macOS and Linux, against the runtime's default limit of
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
  | Generic_function_name

type ordinary = { declaration : reference; kind : kind }

(* What the definition of a generic type allows at the cursor (design 3.5
   rule 4): a structure or union body only where the definition of an
   instance holds it, and no type parameter inside an [_Alignas]. *)
type generic_place = { bodies_allowed : bool; in_alignment : bool }

(* A tag in scope: its declaration, and whether a type declaration
   claims it for the C that it lowers to (design 10.1 rule 6, 10.2). *)
type tag_entry = { tag : tag_id; claimed : bool }

(* The scopes open at a point, in the two name spaces that scopes hold
   (6.2.3): ordinary identifiers, and tags. File scope opens inside the
   universe scope (design 2.3), which holds the generics that the
   universe text declares ({!Scope.file_within}), so every lookup and
   every view finds them; {!Universe} names the rest. *)
type scope = (ordinary, tag_entry) Scope.t

(* A label of the body being read, and whether a statement has defined
   it so far. *)
type label_entry = { identity : label_id; mutable defined : bool }

module Names = Map.Make (String)
module Name_set = Set.Make (String)

(* What a name denotes at a point (parser.mli): the scopes open there,
   and the GNU local labels visible there by name, which a label name
   denotes before the function's label of its name. Both are persistent,
   so keeping a view copies nothing. *)
type view = { scopes : scope; local_labels : label_entry Names.t }

let empty_view = { scopes = Scope.file; local_labels = Names.empty }

(* Values by the index of a token in [Reader.t.tokens]. *)
module Places = Map.Make (Int)

(* The scopes at a hoisted operand; parser.mli says what they are. *)
type try_views = {
  place : view;
  place_before : int;
  own : view;
  depth : scope_depth;
}

(* The scopes that unread and moved text stands in (design 13.5), by the
   index of a token: at the [(] of the arguments of each attribute, and
   for an attribute the span of its arguments, at each pragma token, at
   each [try], and at each statement that lowering writes around for a
   defer (parser.mli). [occurrences] holds each attribute and alignment
   specifier by its first token, which {!attributes_in} lists, and
   [alignments] the scope at the operand of each alignment specifier, by
   the operand's first token. *)
type statement_view = { view : view; depth : scope_depth }

type views = {
  attributes : (span * view) Places.t;
  occurrences : attribute Places.t;
  alignments : view Places.t;
  pragmas : view Places.t;
  tries : try_views Places.t;
  statements : statement_view Places.t;
}

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
  | Deferred_statement
      (* the statement of a defer, which no break or continue leaves
         (design 6 rule 4) *)

(* The innermost match arm around the cursor: the match it belongs to,
   and the breaks in Type-C text read in it so far that leave that
   match, by the first token of each, latest first. Design 4.3 rule 5
   judges them where the arm ends. *)
type arm_breaks = { matched : jump_target; mutable leaving : int list }

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

(* The operand of a [slice_from_array] being read, which lowering writes
   a second time (design section 8 rule 2): the labels of the body that
   holds it and the index of its first token. *)
type array_operand = { around : body_labels; first : int }

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
  keywords : Keyword_set.t;  (** which the grammar tokens are read with *)
  grammar : grammar_token array;
  mutable position : int;  (** in [grammar] *)
  mutable open_brackets : opening list;
      (** read and not yet closed, innermost first *)
  mutable scope : scope;
  mutable place : view;
      (** in front of the innermost external declaration, block item,
          or statement without a substatement after its labels, being
          read: where lowering writes the operand of a [try] that the
          statement or declaration holds (design 5.1 rule 3) *)
  mutable place_start : int;  (** the position in [grammar] of [place] *)
  mutable jumps : jump_scope;
  mutable arm : arm_breaks option;
  mutable labels : body_labels option;  (** [None] outside every body *)
  mutable array_operand : array_operand option;
      (** the innermost operand of a [slice_from_array] being read *)
  mutable generic : generic_place option;
      (** [None] outside the definition of a generic type *)
  mutable parameter_depth : int option;
      (** the depth of the scope of the type parameters of the generic,
          type or function, being read, which stands where file scope
          stands in the C that the text lowers to (design 3.5 rule 8);
          [None] outside one *)
  mutable names_generic_function : bool;
      (** whether the next declarator at [parameter_depth] declares the
          name of a generic function, which is declared in the file
          scope around its type parameters (design 7.1 rule 1) *)
  mutable in_type_argument : bool;  (** design 3.5 rule 2 *)
  mutable in_generic_head : bool;
      (** whether the head of a generic function is being read, which
          every instance writes twice (design 7.1 rule 6) *)
  mutable views : views;  (** taken so far *)
  mutable generics : Name_set.t;
      (** the names of the generic types declared so far, those of the
          universe text included, whose instances claim names (design
          10.3) *)
  mutable longest_type_name : int;
      (** the bytes of the longest name of a type declaration or a
          generic function read so far (design 3.5 rule 7) *)
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

(* The refusal of a disputed break or continue (design 4.4). *)
let disputed_jump keyword =
  Rule.message Disputed_jump
    (Printf.sprintf
       "a %s in the condition of a loop or the step of a for, which Clang \
        takes to leave the loop and GCC the statement around it"
       keyword)

let fail_disputed_jump state start keyword =
  fail_jump state start (disputed_jump keyword)

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

let quoted spelling =
  if String.length spelling <= max_quoted_spelling then "`" ^ spelling ^ "`"
  else "`" ^ String.sub spelling 0 max_quoted_spelling ^ "...`"

(* Design section 8 rule 2: the second writing of the operand of a
   [slice_from_array] would define again a label whose scope reaches
   beyond it, the function's or a local label declared outside it. *)
let refuse_label_in_array_operand state labels (name : identifier) entry =
  let outlives { around; first } =
    let (Label_at declared) = entry.identity in
    around == labels
    && ((not (Names.mem name.node labels.local_labels)) || declared < first)
  in
  match state.array_operand with
  | Some operand when outlives operand ->
      fail_at_token state name.span.first
        (Rule.message Array_operand_moved
           (Printf.sprintf
              "the label %s is defined in the operand of `slice_from_array`, \
               which lowering writes again as the operand of `sizeof`, and \
               its scope reaches beyond the operand; declare it with \
               `__label__` in a statement expression of the operand"
              (quoted name.node)))
  | Some _ | None -> ()

(* The label that a labelled statement defines, once in its scope
   (6.8.1p3). *)
let define_label state name =
  let labels = body_labels state name in
  let entry = label_named labels name in
  refuse_label_in_array_operand state labels name entry;
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

(* Runs [parse], the statement of a defer, which no break or continue
   leaves (design 6 rule 4). *)
let as_deferred state parse = with_jumps state Deferred_statement parse

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

(* Whether the token [index] of [Reader.t.tokens] is Type-C text. *)
let is_type_c_text_at state index =
  File.is_type_c_text state.reader.tokens.(index).owner

(* Whether the token [index] of [Reader.t.tokens] is of the universe text
   (design 13.3), which no line marker can open. *)
let is_universe_text_at state index =
  File.is_universe state.reader.tokens.(index).owner

(* Whether the token [index] of [Reader.t.tokens] is C text of a system
   header, the one text that is written for its own compiler. *)
let is_system_c_text_at state index =
  let owner = state.reader.tokens.(index).owner in
  owner.system_header && not (File.is_type_c_text owner)

(* The two readings of a disputed scope (design 4.4): Clang takes a jump
   there to leave the loop, and GCC reads the scope around the loop. *)
type reading = Clang_reading | Gcc_reading

(* What a break or continue finds on one reading: the statement that it
   leaves, none, or the statement of a defer, which it may not leave. *)
type departure = Leaves of jump_target | Leaves_nothing | Leaves_deferred

(* What a break in [jumps] leaves on [reading]. *)
let rec break_leaves reading = function
  | Loop target | Switch_or_match { target; _ } -> Leaves target
  | Disputed { loop; around } -> (
      match reading with
      | Clang_reading -> Leaves loop
      | Gcc_reading -> break_leaves reading around)
  | Deferred_statement -> Leaves_deferred
  | Function_body -> Leaves_nothing

(* What a continue in [jumps] continues on [reading]: the innermost loop,
   through any switch or match inside it. *)
let rec continue_leaves reading = function
  | Loop target -> Leaves target
  | Switch_or_match { around; _ } -> continue_leaves reading around
  | Disputed { loop; around } -> (
      match reading with
      | Clang_reading -> Leaves loop
      | Gcc_reading -> continue_leaves reading around)
  | Deferred_statement -> Leaves_deferred
  | Function_body -> Leaves_nothing

let refuse_type_c_dispute state start keyword =
  if is_type_c_text_at state (first_token state start) then
    fail_disputed_jump state start keyword

(* What the [keyword] at [start] leaves, by [leaves]. The two readings
   differ only where the jump is in a disputed scope, which Type-C text
   refuses and other C text leaves to the backend; where Clang finds
   nothing or the deferred statement, GCC does too, as no disputed scope
   is in the way. A deferred statement refuses a disputed jump in any
   text (design 6 rule 10): here one that GCC takes to leave it, and in
   [Deferred] one that stays in it on both readings, which its tree
   holds. *)
let jump_targets state start keyword leaves ~no_target =
  match (leaves Clang_reading state.jumps, leaves Gcc_reading state.jumps) with
  | Leaves_nothing, _ -> fail_jump state start no_target
  | Leaves_deferred, _ ->
      fail_jump state start
        (Rule.message Deferred_exit
           (Printf.sprintf "a `%s` that leaves the statement of a defer"
              keyword))
  | Leaves clang, Leaves gcc when clang = gcc -> Only clang
  | Leaves _, Leaves_deferred -> fail_disputed_jump state start keyword
  | Leaves loop, Leaves_nothing ->
      refuse_type_c_dispute state start keyword;
      Only loop (* GCC refuses it *)
  | Leaves loop, Leaves around ->
      refuse_type_c_dispute state start keyword;
      Either { loop; around }

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
    | (Block_declaration _ | Block_type_declaration _ | Block_defer _) :: _
    | [] ->
        []
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
            `return`, or use a single-pattern test")

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
let refuse_pragma_without_tokens state ~moved index (token : Token.t) =
  match token.kind with
  | Token.Pragma (Not_tokens reason) when moved || is_type_c_text_at state index
    ->
      fail_at_token state index
        (Rule.message Pragma_tokens
           ("a `#pragma` line whose text is no sequence of preprocessing \
             tokens: " ^ reason))
  | Token.Pragma (Not_tokens _ | Identifiers _) | Typec_pragma | Identifier _
  | Number | Character _ | String _ | Punctuator _ ->
      ()

let refuse_pragmas_without_tokens state =
  Array.iteri (refuse_pragma_without_tokens state ~moved:false)
    state.reader.tokens

(* Lowering copies a deferred statement to each exit of its scope, so it
   may hold only the pragmas that apply to the statement after them
   (design 6 rule 9, 13.5). *)
let refuse_state_pragma state index (token : Token.t) =
  match token.kind with
  | Token.Pragma (Identifiers names)
    when not (Statement_pragma.is_statement_scoped names) ->
      fail_at_token state index
        (Rule.message Deferred_pragma
           "a `#pragma` line in a deferred statement, which lowering \
            copies to each exit, that is not one of the pragmas that \
            apply only to the statement after them")
  | Token.Pragma (Identifiers _ | Not_tokens _) | Typec_pragma | Identifier _
  | Number | Character _ | String _ | Punctuator _ ->
      ()

(* The pragma lines of a deferred statement, which is moved text in any
   text (design 13.5): the one place that decides which may move. *)
let refuse_moved_pragmas state (span : span) =
  for index = span.first to span.last do
    let token = state.reader.tokens.(index) in
    refuse_pragma_without_tokens state ~moved:true index token;
    refuse_state_pragma state index token
  done

(* Lowering removes a defer statement from its place, so a pragma line
   directly before the keyword would apply to the statement after it
   (design 6 rule 9). A defer has no label, so the token before the
   keyword is a pragma exactly where one stands directly before it. *)
let refuse_pragma_before_defer state ~keyword =
  if keyword > 0 then
    match state.reader.tokens.(keyword - 1).kind with
    | Token.Pragma _ | Typec_pragma ->
        fail_at_token state (keyword - 1)
          (Rule.message Deferred_pragma
             "a `#pragma` line directly before a defer statement, which \
              lowering removes, so the pragma would apply to the \
              statement after it; put a `;` between them")
    | Identifier _ | Number | Character _ | String _ | Punctuator _ -> ()

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

(* The view at the cursor. *)
let view_here state =
  let local_labels =
    match state.labels with
    | Some labels -> labels.local_labels
    | None -> Names.empty
  in
  { scopes = state.scope; local_labels }

(* Keeps the view at each pragma token after the last grammar token read
   and before the token at [before], none of which the grammar reads.
   The parser takes the scope that holds at a place before it moves past
   the next grammar token, so a pragma token gets the scope in front of
   the grammar token after it (design 13.5). *)
let take_pragma_views state ~before =
  for index = after_last_read state to before - 1 do
    state.views <-
      {
        state.views with
        pragmas = Places.add index (view_here state) state.views.pragmas;
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

(* File scope inside [universe], with the typedef names that GCC and
   Clang declare before the first token for a backend with [keywords]. *)
let initial_scope keywords ~universe =
  List.fold_left
    (fun scope (name, builtin) ->
      if Builtin_typedef.declared keywords builtin then
        let entry = { declaration = Builtin name; kind = Typedef_name } in
        Scope.declare scope name entry
      else scope)
    (Scope.file_within universe)
    Builtin_typedef.table

let names_type = function
  | Not_a_type | Derived_enumerator | Generic_function_name -> false
  | Typedef_name | Declared_type _ | Type_parameter -> true

(* The number of type parameters of the type that a name of [kind]
   names, which is not zero for a generic type (design 3.5 rule 1). *)
let type_parameters_of = function
  | Declared_type { parameters; _ } -> parameters
  | Not_a_type | Typedef_name | Type_parameter | Derived_enumerator
  | Generic_function_name ->
      0

let is_generic kind = type_parameters_of kind > 0

(* The declaration of the ordinary identifier [name] that is visible at
   the cursor, which may be one of the universe scope (design 2.3). *)
let visible state name = Scope.find state.scope name

(* The visible declaration of [name] where it is a typedef name. *)
let typedef_declaration state name =
  match visible state name with
  | Some ordinary when names_type ordinary.kind -> Some ordinary
  | Some _ | None -> None

let is_typedef_name state name = typedef_declaration state name <> None

(* An identifier is the only token that a declaration is made at, and
   the cursor reads each token once, so the token is a unique id. *)
let token_of (name : identifier) = name.span.first

let is_type_declared = function
  | Declared_type _ -> true
  | Not_a_type | Typedef_name | Type_parameter | Derived_enumerator
  | Generic_function_name ->
      false

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
  match visible state name with
  | Some { kind = Derived_enumerator; _ } -> true
  | Some _ | None -> false

let claims_tag state name =
  match Scope.find_tag state.scope name with
  | Some { claimed; _ } -> claimed
  | None -> false

(* The generic that claims [name] for its instances (design 10.3). The
   set of generics only grows, as hiding a generic's name ends no claim:
   an instance of it may still be used in the scope that hides it. *)
let instance_claim state name =
  match Spelling.instance_space name with
  | Some generic when Name_set.mem generic state.generics -> Some generic
  | Some _ | None -> None

(* The name [name] at the token [index]: [what] is its name space, and
   [use] what the source does with it, as the message words them. *)
let refuse_instance_name state index name ~what ~use =
  match instance_claim state name with
  | Some generic ->
      fail_at_token state index
        (Rule.message Claimed_name
           (Printf.sprintf
              "%s %s is %s, but the generic %s claims every name that \
               begins with its own name and `__` for its instances"
              what (quoted name) use (quoted generic)))
  | None -> ()

(* The claim of the generic [name] also refuses a name of its space that
   its scope declares before it. A generic is declared at file scope or
   in the universe scope only, and no scope that ended before it can hold
   a use of it. *)
let claim_instance_space state (name : identifier) =
  match Scope.first_in_space state.scope name.node with
  | Some taken ->
      fail_at_token state (token_of name)
        (Rule.message Claimed_name
           (Printf.sprintf
              "the generic %s claims every name that begins with its own \
               name and `__` for its instances, and this scope declares %s \
               already"
              (quoted name.node) (quoted taken)))
  | None -> state.generics <- Name_set.add name.node state.generics

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

(* The depth of the innermost scope in the C that the text lowers to
   ({!Tree.scope_depth}), where the scope of a generic's type parameters
   stands for file scope. *)
let scope_depth state =
  let depth = Scope.depth state.scope in
  match state.parameter_depth with
  | Some parameter_depth -> Scope_depth (depth - parameter_depth + 1)
  | None -> Scope_depth depth

(* Whether a declarator at the cursor declares the name of a generic
   function, in the file scope around the scope of its type parameters
   (design 7.1 rule 1): the first one at their depth, and no other. *)
let declares_outside state =
  let outside =
    state.names_generic_function
    && state.parameter_depth = Some (Scope.depth state.scope)
  in
  if outside then state.names_generic_function <- false;
  outside

(* The declaration [id] of an ordinary identifier in the innermost
   scope, which redeclares [earlier]. *)
let declared_here state id ~earlier = { id; scope = scope_depth state; earlier }

(* Declares the ordinary identifier [name] in the innermost scope, where
   its scope begins, or, [outside], in the scope around it. *)
let declare_in state ~outside ~kind (name : identifier) =
  let id = Ordinary_at (token_of name) in
  if claims_enumerator state name.node then
    fail_claimed state name "enumerator" "is declared again";
  refuse_instance_name state (token_of name) name.node ~what:"the name"
    ~use:"declared";
  let declaring = if outside then Scope.outer state.scope else state.scope in
  let earlier = Scope.find_in_innermost declaring name.node in
  refuse_second_definition state name kind earlier;
  if is_generic kind then claim_instance_space state name;
  let binding = { declaration = In_tree id; kind } in
  state.scope <-
    (if outside then Scope.declare_outside state.scope name.node binding
     else Scope.declare state.scope name.node binding);
  declared_here state id
    ~earlier:(Option.map (fun ordinary -> ordinary.declaration) earlier)

let declare state ~kind name = declare_in state ~outside:false ~kind name

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

(* At a defer statement that stands in [where], which is no block item of
   a compound statement or a match arm in a function body. *)
let fail_defer_position state where =
  fail state
    (Rule.message Defer_position
       ("a `defer` statement is a block item of a compound statement or a \
         match arm in a function body, not " ^ where))

(* A defer in the statement of another, at any depth (design 6 rule 11):
   lowering copies the outer statement to each exit of its scope, and
   each copy would hold every copy of the inner one, so the output would
   multiply with each level of nesting. *)
let defer_in_deferred =
  Rule.message Defer_in_deferred
    "a `defer` statement in the statement of a defer, which lowering \
     copies to each exit of its scope, where each copy would repeat every \
     copy of the inner statement"

(* The statement of a defer, which lowering copies to each exit of its
   scope (design 6 rules 4, 9, 10 and 11, 13.5): a jump out of it would
   skip the rest of the exit, a definition in it would be made once for
   each copy, a disputed jump would leave it on one backend's reading,
   and a defer in it would multiply the copies. One walk over its tree,
   once the parser has read it, refuses the first such construct in the
   order of the source; an error that the parser reports while it reads
   the statement comes before it, as does one in the statement of a
   defer inside it, which the parser walks as it reads that defer. It
   matches every node and every field, with no wildcard, so that a node
   added to the tree fails to compile here until it is classified. It
   stops at a construct it refuses, such as a block literal or the body
   of a structure, so what those hold needs no class. A break or
   continue that leaves the statement is no node: the
   [Deferred_statement] scope of its jumps refuses it as it is read. *)
module Deferred = struct
  exception Refused of int * Rule.diagnostic

  let refuse_exit ~at what =
    raise
      (Refused
         ( at,
           Rule.message Deferred_exit
             (what
            ^ " in the statement of a defer, which control leaves only at \
               its end") ))

  let refuse_definition ~at what =
    raise
      (Refused
         ( at,
           Rule.message Deferred_declaration
             (what
            ^ " in the statement of a defer, which lowering copies to each \
               exit of its scope, where each copy would define it again") ))

  (* A jump that the parser resolved to a statement in the walk, or, on
     two readings, to two (rule 10). *)
  let jump ~at keyword = function
    | Only _ -> ()
    | Either { loop = _; around = _ } ->
        raise (Refused (at, disputed_jump keyword))

  (* A declaration with [extern] defines no object (rule 9). *)
  let storage (specifiers : specifiers) =
    let is_extern (specifier : declaration_specifier spanned) =
      specifier.node = Storage_class Extern
    in
    let is_static (specifier : declaration_specifier spanned) =
      specifier.node = Storage_class Static
      || specifier.node = Storage_class Thread_local
    in
    match List.find_opt is_static specifiers with
    | Some specifier when not (List.exists is_extern specifiers) ->
        refuse_definition ~at:specifier.span.first
          "a declaration with static or thread storage duration and no \
           `extern`"
    | Some _ | None -> ()

  let tag { name; binding } =
    match binding with
    | Declares { id = _; scope = _; earlier = _; implicit = _ } ->
        refuse_definition ~at:name.span.first
          ("the declaration of the tag " ^ quoted name.node)
    | Names _ -> ()

  let rec statement (read : statement) =
    let at = read.span.first in
    match read.node with
    | Labeled { label = labelling; statement = labelled } ->
        label labelling;
        statement labelled
    | Compound body -> block body
    | Expression_statement value -> expression value
    | Null_statement | Attribute_statement _ -> ()
    | If { condition = test; then_branch; else_branch } ->
        condition test;
        statement then_branch;
        Option.iter statement else_branch
    | Switch { controlling; body } ->
        expression controlling;
        statement body
    | While { condition = test; body } ->
        condition test;
        statement body
    | Do { body; condition = test } ->
        statement body;
        expression test
    | For { clause; condition = test; step; body } ->
        Option.iter for_clause clause;
        Option.iter expression test;
        Option.iter expression step;
        statement body
    | Goto _ -> refuse_exit ~at "`goto`"
    | Computed_goto _ -> refuse_exit ~at "`goto *`"
    | Continue { loop } -> jump ~at "continue" loop
    | Break { leaves } -> jump ~at "break" leaves
    | Return _ -> refuse_exit ~at "`return`"
    | Asm read -> assembler read
    | Match { scrutinee; arms } ->
        expression scrutinee;
        List.iter arm arms

  and label (read : label) =
    match read.node with
    | Named_label { name; label = _; attributes = _ } ->
        refuse_definition ~at:read.span.first ("the label " ^ quoted name)
    | Case_label value -> expression value
    | Case_range { low; high } ->
        expression low;
        expression high
    | Default_label -> ()

  and condition = function
    | Controlling value -> expression value
    | Pattern_test { pattern_span = _; pattern = _; operand } ->
        expression operand

  and for_clause = function
    | Clause_declaration read -> declaration read
    | Clause_expression value -> expression value

  and assembler { qualifiers; template = _; operands } =
    List.iter asm_qualifier qualifiers;
    Option.iter asm_operands operands

  and asm_qualifier (qualifier : asm_qualifier spanned) =
    match qualifier.node with
    | Asm_goto -> refuse_exit ~at:qualifier.span.first "`asm goto`"
    | Asm_volatile | Asm_inline -> ()

  and asm_operands { outputs; inputs; clobbers = _; labels = _ } =
    List.iter asm_operand outputs;
    List.iter asm_operand inputs

  and asm_operand (operand : asm_operand) =
    let { symbolic_name = _; constraint_ = _; value } = operand.node in
    expression value

  and arm (read : arm) =
    let { labels = _; items } = read.node in
    List.iter block_item items

  and block (read : block) =
    let { local_labels; items } = read.node in
    (match local_labels with
    | first :: _ -> refuse_definition ~at:first.span.first "`__label__`"
    | [] -> ());
    List.iter block_item items

  and block_item = function
    | Block_declaration read -> declaration read
    | Block_type_declaration { declaration = declared; scope_end = _ } ->
        refuse_definition ~at:declared.span.first "a type declaration"
    | Block_statement read -> statement read
    | Block_defer { keyword; statement = _ } ->
        raise (Refused (keyword.first, defer_in_deferred))

  and declaration (read : declaration) =
    match read.node with
    | Declaration { specifiers = specified; declarators } ->
        specifiers specified;
        List.iter init_declarator declarators
    | Static_assert assertion -> static_assertion assertion

  and static_assertion { condition = test; message = _ } = expression test

  and init_declarator (read : init_declarator) =
    let { declarator = declared; declared = _; asm_label = _; attributes = _;
          initialiser = value } =
      read.node
    in
    declarator declared;
    Option.iter initialiser value

  (* The storage class counts once the specifiers are read, as the parser
     reads a structure among them first. *)
  and specifiers (read : specifiers) =
    List.iter declaration_specifier read;
    storage read

  and declaration_specifier (specifier : declaration_specifier spanned) =
    match specifier.node with
    | Storage_class _ | Type_qualifier _ | Function_specifier _
    | Attributes _ ->
        ()
    | Type_specifier read -> type_specifier ~at:specifier.span.first read
    | Alignment_specifier (Alignas_type name) -> type_name name
    | Alignment_specifier (Alignas_expression value) -> expression value

  (* The tree keeps no span of an enumerator list, so its refusal is at
     the specifier, [at]. *)
  and type_specifier ~at = function
    | Basic _ | Typedef_name { name = _; declaration = _ } -> ()
    | Atomic_type name | Typeof_type name -> type_name name
    | Typeof_expression value -> expression value
    | Application { name = _; generic = _; arguments } ->
        List.iter type_name arguments
    | Struct_or_union { kind = _; attributes = _; tag = named; members } ->
        (match members with
        | Some body ->
            refuse_definition ~at:body.span.first
              "a structure or union with a body"
        | None -> ());
        Option.iter tag named
    | Enum { attributes = _; tag = named; underlying; enumerators } ->
        Option.iter specifiers underlying;
        (match enumerators with
        | Some _ -> refuse_definition ~at "an enumeration with a body"
        | None -> ());
        Option.iter tag named

  and type_name (name : type_name) =
    let { specifier_qualifiers; abstract } = name.node in
    specifiers specifier_qualifiers;
    Option.iter declarator abstract

  (* The parts of a derived declarator after its [inner] follow it in the
     source. *)
  and declarator (read : declarator) =
    match read.node with
    | Name _ -> ()
    | Parenthesized_declarator { attributes = _; inner } -> declarator inner
    | Pointer { qualifiers = _; attributes = _; inner }
    | Block_pointer { qualifiers = _; attributes = _; inner } ->
        Option.iter declarator inner
    | Array { inner; qualifiers = _; size } ->
        Option.iter declarator inner;
        array_size size
    | Function { inner; parameters = declared } ->
        Option.iter declarator inner;
        parameters declared

  and array_size = function
    | Unsized | Unspecified_variable -> ()
    | Sized value | Static_sized value -> expression value

  and parameters = function
    | Prototype { parameters = declared; variadic = _ } ->
        List.iter parameter declared
    | Identifier_list _ -> ()

  and parameter (read : parameter) =
    let ({ specifiers = specified; declarator = declared; attributes = _ }
          : parameter_node) =
      read.node
    in
    specifiers specified;
    match declared with
    | Named_parameter { declarator = named; declared = _ } -> declarator named
    | Abstract_parameter abstract -> Option.iter declarator abstract

  and initialiser = function
    | Expression_initialiser value -> expression value
    | Braced values -> initialiser_list values

  and initialiser_list (values : initialiser_list) =
    List.iter designated_initialiser values.node

  and designated_initialiser (value : designated_initialiser) =
    let { designators; initialiser = initial } = value.node in
    List.iter designator designators;
    initialiser initial

  and designator (read : designator) =
    match read.node with
    | Index index -> expression index
    | Index_range { low; high } ->
        expression low;
        expression high
    | Member_designator _ -> ()

  and expression (read : expression) =
    match read.node with
    | Identifier { name = _; resolution = _ }
    | Constant _ | Character _ | String _ | Label_address _ ->
        ()
    | Parenthesized operand
    | Post_increment operand
    | Post_decrement operand
    | Unary (_, operand)
    | Sizeof_expression operand
    | Alignof_expression operand
    | Member { operand; member = _ }
    | Pointer_member { operand; member = _ }
    | Try { operand } ->
        expression operand
    | Sizeof_type name | Alignof name -> type_name name
    | Slice_operation operation ->
        List.iter expression (Tree.slice_operands operation)
    | Generic { controlling; associations } ->
        expression controlling;
        List.iter generic_association associations
    | Compound_literal { type_name = name; values } ->
        type_name name;
        initialiser_list values
    | Qualified_constructor { variant; constructor = _ } -> type_name variant
    | Subscript { operand = left; index = right }
    | Binary (_, left, right)
    | Assignment (_, left, right)
    | Comma (left, right) ->
        expression left;
        expression right
    | Call { callee; arguments } ->
        expression callee;
        List.iter expression arguments
    | Instance { generic; type_arguments } ->
        expression generic;
        List.iter type_name type_arguments
    | Cast { type_name = name; operand } ->
        type_name name;
        expression operand
    | Conditional { condition = test; if_true; if_false } ->
        expression test;
        Option.iter expression if_true;
        expression if_false
    | Choose { condition = test; first; second } ->
        expression test;
        expression first;
        expression second
    | Statement_expression body -> block body
    | Va_arg { list; type_name = name } ->
        expression list;
        type_name name
    | Offsetof { type_name = name; member = _; designators } ->
        type_name name;
        List.iter designator designators
    | Types_compatible (first, second) ->
        type_name first;
        type_name second
    | Block_literal { parameters = _; body = _ } ->
        refuse_definition ~at:read.span.first "a block literal"

  and generic_association (association : generic_association) =
    match association.node with
    | Association (name, value) ->
        type_name name;
        expression value
    | Default_association value -> expression value
end

(* The first construct in the statement of a defer that [Deferred]
   refuses. *)
let refuse_deferred state statement =
  match Deferred.statement statement with
  | () -> ()
  | exception Deferred.Refused (at, diagnostic) ->
      fail_at_token state at diagnostic

(* The identifiers that are words of Type-C text where no declaration
   hides them (design 2.3). *)
type type_c_word = Try | Defer

let type_c_word = function
  | "try" -> Some Try
  | "defer" -> Some Defer
  | _ -> None

(* Whether the word at the cursor is Type-C's [word]: in Type-C text,
   where no declaration of the same identifier hides it, as one hides a
   universe name (design 2.3). *)
let begins_word state word =
  match peek state with
  | Identifier_token name when type_c_word name = Some word ->
      is_type_c_text_at state state.grammar.(state.position).index
      && Option.is_none (visible state name)
  | _ -> false

let begins_try state = begins_word state Try

(* [_Defer] is the statement in every text (design 6 rule 10). *)
let begins_defer state =
  peek state = Keyword_token Keyword.Defer || begins_word state Defer

(* Runs [read] with [state.place] at the scope in front of what it
   reads, and restores the place around it after. *)
let in_place state read =
  let around = state.place and around_start = state.place_start in
  state.place <- view_here state;
  state.place_start <- state.position;
  let result = read state in
  state.place <- around;
  state.place_start <- around_start;
  result

(* The views of a hoisted operand of Type-C text that begins at the
   cursor, in [state.place]; [hoist] records them once the operator that
   hoists the operand is read, since an operand of [&&], [||], [?:] or a
   comma is known to be a first operand only after it (design 5.1 rule
   3). *)
let hoistable state =
  let start = state.position and place_start = state.place_start in
  let place = state.place and own = view_here state in
  let depth = scope_depth state in
  fun () ->
    let token = first_token state start in
    let views =
      { place; place_before = first_token state place_start; own; depth }
    in
    if is_type_c_text_at state token then
      state.views <-
        { state.views with tries = Places.add token views state.views.tries }

(* At an [if] or a [switch], which holds a [try] in its controlling
   expression with its prelude in front of it, after its labels (design
   5.1 rule 3, 13.5): the place of the operands that it hoists. *)
let holds_place state =
  state.place <- view_here state;
  state.place_start <- state.position

(* At the [try] that [begins_try] recognises: records its views and
   returns the node it makes of its operand. *)
let try_prefix state =
  hoistable state ();
  advance state;
  fun operand -> Tree.Try { operand }

(* The view at the token in front of the cursor, which lowering writes
   the copies of deferred statements in front of, or which begins text
   that it writes in a block of its own (design 13.5). *)
and take_statement_view state =
  let token = first_token state state.position in
  let taken = { view = view_here state; depth = scope_depth state } in
  state.views <-
    { state.views with
      statements = Places.add token taken state.views.statements }

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
  match visible state name with
  | Some { declaration; kind = Derived_enumerator } ->
      refuse_derived_enumerator state name;
      Resolved declaration
  | Some { declaration; _ } -> Resolved declaration
  | None ->
      (* A cast-expression reads an unhidden [try] before it would read
         a primary-expression, the one place that resolves a name. *)
      if begins_try state then invalid_arg "Parser: a try read as a name";
      (* A defer statement begins a block item, never an operand. *)
      if begins_defer state then fail_expected state "an expression";
      Undeclared

(* Whether the innermost scope is file scope in the C that the text
   lowers to, where the scope of a generic's type parameters is not. *)
let at_file_level state = scope_depth state = Scope_depth 1

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
let declare_tag state (name : identifier) ~implicit =
  let id = Tag_at (token_of name) in
  refuse_argument_tag state name;
  if claims_tag state name.node then
    fail_claimed state name "tag" "is declared again";
  refuse_instance_name state (token_of name) name.node ~what:"the tag"
    ~use:(if implicit then "named" else "declared");
  let earlier = Scope.find_tag_in_innermost state.scope name.node in
  state.scope <-
    Scope.declare_tag state.scope name.node { tag = id; claimed = false };
  Declares
    {
      id;
      scope = scope_depth state;
      earlier = Option.map (fun entry -> entry.tag) earlier;
      implicit;
    }

(* The spelling of [name] as that of a [what], from which typec derives
   names for C (design 3.1 rules 6 and 7). Its length is a translation
   limit, whose refusal carries no code (3.5 rule 7). *)
let checked_spelling state ~at_file_scope (name : identifier) ~what =
  let refuse diagnostic = fail_at_token state (token_of name) diagnostic in
  match Spelling.type_name ~at_file_scope name.node with
  | Ok checked ->
      let length = String.length name.node in
      state.longest_type_name <- max state.longest_type_name length;
      checked
  | Error (Too_long length) ->
      refuse
        (Rule.c_text
           (Printf.sprintf
              "the name of a %s holds %d bytes, over the %d that typec \
               takes (a translation limit, C11 5.2.4.1)"
              what length Spelling.max_type_name_length))
  | Error (Misspelt reason) ->
      refuse
        (Rule.message Type_name_spelling
           (Printf.sprintf "%s cannot name a %s%s" (quoted name.node) what
              reason))

(* The name of a type declaration. [name] is the node made last, which
   the checked name replaces: it counts as a part, a level too many. *)
let checked_type_name state (name : identifier) =
  let at_file_scope = Scope.is_file state.scope in
  spanned state name.span
    (checked_spelling state ~at_file_scope name ~what:"type declaration")

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
   claims none of these, but the names of its instances
   ({!claim_instance_space}, 10.3). *)
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
        declared_here state id ~earlier:(Some declaration)
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

(* An instance writes the head of a generic function as its prototype
   and again at its definition, so a tag that the head declares would
   name two types, and a body there would define its type twice (design
   7.1 rule 6). *)
let refuse_tag_in_generic_head state =
  if state.in_generic_head then
    fail state
      (Rule.message Generic_function_form
         "the head of a generic function declares no structure, union \
          or enumeration tag, which every instance would declare twice")

let declared_tag state name ~implicit =
  refuse_tag_in_generic_head state;
  declare_tag state name ~implicit

(* A tag that [declares] by its form declares itself in the current
   scope (6.7.2.3p6, p7); any other names the visible tag (p9), or
   declares one where none is visible (p8). *)
let bound_tag state (name : identifier) ~declares =
  let binding =
    if declares then declared_tag state name ~implicit:false
    else
      match Scope.find_tag state.scope name.node with
      | Some entry -> named_tag state name entry
      | None -> declared_tag state name ~implicit:true
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

(* Where a compound statement stands, which decides whether a defer
   statement may be one of its block items: not in a statement
   expression, whose last item gives its value (design 6 rule 11). *)
type compound_place = Plain_block | Statement_expression_body

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

(* Unread text (design 13.5). *)

(* What lowering writes under a name of its own, which unread text keeps
   under the spelling of the source; parser.mli says more. *)
type own_name = Own_type_parameter | Own_generic | Own_universe_name

(* No generic of a unit has a universe name (design 3.6), so a generic
   that has one is the universe's. *)
let own_name (found : ordinary option) name =
  let universe_name = Option.is_some (Universe.find name) in
  match found with
  | Some { kind = Type_parameter; _ } -> Some Own_type_parameter
  | Some { kind = Declared_type { parameters; _ }; _ }
    when parameters > 0 && universe_name ->
      Some Own_universe_name
  | Some { kind = Declared_type { parameters; _ }; _ } when parameters > 0 ->
      Some Own_generic
  | Some _ -> None
  | None when universe_name -> Some Own_universe_name
  | None -> None

let own_name_kind = function
  | Own_type_parameter -> "a type parameter"
  | Own_generic -> "a generic"
  | Own_universe_name -> "a universe name"

(* Lowering leaves the arguments of an attribute as written, so the
   identifier [name] at the token [index] there, which [scope] resolves,
   must not denote an [own_name]: a type parameter in the definition of
   a generic, whatever its text (design 3.5 rule 4), and a generic or a
   universe name in Type-C text. *)
let refuse_own_name state scope index name =
  match own_name (Scope.find scope name) name with
  | Some Own_type_parameter ->
      fail_at_token state index
        (Rule.message Generic_definition
           (Printf.sprintf
              "the type parameter %s is used in the arguments of an \
               attribute"
              (quoted name)))
  | Some ((Own_generic | Own_universe_name) as own)
    when is_type_c_text_at state index ->
      fail_at_token state index
        (Rule.message Unread_own_name
           (Printf.sprintf
              "%s in the arguments of an attribute denotes %s, which \
               lowering writes under a name of its own, but it leaves the \
               arguments as written"
              (quoted name) (own_name_kind own)))
  | Some (Own_generic | Own_universe_name) | None -> ()

(* The kinds of unread text that the scan holds to its rules. A
   [#pragma] line, the other kind, is not scanned for words or names: it
   holds no statement (design 6 rule 13), and C text that does not move
   is the backend's to read (13.5). *)
type unread =
  | Unread_attribute of scope  (** the scope at their [(] *)
  | Unread_block_literal
  | Unread_body  (** a function body that C text of a system header opens *)

let unread_place = function
  | Unread_attribute _ -> "the arguments of an attribute"
  | Unread_block_literal -> "a block literal"
  | Unread_body -> "a function body that a system header opens"

(* A block literal is C text only, and a body passed through unread C
   text of system headers only, for which alone the reason to pass it
   through holds (design 13.3). A [#pragma] line's token counts, as
   unread text is emitted whole. *)
let refuse_owner_text state unread index =
  match unread with
  | Unread_block_literal when is_type_c_text_at state index ->
      fail_at_token state index
        (Rule.message Block_literal_text
           "a block literal is C text only, so Type-C text cannot write one \
            or be included in one")
  | Unread_body when not (is_system_c_text_at state index) ->
      fail_at_token state index
        (Rule.message System_body_text
           "a function body that C text of a system header opens is \
            passed through unread, so it holds C text of system headers \
            only")
  | Unread_attribute _ | Unread_block_literal | Unread_body -> ()

(* The construct that the word at the token [index] begins would reach
   the backend as written. *)
let fail_unread_word state unread index =
  fail_at_token state index
    (Rule.message Unread_word
       (Printf.sprintf
          "%s in %s, which typing does not read, begins a construct of \
           Type-C that would reach the backend as written"
          (quoted (Reader.spelling state.reader state.reader.tokens.(index)))
          (unread_place unread)))

(* [defer] and [try] are words of Type-C text where no declaration that
   [scope], at the attribute's [(], holds hides them (design 2.3). *)
let refuse_type_c_word state scope index name =
  if
    is_type_c_text_at state index
    && Option.is_some (type_c_word name)
    && Option.is_none (Scope.find scope name)
  then fail_unread_word state (Unread_attribute scope) index

(* The rules of an identifier of unread text: a name that a generic
   claims, as typec cannot tell whether the text declares it (design
   10.3); and in an attribute argument a word of Type-C text and a name
   that lowering writes as its own (13.5). *)
let refuse_unread_identifier state unread index name =
  refuse_instance_name state index name ~what:"the name"
    ~use:("spelled in " ^ unread_place unread ^ ", which typing does not read");
  match unread with
  | Unread_attribute scope ->
      refuse_type_c_word state scope index name;
      refuse_own_name state scope index name
  | Unread_block_literal | Unread_body -> ()

(* Every rule that unread text is held to, applied to its token [index].
   [_Defer] is a keyword in every text. *)
let refuse_unread_token state unread index =
  refuse_owner_text state unread index;
  match lexeme_of state.keywords state.reader.tokens.(index) with
  | Some (Keyword_token Keyword.Defer) -> fail_unread_word state unread index
  | Some (Identifier_token name) ->
      refuse_unread_identifier state unread index name
  | Some
      ( Keyword_token _ | Number_token | Character_token _ | String_token _
      | Punctuator_token _ | End_of_input )
  | None ->
      ()

(* The one scan of unread text: each token of [span] is held here to every
   rule of unread text, so none is a check of its own that a kind of
   unread text could miss (design 6 rule 13). *)
let scan_unread state unread (span : span) =
  for index = span.first to span.last do
    refuse_unread_token state unread index
  done

(* Consumes the tokens from an opening bracket to the one that closes it,
   which are the [unread] text that the scan passes over, and returns
   their span; [expected] names the closer for the end of input. The
   cursor matches every bracket, so the skip ends at the right one, and
   the bound on nesting holds here too. *)
let skip_balanced state unread expected =
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
  let span = span_from state start in
  scan_unread state unread span;
  span

(* Attributes, GNU (GCC manual 6.39) and C23. *)

(* The arguments of an attribute, if the cursor is at their [(]. The
   parser does not read them, so it keeps the view there, under the
   token where their span starts, which says what each identifier among
   them denotes (design 13.5). *)
let attribute_arguments state =
  if peek state = Punctuator_token P.Left_paren then begin
    let view = view_here state in
    let arguments =
      skip_balanced state (Unread_attribute view.scopes)
        "`)` to end the arguments of an attribute"
    in
    state.views <-
      {
        state.views with
        attributes =
          Places.add arguments.first (arguments, view) state.views.attributes;
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

(* Every attribute and alignment specifier is recorded here, the one
   place that makes them, so that {!attributes_in} misses none. *)
let note_occurrence state (attribute : attribute) =
  state.views <-
    {
      state.views with
      occurrences =
        Places.add attribute.span.first attribute state.views.occurrences;
    }

let parsed_attribute state start name arguments =
  let attribute = finish state start { name; arguments } in
  note_occurrence state attribute;
  attribute

let attributes_in (views : views) (span : span) =
  Places.to_seq_from span.first views.occurrences
  |> Seq.take_while (fun (first, _) -> first <= span.last)
  |> Seq.map snd |> List.of_seq

let attribute state =
  let start = state.position in
  let name = attribute_name state in
  let arguments = attribute_arguments state in
  parsed_attribute state start name arguments

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
  Option.map (fun name -> parsed_attribute state start name arguments) name

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
  | Try _ | Identifier _ | Constant _ | Character _ | String _ | Parenthesized _
  | Generic _ | Compound_literal _ | Qualified_constructor _ | Subscript _
  | Slice_operation _
  | Call _ | Instance _ | Member _ | Pointer_member _ | Post_increment _
  | Post_decrement _ | Unary _
  | Sizeof_expression _ | Sizeof_type _ | Alignof _ | Alignof_expression _
  | Statement_expression _ | Label_address _ | Va_arg _ | Offsetof _
  | Types_compatible _ | Choose _ | Block_literal _ ->
      true

(* Which declarators a context takes: a declaration names what it
   declares, a type name does not, and a parameter may do either. *)
type declarator_form = Named | Abstract | Named_or_abstract

(* Whether the token at [offset] is a name whose visible declaration is
   one of the universe text. *)
let names_universe_declaration state offset =
  match peek_at state offset with
  | Identifier_token name -> (
      match visible state name with
      | Some { declaration = In_tree (Ordinary_at token); _ } ->
          is_universe_text_at state token
      | Some { declaration = Builtin _; _ } | None -> false)
  | _ -> false

(* Whether the token at [offset] is a universe name in C text that
   stands as a name of an identifier list, before [,] or [)]: C text
   keeps C's meaning there, where C reads the undeclared name as the
   parameter of an old-style definition (design 2.3). *)
let is_c_text_universe_parameter state offset =
  let in_c_text () =
    not (is_type_c_text_at state state.grammar.(state.position + offset).index)
  in
  let ends_name () =
    match peek_at state (offset + 1) with
    | Punctuator_token (P.Comma | P.Right_paren) -> true
    | _ -> false
  in
  names_universe_declaration state offset && in_c_text () && ends_name ()

(* In a declarator, [(] begins a parameter list rather than a nested
   declarator where the declarator may be abstract and the [(] is
   followed by [)] or a declaration specifier, a typedef name included
   (6.7.6.3p11), except that in a parameter a universe name there is the
   name that the parameter declares, as in C (design 2.3). GNU
   attributes may begin either, so GCC decides at the token after them,
   and so does the parser. *)
let opens_nested_declarator state form =
  let next = past_attributes state 1 in
  let begins_parameters () =
    peek_at state next = Punctuator_token P.Right_paren
    || starts_declaration state next
  in
  match form with
  | Named -> true
  | Abstract -> not (begins_parameters ())
  | Named_or_abstract ->
      names_universe_declaration state next || not (begins_parameters ())

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
   scope begins: its constructor and its sub-patterns (design 4.7,
   Appendix A). *)
type pattern_words = {
  constructor : identifier;
  sub_patterns : (span * sub_pattern_words) list option;
}

(* A sub-pattern as read: a pattern, which without a field list is an
   identifier alone and may be [_]; [*] and a pattern; or a typed
   binding, its type name and its identifier. *)
and sub_pattern_words =
  | Pattern_words of pattern_words
  | Followed_words of pattern_words
  | Typed_words of { type_name : type_name; name : identifier }

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
        match visible state name with
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

(* An instance writes the head of a generic function as its prototype
   and again at its definition, so a body there would define its type
   twice (design 7.1 rule 6). At the [{] of a structure, union or
   enumeration specifier. *)
let refuse_body_in_generic_head state =
  if state.in_generic_head then
    fail state
      (Rule.message Generic_function_form
         "the head of a generic function defines no structure, union or \
          enumeration, which every instance would define twice")

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
         (quoted name.node ^ " names two type parameters of one generic"));
  { name; declared = declare state ~kind:Type_parameter name }

(* After the [(] of the type parameters of a generic (design 3.5, 7.1):
   the parameters, to the [)], declared in the innermost scope. *)
let type_parameter_list state =
  let rec parameters declared =
    let name = identifier state "the name of a type parameter" in
    let declared = declare_type_parameter state name :: declared in
    if accept state P.Comma then parameters declared
    else begin
      expect state P.Right_paren "`,` or `)` after a type parameter";
      List.rev declared
    end
  in
  parameters []

(* Runs [parse] with the scope at the cursor standing for file scope, as
   that of the type parameters of a generic does (design 3.5 rule 8). *)
let with_parameter_scope state parse =
  let saved = state.parameter_depth in
  state.parameter_depth <- Some (Scope.depth state.scope);
  let result = parse () in
  state.parameter_depth <- saved;
  result

(* At the [(] after the name of a generic type, which is declared at file
   scope only, where its instances are emitted (design 3.1), and has no
   universe name (3.6) unless the universe text declares it: its type
   parameters, which a scope of their own declares. *)
let generic_head state (checked : Spelling.type_name spanned) =
  let name = (checked :> identifier) in
  if not (Scope.is_file state.scope) then
    fail_at_token state (token_of name)
      (Rule.message Generic_scope
         (Printf.sprintf
            "the generic type %s is declared in a block; a generic type is \
             declared at file scope only"
            (quoted name.node)));
  if
    Universe.find name.node <> None
    && not (is_universe_text_at state (token_of name))
  then
    fail_at_token state (token_of name)
      (Rule.message Generic_universe_name
         (quoted name.node ^ " is a universe name, which no generic type has"));
  advance state;
  let parameter_names, parameter_frame =
    run_in_scope state (inner_scope state) (fun () ->
        type_parameter_list state)
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
      let generic = Some { bodies_allowed; in_alignment = false } in
      in_scope state scope (fun () ->
          with_parameter_scope state (fun () ->
              with_generic state ~in_type_argument:false generic parse))

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
    | Alignas_word -> Alignment_specifier (alignment state start)
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
  | Not_a_type | Typedef_name | Declared_type _ | Derived_enumerator
  | Generic_function_name ->
      ());
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

(* Where a declaration must begin and does not. *)
and refuse_declaration state = fail_expected state "a declaration"

(* After the [typeof]. *)
and typeof_specifier state =
  expect state P.Left_paren "`(` after `typeof`";
  let specifier =
    if starts_type_name state 0 then Typeof_type (type_name state)
    else Typeof_expression (expression state)
  in
  expect state P.Right_paren "`)` after the operand of `typeof`";
  specifier

(* Design 13.3 reads an alignment specifier as the attribute [aligned],
   recorded at its [_Alignas], at [start], with its operand, which typing
   reads, as its arguments, whose identifiers the rule of a generic reads
   as those of any attribute. *)
and alignment state start =
  let name = finish state start "aligned" in
  expect state P.Left_paren "`(` after `_Alignas`";
  let view = view_here state in
  let operand_start = state.position in
  let alignment =
    read_alignment_operand state (fun () ->
        if starts_type_name state 0 then Alignas_type (type_name state)
        else Alignas_expression (constant_expression state))
  in
  let operand = span_from state operand_start in
  state.views <-
    {
      state.views with
      alignments = Places.add operand.first view state.views.alignments;
    };
  note_occurrence state
    (finish state start { name; arguments = Some operand });
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
  if has_body then begin
    refuse_body_in_generic_head state;
    refuse_generic_body state ~tag_name
  end;
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
  if has_body then begin
    refuse_body_in_generic_head state;
    refuse_generic_enumerators state
  end;
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
  else if
    starts_declaration state 0
    && not (form <> Abstract && is_c_text_universe_parameter state 0)
  then begin
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
    | Identifier_token name
      when is_typedef_name state name
           && not (is_c_text_universe_parameter state 0) ->
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
  let hoist = hoistable state in
  let rec loop left =
    if accept state P.Comma then begin
      hoist ();
      let right = assignment_expression state in
      loop (finish state start (Comma (left, right)))
    end
    else left
  in
  loop (assignment_expression state)

and constant_expression state = conditional_expression state

(* Assignment is right-associative: the targets are collected in a loop
   as prefixes of the value after them, and the nodes made from the
   right. *)
and assignment_expression state =
  let rec collect prefixes =
    let start = state.position in
    let operand = conditional_expression state in
    match assignment_operator (peek state) with
    | Some operator when is_unary_expression operand ->
        advance state;
        let assign right = Assignment (operator, operand, right) in
        collect ((start, assign) :: prefixes)
    | Some _ ->
        fail state
          (Rule.c_text
             (Printf.sprintf "the left operand of %s is not a unary expression"
                (found state)))
    | None -> (operand, prefixes)
  in
  let value, prefixes = collect [] in
  List.fold_left
    (fun right (start, prefix) -> finish state start (prefix right))
    value prefixes

(* Right-associative like assignment: [a ? b : c ? d : e] groups as
   [a ? b : (c ? d : e)]. GNU [a ?: b] omits the middle operand. *)
and conditional_expression state =
  let rec collect branches =
    let start = state.position in
    let hoist = hoistable state in
    let condition = binary_expression state lowest_precedence in
    if accept state P.Question then begin
      hoist ();
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
  let hoist = hoistable state in
  let rec loop left =
    match binary_operator (peek state) with
    | Some (operator, precedence) when precedence >= minimum ->
        if operator = Logical_and || operator = Logical_or then hoist ();
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
   cast-expression. GNU [&&] label is a whole unary-expression. A [try]
   takes a cast-expression, as a unary operator does (design 5.1 rule
   3, Appendix A). *)
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
    | Identifier_token _ when begins_try state ->
        let apply = try_prefix state in
        collect ((start, apply) :: prefixes) ~cast_allowed:true
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
  | Punctuator_token P.Left_paren when names_instance state operand ->
      advance state;
      let type_arguments = type_arguments_of_instance state in
      continue_with (Instance { generic = operand; type_arguments })
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
  let variant = named_type_name state name ordinary in
  expect state P.Dot "`.` after the type name";
  let constructor = identifier state "a constructor name after `.`" in
  let named =
    finish state start (Qualified_constructor { variant; constructor })
  in
  postfix_operators state start named

(* At the typedef name [name], which [ordinary] declares: the type name
   of it alone, or of its application, as a qualified constructor and a
   typed binding write it (design 3.3, 4.7 rule 4). *)
and named_type_name state name ordinary =
  let start = state.position in
  advance state;
  let at = first_token state start in
  let specifier =
    finish state start (Type_specifier (named_type state name ordinary ~at))
  in
  finish state start { specifier_qualifiers = [ specifier ]; abstract = None }

(* After the [(] of a call, up to and including the [)]. *)
(* Design 7.2 rule 4: at the [(] after the name of a generic function, a
   type name begins the type arguments of an explicit instance. The
   parser decides it before any target type is known, as it decides a
   cast after [(] (design 3.3), so an unqualified constructor that is a
   typedef name cannot be the first argument of a call of a generic. *)
and names_instance state (operand : expression) =
  match operand.node with
  | Identifier { name; resolution = Resolved _ } -> (
      match visible state name with
      | Some { kind = Generic_function_name; _ } -> starts_type_name state 1
      | Some _ | None -> false)
  | _ -> false

(* After the [(] of an explicit instance: the type names, to the [)]. *)
and type_arguments_of_instance state =
  let rec loop type_arguments =
    let type_arguments = type_name state :: type_arguments in
    if accept state P.Comma then loop type_arguments
    else begin
      expect state P.Right_paren "`,` or `)` after a type argument";
      List.rev type_arguments
    end
  in
  loop []

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

(* At an identifier where an expression begins: an operator of section
   8 where its universe name is not hidden, and otherwise a name. *)
and name_operand state name =
  let start = state.position in
  match (visible state name, Universe.find name) with
  | None, Some { meaning = Slice_operator operator; _ } ->
      take_statement_view state;
      advance state;
      let operation = slice_operation state name operator in
      finish state start (Slice_operation operation)
  | _ ->
      let resolution = resolve state name in
      advance state;
      finish state start (Identifier { name; resolution })

(* After the name of an operator of section 8, its parenthesized
   operands, as many as the operator takes. *)
and slice_operation state name (operator : Universe.slice_operator) =
  let after = "after an operand of " ^ quoted name in
  expect state P.Left_paren ("`(` after " ^ quoted name);
  let operand ~last =
    let value = assignment_expression state in
    if last then expect state P.Right_paren ("`)` " ^ after)
    else expect state P.Comma ("`,` " ^ after);
    value
  in
  match operator with
  | From_array -> Slice_from_array
        (array_operand state (fun () -> operand ~last:true))
  | Sub ->
      let slice = operand ~last:false in
      let low = operand ~last:false in
      Slice_sub { slice; low; high = operand ~last:true }
  | Unchecked ->
      let pointer = operand ~last:false in
      Slice_unchecked { pointer; count = operand ~last:true }

(* [read] of the operand of a [slice_from_array], with the labels it
   may define (refuse_label_in_array_operand). *)
and array_operand state read =
  let saved = state.array_operand in
  state.array_operand <-
    Option.map
      (fun around -> { around; first = first_token state state.position })
      state.labels;
  Fun.protect ~finally:(fun () -> state.array_operand <- saved) read

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
      let body = statement_expression_body state in
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
  scan_unread state Unread_block_literal (span_from state start);
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
  let outside = declares_outside state in
  let kind =
    if outside then Generic_function_name else declared_kind specifiers
  in
  let declared =
    declare_in state ~outside ~kind (named_identifier state declarator)
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
   parameters of [head] are visible in. A generic type claims no
   derived name of its own, but those of its instances (design 10.3). *)
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
  (* A block item reaches here only after a label, as [read_block_item]
     reads a defer itself. *)
  | _ when begins_defer state -> refuse_defer_as_statement state opened
  | Keyword_token Keyword.If ->
      holds_place state;
      advance state;
      open_block_statement ~body_jumps:outer_jumps (fun () ->
          let condition =
            condition state "if" ~controlling_jumps:outer_jumps
              ~test_jumps:outer_jumps
          in
          let statement_scope = state.scope in
          fun () -> Open_if { condition = condition (); statement_scope })
  | Keyword_token Keyword.Switch ->
      holds_place state;
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

(* At a defer that [open_statements] meets inside [opened], which is no
   block item. With nothing open it is the statement of a defer, as
   [read_block_item] reads every other defer, and braces would not help
   there: rule 11 refuses a defer anywhere in that statement. *)
and refuse_defer_as_statement state opened =
  match opened with
  | [] -> fail state defer_in_deferred
  | { kind = Open_labeled _; _ } :: _ ->
      fail_defer_position state
        "the statement of a label; write it in a compound statement"
  | _ :: _ ->
      fail_defer_position state
        "the substatement of a statement; write it in a compound statement"

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

(* A statement without a substatement, after its labels. *)
and simple_statement state = in_place state read_simple_statement

and read_simple_statement state =
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
      take_statement_view state;
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
      take_statement_view state;
      advance state;
      let loop = continue_target state start in
      expect state P.Semicolon "`;` after `continue`";
      finish state start (Continue { loop })
  | Keyword_token Keyword.Break ->
      take_statement_view state;
      advance state;
      let leaves = break_target state start in
      expect state P.Semicolon "`;` after `break`";
      finish state start (Break { leaves })
  | Keyword_token Keyword.Return ->
      take_statement_view state;
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
        else items (block_item state Plain_block :: read)
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

(* After the [case], or where a sub-pattern begins, which [expected]
   names: a constructor and its sub-patterns. *)
and pattern_words ?(expected = "a constructor after `case`") state =
  let constructor = identifier state expected in
  let sub_patterns =
    if accept state P.Left_paren then begin
      let read = one_or_more state sub_pattern_words in
      expect state P.Right_paren "`)` after the sub-patterns of a pattern";
      Some read
    end
    else None
  in
  { constructor; sub_patterns }

(* Design 4.7 rule 4: what follows a name tells a typed binding from a
   pattern, whatever names are visible. An identifier follows the type
   name of a typed binding, directly or after the type arguments of an
   application; [,] or [)] follows a pattern. *)
and sub_pattern_words state =
  let start = state.position in
  let node =
    if accept state P.Star then
      Followed_words (pattern_words ~expected:"a constructor after `*`" state)
    else if begins_typed_binding state then typed_binding_words state
    else Pattern_words (pattern_words ~expected:"a sub-pattern" state)
  in
  (span_from state start, node)

and begins_typed_binding state =
  match (peek state, peek_at state 1) with
  | Identifier_token _, Identifier_token _ -> true
  | Identifier_token _, Punctuator_token P.Left_paren ->
      is_identifier (peek_at state (past_group state P.Left_paren 1))
  | _ -> false

(* [T x], where [T] is a typedef name or the application of a generic
   type. *)
and typed_binding_words state =
  let name = next_spelling state in
  match typedef_declaration state name with
  | None ->
      fail state
        (Rule.c_text
           (Printf.sprintf
              "expected a type name before the binding of a sub-pattern, \
               found %s"
              (found state)))
  | Some ordinary ->
      let type_name = named_type_name state name ordinary in
      Typed_words { type_name; name = identifier state "a binding" }

(* The pattern [words], whose bindings enter the current scope here: the
   one place that declares a binding (design 4.1 rule 4). An identifier
   alone enters scope as a binding also where its position, which typing
   reads, makes it a constructor (4.7 rule 3). *)
and bound_pattern state (words : pattern_words) : pattern =
  { constructor = words.constructor;
    sub_patterns =
      Option.map (List.map (bound_sub_pattern state)) words.sub_patterns }

and bound_sub_pattern state ((span : span), (words : sub_pattern_words)) =
  let bind name = declare state ~kind:Not_a_type name in
  let node =
    match words with
    | Pattern_words { constructor; sub_patterns = None }
      when constructor.node = wildcard_word ->
        Wildcard
    | Pattern_words { constructor = name; sub_patterns = None } ->
        Alone { name; declared = bind name }
    | Pattern_words words -> Nested (bound_pattern state words)
    | Followed_words words -> Followed (bound_pattern state words)
    | Typed_words { type_name; name } ->
        Typed_binding { type_name; name; declared = bind name }
  in
  spanned state span node

(* After the [asm]: its qualifiers, and its template and operands in
   parentheses. *)
and assembler state =
  let qualifiers = asm_qualifiers state in
  expect state P.Left_paren "`(` after `asm`";
  let template = string_literal state in
  let takes_labels =
    List.exists
      (fun (qualifier : asm_qualifier spanned) -> qualifier.node = Asm_goto)
      qualifiers
  in
  let operands =
    if peek state = Punctuator_token P.Colon then
      Some (asm_operands state ~takes_labels)
    else None
  in
  expect state P.Right_paren "`:` or `)` in `asm`";
  { qualifiers; template; operands }

(* At the first [:] after the template. Only an [asm goto] has labels,
   its jumps, which GCC and Clang read in no other (GCC manual,
   "Extended Asm"). *)
and asm_operands state ~takes_labels =
  let section read = if accept state P.Colon then read () else [] in
  let outputs = section (fun () -> comma_separated state asm_operand) in
  let inputs = section (fun () -> comma_separated state asm_operand) in
  let clobbers = section (fun () -> comma_separated state string_literal) in
  let labels =
    if takes_labels then
      section (fun () ->
          comma_separated state (fun state ->
              jump_label state (identifier state "a label")))
    else if peek state = Punctuator_token P.Colon then
      fail state
        (Rule.c_text
           "labels after the clobbers of an `asm` without `goto` (GCC \
            manual, \"Extended Asm\")")
    else []
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

and statement_expression_body state =
  in_scope state (inner_scope state) (fun () ->
      compound_in state Statement_expression_body)

(* From the [{] to the [}], in the current scope: the body of a function
   definition is in the block scope of its parameters (6.2.1p4), so that
   a declaration in it cannot hide one of them (6.7p3). *)
and compound_statement state = compound_in state Plain_block

and compound_in state place =
  let start = state.position in
  expect state P.Left_brace "`{`";
  in_local_label_scope state (fun () ->
      let local_labels = local_label_declarations state in
      let items = block_items state place in
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
and block_items state place =
  let rec loop read =
    match peek state with
    | Punctuator_token P.Right_brace ->
        take_statement_view state;
        advance state;
        close_scope ~scope_end:(last_read state) read
    | End_of_input -> fail_expected state "`}` to end a compound statement"
    | _ -> loop (block_item state place :: read)
  in
  loop []

and block_item state place = in_place state (read_block_item place)

(* A label comes first: [T:] begins one where [T] is a typedef name. Then
   attributes before a [;], which begin a declaration elsewhere. *)
and read_block_item place state =
  if begins_label state || begins_attribute_statement state then
    Complete (Block_statement (statement state))
  else if begins_defer state then Complete (defer_statement state place)
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

(* Design section 6: at the [defer] or [_Defer] that [begins_defer]
   recognises. The statement is a block of its own (rule 8), and moved
   text, whose pragma lines need identifiers (13.5). *)
and defer_statement state place =
  let keyword = first_token state state.position in
  refuse_defer_place state place;
  take_statement_view state;
  advance state;
  let statement =
    as_deferred state (fun () ->
        in_scope state (inner_scope state) (fun () -> statement state))
  in
  refuse_pragma_before_defer state ~keyword;
  let keyword = { first = keyword; last = keyword } in
  refuse_moved_pragmas state
    (Tree.deferred_text ~keyword ~statement:statement.span);
  refuse_deferred state statement;
  Block_defer { keyword; statement }

(* At a defer statement that is a block item of a compound statement in
   [place] (design 6 rule 11). Only a function body holds statements
   that run, as a block outside one stands in a statement expression. *)
and refuse_defer_place state place =
  match place with
  | Statement_expression_body ->
      fail_defer_position state
        "a block item of the compound statement of a statement expression, \
         whose last item gives its value"
  | Plain_block when Option.is_none state.labels ->
      fail_defer_position state "outside every function body"
  | Plain_block -> ()

(* GCC's nested functions are outside the profile, as Clang has none; a
   [{] after the first declarator names them rather than the [;]. *)
and block_declaration state =
  match declaration_start state with
  | First_declarator { first = { named_function = Some _; _ }; _ }
    when peek state = Punctuator_token P.Left_brace ->
      fail state
        (Rule.message Profile
           "a function definition in a block (a GNU nested function) is \
            outside the GNU profile")
  | start -> declaration_of_start state start

(* External declarations (C11 6.9). *)

(* At the [{]. A body whose [{] is C text of a system header is not parsed
   (design 13.3): it is written for its own compiler and may use any of
   its extensions. Any other body is read, each token as the text it
   is. *)
let function_body state =
  if is_system_c_text_at state (first_token state state.position) then
    Skipped (skip_balanced state Unread_body "`}` to end the function body")
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
  finish state start
    {
      specifiers;
      declarator = first.declarator;
      declared = first.declared;
      attributes = first.attributes;
      declarations;
      body;
    }

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
          Function_definition
            (function_definition state start specifiers first named)
      | declaration_start ->
          External_declaration (declaration_of_start state declaration_start))

(* A generic function (design 7.1) is recognised by position, as a type
   declaration is: [generic] and [(] where an external declaration
   begins, except where [generic] is visible as a typedef name (design
   2.3). C11 has no implicit [int], so no C declaration begins so. *)
let generic_word = "generic"

let begins_generic_function state =
  peek state = Identifier_token generic_word
  && peek_at state 1 = Punctuator_token P.Left_paren
  && not (is_typedef_name state generic_word)

(* Design 7.1 rule 6: what follows [generic( )] is one function that
   its instances are written from. *)
let fail_generic_form state token reason =
  fail_at_token state token (Rule.message Generic_function_form reason)

let fail_one_function state token =
  fail_generic_form state token
    "`generic( )` prefixes one function: its definition, or a \
     declaration with one declarator, which declares a function"

(* What every declaration of a generic function meets: a prototype, an
   instance's own, which deduction reads (7.2); internal linkage, which
   every instance has; and an instance's own name. *)
let check_generic_head state specifiers (first : scoped_declarator) =
  let at_declarator = first_token state first.declarator_start in
  (match first.named_function with
  | Some { parameters = Prototype _; _ } -> ()
  | Some { parameters = Identifier_list _; _ } ->
      fail_generic_form state at_declarator
        "a generic function has a prototype, `(void)` where it takes no \
         argument, and neither `()` nor an identifier list"
  | None -> fail_one_function state at_declarator);
  let storage (specifier : declaration_specifier spanned) =
    match specifier.node with
    | Storage_class Static -> ()
    | Storage_class _ ->
        fail_generic_form state specifier.span.first
          "`static` is the only storage class of a generic function, \
           whose instances have internal linkage"
    | Type_specifier _ | Type_qualifier _ | Function_specifier _
    | Alignment_specifier _ | Attributes _ ->
        ()
  in
  List.iter storage specifiers;
  match first.asm_label with
  | Some _ ->
      fail_generic_form state at_declarator
        "an assembler label would give every instance of a generic \
         function one name"
  | None -> ()

(* A declaration that is no definition writes nothing into an instance,
   so it carries nothing that the backend would not be told. *)
let check_generic_prototype state start specifiers =
  let refuse token =
    fail_generic_form state token
      "`_Noreturn` and attributes stand on the definition of a generic \
       function, which its instances are written from"
  in
  let carried (specifier : declaration_specifier spanned) =
    match specifier.node with
    | Function_specifier Noreturn -> refuse specifier.span.first
    | Storage_class _ | Type_specifier _ | Type_qualifier _
    | Function_specifier Inline | Alignment_specifier _ | Attributes _ ->
        ()
  in
  List.iter carried specifiers;
  match attributes_in state.views (span_from state start) with
  | attribute :: _ -> refuse attribute.span.first
  | [] -> ()

(* The one declarator of a generic prototype, after its first. *)
let generic_prototype state start specifiers first =
  let declaration =
    declaration_of_start state (First_declarator { start; specifiers; first })
  in
  match declaration.node with
  | Declaration { specifiers; declarators = [ declarator ] }
    when Option.is_none declarator.node.initialiser ->
      Generic_prototype { specifiers; declarator }
  | Declaration { declarators = [ declarator ]; _ } ->
      fail_one_function state declarator.span.first
  | Declaration { declarators = _ :: second :: _; _ } ->
      fail_one_function state second.span.first
  | Declaration { declarators = []; _ } | Static_assert _ ->
      fail_one_function state declaration.span.first

(* What follows the type parameters of a generic function: the
   definition or the declaration of one function, and the declarator of
   its name. *)
let generic_form state =
  let head () =
    state.in_generic_head <- true;
    Fun.protect
      ~finally:(fun () -> state.in_generic_head <- false)
      (fun () -> declaration_start state)
  in
  match head () with
  | First_declarator { start; specifiers; first } -> (
      check_generic_head state specifiers first;
      match first.named_function with
      | Some named when begins_definition state named ->
          let definition =
            function_definition state start specifiers first named
          in
          (Generic_definition definition, first.declarator)
      | Some _ | None ->
          check_generic_prototype state start specifiers;
          (generic_prototype state start specifiers first, first.declarator))
  | Complete declaration -> fail_one_function state declaration.span.first

(* The function's name, which is declared at file scope, meets the rules
   of a type name there, as its instances are named as those of a
   generic type are (design 7.1 rule 1, 3.1 rules 6 and 7), and claims
   the names of its instances (10.3). *)
let check_generic_name state declarator =
  match Tree.declared_identifier declarator with
  | None -> fail_one_function state (first_token state state.position)
  | Some name ->
      ignore
        (checked_spelling state ~at_file_scope:true name
           ~what:"generic function");
      claim_instance_space state name

(* At the [generic] that [begins_generic_function] recognises. The type
   parameters are declared in a scope of their own, which stands for
   file scope while the function is read (design 3.5 rule 8), and the
   function in file scope around it. *)
let generic_function state =
  let start = state.position in
  advance state;
  advance state;
  let (type_parameters, (generic, declarator)), left =
    run_in_scope state (inner_scope state) (fun () ->
        let type_parameters = type_parameter_list state in
        let form =
          with_parameter_scope state (fun () ->
              state.names_generic_function <- true;
              generic_form state)
        in
        (type_parameters, form))
  in
  state.scope <- Scope.outer left;
  check_generic_name state declarator;
  finish state start ({ type_parameters; generic } : generic_function_node)

(* Whether the cursor is at the universe text, which stands in front of
   the unit's own text where the reader holds it (design 13.3). *)
let at_universe_text state =
  peek state <> End_of_input
  && is_universe_text_at state (first_token state state.position)

(* An external declaration and the view in front of it (design 13.5). *)
let external_declaration state =
  let view = view_here state in
  if begins_type_declaration state then
    let declaration = type_declaration state in
    Until_scope_end
      (fun scope_end -> (Type_declaration { declaration; scope_end }, view))
  else if begins_generic_function state then
    Complete (Generic_function (generic_function state), view)
  else Complete (c_external_declaration state, view)

(* The generics of the universe text, latest first, each with the scope
   in front of it, read in a scope of their own, the universe scope. The
   text declares generics alone (design 3.6), so anything else in it is
   a syntax error. *)
let universe_declarations state =
  let rec loop read =
    if at_universe_text state then begin
      let view = view_here state in
      let declaration = type_declaration state in
      let scoped scope_end =
        (({ declaration; scope_end } : scoped_type_declaration), view)
      in
      loop (Until_scope_end scoped :: read)
    end
    else read
  in
  loop []

(* The generics of the universe text and the unit's own external
   declarations, each with the scope in front of it; file scope opens
   inside the universe scope after the generics. Both scopes close with
   the text, whose last tokens may be pragma tokens, which stand in file
   scope. *)
let translation_unit state ~keywords =
  let universe = universe_declarations state in
  state.scope <- initial_scope keywords ~universe:state.scope;
  let rec loop read =
    if peek state = End_of_input then read
    else loop (in_place state external_declaration :: read)
  in
  let own = loop [] in
  let tokens = Array.length state.reader.tokens in
  take_pragma_views state ~before:tokens;
  let scope_end = tokens - 1 in
  (close_scope ~scope_end universe, close_scope ~scope_end own)

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
  type t = view

  let empty = empty_view
  let find view name = Scope.find view.scopes name

  let find_tag view name =
    Option.map
      (fun (entry : tag_entry) -> entry.tag)
      (Scope.find_tag view.scopes name)

  let find_local_label (view : view) name =
    Option.map
      (fun (entry : label_entry) -> entry.identity)
      (Names.find_opt name view.local_labels)
end

type scopes = {
  file_scope : file_scope;
  universe : (scoped_type_declaration item * View.t) list;
  declarations : (external_declaration item * View.t) list;
  views : views;
  longest_type_name : int;
}

(* [attribute_arguments] keeps a view under the first token of each span
   of arguments that it makes, which is the only way a parsed attribute
   gets one, so [Places.find] finds it. *)
let attribute_view (views : views) (attribute : attribute) =
  Option.map
    (fun (arguments : span) ->
      match Places.find_opt arguments.first views.alignments with
      | Some view -> view
      | None -> snd (Places.find arguments.first views.attributes))
    attribute.node.arguments

let attributes_within (views : views) (span : span) =
  Places.to_seq_from span.first views.attributes
  |> Seq.take_while (fun (first, _) -> first <= span.last)
  |> Seq.map snd |> List.of_seq

let pragma_view (views : views) token = Places.find_opt token views.pragmas

let pragmas_within (views : views) (span : span) =
  Places.to_seq_from span.first views.pragmas
  |> Seq.take_while (fun (index, _) -> index <= span.last)
  |> List.of_seq
let try_views (views : views) token = Places.find_opt token views.tries

let statement_view (views : views) token =
  Places.find_opt token views.statements

let parse_with_scopes ~keywords reader =
  let state =
    {
      reader;
      keywords;
      grammar = grammar_tokens keywords reader;
      position = 0;
      open_brackets = [];
      scope = Scope.file;
      place = empty_view;
      place_start = 0;
      jumps = Function_body;
      arm = None;
      labels = None;
      array_operand = None;
      generic = None;
      parameter_depth = None;
      names_generic_function = false;
      in_type_argument = false;
      in_generic_head = false;
      views =
        {
          attributes = Places.empty;
          occurrences = Places.empty;
          alignments = Places.empty;
          pragmas = Places.empty;
          tries = Places.empty;
          statements = Places.empty;
        };
      generics = Name_set.empty;
      longest_type_name = 0;
      counter = Spanned.counter ~max_depth;
    }
  in
  match
    refuse_generated_names state;
    refuse_pragmas_without_tokens state;
    translation_unit state ~keywords
  with
  | universe, declarations ->
      (* Every scope the unit opens is closed, so [state.scope] is file
         scope as the unit leaves it. *)
      let file_scope = file_scope_declarations state.scope in
      let item (declaration, view) = (Anchor.item declaration, view) in
      let universe = List.map item universe in
      let declarations = List.map item declarations in
      let scopes =
        {
          file_scope;
          universe;
          declarations;
          views = state.views;
          longest_type_name = state.longest_type_name;
        }
      in
      Ok (List.map fst declarations, scopes)
  | exception Failed error -> Error error

let parse ~keywords reader =
  Result.map fst (parse_with_scopes ~keywords reader)

let error_message = Reader.error_message
