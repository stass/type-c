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
   [_Atomic (], [typeof (]), and the fixed type of an enumeration takes
   no specifier that holds another (see [allowed]). So [advance] bounds
   the recursion by bounding the brackets open. C11
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

(* What the cursor holds open: a bracket and the bracket that closes it,
   or the [?] of a conditional, which its [:] closes. *)
type opening = Open_bracket of P.t | Open_conditional

(* What the grammar needs of an ordinary identifier in scope: its
   declaration, and whether it is a typedef name. Parsing needs the kind
   of a name, never its type. *)
type ordinary = { declaration : declaration_id; names_type : bool }

(* The scopes open at a point, in the two name spaces that scopes hold
   (6.2.3): ordinary identifiers, and tags by their declaration. *)
type scope = (ordinary, declaration_id) Scope.t

(* The cursor. [scope] is persistent, so leaving a scope restores the
   value saved on entering it. *)
type state = {
  reader : Reader.t;
  grammar : grammar_token array;
  mutable position : int;  (** in [grammar] *)
  mutable open_brackets : opening list;
      (** read and not yet closed, innermost first *)
  mutable scope : scope;
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
let lexeme_of keywords reader (token : Token.t) =
  match token.kind with
  | Token.Identifier -> (
      let spelling = Reader.spelling reader token in
      match Keyword.of_spelling keywords spelling with
      | Some keyword -> Some (Keyword_token keyword)
      | None -> Some (Identifier_token spelling))
  | Token.Number -> Some Number_token
  | Token.Character encoding -> Some (Character_token encoding)
  | Token.String encoding -> Some (String_token encoding)
  | Token.Punctuator punctuator -> Some (Punctuator_token punctuator)
  | Token.Pragma | Token.Typec_pragma -> None

let grammar_tokens keywords (reader : Reader.t) =
  Array.to_seqi reader.tokens
  |> Seq.filter_map (fun (index, token) ->
         Option.map
           (fun lexeme -> { lexeme; index })
           (lexeme_of keywords reader token))
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

(* The one way the cursor moves, called only after [peek] has matched a
   token. A [:] closes a [?] and nothing else. *)
let advance state =
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
   GCC and Clang declare there. *)
let file_scope =
  List.fold_left
    (fun scope (name, _) ->
      let builtin = { declaration = Builtin name; names_type = true } in
      Scope.declare scope name builtin)
    Scope.file Builtin_typedef.table

let typedef_declaration state name =
  match Scope.find state.scope name with
  | Some { declaration; names_type = true } -> Some declaration
  | Some { names_type = false; _ } | None -> None

let is_typedef_name state name = typedef_declaration state name <> None

(* An identifier is the only token that a declaration is made at, and
   the cursor reads each token once, so the token is a unique id. *)
let declaration_at (name : identifier) = At_token name.span.first

(* Declares the ordinary identifier [name] in the innermost scope, where
   its scope begins. *)
let declare state ~names_type (name : identifier) =
  let id = declaration_at name in
  let earlier =
    Option.map
      (fun ordinary -> ordinary.declaration)
      (Scope.find_in_innermost state.scope name.node)
  in
  state.scope <-
    Scope.declare state.scope name.node { declaration = id; names_type };
  { id; earlier }

let resolve state name =
  match Scope.find state.scope name with
  | Some { declaration; _ } -> Resolved declaration
  | None -> Undeclared

let declare_tag state (name : identifier) =
  let id = declaration_at name in
  let earlier = Scope.find_tag_in_innermost state.scope name.node in
  state.scope <- Scope.declare_tag state.scope name.node id;
  Declares { id; earlier }

(* A tag that [declares] by its form declares itself in the current
   scope (6.7.2.3p6, p7); any other names the visible tag (p9), or
   declares one where none is visible (p8). *)
let bound_tag state (name : identifier) ~declares =
  let binding =
    if declares then declare_tag state name
    else
      match Scope.find_tag state.scope name.node with
      | Some id -> Names id
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
  | Typedef_word of string * declaration_id
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
  | Float16 -> Some (Basic_word Float16)
  | Struct -> Some (Struct_word Struct)
  | Union -> Some (Struct_word Union)
  | Enum -> Some Enum_word
  | Alignas -> Some Alignas_word
  | Typeof -> Some Typeof_word
  | Attribute -> Some Attribute_word
  | Break | Case | Continue | Default | Do | Else | For | Goto | If | Return
  | Sizeof | Switch | While | Alignof | Generic | Imaginary | Static_assert
  | Asm | Extension | Label | Builtin_va_arg | Builtin_offsetof
  | Builtin_types_compatible_p | Real | Imag ->
      None

(* The specifier that the token [offset] places ahead begins. A typedef
   name is one only where no other type specifier precedes it, which the
   caller decides. *)
let specifier_word state offset =
  match peek_at state offset with
  | Keyword_token keyword -> keyword_specifier_word state offset keyword
  | Identifier_token name -> (
      match typedef_declaration state name with
      | Some declaration -> Some (Typedef_word (name, declaration))
      | None -> None)
  | Punctuator_token _ | Number_token | Character_token _ | String_token _
  | End_of_input ->
      None

let starts_declaration state offset = specifier_word state offset <> None

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
   takes only the specifiers that hold no other specifier: the list
   cannot nest, and needs no bracket to bound its recursion. *)
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
  let arguments =
    if peek state = Punctuator_token P.Left_paren then
      Some
        (skip_balanced state
           "`)` to end the arguments of an attribute")
    else None
  in
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

