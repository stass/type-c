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
   So [advance] bounds the recursion by bounding the brackets open. C11
   5.2.4.1 asks for 63 levels of parentheses in an expression; 256 is the
   bracket depth Clang accepts by default, enough for real code, and
   keeps the stack small. *)
let max_nesting = 256

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

(* What the cursor holds open: a bracket, or the [?] of a conditional,
   which its [:] closes. *)
type opening = Open_bracket | Open_conditional

(* What an ordinary identifier in scope is. Stage 1 adds the universe
   names of design 2.3. *)
type binding = Typedef_name_binding | Ordinary_binding

module Scope = Map.Make (String)

(* The cursor. [scope] is persistent, so leaving a scope restores the map
   saved on entering it; block scopes use the same mechanism. *)
type state = {
  reader : Reader.t;
  grammar : grammar_token array;
  mutable position : int;  (** in [grammar] *)
  mutable open_brackets : opening list;
      (** read and not yet closed, innermost first *)
  mutable scope : binding Scope.t;
}

(* The function derivation applied to the name that a declarator
   declares: its parameters, and the scope at their [)], which the body of
   a definition continues (6.2.1p4). *)
type named_function = {
  parameters : parameters;
  parameter_scope : binding Scope.t;
}

(* Raised at the first token that the grammar does not accept. *)
exception Failed of error

(* Reading the grammar tokens. *)

