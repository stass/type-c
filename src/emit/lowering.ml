(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

(* Whether [indexes] are a run of adjacent tokens of one file, which an
   edit may replace whole without dropping a pragma or a line marker
   that enters or leaves a file between them. *)
let is_run (tokens : Token.t array) = function
  | [] -> true
  | first :: _ as indexes ->
      let owner = tokens.(first).owner in
      let rec from expected = function
        | [] -> true
        | index :: rest ->
            index = expected
            && tokens.(index).owner == owner
            && from (expected + 1) rest
      in
      from first indexes

(* The edits that replace the tokens at [indexes], in source order, by
   [text]. Where the tokens are a run, one edit replaces them all. Where a
   pragma or a file boundary stands between them, [text] replaces the
   first and the others are deleted, so what stands between them stays. *)
let replace (tokens : Token.t array) ~location text indexes :
    Emitter.edit list =
  match indexes with
  | [] -> []
  | first :: _ when is_run tokens indexes ->
      let count = List.length indexes in
      [ Emitter.code (Reader.range tokens ~first ~count) ~location text ]
  | first :: rest ->
      let delete index =
        Emitter.code (Reader.range tokens ~first:index ~count:1) ~location ""
      in
      Emitter.code (Reader.range tokens ~first ~count:1) ~location text
      :: List.map delete rest

let insert (tokens : Token.t array) ~before text =
  Emitter.code
    (Reader.range tokens ~first:before ~count:0)
    ~location:tokens.(before).location text

(* [text] after token [after], as the end of the construct that ends
   there, so that it moves with that construct's tokens. *)
let close (tokens : Token.t array) ~after text =
  Emitter.closing tokens ~after ~location:tokens.(after).location text

(* The grammar tokens from [first] to [last], without the pragmas
   between them, which stay. *)
let grammar_tokens (tokens : Token.t array) first last =
  List.init (last - first + 1) (fun offset -> first + offset)
  |> List.filter (fun index ->
         match tokens.(index).kind with
         | Token.Pragma _ | Token.Typec_pragma -> false
         | Token.Identifier _ | Token.Number | Token.Character _
         | Token.String _ | Token.Punctuator _ ->
             true)

(* The token before [index] that is not a pragma: the grammar gives
   pragmas no place, so before a definition it is the [=]. *)
let rec grammar_token_before (tokens : Token.t array) index =
  let before = index - 1 in
  match tokens.(before).kind with
  | Token.Pragma _ | Token.Typec_pragma -> grammar_token_before tokens before
  | Token.Identifier _ | Token.Number | Token.Character _ | Token.String _
  | Token.Punctuator _ ->
      before

(* The token after [index] that is not a pragma. *)
let rec grammar_token_after (tokens : Token.t array) index =
  let after = index + 1 in
  match tokens.(after).kind with
  | Token.Pragma _ | Token.Typec_pragma -> grammar_token_after tokens after
  | Token.Identifier _ | Token.Number | Token.Character _ | Token.String _
  | Token.Punctuator _ ->
      after

(* The token that the declared name goes before in an abstract
   declarator: where the identifier would be that the type name omits
   (C11 6.7.7p2). It is innermost, past a pointer that has no inner
   declarator and before a suffix that has none. *)
let rec name_position (declarator : Tree.declarator) =
  match declarator.node with
  | Pointer { inner = None; _ } | Block_pointer { inner = None; _ } ->
      declarator.span.last + 1
  | Array { inner = None; _ } | Function { inner = None; _ } ->
      declarator.span.first
  | Parenthesized_declarator { inner; _ }
  | Pointer { inner = Some inner; _ }
  | Block_pointer { inner = Some inner; _ }
  | Array { inner = Some inner; _ }
  | Function { inner = Some inner; _ } ->
      name_position inner
  | Name _ -> invalid_arg "Lowering.name_position: a named declarator"

let keyword : Tree.struct_or_union -> string = function
  | Struct -> "struct"
  | Union -> "union"

(* What [type N] lowers to where [N] is the structure or union [kind]
   with the tag [tag]. *)
let record_declarations kind ~tag name =
  let record = keyword kind ^ " " ^ tag in
  Printf.sprintf "%s; typedef %s %s;" record record name

(* [type N = T;]: the typedef, with [N] where the declarator of [T]
   would name it. [typedef] replaces the tokens before [T]: [type N =],
   with the type parameters of a generic and the words of a distinct
   type. *)
let alias tokens ~location (declaration : Tree.type_declaration) name
    (type_name : Tree.type_name) =
  let before_type = grammar_token_before tokens type_name.span.first in
  let name_before =
    match type_name.node.abstract with
    | Some abstract -> name_position abstract
    | None -> type_name.span.last + 1
  in
  replace tokens ~location "typedef"
    (grammar_tokens tokens declaration.span.first before_type)
  @ [ insert tokens ~before:name_before name ]

(* For a variant or a record alias [declaration]: the grammar tokens
   that its forward declaration replaces, and the first token after
   them, where {!Tree.after_forward_declaration} anchors. *)
let forward_declaration tokens (declaration : Tree.type_declaration) =
  let forward_end = Option.get (Tree.forward_declaration_end declaration) in
  (grammar_tokens tokens declaration.span.first (forward_end - 1), forward_end)

(* A specifier without a tag of its own takes [name], before its body. *)
let record_alias tokens ~location ~name (declaration : Tree.type_declaration)
    (specifier : Tree.record_specifier Tree.spanned) =
  let { Tree.kind; tag; members; _ } = specifier.node in
  let replace_head ~tag =
    replace tokens ~location
      (record_declarations kind ~tag name)
      (fst (forward_declaration tokens declaration))
  in
  let insert_tag (body : _ Tree.spanned) =
    insert tokens ~before:body.span.first name
  in
  match tag with
  | Some own -> replace_head ~tag:own.name.node
  | None ->
      replace_head ~tag:name @ Option.to_list (Option.map insert_tag members)

(* Variants (design 10.1). The tokens of each field are kept, so the
   struct of a constructor's fields keeps their lines. In an instance, a
   field in [void_fields] does not exist (design 3.5 rule 6): its
   tokens go as a range that lowering replaces whole (see
   {!text_edits}), and the edits here leave it out of its struct. The
   void fields are a set, since lowering looks up every field of the
   instance. *)

module Spans = Set.Make (struct
  type t = Tree.span

  let compare (a : Tree.span) (b : Tree.span) =
    match Int.compare a.first b.first with
    | 0 -> Int.compare a.last b.last
    | by_first -> by_first
end)

let is_void_field void_fields (field : Tree.field) =
  Spans.mem field.span void_fields

let has_fields void_fields (constructor : Tree.constructor) =
  not (List.for_all (is_void_field void_fields) constructor.node.fields)

(* The forward declaration of a variant: the structure and typedef,
   which the incomplete variant declares already where the variant
   [completes] one (design 10.1 rule 7). *)
let variant_forward ~completes (variant : Spelling.c_name) =
  let name = (variant :> string) in
  if completes then "" else record_declarations Struct ~tag:name name

(* What comes between the forward declaration and the constructors: the
   enumeration of the tags, numbered from 0 in order (rule 1), and the
   structure up to its union where it has one (rule 3). *)
let variant_head (variant : Spelling.c_name) ~has_union constructors =
  let name = (variant :> string) in
  let enumerator (constructor : Tree.constructor) =
    Tree.enumerator_name ~variant constructor.node.name.node
  in
  let tag_enum = "enum " ^ Tree.enum_tag_name variant in
  let union = if has_union then " union {" else "" in
  Printf.sprintf "%s { %s }; struct %s { %s %s;%s" tag_enum
    (String.concat ", " (List.map enumerator constructors))
    name tag_enum Tree.tag_member union

let variant_tail ~has_union =
  if has_union then Printf.sprintf "} %s; };" Tree.union_member else "};"

(* The tokens at [indexes], the first of which is [first], replaced by
   [text] at the location of [first]. *)
let replace_at (tokens : Token.t array) ~first text indexes =
  replace tokens ~location:tokens.(first).location text (first :: indexes)

(* A constructor with fields becomes the struct of them that the union
   holds, named after it; [| C (] opens it, the [,] after each field
   ends that field, and the [)] closes the struct. The [,] or [)] after
   a void field ends no field, so it becomes nothing or only the close.
   A constructor without fields becomes nothing (rule 3), and so do its
   parentheses and commas where every field is void. *)
let constructor_edits tokens ~void_fields (constructor : Tree.constructor) =
  let { Tree.name; fields } = constructor.node in
  let bar = constructor.span.first and close = constructor.span.last in
  let has_fields = has_fields void_fields constructor in
  let field_end (field : Tree.field) =
    let after = grammar_token_after tokens field.span.last in
    let ends = if is_void_field void_fields field then "" else ";" in
    let closes =
      if after = close && has_fields then
        Printf.sprintf " } %s;" (name.node :> string)
      else ""
    in
    replace_at tokens ~first:after (ends ^ closes) []
  in
  match fields with
  | [] -> replace_at tokens ~first:bar "" [ name.span.first ]
  | _ :: _ ->
      let open_paren = grammar_token_after tokens name.span.first in
      let opens = if has_fields then "struct {" else "" in
      replace_at tokens ~first:bar opens [ name.span.first; open_paren ]
      @ List.concat_map field_end fields

(* [type N = ... ;]: the forward declaration replaces [type], the head
   [N =] and [private] where it follows, and the tail the [;]. *)
let variant tokens ~location ~lowered ~void_fields
    (declaration : Tree.type_declaration) constructors =
  let completes = declaration.node.declared.earlier <> None in
  let has_union = List.exists (has_fields void_fields) constructors in
  let first_bar = (List.hd constructors : Tree.constructor).span.first in
  let forward_tokens, forward_end = forward_declaration tokens declaration in
  replace tokens ~location (variant_forward ~completes lowered) forward_tokens
  @ replace tokens ~location
      (variant_head lowered ~has_union constructors)
      (grammar_tokens tokens forward_end (first_bar - 1))
  @ List.concat_map (constructor_edits tokens ~void_fields) constructors
  @ replace_at tokens ~first:declaration.span.last (variant_tail ~has_union)
      []

(* The type declaration under the name [lowered], which is its own or,
   for the definition of a generic, that of an instance (design 10.3). *)
let type_declaration (tokens : Token.t array) ~(lowered : Spelling.c_name)
    ~void_fields (declaration : Tree.type_declaration) =
  let name = (lowered :> string) in
  let location = tokens.(declaration.span.first).location in
  match declaration.node.definition with
  | Incomplete_variant ->
      replace tokens ~location
        (record_declarations Struct ~tag:name name)
        (grammar_tokens tokens declaration.span.first declaration.span.last)
  | Alias type_name -> alias tokens ~location declaration name type_name
  (* Design 10.2: the typedef of its representation. *)
  | Distinct { representation; _ } ->
      alias tokens ~location declaration name representation
  | Record_alias record ->
      record_alias tokens ~location ~name declaration record
  | Variant { constructors; _ } ->
      variant tokens ~location ~lowered ~void_fields declaration
        constructors

(* Design 13.5: a constructor expression becomes the compound literal
   [((struct N){ .tag = N_C, .u.C = { a, b } })], or inside an
   initialiser the braced list alone. It names the structure tag, which
   no declaration in the variant's scope may hide (design 10.1 rule 6),
   rather than the typedef name, which a block may hide. The arguments
   keep their tokens; only the name of the constructor, the [(] and the
   [)] are replaced. *)

(* The opening of the compound literal of a constructor of [variant]. *)
let literal_opening (variant : Spelling.c_name) =
  Printf.sprintf "((struct %s){ " (variant :> string)

let literal_closing = "})"

(* The designation of the tag of a constructor's value, its enumerator. *)
let tag_designation ~variant constructor =
  Printf.sprintf ".%s = %s" Tree.tag_member
    (Tree.enumerator_name ~variant constructor)

(* The designator of the structure of a constructor's fields. *)
let fields_designator (constructor : Spelling.constructor) =
  Printf.sprintf ".%s.%s" Tree.union_member (constructor :> string)

(* What stands between the designation of the tag and the values of a
   constructor's fields, and after those values. *)
let fields_opening constructor =
  Printf.sprintf ", %s = { " (fields_designator constructor)

let fields_closing = " } "

let construction (tokens : Token.t array)
    (construction : Typec_sema.Expressions.construction) =
  let { Typec_sema.Expressions.span; variant; constructor; callee; braced; _ } =
    construction
  in
  let location = tokens.(span.first).location in
  let variant = Typec_sema.Encoding.variant_name variant in
  let opening = if braced then "{ " else literal_opening variant in
  let closing = if braced then "}" else literal_closing in
  let tag = tag_designation ~variant constructor in
  match callee with
  | None ->
      replace tokens ~location
        (opening ^ tag ^ " " ^ closing)
        (grammar_tokens tokens span.first span.last)
  | Some callee ->
      let left_paren = grammar_token_after tokens callee.last in
      replace tokens ~location
        (opening ^ tag ^ fields_opening constructor)
        (grammar_tokens tokens span.first left_paren)
      @ replace tokens
          ~location:tokens.(span.last).location
          (fields_closing ^ closing) [ span.last ]

(* The tokens that the head of a construction replaces: the callee and
   its [(], or the whole construction without arguments. A qualifying
   application in them goes with them. *)
let construction_head (tokens : Token.t array)
    (construction : Typec_sema.Expressions.construction) : Tree.span =
  let span = construction.span in
  match construction.callee with
  | None -> span
  | Some callee ->
      { first = span.first; last = grammar_token_after tokens callee.last }

(* Design 13.5, 10.5: a match becomes a block that reaches the scrutinee
   through [__tc_match], a pointer to it or to a copy of it, and a
   [switch] on its tag. Each arm is a block after the [case] of every
   constructor it takes; the block declares the bindings and ends in a
   trap, and the [default] of the switch, which only an invalid tag
   reaches, traps (design 4.3, 4.5). A single-pattern test holds its
   operand in the same way. The scrutinee and the block items keep their
   tokens. *)

(* The trap of design 10.5 on a GNU-compatible compiler. *)
let trap = "__builtin_trap();"

let scrutinee_pointer = "__tc_match"
let scrutinee_copy = "__tc_copy"

(* What replaces the tokens before and after the scrutinee of a match or
   the operand of a test: the opening of the block, and the declaration
   of the pointer around the scrutinee. *)
let scrutinee_holder (matching : _ Typec_sema.Expressions.matching_of) =
  let variant = Typec_sema.Encoding.variant_name matching.variant in
  let record = "struct " ^ (variant :> string) in
  match matching.access with
  | Through_pointer ->
      ( Printf.sprintf "{ const %s *const %s = &(" record scrutinee_pointer,
        "); " )
  | Through_copy ->
      ( Printf.sprintf "{ const %s %s = (" record scrutinee_copy,
        Printf.sprintf "), *const %s = &%s; " scrutinee_pointer
          scrutinee_copy )

(* The type of a binding is spelt [__typeof__] its field (design 2.4),
   because no name of the field's type that C11 can spell is sure to be
   visible, and not hidden, at the match. *)
let binding_declaration (binding : Typec_sema.Expressions.binding) =
  let field =
    Printf.sprintf "%s->%s.%s.%s" scrutinee_pointer Tree.union_member
      (binding.constructor :> string)
      binding.field
  in
  Printf.sprintf " const __typeof__(%s) %s = %s;" field binding.name field

let binding_declarations bindings =
  String.concat "" (List.map binding_declaration bindings)

let case_label ~variant constructor =
  Printf.sprintf "case %s:" (Tree.enumerator_name ~variant constructor)

(* The [default] that only a tag that is no constructor's reaches. *)
let invalid_tag = Printf.sprintf "default: %s" trap

(* The text that opens the block of an arm and the text that closes it
   after the last item. An arm that binds holds its items in a block of
   their own after the bindings, so that they begin a block as written,
   where a pragma such as STDC FENV_ACCESS must stand; one that binds
   nothing begins its block with them already. A declaration in that
   inner block could hide a binding in C, but none redeclares one,
   since typec refuses it in the one scope of an arm (4.1 rule 5). *)
let arm_block (bindings : Typec_sema.Expressions.binding list) =
  match bindings with
  | [] -> ("{", " " ^ trap ^ " }")
  | _ -> ("{" ^ binding_declarations bindings ^ " {", " } " ^ trap ^ " }")

(* The labels of an arm become the [case] of each constructor it takes
   and open its block; a trap closes the block after its last item. *)
let matched_arm tokens ~variant (arm : Typec_sema.Expressions.matched_arm) =
  let opening, closing = arm_block arm.bindings in
  let cases = String.concat " " (List.map (case_label ~variant) arm.cases) in
  replace tokens ~location:tokens.(arm.labels.first).location
    (cases ^ " " ^ opening)
    (grammar_tokens tokens arm.labels.first arm.labels.last)
  @ [ close tokens ~after:arm.arm.last closing ]

let match_statement (tokens : Token.t array) matching arms =
  let { Typec_sema.Expressions.statement; scrutinee; variant; _ } =
    matching
  in
  let variant = Typec_sema.Encoding.variant_name variant in
  let match_token = statement.first in
  let open_paren = grammar_token_after tokens match_token in
  let close_paren = grammar_token_after tokens scrutinee.last in
  let open_brace = grammar_token_after tokens close_paren in
  let opening, held = scrutinee_holder matching in
  let switch =
    Printf.sprintf "switch (%s->%s) {" scrutinee_pointer Tree.tag_member
  in
  replace tokens ~location:tokens.(match_token).location opening
    [ match_token; open_paren ]
  @ replace tokens ~location:tokens.(close_paren).location (held ^ switch)
      [ close_paren; open_brace ]
  @ List.concat_map (matched_arm tokens ~variant) arms
  @ replace tokens
      ~location:tokens.(statement.last).location
      (Printf.sprintf "%s } }" invalid_tag)
      [ statement.last ]

(* Design 13.5: a single-pattern test becomes the block of a match that
   reads the tag once into [__tc_tag] and has an [if] on it. Its true
   branch is a block that the [)] of the test opens, which declares the
   bindings and then holds the statement as written: a compound
   statement still begins a block, where a pragma such as STDC
   FENV_ACCESS must stand, a pragma before the statement still precedes
   it, and an [if] in the statement cannot take the [else] of the false
   branch. A declaration in a compound statement could hide a binding
   in C, but none redeclares one, since typec refuses it in the one
   scope of the bindings and the statement (4.6 rule 4). The false
   branch traps on a tag that is no constructor's (4.5), with a
   [switch] whose cases are those of a match, and then runs the [else]
   statement of an [if]. A [while] test is the body of an endless loop
   whose false branch ends in [break], so that the operand is evaluated
   in that loop (4.4). *)

let tag_local = "__tc_tag"

let tag_declaration =
  Printf.sprintf "const __typeof__(%s->%s) %s = %s->%s; " scrutinee_pointer
    Tree.tag_member tag_local scrutinee_pointer Tree.tag_member

let tag_check ~variant constructors =
  Printf.sprintf "switch (%s) { %s break; %s } " tag_local
    (String.concat " " (List.map (case_label ~variant) constructors))
    invalid_tag

(* The false branch of a test of [form] after the statement that ends at
   [controlled_last]: the end of the block around that statement, the
   [check] of the tag, then the [else] statement of an [if], or the end
   of the loop of a [while]. *)
let false_branch tokens form ~controlled_last ~check =
  let after_controlled text =
    close tokens ~after:controlled_last (" }" ^ text)
  in
  match (form : Typec_sema.Expressions.test_form) with
  | If_test { otherwise = None } ->
      [ after_controlled (" else { " ^ check ^ "} }") ]
  | If_test { otherwise = Some otherwise } ->
      let else_token = grammar_token_before tokens otherwise.first in
      after_controlled ""
      :: replace tokens ~location:tokens.(else_token).location
          ("else { " ^ check)
          [ else_token ]
      @ [ close tokens ~after:otherwise.last " } }" ]
  | While_test -> [ after_controlled (" else { " ^ check ^ "break; } }") ]

let single_pattern_test (tokens : Token.t array) matching
    (test : Typec_sema.Expressions.test) =
  let { Typec_sema.Expressions.statement; scrutinee; variant; _ } =
    matching
  in
  let variant = Typec_sema.Encoding.variant_name variant in
  let equals = grammar_token_before tokens scrutinee.first in
  let close_paren = grammar_token_after tokens scrutinee.last in
  let opening, held = scrutinee_holder matching in
  let loop = match test.form with If_test _ -> "" | While_test -> "for (;;) " in
  let selected =
    Printf.sprintf "if (%s == %s) " tag_local
      (Tree.enumerator_name ~variant test.constructor)
  in
  let check = tag_check ~variant test.constructors in
  replace tokens ~location:tokens.(statement.first).location
    (loop ^ opening)
    (grammar_tokens tokens statement.first equals)
  @ replace tokens ~location:tokens.(close_paren).location
      (held ^ tag_declaration ^ selected ^ "{"
      ^ binding_declarations test.bindings)
      [ close_paren ]
  @ false_branch tokens test.form ~controlled_last:test.controlled.last
      ~check

let matching (tokens : Token.t array)
    (matching : Typec_sema.Expressions.matching) =
  match matching.selects with
  | Arms arms -> match_statement tokens matching arms
  | Test test -> single_pattern_test tokens matching test

(* Edits in {!Emitter.in_order}, so that those that a stretch of tokens
   owns are found by a search, not a scan of all of them. *)
type ordered_edits = Emitter.edit array

let order_edits edits : ordered_edits = Array.of_list (Emitter.in_order edits)

(* The edits of [ordered] that tokens [first] to [last] own, in
   order. *)
let edits_within (ordered : ordered_edits) ~first ~last =
  (* The number of edits owned by a token before [index]: those below
     [low] are, those from [high] on are not. *)
  let rec owned_before index low high =
    if low = high then low
    else
      let middle = (low + high) / 2 in
      if ordered.(middle).owner < index then
        owned_before index (middle + 1) high
      else owned_before index low middle
  in
  let count = Array.length ordered in
  let start = owned_before first 0 count in
  let stop = owned_before (last + 1) start count in
  Array.to_list (Array.sub ordered start (stop - start))

(* The tokens [first] to [last] of a text with the edits that they own
   in [ordered] applied, as moved text: every token at its own location,
   and the text of each edit at the edit's. The moved text of an edit
   inside, such as the copies that a return in the operand of a try
   runs, moves with it. *)
let moved_text (text : Reader.t) ordered ~first ~last =
  let moved_piece : Emitter.moved_piece -> Emitter.piece = function
    | Piece piece -> piece
    | Pragma_line _ -> invalid_arg "Lowering.moved_text: a pragma line"
  in
  let written (edit : Emitter.edit) =
    match edit.text with
    | Emitter.Code { code = ""; _ } -> []
    | Emitter.Code { location; code } -> [ Emitter.generated location code ]
    | Emitter.Bracketed _ -> invalid_arg "Lowering.moved_text: a bracket"
    | Emitter.Moved pieces -> List.map moved_piece pieces
  in
  let token index =
    match Emitter.token text index with
    | Some piece -> piece
    | None -> invalid_arg "Lowering.moved_text: an unmovable token"
  in
  (* A closing insertion that token [last] owns stands after it, so
     the edits are done before the tokens are. *)
  let rec from index edits pieces =
    match edits with
    | (edit : Emitter.edit) :: rest when edit.range.first = index ->
        from (index + edit.range.count) rest (written edit :: pieces)
    | (edit : Emitter.edit) :: _ when edit.range.first < index ->
        invalid_arg "Lowering.moved_text: overlapping edits"
    | _ when index > last -> List.concat (List.rev pieces)
    | _ -> from (index + 1) edits ([ token index ] :: pieces)
  in
  from first (edits_within ordered ~first ~last) []

(* Design 13.5: a construct that typec answers, where the backend would
   answer for the representation of a distinct type, is steered to or
   replaced by the answer. Each range of its tokens that lowering
   replaces is replaced by [text], and the edits inside it go. *)
type dropped = { span : Tree.span; text : string }

let integer_constant compatible = if compatible then "1" else "0"

(* The type name that only association [index] of an answered generic
   selection matches, counting from 1: pointers to arrays of different
   constant lengths are incompatible (C11 6.7.6.2p6). *)
let steering_type index = Printf.sprintf "char (*)[%d]" index

(* A generic selection that typec answers keeps its controlling
   expression and its associations, so the backend sees the names they
   use and the tags they declare, but for those in a type name. Each
   association is numbered by its position, the type name of association
   [i] becomes [steering_type i], and the controlling expression, which
   is not evaluated (C11 6.5.1.1p3), is kept beside a null pointer of
   the selected association's steering type, so the backend selects
   what typec did. [default] has no type name and stays: when typec
   selects it, no type name has its number. *)
let numbered associations =
  List.mapi (fun index association -> (index + 1, association)) associations

let result_of (association : Tree.generic_association) =
  match association.node with
  | Association (_, result) | Default_association result -> result

let steered_type_names associations =
  List.filter_map
    (fun (number, (association : Tree.generic_association)) ->
      match association.node with
      | Association (type_name, _) ->
          Some { span = type_name.span; text = steering_type number }
      | Default_association _ -> None)
    (numbered associations)

let selected_number associations (result : Tree.expression) =
  let selects (_, association) =
    (result_of association).span = result.span
  in
  fst (List.find selects (numbered associations))

let dropped_ranges (answered : Typec_sema.Expressions.answered) =
  let { Typec_sema.Expressions.construct; answer } = answered in
  match answer with
  | Compatible compatible ->
      [ { span = construct; text = integer_constant compatible } ]
  | Selected { associations; _ } -> steered_type_names associations

let steered_controlling tokens (answered : Typec_sema.Expressions.answered) =
  match answered.answer with
  | Compatible _ -> []
  | Selected { controlling; associations; result } ->
      let selected = steering_type (selected_number associations result) in
      [ insert tokens ~before:controlling.span.first "((void)(";
        insert tokens
          ~before:(grammar_token_after tokens controlling.span.last)
          (Printf.sprintf "), (%s)0)" selected) ]

(* Spans sorted by first token, each with the furthest last token of
   the spans up to it, so that whether one span covers a stretch is one
   search, not a comparison with each. *)
type cover = { firsts : int array; reaches : int array }

let cover (spans : Tree.span list) =
  let sorted = Array.of_list spans in
  Array.stable_sort
    (fun (a : Tree.span) (b : Tree.span) -> compare a.first b.first)
    sorted;
  let reaches = Array.map (fun (span : Tree.span) -> span.last) sorted in
  for index = 1 to Array.length reaches - 1 do
    reaches.(index) <- max reaches.(index) reaches.(index - 1)
  done;
  { firsts = Array.map (fun (span : Tree.span) -> span.first) sorted; reaches }

(* Whether one of the spans begins at or before token [first] and ends
   at or after token [last]. *)
let covers { firsts; reaches } ~first ~last =
  (* The number of spans that begin at or before [first]: those below
     [low] do, those from [high] on do not. *)
  let rec begun low high =
    if low = high then low
    else
      let middle = (low + high) / 2 in
      if firsts.(middle) <= first then begun (middle + 1) high
      else begun low middle
  in
  let count = begun 0 (Array.length firsts) in
  count > 0 && reaches.(count - 1) >= last

(* The outermost of the dropped ranges, the first of those with one
   span: the edits of a range inside another would overlap those of the
   one around it, so it goes with it, and an answered construct's text
   stands before the name of an application with the same tokens, such
   as the steering type of an association that names an instance. In
   order of first token and longest first, a range is inside an earlier
   one or has its span exactly when it ends no later than the furthest
   of them. *)
let outermost dropped =
  let order a b =
    match compare a.span.first b.span.first with
    | 0 -> compare b.span.last a.span.last
    | by_first -> by_first
  in
  let keep (reach, kept) range =
    if range.span.last <= reach then (reach, kept)
    else (range.span.last, range :: kept)
  in
  let _, kept = List.fold_left keep (-1, []) (List.stable_sort order dropped) in
  List.rev kept

(* Whether [edit] goes with one of the [dropped] spans: by the tokens it
   replaces; for a closing insertion by its owner, the last token of
   what it closes; for another insertion by the place it inserts at,
   between two tokens, so that one at either edge of a span stays with
   the tokens kept beside it. *)
let goes_with dropped (edit : Emitter.edit) =
  let first = edit.range.first in
  if edit.range.count > 0 then
    covers dropped ~first ~last:(Reader.end_token edit.range)
  else if edit.owner < first then
    covers dropped ~first:edit.owner ~last:edit.owner
  else covers dropped ~first:(first - 1) ~last:first

let dropped_edits tokens { span; text } =
  replace tokens ~location:tokens.(span.first).location text
    (grammar_tokens tokens span.first span.last)

(* Design 5.1, 13.5: a try becomes a temporary of the operand's result
   type that holds the operand, and a test of the temporary's tag that
   only Ok passes, written directly before the statement or declaration
   that holds the try; the try becomes the read of the Ok field, and a
   statement [try e;] becomes nothing. The labels of that statement stay
   in place on a null statement before the temporary, and a statement
   that is the substatement of another becomes a block around the
   labels, the temporary, the test and itself, so that the labels stay
   under the statement around it. The temporary is const and names the
   instance by its claimed tag, as the copy of a match does. *)

let temporary_name number = Printf.sprintf "__tc_t%d" number

(* The constructors of the universe's result (design 3.6). *)
let result_constructor name =
  match Spelling.constructor name with
  | Ok constructor -> constructor
  | Error _ -> invalid_arg "Lowering: a constructor of result"

let ok_constructor = result_constructor Typec_sema.Ctype.result_ok
let err_constructor = result_constructor Typec_sema.Ctype.result_err

(* typec's own text of a try, at the location of its [try]. *)
let try_piece location text = Emitter.Piece (Emitter.generated location text)

(* Whether the tag of [temporary], an object of [variant], is not that
   of [constructor]. *)
let tag_differs ~temporary ~variant constructor =
  Printf.sprintf "%s.%s != %s" temporary Tree.tag_member
    (Tree.enumerator_name ~variant constructor)

let field_read ~temporary constructor field =
  Printf.sprintf "%s%s.%s" temporary (fields_designator constructor) field

(* The Err of the function's [returned] instance, built from the error
   that [temporary] holds, or without a field where E is void. The field
   of the operand's Err is that of the function's, since typing refuses
   a try whose two error types differ (design 5.1 rule 1). *)
let returned_err ~returned ~temporary (err_field : string option) =
  let tag = tag_designation ~variant:returned err_constructor in
  match err_field with
  | None -> literal_opening returned ^ tag ^ " " ^ literal_closing
  | Some field ->
      literal_opening returned ^ tag
      ^ fields_opening err_constructor
      ^ field_read ~temporary err_constructor field
      ^ fields_closing ^ literal_closing

(* The error path in the four parts of the [try] row of 13.5: the test
   that only Ok passes; the trap of a tag that is not Err either (5.1
   rule 2); the cleanups, the copies of the deferred statements that are
   active at the try (section 6); and the return of the Err, built from
   the temporary after them. *)
let error_path ~location ~variant (site : Typec_sema.Expressions.try_site)
    ~cleanups =
  let temporary = temporary_name site.temporary in
  let returned =
    Typec_sema.Encoding.variant_name (Applied site.return_instance)
  in
  let test =
    Printf.sprintf "if (%s) {" (tag_differs ~temporary ~variant ok_constructor)
  in
  let trap_unless_err =
    Printf.sprintf "if (%s) %s"
      (tag_differs ~temporary ~variant err_constructor)
      trap
  in
  let return =
    Printf.sprintf "return %s; }"
      (returned_err ~returned ~temporary site.err_field)
  in
  [ try_piece location test; try_piece location trap_unless_err ]
  @ cleanups
  @ [ try_piece location return ]

(* The text in front of the holder: the null statement of its labels,
   the temporary initialised with the operand, which moves with the
   edits inside it, and the error path, which runs [cleanups]. *)
let front (text : Reader.t) ordered ~location ~cleanups
    (site : Typec_sema.Expressions.try_site) =
  let variant =
    Typec_sema.Encoding.variant_name (Applied site.operand_instance)
  in
  let null_statement =
    match site.holder.labels with
    | Some _ -> [ try_piece location ";" ]
    | None -> []
  in
  let declaration =
    Printf.sprintf "const struct %s %s =" (variant :> string)
      (temporary_name site.temporary)
  in
  let operand =
    moved_text text ordered ~first:site.operand.first
      ~last:site.operand.last
  in
  null_statement
  @ [ try_piece location declaration ]
  @ List.map (fun piece -> Emitter.Piece piece) operand
  @ [ try_piece location ";" ]
  @ error_path ~location ~variant site ~cleanups

(* The tokens that the try's value replaces: the try, or for [try e;]
   the whole statement, so that no read of the Ok field is left as a
   statement whose value goes unused (-Wunused-value). *)
let replaced_span (site : Typec_sema.Expressions.try_site) =
  match site.form with
  | Whole_statement -> site.holder.statement
  | Assigned | Initialiser -> site.try_span

(* What replaces [replaced_span]: the read of the Ok field, which an
   assignment or an initialiser takes only where T is not void. *)
let try_value (site : Typec_sema.Expressions.try_site) =
  match (site.form, site.ok_field) with
  | Whole_statement, _ -> ""
  | (Assigned | Initialiser), Some field ->
      field_read ~temporary:(temporary_name site.temporary) ok_constructor
        field
  | (Assigned | Initialiser), None ->
      invalid_arg "Lowering: the void value of a try that is no statement"

(* The edits of a try: those in front of its holder and in place of the
   try, and those after the holder, which close the block of a
   substatement. *)
type try_lowering = {
  opening : Emitter.edit list;
  closing : Emitter.edit list;
}

let lower_try (text : Reader.t) ordered ~cleanups_of
    (site : Typec_sema.Expressions.try_site) =
  let tokens = text.tokens in
  let { Typec_sema.Expressions.statement; labels; standing } = site.holder in
  let location = tokens.(site.try_span.first).location in
  let in_front =
    Emitter.moved
      (Reader.range tokens ~first:statement.first ~count:0)
      (front text ordered ~location ~cleanups:(cleanups_of site) site)
  in
  let replaced = replaced_span site in
  let value =
    replace tokens ~location:tokens.(replaced.first).location
      (try_value site)
      (grammar_tokens tokens replaced.first replaced.last)
  in
  match standing with
  | Block_item -> { opening = in_front :: value; closing = [] }
  | Substatement ->
      let first = (Option.value labels ~default:statement).first in
      { opening = insert tokens ~before:first "{" :: in_front :: value;
        closing = [ close tokens ~after:statement.last "}" ] }

(* The edits of a text with its tries lowered. The edits inside the
   tokens that a try replaces go with its operand, which moves, and the
   try's own replace them. Where another construct inserts at the token
   where a try's holder begins or ends, the two nest: one that ends
   where the holder begins closes before the try's opening, and one
   around the holder closes after the try's block. So the closings of
   the tries go first and their openings last. [cleanups_of] gives the
   cleanups of the error path of a try. *)
let with_tries text edits tries ~cleanups_of =
  let replaced = cover (List.map replaced_span tries) in
  let ordered = order_edits edits in
  let lowered = List.map (lower_try text ordered ~cleanups_of) tries in
  List.concat_map (fun lowered -> lowered.closing) lowered
  @ List.filter (fun edit -> not (goes_with replaced edit)) edits
  @ List.concat_map (fun lowered -> lowered.opening) lowered

(* Design 6 and 13.5: a defer statement is removed, and a copy of its
   statement [S], as a block, runs at each exit of its scope. An exit
   that leaves several scopes runs their copies latest first. The end of
   a block that can complete gets the copies before its [}]; one that
   cannot gets a trap there instead (6 rule 1), and the end of a match
   arm has its own. A jump that runs copies becomes a block that holds
   them and then the jump, [{ copies jump; }], after the labels of its
   statement; a [return e;] holds [e] first, in the temporary [__tc_r]
   of the type [__tc_ret], or in a function that returns void as an
   expression statement. The error path of a try gets its copies where
   the try is lowered ({!with_tries}). A copy of [S] is the text of [S]
   with the edits that its tokens own; [S] holds no defer (design 6 rule
   11). *)

module Reachability = Typec_sema.Reachability

let return_type_name = "__tc_ret"
let return_temporary = "__tc_r"

(* The tokens [defer S], which lowering removes. *)
let defer_span (site : Reachability.defer_site) =
  { Tree.first = site.keyword.first; last = site.deferred.last }

(* A place that runs the copies of the scopes it leaves: the end of a
   block that can complete, by the token of its [}], or a jump. *)
type exit_place = Block_end of int | Left_by of Reachability.exit

let exit_places (site : Reachability.defer_site) =
  let ending =
    match site.ending with
    | Completes closing -> [ Block_end closing ]
    | Cannot_complete _ | Arm_end -> []
  in
  ending @ List.map (fun exit -> Left_by exit) site.exits

(* Each place of [sites] with the sites whose scopes it leaves, in the
   order their copies run, the latest first. *)
let places (sites : Reachability.defer_site list) =
  let pairs =
    List.concat_map
      (fun site -> List.map (fun place -> (place, site)) (exit_places site))
      sites
  in
  let sorted = List.stable_sort (fun (a, _) (b, _) -> compare a b) pairs in
  let group grouped (place, site) =
    match grouped with
    | (last, leaving) :: earlier when last = place ->
        (last, site :: leaving) :: earlier
    | _ -> (place, [ site ]) :: grouped
  in
  List.rev (List.fold_left group [] sorted)

(* The trap at the end of a block that cannot complete, once for each
   block however many defers it holds. *)
let trap_edits (text : Reader.t) (sites : Reachability.defer_site list) =
  let closing (site : Reachability.defer_site) =
    match site.ending with
    | Cannot_complete closing -> Some closing
    | Completes _ | Arm_end -> None
  in
  List.sort_uniq Int.compare (List.filter_map closing sites)
  |> List.map (fun closing -> insert text.tokens ~before:closing trap)

let defer_piece location text = Emitter.Piece (Emitter.generated location text)

(* The copy of the statement of [site], [{ S }], from the edits [base]
   of the text. *)
let copy (text : Reader.t) base (site : Reachability.defer_site) =
  let statement = site.deferred in
  let location = text.tokens.(statement.first).location in
  let pieces =
    moved_text text base ~first:statement.first ~last:statement.last
  in
  let moved = List.map (fun piece -> Emitter.Piece piece) pieces in
  (defer_piece location "{" :: moved) @ [ defer_piece location "}" ]

(* The text of a [return e;] that runs copies: [value_opening] replaces
   its [return], [value_closing] its [;], before the copies, and
   [returned] follows them. *)
type return_form = {
  value_opening : string;
  value_closing : string;
  returned : string;
}

let return_form : Typec_sema.Expressions.returns -> return_form = function
  | Returns_value ->
      { value_opening =
          Printf.sprintf "{ %s %s = (" return_type_name return_temporary;
        value_closing = ");";
        returned = Printf.sprintf "return %s; }" return_temporary }
  | Returns_void ->
      { value_opening = "{"; value_closing = ";"; returned = "return; }" }

(* The edits of one place of a function that [returns], which runs the
   copies of [leaving]. *)
let place_edits (text : Reader.t) base returns (place, leaving) =
  let tokens = text.tokens in
  let copies = List.concat_map (copy text base) leaving in
  let at index = tokens.(index).location in
  let insertion index = Reader.range tokens ~first:index ~count:0 in
  let token index = Reader.range tokens ~first:index ~count:1 in
  match place with
  | Block_end closing -> [ Emitter.moved (insertion closing) copies ]
  | Left_by (Jump jump) ->
      [ Emitter.moved (insertion jump.first)
          (defer_piece (at jump.first) "{" :: copies);
        Emitter.code (token jump.last) ~location:(at jump.last) "; }" ]
  | Left_by (Value_return { statement; operand = _ }) ->
      let form = return_form returns in
      [ Emitter.code (token statement.first) ~location:(at statement.first)
          form.value_opening;
        Emitter.moved (token statement.last)
          ((defer_piece (at statement.last) form.value_closing :: copies)
          @ [ defer_piece (at statement.last) form.returned ]) ]
  | Left_by (Error_path _) -> []

let rec names_directly (declarator : Tree.declarator) =
  match declarator.node with
  | Name _ -> true
  | Parenthesized_declarator { inner; _ } -> names_directly inner
  | Pointer _ | Block_pointer _ | Array _ | Function _ -> false

(* The parameter list of the function that a definition's declarator
   declares: that of the function derivation of its name. *)
let rec definition_parameters (declarator : Tree.declarator) =
  match declarator.node with
  | Function { inner = Some inner; parameters } when names_directly inner ->
      parameters
  | Parenthesized_declarator { inner; _ }
  | Pointer { inner = Some inner; _ }
  | Block_pointer { inner = Some inner; _ }
  | Array { inner = Some inner; _ }
  | Function { inner = Some inner; _ } ->
      definition_parameters inner
  | Name _
  | Pointer { inner = None; _ }
  | Block_pointer { inner = None; _ }
  | Array { inner = None; _ }
  | Function { inner = None; _ } ->
      invalid_arg "Lowering: a definition that declares no function"

(* The name of a parameter that the call of [__tc_ret] passes an lvalue
   of. A parameter without a name is a refusal of the form of 13.5
   (TODO.md), which the front end's refusal of every defer (TC0023)
   keeps from the backend. *)
let parameter_name (parameter : Tree.parameter) =
  let name =
    match parameter.node.declarator with
    | Named_parameter { declarator; _ } -> Tree.declared_name declarator
    | Abstract_parameter _ -> None
  in
  match name with
  | Some name -> name
  | None -> invalid_arg "Lowering: a parameter without a name"

(* The parameters that the call passes: none for [(void)], the one
   parameter that has no declarator, and the named ones of a variadic
   function. *)
let parameter_names : Tree.parameters -> string list = function
  | Identifier_list names ->
      List.map (fun (name : Tree.parameter_name) -> name.name.node) names
  | Prototype
      {
        parameters =
          [ { node = { declarator = Abstract_parameter None; _ }; _ } ];
        variadic = false;
      } ->
      []
  | Prototype { parameters; variadic = _ } -> List.map parameter_name parameters

(* Design 13.5: [typedef __typeof__(call of f) __tc_ret;] in a block
   around the body, which stays a block of its own. *)
let return_type_edits (text : Reader.t)
    (defers : Typec_sema.Expressions.function_defers) =
  let tokens = text.tokens in
  let lvalue name = Printf.sprintf "*(__typeof__(%s) *)0" name in
  let arguments =
    parameter_names (definition_parameters defers.declarator)
    |> List.map lvalue |> String.concat ", "
  in
  let typedef =
    Printf.sprintf "{ typedef __typeof__(((__typeof__(%s) *)0)(%s)) %s;"
      defers.function_name arguments return_type_name
  in
  let body = defers.body in
  [ insert tokens ~before:body.first typedef;
    Emitter.code
      (Reader.range tokens ~first:body.last ~count:1)
      ~location:tokens.(body.last).location "} }" ]

(* The token where [place] stands, which goes with any text that
   lowering drops around it. *)
let place_token = function
  | Block_end closing -> closing
  | Left_by (Jump jump) -> jump.first
  | Left_by (Value_return { statement; operand = _ }) -> statement.first
  | Left_by (Error_path try_span) -> try_span.first

let is_value_return = function
  | Left_by (Value_return _) -> true
  | Block_end _ | Left_by (Jump _ | Error_path _) -> false

(* The edits of a function with its defers lowered: the copies at each
   exit, the traps, and [__tc_ret] where a [return e;] that runs copies
   needs it. A defer and an exit in text that lowering drops, such as
   a statement expression in an answered type name, go with that text:
   it never runs. *)
let function_edits (text : Reader.t) base ~dropped
    (defers : Typec_sema.Expressions.function_defers) =
  let kept_token index = not (covers dropped ~first:index ~last:index) in
  let kept_places =
    List.filter
      (fun (place, _) -> kept_token (place_token place))
      (places defers.sites)
  in
  let kept_sites =
    List.filter
      (fun (site : Reachability.defer_site) -> kept_token site.keyword.first)
      defers.sites
  in
  let return_type =
    if
      defers.returns = Returns_value
      && List.exists (fun (place, _) -> is_value_return place) kept_places
    then return_type_edits text defers
    else []
  in
  let removal site =
    dropped_edits text.tokens { span = defer_span site; text = "" }
  in
  List.concat_map (place_edits text base defers.returns) kept_places
  @ trap_edits text kept_sites
  @ List.concat_map removal kept_sites
  @ return_type

(* The cleanups of the error path of each try (13.5, the [try] row):
   the copies of the scopes of [functions] that it leaves, the latest
   first, from the edits [base] of the text. *)
let error_path_cleanups (text : Reader.t) base
    (functions : Typec_sema.Expressions.function_defers list) =
  let leaving =
    List.concat_map
      (fun (defers : Typec_sema.Expressions.function_defers) ->
        places defers.sites)
      functions
  in
  fun (site : Typec_sema.Expressions.try_site) ->
    match List.assoc_opt (Left_by (Error_path site.try_span)) leaving with
    | Some sites -> List.concat_map (copy text base) sites
    | None -> []

(* The edits of a text with the defers of its functions lowered. The
   statements go, and the edits that their tokens own go with them, to
   their copies, which [base], the ordered [edits], gives. [dropped] is
   the text that lowering drops. *)
let with_defers (text : Reader.t) edits ~base ~dropped
    (functions : Typec_sema.Expressions.function_defers list) =
  let sites =
    List.concat_map
      (fun (defers : Typec_sema.Expressions.function_defers) -> defers.sites)
      functions
  in
  let removed = cover (List.map defer_span sites) in
  List.filter (fun edit -> not (goes_with removed edit)) edits
  @ List.concat_map (function_edits text base ~dropped) functions

(* The edits of one text: the unit's own, or the definition of an
   instance. A type declaration may hold another, in a statement
   expression of its definition, and a constructor's arguments other
   constructors; {!Emitter.in_order} orders the edits, an insertion
   before a token ahead of an edit that replaces it, and two insertions
   before one token in the order of the list. Two statements that end at
   one token nest, and the inner one, which begins later, closes first,
   so the matchings go in reverse source order. The steering of a
   generic selection nests only because no other lowering inserts before
   the first token of its controlling expression or the comma after it.
   [replaced] are ranges that lowering replaces whole, such as an
   application by the name of its instance, unless the head of a
   construction replaces them; with those of [answered], the edits
   inside one go, and the range's own edits replace them. Last, the
   tries are lowered ({!with_tries}), and the edits inside the operand
   of one move with it. *)
let text_edits (text : Reader.t) ~declarations ~void_field_spans ~replaced
    typed =
  let tokens = text.tokens in
  let answered = Typec_sema.Expressions.answered typed in
  let constructions = Typec_sema.Expressions.constructions typed in
  let heads = cover (List.map (construction_head tokens) constructions) in
  let in_head { span; _ } = covers heads ~first:span.first ~last:span.last in
  (* An insertion before the first token of a void field would survive
     its removal ({!goes_with}); none stands there, since a field begins
     with a specifier, before which no lowering inserts. *)
  let removed span = { span; text = "" } in
  let dropped =
    outermost
      (List.concat_map dropped_ranges answered
      @ List.map removed void_field_spans
      @ List.filter (fun range -> not (in_head range)) replaced)
  in
  let dropped_spans = cover (List.map (fun range -> range.span) dropped) in
  let kept edit = not (goes_with dropped_spans edit) in
  let void_fields = Spans.of_list void_field_spans in
  let declaration (lowered, declaration) =
    type_declaration tokens ~lowered ~void_fields declaration
  in
  let lowered =
    List.concat_map declaration declarations
    @ List.concat_map (construction tokens) constructions
    @ List.concat_map (matching tokens)
        (List.rev (Typec_sema.Expressions.matchings typed))
    @ List.concat_map (steered_controlling tokens) answered
  in
  let undeferred =
    List.concat_map (dropped_edits tokens) dropped @ List.filter kept lowered
  in
  let functions = Typec_sema.Expressions.defers typed in
  (* The copies of a deferred statement, at its exits and on the error
     path of a try, are its text with the edits that its tokens own,
     which lowering the defers moves out of the text. *)
  let base = order_edits undeferred in
  (* The defers go before the tries, so that a jump in the operand of a
     try runs its copies wherever the operand moves. *)
  let deferred =
    with_defers text undeferred ~base ~dropped:dropped_spans functions
  in
  with_tries text deferred
    (Typec_sema.Expressions.tries typed)
    ~cleanups_of:(error_path_cleanups text base functions)

let named (span, name) = { span; text = name }

(* Instances (design 10.3). Each text of an instance stands at the
   anchor that its placement names, in a packing bracket; the texts at
   one anchor share one bracket, in the order of the placements. *)

(* The generic's definition under the instance's name, with each type
   parameter and application written as the name that the reading
   found for it, from token [first] to its end. *)
let instance_definition (text : Reader.t) instance ~first
    (reading : Typec_sema.Declarations.instance_text) =
  let lowered = Typec_sema.Encoding.variant_name (Applied instance) in
  let edits =
    text_edits text
      ~declarations:[ (lowered, reading.generic) ]
      ~void_field_spans:reading.void_field_spans
      ~replaced:(List.map named reading.names)
      reading.typed
  in
  moved_text text (order_edits edits) ~first
    ~last:reading.generic.span.last

(* What the texts of the placements are written from: the unit and what
   its reading found. *)
type instance_context = {
  unit : Reader.t;
  declarations : Typec_sema.Declarations.t;
}

(* Design 10.3: each typedef after the lines that declare its tags. *)
let argument_typedefs location typedefs =
  let lines (typedef : Typec_sema.Declarations.argument_typedef) =
    List.map (fun (tag_line : Typec_sema.Type_name.tag_line) -> tag_line.line)
      typedef.tag_lines
    @ [ typedef.line ]
  in
  List.concat_map lines typedefs |> List.map (Emitter.generated location)

let reading context instance =
  match Typec_sema.Declarations.instance_text context.declarations instance with
  | Some reading -> reading
  | None -> invalid_arg "Lowering: an instance text without its reading"

(* Step 1: [struct I; typedef struct I I;] for a structure, union or
   variant, whose definition follows where it is needed; the whole
   typedef of 10.2 for an alias or a distinct generic. *)
let instance_declaration context location instance
    (generic : Tree.type_declaration) =
  let name = Typec_sema.Encoding.instance_name instance in
  let forward kind =
    [ Emitter.generated location (record_declarations kind ~tag:name name) ]
  in
  match generic.node.definition with
  | Variant _ | Incomplete_variant -> forward Struct
  | Record_alias specifier -> forward specifier.node.kind
  | Alias _ | Distinct _ ->
      let reading = reading context instance in
      instance_definition context.unit instance
        ~first:reading.generic.span.first reading

(* Step 2: the rest of 10.1 or 10.2, after the forward declaration. *)
let instance_rest context instance =
  let reading = reading context instance in
  match Tree.forward_declaration_end reading.generic with
  | Some first -> instance_definition context.unit instance ~first reading
  | None -> invalid_arg "Lowering.instance_rest: a typedef instance"

let placement_text context (placement : Typec_sema.Declarations.placement) =
  let location = context.unit.tokens.(placement.application.first).location in
  match placement.step with
  | Typedefs typedefs -> argument_typedefs location typedefs
  | Declared { generic } ->
      instance_declaration context location placement.instance generic
  | Defined -> instance_rest context placement.instance

(* The placements in runs that share an anchor, each run in order. *)
let by_anchor placements =
  let add runs (placement : Typec_sema.Declarations.placement) =
    match runs with
    | (at, run) :: earlier when at = placement.at ->
        (at, placement :: run) :: earlier
    | _ -> (placement.at, [ placement ]) :: runs
  in
  List.rev_map
    (fun (at, run) -> (at, List.rev run))
    (List.fold_left add [] placements)

let instance_brackets context =
  let bracket (at, (run : Typec_sema.Declarations.placement list)) =
    let first = List.hd run in
    let location = context.unit.tokens.(first.application.first).location in
    Emitter.bracketed context.unit ~at ~location
      (List.concat_map (placement_text context) run)
  in
  List.map bracket
    (by_anchor (Typec_sema.Declarations.placements context.declarations))

(* The unit's own text: each type declaration that is no generic under
   its own name, each generic's definition removed, as only its
   instances write it, and each application replaced by the name of its
   instance. *)
let unit_edits (text : Reader.t) declarations =
  let split (declaration : Tree.type_declaration) =
    match declaration.node.type_parameters with
    | [] ->
        Either.Left
          (Spelling.declared declaration.node.name.node, declaration)
    | _ :: _ -> Either.Right { span = declaration.span; text = "" }
  in
  let own, generics =
    List.partition_map split
      (Typec_sema.Declarations.type_declarations declarations)
  in
  text_edits text ~declarations:own ~void_field_spans:[]
    ~replaced:
      (generics
      @ List.map named (Typec_sema.Declarations.instance_names declarations))
    (Typec_sema.Declarations.typed declarations)

let edits (text : Reader.t) declarations =
  let context = { unit = text; declarations } in
  instance_brackets context @ unit_edits text declarations