(* The offset after the parentheses that open [offset] tokens ahead, or of
   the end of the input if they do not close; [offset] if no [(] opens
   there. *)
let past_parentheses state offset =
  let rec loop offset depth =
    match peek_at state offset with
    | Punctuator_token P.Left_paren -> loop (offset + 1) (depth + 1)
    | Punctuator_token P.Right_paren when depth = 1 -> offset + 1
    | Punctuator_token P.Right_paren -> loop (offset + 1) (depth - 1)
    | End_of_input -> offset
    | _ -> loop (offset + 1) depth
  in
  if peek_at state offset = Punctuator_token P.Left_paren then loop offset 0
  else offset

(* The offset after the GNU attributes that begin [offset] tokens ahead:
   each [__attribute__] and the parentheses after it. The lookahead only
   decides; the parse that follows matches every bracket. *)
let rec past_attributes state offset =
  if peek_at state offset = Keyword_token Keyword.Attribute then
    past_attributes state (past_parentheses state (offset + 1))
  else offset

(* GNU attributes and the [;] after them, which in a block are a null
   statement with attributes rather than C23's attribute declaration. *)
let begins_attribute_statement state =
  peek state = Keyword_token Keyword.Attribute
  && peek_at state (past_attributes state 0) = Punctuator_token P.Semicolon

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
  | Generic _ | Compound_literal _ | Subscript _ | Call _ | Member _
  | Pointer_member _ | Post_increment _ | Post_decrement _ | Unary _
  | Sizeof_expression _ | Sizeof_type _ | Alignof _ | Alignof_expression _
  | Statement_expression _ | Label_address _ | Va_arg _ | Offsetof _
  | Types_compatible _ | Block_literal _ ->
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
   6.8.5p5). A label opens no scope, so its [outer] is None. *)
type open_statement = { start : int; outer : scope option; kind : open_kind }

(* [statement_scope] is the scope of the whole statement after its head;
   the [else] branch and the condition of a [do] are read in it. *)
and open_kind =
  | Open_labeled of label
  | Open_if of { condition : expression; statement_scope : scope }
  | Open_else of { condition : expression; then_branch : statement }
  | Open_switch of expression
  | Open_while of expression
  | Open_do of { statement_scope : scope }
  | Open_for of {
      clause : for_clause option;
      condition : expression option;
      step : expression option;
    }

(* What the substatement of an open statement leaves: the statement
   closed, or, after the [else] of an [if], open again. *)
type closing = Closed of statement_node | Reopened of open_kind

(* The grammar: declarations, expressions and statements, which nest in
   each other through statement expressions. *)

(* [only_attributes] holds while every specifier read is attributes, so
   that a tag specifier can tell whether it is alone in its declaration. *)
let rec specifiers state context =
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
  loop ~seen_type_specifier:false ~only_attributes:true []

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
    | Typedef_word (name, declaration) ->
        Type_specifier (Typedef_name { name; declaration })
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
    if starts_type_name state 0 then Alignas_type (type_name state)
    else Alignas_expression (constant_expression state)
  in
  expect state P.Right_paren "`)` after the operand of `_Alignas`";
  alignment

(* The attributes after the keyword and after a body apply to the type
   (GCC manual 6.39.5). *)
and struct_or_union state kind ~alone =
  let leading = attributes state in
  let tag_name = optional_identifier state in
  let declares =
    peek state = Punctuator_token P.Left_brace || ends_alone state ~alone
  in
  let tag = Option.map (fun name -> bound_tag state name ~declares) tag_name in
  let members =
    if accept state P.Left_brace then Some (member_declarations state)
    else None
  in
  if tag = None && members = None then
    fail_expected state "a tag or `{` after `struct` or `union`";
  let trailing = if members = None then [] else attributes state in
  Struct_or_union { kind; attributes = leading @ trailing; tag; members }

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
  let declares =
    peek state = Punctuator_token P.Left_brace
    || (underlying <> None && ends_alone state ~alone)
  in
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
  let declared = declare state ~names_type:false name in
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
          let declared = declare state ~names_type:false name in
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
    let declared = declare state ~names_type:false name in
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
  let designators = designators state in
  if designators <> [] then expect state P.Equal "`=` after a designator";
  let initialiser = initialiser state in
  finish state start { designators; initialiser }

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
        let label = identifier state "a label after `&&`" in
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
      finish state start (Identifier { name; resolution = resolve state name })
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