(* The lexeme of a token, or None for a pragma: C gives a pragma no place
   in the grammar and one may stand between any two tokens, so the
   grammar passes over it. A [#pragma typec] line is passed over the same
   way until Stage 5 gives it a meaning. *)
let lexeme_of reader (token : Token.t) =
  match token.kind with
  | Token.Identifier -> (
      let spelling = Reader.spelling reader token in
      match Keyword.of_spelling spelling with
      | Some keyword -> Some (Keyword_token keyword)
      | None -> Some (Identifier_token spelling))
  | Token.Number -> Some Number_token
  | Token.Character encoding -> Some (Character_token encoding)
  | Token.String encoding -> Some (String_token encoding)
  | Token.Punctuator punctuator -> Some (Punctuator_token punctuator)
  | Token.Pragma | Token.Typec_pragma -> None

let grammar_tokens (reader : Reader.t) =
  Array.to_seqi reader.tokens
  |> Seq.filter_map (fun (index, token) ->
         Option.map (fun lexeme -> { lexeme; index }) (lexeme_of reader token))
  |> Array.of_seq

let peek_at state offset =
  let position = state.position + offset in
  if position < Array.length state.grammar then
    state.grammar.(position).lexeme
  else End_of_input

let peek state = peek_at state 0

(* Spans. A node starts at a grammar position taken before it is read and
   ends at the last token read, so [finish] is the only way to make one
   and every node holds at least one token. *)

let span_from state start =
  {
    first = state.grammar.(start).index;
    last = state.grammar.(state.position - 1).index;
  }

let finish state start node = { span = span_from state start; node }

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

let fail state message =
  raise (Failed { location = error_location state; message })

let quoted spelling =
  if String.length spelling <= max_quoted_spelling then "`" ^ spelling ^ "`"
  else "`" ^ String.sub spelling 0 max_quoted_spelling ^ "...`"

let found state =
  match peek state with
  | End_of_input -> "end of input"
  | Keyword_token _ | Identifier_token _ | Punctuator_token _ | Number_token
  | Character_token _ | String_token _ ->
      quoted (next_spelling state)

let fail_expected state expected =
  fail state (Printf.sprintf "expected %s, found %s" expected (found state))

let open_one state opening =
  if List.length state.open_brackets = max_nesting then
    fail state
      (Printf.sprintf "more than %d nested brackets or conditionals"
         max_nesting);
  state.open_brackets <- opening :: state.open_brackets

(* The one way the cursor moves, called only after [peek] has matched a
   token. A closing bracket closes the innermost one open, whatever its
   kind: the grammar reports a mismatch, and in a body it skips, the body
   ends where the brackets say. A [:] closes a [?] and nothing else. *)
let advance state =
  (match (peek state, state.open_brackets) with
  | Punctuator_token (P.Left_paren | P.Left_bracket | P.Left_brace), _ ->
      open_one state Open_bracket
  | Punctuator_token P.Question, _ -> open_one state Open_conditional
  | Punctuator_token (P.Right_paren | P.Right_bracket | P.Right_brace),
    _ :: outer
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

(* Scopes of ordinary identifiers (C11 6.2.1), which say whether an
   identifier is a typedef name. *)

let is_typedef_name state name =
  Scope.find_opt name state.scope = Some Typedef_name_binding

let declare state name binding =
  state.scope <- Scope.add name binding state.scope

(* Runs [parse] in a scope nested in the current one and returns its
   result with the nested scope as [parse] left it. An error abandons the
   state, so the scope needs no restoring on one. *)
let nested_scope state parse =
  let saved = state.scope in
  let result = parse () in
  let nested = state.scope in
  state.scope <- saved;
  (result, nested)

let within_scope state parse = fst (nested_scope state parse)

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
  | Typedef_word of string

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
  | Struct -> Some (Struct_word Struct)
  | Union -> Some (Struct_word Union)
  | Enum -> Some Enum_word
  | Alignas -> Some Alignas_word
  | Break | Case | Continue | Default | Do | Else | For | Goto | If | Return
  | Sizeof | Switch | While | Alignof | Generic | Imaginary | Static_assert ->
      None

(* The specifier that the token [offset] places ahead begins. A typedef
   name is one only where no other type specifier precedes it, which the
   caller decides. *)
let specifier_word state offset =
  match peek_at state offset with
  | Keyword_token keyword -> keyword_specifier_word state offset keyword
  | Identifier_token name when is_typedef_name state name ->
      Some (Typedef_word name)
  | Identifier_token _ | Punctuator_token _ | Number_token
  | Character_token _ | String_token _ | End_of_input ->
      None

let starts_declaration state offset = specifier_word state offset <> None

(* A declaration begins with a specifier or with [_Static_assert]. *)
let begins_declaration state =
  starts_declaration state 0 || peek state = Keyword_token Keyword.Static_assert

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
   alignment specifier, as in C17 (DR 444). *)
let starts_type_name state offset =
  match specifier_word state offset with
  | Some (Storage_word _ | Function_word _) | None -> false
  | Some
      ( Qualifier_word _ | Basic_word _ | Atomic_type_word | Struct_word _
      | Enum_word | Alignas_word | Typedef_word _ ) ->
      true

(* [(] followed by a type name, [offset] tokens ahead: a cast, a compound
   literal or the operand of [sizeof]. *)
let opens_type_name_at state offset =
  peek_at state offset = Punctuator_token P.Left_paren
  && starts_type_name state (offset + 1)

(* Which specifiers a context takes: a specifier-qualifier list has no
   storage class or function specifier. *)
type specifier_context = Declaration_specifiers | Specifier_qualifiers

let allowed context word =
  match (context, word) with
  | Specifier_qualifiers, Some (Storage_word _ | Function_word _) -> None
  | (Declaration_specifiers | Specifier_qualifiers), _ -> word

let is_type_specifier = function
  | Type_specifier _ -> true
  | Storage_class _ | Type_qualifier _ | Function_specifier _
  | Alignment_specifier _ ->
      false

let declares_typedef specifiers =
  List.exists (fun specifier -> specifier.node = Storage_class Typedef)
    specifiers

let is_identifier = function
  | Identifier_token _ -> true
  | Keyword_token _ | Punctuator_token _ | Number_token | Character_token _
  | String_token _ | End_of_input ->
      false

let fail_type_name state expected name =
  fail state
    (Printf.sprintf "expected %s, found the type name %s" expected
       (quoted name))

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
        | Struct_word _ | Enum_word | Alignas_word | Typedef_word _ )
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
  | _ -> None

(* The left operand of an assignment is a unary-expression (6.5.16); any
   other expression ends before the assignment operator. *)
let is_unary_expression expression =
  match expression.node with
  | Binary _ | Conditional _ | Cast _ | Assignment _ | Comma _ -> false
  | Identifier _ | Constant _ | Character _ | String _ | Parenthesized _
  | Generic _ | Compound_literal _ | Subscript _ | Call _ | Member _
  | Pointer_member _ | Post_increment _ | Post_decrement _ | Unary _
  | Sizeof_expression _ | Sizeof_type _ | Alignof _ ->
      true

(* Which declarators a context takes: a declaration names what it
   declares, a type name does not, and a parameter may do either. *)
type declarator_form = Named | Abstract | Named_or_abstract

(* In a declarator, [(] begins a parameter list rather than a nested
   declarator where the declarator may be abstract and the [(] is
   followed by [)] or a declaration specifier, a typedef name included
   (6.7.6.3p11). *)
let opens_nested_declarator state form =
  match form with
  | Named -> true
  | Abstract | Named_or_abstract ->
      not
        (peek_at state 1 = Punctuator_token P.Right_paren
        || starts_declaration state 1)

(* Whether a declarator is its name, in parentheses or not: a derivation
   around it applies to the name. *)
let rec is_name declarator =
  match declarator.node with
  | Name _ -> true
  | Parenthesized_declarator inner -> is_name inner
  | Pointer _ | Array _ | Function _ -> false

(* The grammar: declarations and expressions, which nest in each other. *)

let rec specifiers state context =
  let rec loop seen_type_specifier specifiers =
    match allowed context (specifier_word state 0) with
    | Some (Typedef_word _) when seen_type_specifier -> List.rev specifiers
    | Some word ->
        let specifier = specifier state word in
        loop
          (seen_type_specifier || is_type_specifier specifier.node)
          (specifier :: specifiers)
    | None -> List.rev specifiers
  in
  loop false []

and specifier state word =
  let start = state.position in
  advance state;
  let node =
    match word with
    | Storage_word storage_class -> Storage_class storage_class
    | Qualifier_word qualifier -> Type_qualifier qualifier
    | Function_word function_specifier -> Function_specifier function_specifier
    | Basic_word basic -> Type_specifier (Basic basic)
    | Typedef_word name -> Type_specifier (Typedef_name name)
    | Atomic_type_word ->
        expect state P.Left_paren "`(` after `_Atomic`";
        let type_name = type_name state in
        expect state P.Right_paren "`)` after the type name of `_Atomic`";
        Type_specifier (Atomic_type type_name)
    | Alignas_word -> Alignment_specifier (alignment state)
    | Struct_word kind -> Type_specifier (struct_or_union state kind)
    | Enum_word -> Type_specifier (enum_specifier state)
  in
  finish state start node

and alignment state =
  expect state P.Left_paren "`(` after `_Alignas`";
  let alignment =
    if starts_type_name state 0 then Alignas_type (type_name state)
    else Alignas_expression (constant_expression state)
  in
  expect state P.Right_paren "`)` after the operand of `_Alignas`";
  alignment

and struct_or_union state kind =
  let tag = optional_identifier state in
  let members =
    if accept state P.Left_brace then Some (member_declarations state)
    else None
  in
  if tag = None && members = None then
    fail_expected state "a tag or `{` after `struct` or `union`";
  Struct_or_union { kind; tag; members }

(* After the [{]: at least one member declaration and the [}]. *)
and member_declarations state =
  let rec loop members =
    let members = member_declaration state :: members in
    if accept state P.Right_brace then List.rev members else loop members
  in
  loop []

and member_declaration state =
  let start = state.position in
  if accept_keyword state Keyword.Static_assert then
    finish state start (Member_static_assert (static_assertion state))
  else
    let specifiers = specifiers state Specifier_qualifiers in
    if specifiers = [] then fail_expected state "a member declaration";
    let declarators =
      if peek state = Punctuator_token P.Semicolon then []
      else member_declarators state
    in
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
  if accept state P.Colon then
    let width = constant_expression state in
    finish state start (Bit_field { declarator = None; width })
  else
    let declarator = named_declarator state in
    if accept state P.Colon then
      let width = constant_expression state in
      finish state start (Bit_field { declarator = Some declarator; width })
    else finish state start (Field declarator)

and enum_specifier state =
  let tag = optional_identifier state in
  let enumerators =
    if accept state P.Left_brace then Some (enumerators state) else None
  in
  if tag = None && enumerators = None then
    fail_expected state "a tag or `{` after `enum`";
  Enum { tag; enumerators }

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
  let value =
    if accept state P.Equal then Some (constant_expression state) else None
  in
  declare state name.node Ordinary_binding;
  finish state start { name; value }

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

and named_declarator state = fst (named_declarator_and_function state)

and named_declarator_and_function state =
  match declarator_and_function state Named with
  | Some declarator, named_function -> (declarator, named_function)
  | None, _ -> fail_expected state "a declarator"

and declarator state form = fst (declarator_and_function state form)

(* A declarator, None where an abstract one is empty, and its
   {!named_function} if a function derivation applies to its name. The
   leftmost [*] is the outermost node (6.7.6.1). *)
and declarator_and_function state form =
  let rec pointers innermost_first =
    if peek state = Punctuator_token P.Star then begin
      let start = state.position in
      advance state;
      let qualifiers = type_qualifiers state in
      pointers ((start, qualifiers) :: innermost_first)
    end
    else innermost_first
  in
  let innermost_first = pointers [] in
  let direct, named_function = direct_declarator state form in
  let pointer inner (start, qualifiers) =
    Some (finish state start (Pointer { qualifiers; inner }))
  in
  (List.fold_left pointer direct innermost_first, named_function)

and direct_declarator state form =
  let start = state.position in
  let base, named_function =
    match peek state with
    | Identifier_token name when form <> Abstract ->
        advance state;
        (Some (finish state start (Name name)), None)
    | Punctuator_token P.Left_paren when opens_nested_declarator state form ->
        advance state;
        let inner, named_function =
          match declarator_and_function state form with
          | Some inner, named_function -> (inner, named_function)
          | None, _ -> fail_expected state "a declarator"
        in
        expect state P.Right_paren "`)` after a declarator";
        (Some (finish state start (Parenthesized_declarator inner)),
         named_function)
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
        nested_scope state (fun () -> parameters state form)
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
   declarator with a name. *)
and parameters state form =
  if accept state P.Right_paren then Identifier_list []
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
  Option.iter
    (fun name -> declare state name Ordinary_binding)
    (Option.bind declarator declared_name);
  finish state start ({ specifiers; declarator } : parameter_node)

(* A typedef name is refused in an identifier list: it would begin a
   parameter declaration. *)
and identifier_list state =
  let rec loop identifiers =
    (match peek state with
    | Identifier_token name when is_typedef_name state name ->
        fail_type_name state "a parameter name" name
    | _ -> ());
    let name = identifier state "a parameter name" in
    declare state name.node Ordinary_binding;
    let identifiers = name :: identifiers in
    if accept state P.Comma then loop identifiers else List.rev identifiers
  in
  loop []

(* Initialisers. *)

and initialiser state =
  if peek state = Punctuator_token P.Left_brace then
    Braced (initialiser_list state)
  else Expression_initialiser (assignment_expression state)

(* From the [{] to the [}]: at least one value and an optional [,]. *)
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
  let values = loop [] in
  finish state start values

and designated_initialiser state =
  let start = state.position in
  let rec designators reversed =
    match peek state with
    | Punctuator_token (P.Left_bracket | P.Dot) ->
        designators (designator state :: reversed)
    | _ -> List.rev reversed
  in
  let designators = designators [] in
  if designators <> [] then expect state P.Equal "`=` after a designator";
  let initialiser = initialiser state in
  finish state start { designators; initialiser }

and designator state =
  let start = state.position in
  if accept state P.Dot then
    let member = identifier state "a member name after `.`" in
    finish state start (Member_designator member)
  else begin
    expect state P.Left_bracket "`[` or `.`";
    let index = constant_expression state in
    expect state P.Right_bracket "`]` after a designator";
    finish state start (Index index)
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
          (Printf.sprintf "the left operand of %s is not a unary expression"
             (found state))
    | None -> (operand, targets)
  in
  let value, targets = collect [] in
  List.fold_left
    (fun right (start, operator, left) ->
      finish state start (Assignment (operator, left, right)))
    value targets

(* Right-associative like assignment: [a ? b : c ? d : e] groups as
   [a ? b : (c ? d : e)]. *)
and conditional_expression state =
  let rec collect branches =
    let start = state.position in
    let condition = binary_expression state lowest_precedence in
    if accept state P.Question then begin
      let if_true = expression state in
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
   unary operators, [++], [--] and [sizeof]) up to the operand they apply
   to, and the nodes are made from the innermost prefix out. After [++],
   [--] and [sizeof] comes a unary-expression, where [(] type-name [)]
   can only begin a compound literal. *)