(* After the [^]: the body, after the parameters if it has them. The
   body continues their scope, as a function's does (6.2.1p4). *)
and block_literal state start =
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
      ~names_type:(declares_typedef specifiers)
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
    if specifiers = [] then fail_expected state "a declaration";
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

(* Statements (C11 6.8). *)

(* [(] expression [)] after the keyword [keyword]. *)
and controlling_expression state keyword =
  expect state P.Left_paren (Printf.sprintf "`(` after `%s`" keyword);
  let value = expression state in
  expect state P.Right_paren
    (Printf.sprintf "`)` after the controlling expression of `%s`" keyword);
  value

(* An optional expression and the token [closing] after it. *)
and optional_expression state closing expected =
  if accept state closing then None
  else
    let value = expression state in
    expect state closing expected;
    Some value

(* After the [for]: the three clauses in their parentheses. *)
and for_clauses state =
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
      let attributes = attributes state in
      Named_label { name = name.node; attributes }
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
  (* A selection or iteration statement is a block, which [read_head]
     reads in, and so is its substatement. *)
  let open_block_statement read_head =
    enter_scope state;
    let kind = read_head () in
    enter_scope state;
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
      open_block_statement (fun () ->
          let condition = controlling_expression state "if" in
          Open_if { condition; statement_scope = state.scope })
  | Keyword_token Keyword.Switch ->
      advance state;
      open_block_statement (fun () ->
          Open_switch (controlling_expression state "switch"))
  | Keyword_token Keyword.While ->
      advance state;
      open_block_statement (fun () ->
          Open_while (controlling_expression state "while"))
  | Keyword_token Keyword.Do ->
      advance state;
      open_block_statement (fun () ->
          Open_do { statement_scope = state.scope })
  | Keyword_token Keyword.For ->
      advance state;
      open_block_statement (fun () ->
          let clause, condition, step = for_clauses state in
          Open_for { clause; condition; step })
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
  | Keyword_token Keyword.Attribute ->
      let attributes = attributes state in
      expect state P.Semicolon "`;` after the attributes of a statement";
      finish state start (Attribute_statement attributes)
  | Keyword_token Keyword.Goto ->
      advance state;
      if accept state P.Star then begin
        let target = expression state in
        expect state P.Semicolon "`;` after `goto *`";
        finish state start (Computed_goto target)
      end
      else
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
  | Keyword_token Keyword.Asm ->
      advance state;
      let assembler = assembler state in
      expect state P.Semicolon "`;` after `asm`";
      finish state start (Asm assembler)
  | _ ->
      let value = expression state in
      expect state P.Semicolon "`;` after an expression";
      finish state start (Expression_statement value)

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
        comma_separated state (fun state -> identifier state "a label"))
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
  let local_labels = local_label_declarations state in
  let items = block_items state in
  finish state start { local_labels; items }

and local_label_declarations state =
  let rec loop declarations =
    let start = state.position in
    if accept_keyword state Keyword.Label then
      let labels =
        one_or_more state (fun state -> identifier state "a label name")
      in
      expect state P.Semicolon "`;` after the labels of `__label__`";
      loop (finish state start labels :: declarations)
    else List.rev declarations
  in
  loop []

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

(* A label comes first: [T:] begins one where [T] is a typedef name. Then
   attributes before a [;], which begin a declaration elsewhere. *)
and block_item state =
  if begins_label state || begins_attribute_statement state then
    Block_statement (statement state)
  else if begins_declaration state then Block_declaration (declaration state)
  else Block_statement (statement state)

(* External declarations (C11 6.9). *)

(* At the [{]. A body that a system header holds is not parsed (design
   13.3): it is written for its own compiler and may use any of its
   extensions. *)
let function_body state =
  if (token_at state state.position).owner.system_header then
    Skipped (skip_balanced state "`}` to end the function body")
  else Parsed (compound_statement state)

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

(* [__extension__] may come before every external declaration; the node
   holds it in its span. A function definition has no asm label: GCC and
   Clang take one only in a declaration. *)
let external_declaration state =
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

let translation_unit state =
  let rec loop declarations =
    if peek state = End_of_input then List.rev declarations
    else loop (external_declaration state :: declarations)
  in
  loop []

let parse ?(keywords = Keyword_set.Gnu) reader =
  let state =
    {
      reader;
      grammar = grammar_tokens keywords reader;
      position = 0;
      open_brackets = [];
      scope = file_scope;
    }
  in
  match translation_unit state with
  | translation_unit -> Ok translation_unit
  | exception Failed error -> Error error

let error_message = Reader.error_message