and cast_expression state =
  let rec collect prefixes ~cast_allowed =
    let start = state.position in
    match peek state with
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
    | Keyword_token Keyword.Sizeof when opens_type_name_at state 1 ->
        advance state;
        let operand_start = state.position in
        let type_name = parenthesized_type_name state in
        if peek state = Punctuator_token P.Left_brace then
          let sizeof operand = Sizeof_expression operand in
          ( (start, sizeof) :: prefixes,
            compound_literal state operand_start type_name )
        else (prefixes, finish state start (Sizeof_type type_name))
    | Keyword_token Keyword.Sizeof ->
        advance state;
        let sizeof operand = Sizeof_expression operand in
        collect ((start, sizeof) :: prefixes) ~cast_allowed:false
    | Keyword_token Keyword.Alignof ->
        advance state;
        let type_name = parenthesized_type_name state in
        (prefixes, finish state start (Alignof type_name))
    | lexeme -> (
        match unary_operator lexeme with
        | Some operator ->
            advance state;
            let apply operand = Unary (operator, operand) in
            collect ((start, apply) :: prefixes) ~cast_allowed:true
        | None -> (prefixes, postfix_expression state))
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

and primary_expression state =
  let start = state.position in
  match peek state with
  | Identifier_token name when is_typedef_name state name ->
      fail_type_name state "an expression" name
  | Identifier_token name ->
      advance state;
      finish state start (Identifier name)
  | Number_token -> (
      match Number.classify (next_spelling state) with
      | Number.Not_a_constant ->
          fail state
            (Printf.sprintf
               "expected a constant, found the preprocessing number %s"
               (found state))
      | constant ->
          advance state;
          finish state start (Constant constant))
  | Character_token encoding ->
      advance state;
      finish state start (Character encoding)
  | String_token _ ->
      let pieces = string_literal state in
      finish state start (String pieces)
  | Punctuator_token P.Left_paren ->
      advance state;
      let inner = expression state in
      expect state P.Right_paren "`)` after an expression";
      finish state start (Parenthesized inner)
  | Keyword_token Keyword.Generic ->
      advance state;
      generic_selection state start
  | _ -> fail_expected state "an expression"

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

(* What the declarators of a declaration with these specifiers declare,
   worked out once per declaration. *)
let binding_of specifiers =
  if declares_typedef specifiers then Typedef_name_binding
  else Ordinary_binding

let declare_declarator state binding declarator =
  Option.iter
    (fun name -> declare state name binding)
    (declared_name declarator)

(* A declarator's identifier is in scope from the end of the declarator,
   before its initialiser (6.2.1p7). *)
let init_declarator state binding start declarator =
  declare_declarator state binding declarator;
  let initialiser =
    if accept state P.Equal then Some (initialiser state) else None
  in
  finish state start { declarator; initialiser }

(* A declaration read up to the end of its first declarator, where a
   function definition parts from it, or read whole if it has no
   declarator. *)
type declaration_start =
  | Complete of declaration
  | First_declarator of {
      start : int;
      specifiers : specifiers;
      declarator_start : int;
      declarator : declarator;
      named_function : named_function option;
    }

let declaration_start state =
  let start = state.position in
  if accept_keyword state Keyword.Static_assert then
    Complete (finish state start (Static_assert (static_assertion state)))
  else begin
    let specifiers = specifiers state Declaration_specifiers in
    if specifiers = [] then fail_expected state "a declaration";
    if accept state P.Semicolon then
      Complete
        (finish state start (Declaration { specifiers; declarators = [] }))
    else
      let declarator_start = state.position in
      let declarator, named_function = named_declarator_and_function state in
      First_declarator
        { start; specifiers; declarator_start; declarator; named_function }
  end

(* The rest of a declaration whose first declarator has been read. *)
let declaration_rest state start specifiers first_start first =
  let binding = binding_of specifiers in
  let rec loop declarators =
    if accept state P.Comma then
      let declarator_start = state.position in
      let declarator = named_declarator state in
      loop
        (init_declarator state binding declarator_start declarator
        :: declarators)
    else List.rev declarators
  in
  let declarators =
    loop [ init_declarator state binding first_start first ]
  in
  expect state P.Semicolon "`;` after a declaration";
  finish state start (Declaration { specifiers; declarators })

let declaration state =
  match declaration_start state with
  | Complete declaration -> declaration
  | First_declarator { start; specifiers; declarator_start; declarator; _ } ->
      declaration_rest state start specifiers declarator_start declarator

(* Statements (C11 6.8). *)

(* A statement read up to its substatement, which ends it or, for [if]
   and [do], which more tokens may follow. [outer] is the scope around
   the statement, which closing it restores: a selection or iteration
   statement is a block, and so is each of its substatements (6.8.4p3,
   6.8.5p5). A label opens no scope, so its [outer] is None. *)
type open_statement = {
  start : int;
  outer : binding Scope.t option;
  kind : open_kind;
}

and open_kind =
  | Open_labeled of label
  | Open_if of {
      condition : expression;
      condition_scope : binding Scope.t;
          (** [outer] and what the condition declared *)
    }
  | Open_else of { condition : expression; then_branch : statement }
  | Open_switch of expression
  | Open_while of expression
  | Open_do
  | Open_for of {
      clause : for_clause option;
      condition : expression option;
      step : expression option;
    }

(* What the substatement of an open statement leaves: the statement
   closed, or, after the [else] of an [if], open again. *)
type closing = Closed of statement_node | Reopened of open_kind

(* [(] expression [)] after the keyword [keyword]. *)
let controlling_expression state keyword =
  expect state P.Left_paren (Printf.sprintf "`(` after `%s`" keyword);
  let value = expression state in
  expect state P.Right_paren
    (Printf.sprintf "`)` after the controlling expression of `%s`" keyword);
  value

(* An optional expression and the token [closing] after it. *)
let optional_expression state closing expected =
  if accept state closing then None
  else
    let value = expression state in
    expect state closing expected;
    Some value

(* After the [for]: the three clauses in their parentheses. *)
let for_clauses state =
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
    optional_expression state P.Semicolon "`;` after the condition of `for`"
  in
  let step =
    optional_expression state P.Right_paren "`)` after the clauses of `for`"
  in
  (clause, condition, step)

(* A label and its [:], where [begins_label] holds. *)
let label state =
  let start = state.position in
  let node =
    if accept_keyword state Keyword.Case then begin
      let value = constant_expression state in
      expect state P.Colon "`:` after the value of `case`";
      Case_label value
    end
    else if accept_keyword state Keyword.Default then begin
      expect state P.Colon "`:` after `default`";
      Default_label
    end
    else begin
      let name = identifier state "a label" in
      expect state P.Colon "`:` after a label";
      Named_label name.node
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
let rec statement state = open_statements state []

and open_statements state opened =
  let start = state.position in
  let outer = state.scope in
  let read_substatement_of kind =
    (open_statements [@tailcall]) state
      ({ start; outer = Some outer; kind } :: opened)
  in
  match peek state with
  | _ when begins_label state ->
      let label = label state in
      (open_statements [@tailcall]) state
        ({ start; outer = None; kind = Open_labeled label } :: opened)
  | Keyword_token Keyword.If ->
      advance state;
      let condition = controlling_expression state "if" in
      read_substatement_of
        (Open_if { condition; condition_scope = state.scope })
  | Keyword_token Keyword.Switch ->
      advance state;
      read_substatement_of
        (Open_switch (controlling_expression state "switch"))
  | Keyword_token Keyword.While ->
      advance state;
      read_substatement_of (Open_while (controlling_expression state "while"))
  | Keyword_token Keyword.Do ->
      advance state;
      read_substatement_of Open_do
  | Keyword_token Keyword.For ->
      advance state;
      let clause, condition, step = for_clauses state in
      read_substatement_of (Open_for { clause; condition; step })
  | _ ->
      let statement = simple_statement state in
      (close_statements [@tailcall]) state opened statement

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
          (close_statements [@tailcall]) state outside
            (finish state innermost.start node))

(* The rest of [opened] after its substatement [statement]. *)
and close_one state opened statement =
  match opened.kind with
  | Open_labeled label -> Closed (Labeled { label; statement })
  | Open_if { condition; condition_scope } ->
      state.scope <- condition_scope;
      if accept_keyword state Keyword.Else then
        Reopened (Open_else { condition; then_branch = statement })
      else
        Closed (If { condition; then_branch = statement; else_branch = None })
  | Open_else { condition; then_branch } ->
      Closed (If { condition; then_branch; else_branch = Some statement })
  | Open_switch controlling -> Closed (Switch { controlling; body = statement })
  | Open_while condition -> Closed (While { condition; body = statement })
  | Open_do ->
      (* The scope of the body ends before the condition. *)
      Option.iter (fun outer -> state.scope <- outer) opened.outer;
      if not (accept_keyword state Keyword.While) then
        fail_expected state "`while` after the body of `do`";
      let condition = controlling_expression state "while" in
      expect state P.Semicolon "`;` after `do` ... `while`";
      Closed (Do { body = statement; condition })
  | Open_for { clause; condition; step } ->
      Closed (For { clause; condition; step; body = statement })

(* A statement without a substatement. *)
and simple_statement state =
  let start = state.position in
  match peek state with
  | Punctuator_token P.Left_brace ->
      let body = block state in
      { span = body.span; node = Compound body }
  | Punctuator_token P.Semicolon ->
      advance state;
      finish state start Null_statement
  | Keyword_token Keyword.Goto ->
      advance state;
      let target = identifier state "a label after `goto`" in
      expect state P.Semicolon "`;` after `goto`";
      finish state start (Goto target)
  | Keyword_token Keyword.Continue ->
      advance state;
      expect state P.Semicolon "`;` after `continue`";
      finish state start Continue
  | Keyword_token Keyword.Break ->
      advance state;
      expect state P.Semicolon "`;` after `break`";
      finish state start Break
  | Keyword_token Keyword.Return ->
      advance state;
      let value =
        optional_expression state P.Semicolon "`;` after `return`"
      in
      finish state start (Return value)
  | _ ->
      let value = expression state in
      expect state P.Semicolon "`;` after an expression";
      finish state start (Expression_statement value)

(* From the [{] to the [}], in a block scope of its own. *)
and block state =
  let start = state.position in
  expect state P.Left_brace "`{`";
  let items = within_scope state (fun () -> block_items state) in
  finish state start items

(* After the [{], up to and including the [}]. *)
and block_items state =
  let rec loop items =
    match peek state with
    | Punctuator_token P.Right_brace ->
        advance state;
        List.rev items
    | End_of_input -> fail_expected state "`}` to end a compound statement"
    | _ -> loop (block_item state :: items)
  in
  loop []

(* A label comes first: [T:] begins one where [T] is a typedef name. *)
and block_item state =
  if begins_label state then Block_statement (statement state)
  else if begins_declaration state then Block_declaration (declaration state)
  else Block_statement (statement state)

(* External declarations (C11 6.9). *)

(* Consumes a body unread, up to the bracket that closes its [{]. *)
let skip_body state =
  let start = state.position in
  let outside = List.length state.open_brackets in
  advance state;
  let rec loop () =
    if List.length state.open_brackets > outside then begin
      if peek state = End_of_input then
        fail_expected state "`}` to end the function body";
      advance state;
      loop ()
    end
  in
  loop ();
  span_from state start

(* At the [{]. A body that a system header holds is not parsed (design
   13.3): it is written for its own compiler and may use any of its
   extensions. *)
let function_body state =
  if (token_at state state.position).owner.system_header then
    Skipped (skip_body state)
  else Parsed (block state)

(* The declaration list of an old-style definition, up to the [{]. *)
let parameter_declarations state =
  let rec loop declarations =
    if peek state = Punctuator_token P.Left_brace then List.rev declarations
    else loop (declaration state :: declarations)
  in
  loop []

let takes_declaration_list = function
  | Identifier_list _ -> true
  | Prototype _ -> false

(* A declarator whose name is a function begins a definition at a [{],
   or, after an identifier list, at a declaration (6.9.1p1), read in the
   scope of the parameters as the declaration list will be. *)
let begins_definition state named_function =
  let begins_declaration_list () =
    state.scope <- named_function.parameter_scope;
    starts_declaration state 0
  in
  peek state = Punctuator_token P.Left_brace
  || takes_declaration_list named_function.parameters
     && within_scope state begins_declaration_list

(* After the declarator of a function. Its parameters and its body are in
   one block scope, which continues the scope of the parameter list
   (6.2.1p4). What the declarator declares after its parameter list, the
   function's own name and any enumerators of its return type, is in
   scope at file scope and missing from the body's scope. That loses no
   typedef name: none of them is one, and none can hide a file-scope
   typedef name, which a declaration at file scope cannot give another
   meaning (6.2.1p2), so a lookup in the body finds no typedef name
   either way. *)
let function_definition state start specifiers declarator named_function =
  declare_declarator state (binding_of specifiers) declarator;
  let file_scope = state.scope in
  state.scope <- named_function.parameter_scope;
  let declarations = parameter_declarations state in
  let body = function_body state in
  state.scope <- file_scope;
  Function_definition
    (finish state start { specifiers; declarator; declarations; body })

let external_declaration state =
  match declaration_start state with
  | Complete declaration -> External_declaration declaration
  | First_declarator
      { start; specifiers; declarator; named_function = Some named; _ }
    when begins_definition state named ->
      function_definition state start specifiers declarator named
  | First_declarator { start; specifiers; declarator_start; declarator; _ } ->
      External_declaration
        (declaration_rest state start specifiers declarator_start declarator)

let translation_unit state =
  let rec loop declarations =
    if peek state = End_of_input then List.rev declarations
    else loop (external_declaration state :: declarations)
  in
  loop []

let parse reader =
  let state =
    {
      reader;
      grammar = grammar_tokens reader;
      position = 0;
      open_brackets = [];
      scope = Scope.empty;
    }
  in
  match translation_unit state with
  | translation_unit -> Ok translation_unit
  | exception Failed error -> Error error

let error_message = Reader.error_message
