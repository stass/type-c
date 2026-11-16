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
   would name it. [head] is the tokens [type N]. *)
let alias tokens ~location ~head name (type_name : Tree.type_name) =
  let equals = grammar_token_before tokens type_name.span.first in
  let name_before =
    match type_name.node.abstract with
    | Some abstract -> name_position abstract
    | None -> type_name.span.last + 1
  in
  replace tokens ~location "typedef" (head @ [ equals ])
  @ [ insert tokens ~before:name_before name ]

(* A specifier without a tag of its own takes [name], before its body. *)
let record_alias tokens ~location ~head name
    (specifier : Tree.record_specifier Tree.spanned) =
  let equals = grammar_token_before tokens specifier.span.first in
  let { Tree.kind; tag; members; _ } = specifier.node in
  let replace_head ~tag =
    replace tokens ~location
      (record_declarations kind ~tag name)
      (head @ [ equals ])
  in
  let insert_tag (body : _ Tree.spanned) =
    insert tokens ~before:body.span.first name
  in
  match tag with
  | Some own -> replace_head ~tag:own.name.node
  | None ->
      replace_head ~tag:name @ Option.to_list (Option.map insert_tag members)

(* Variants (design 10.1). The tokens of each field are kept, so the
   struct of a constructor's fields keeps their lines. *)

let has_payload constructors =
  List.exists
    (fun (constructor : Tree.constructor) -> constructor.node.fields <> [])
    constructors

(* What comes before the constructors: the structure and typedef, which
   the incomplete variant declares already where the variant [completes]
   one; the enumeration of the tags, numbered from 0 in order (rule 1);
   and the structure up to its union where it has one (rule 3). *)
let variant_head ~completes variant constructors =
  let name = (variant : Spelling.type_name :> string) in
  let c_name = Spelling.declared variant in
  let enumerator (constructor : Tree.constructor) =
    Tree.enumerator_name ~variant:c_name constructor.node.name.node
  in
  let tag_enum = "enum " ^ Tree.enum_tag_name c_name in
  let forward =
    if completes then "" else record_declarations Struct ~tag:name name ^ " "
  in
  let union = if has_payload constructors then " union {" else "" in
  Printf.sprintf "%s%s { %s }; struct %s { %s %s;%s" forward tag_enum
    (String.concat ", " (List.map enumerator constructors))
    name tag_enum Tree.tag_member union

let variant_tail constructors =
  if has_payload constructors then Printf.sprintf "} %s; };" Tree.union_member
  else "};"

(* The tokens at [indexes], the first of which is [first], replaced by
   [text] at the location of [first]. *)
let replace_at (tokens : Token.t array) ~first text indexes =
  replace tokens ~location:tokens.(first).location text (first :: indexes)

(* A constructor with fields becomes the struct of them that the union
   holds, named after it; [| C (] opens it, the [,] after each field
   ends that field, and the [)] closes the struct. One without fields
   becomes nothing (rule 3). *)
let constructor_edits tokens (constructor : Tree.constructor) =
  let { Tree.name; fields } = constructor.node in
  let bar = constructor.span.first and close = constructor.span.last in
  let field_end (field : Tree.field) =
    let after = grammar_token_after tokens field.span.last in
    if after = close then
      replace_at tokens ~first:after
        (Printf.sprintf "; } %s;" (name.node :> string))
        []
    else replace_at tokens ~first:after ";" []
  in
  match fields with
  | [] -> replace_at tokens ~first:bar "" [ name.span.first ]
  | _ :: _ ->
      let open_paren = grammar_token_after tokens name.span.first in
      replace_at tokens ~first:bar "struct {" [ name.span.first; open_paren ]
      @ List.concat_map field_end fields

(* [type N = ... ;]: the head replaces [type N =], and [private] where
   it follows, and the tail the [;]. *)
let variant tokens ~location ~head (declaration : Tree.type_declaration)
    constructors =
  let { Tree.name; declared; _ } = declaration.node in
  let completes = declared.earlier <> None in
  let first_bar = (List.hd constructors : Tree.constructor).span.first in
  replace tokens ~location
    (variant_head ~completes name.node constructors)
    (head @ grammar_tokens tokens (name.span.first + 1) (first_bar - 1))
  @ List.concat_map (constructor_edits tokens) constructors
  @ replace_at tokens ~first:declaration.span.last (variant_tail constructors)
      []

let type_declaration (tokens : Token.t array)
    (declaration : Tree.type_declaration) =
  let { Tree.name; definition; _ } = declaration.node in
  let name = (name :> Tree.identifier) in
  let location = tokens.(declaration.span.first).location in
  let head = [ declaration.span.first; name.span.first ] in
  match definition with
  | Incomplete_variant ->
      replace tokens ~location
        (record_declarations Struct ~tag:name.node name.node)
        (head @ [ declaration.span.last ])
  | Alias type_name -> alias tokens ~location ~head name.node type_name
  (* Design 10.2: the typedef of its representation. [alias] replaces
     the [distinct] word, and the head the [=] and [private] before it. *)
  | Distinct { representation; _ } ->
      let distinct_word =
        grammar_token_before tokens representation.span.first
      in
      let definition_words =
        grammar_tokens tokens (name.span.first + 1) (distinct_word - 1)
      in
      alias tokens ~location ~head:(head @ definition_words) name.node
        representation
  | Record_alias record -> record_alias tokens ~location ~head name.node record
  | Variant { constructors; _ } ->
      variant tokens ~location ~head declaration constructors

(* Design 13.5: a constructor expression becomes the compound literal
   [((struct N){ .tag = N_C, .u.C = { a, b } })], or inside an
   initialiser the braced list alone. It names the structure tag, which
   no declaration in the variant's scope may hide (design 10.1 rule 6),
   rather than the typedef name, which a block may hide. The arguments
   keep their tokens; only the name of the constructor, the [(] and the
   [)] are replaced. *)
let construction (tokens : Token.t array)
    (construction : Typec_sema.Expressions.construction) =
  let { Typec_sema.Expressions.span; variant; constructor; callee; braced; _ } =
    construction
  in
  let location = tokens.(span.first).location in
  let variant = Typec_sema.Encoding.variant_name variant in
  let enumerator = Tree.enumerator_name ~variant constructor in
  let opening =
    if braced then "{ "
    else Printf.sprintf "((struct %s){ " (variant :> string)
  in
  let closing = if braced then "}" else "})" in
  let tag = Printf.sprintf ".%s = %s" Tree.tag_member enumerator in
  match callee with
  | None ->
      replace tokens ~location
        (opening ^ tag ^ " " ^ closing)
        (grammar_tokens tokens span.first span.last)
  | Some callee ->
      let fields =
        Printf.sprintf "%s, .%s.%s = { " tag Tree.union_member
          (constructor :> string)
      in
      let left_paren = grammar_token_after tokens callee.last in
      replace tokens ~location (opening ^ fields)
        (grammar_tokens tokens span.first left_paren)
      @ replace tokens
          ~location:tokens.(span.last).location
          (" } " ^ closing) [ span.last ]

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
  @ [ insert tokens ~before:(arm.arm.last + 1) closing ]

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
    insert tokens ~before:(controlled_last + 1) (" }" ^ text)
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
      @ [ insert tokens ~before:(otherwise.last + 1) " } }" ]
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

(* A dropped range inside another goes with it, so only the outermost
   are kept: the edits of one inside would overlap those of the one
   around it. *)
let outermost dropped =
  let contains outer inner =
    outer <> inner
    && outer.span.first <= inner.span.first
    && inner.span.last <= outer.span.last
  in
  List.filter
    (fun inner -> not (List.exists (fun outer -> contains outer inner) dropped))
    dropped

(* Whether [edit] goes with the dropped [span]: by the tokens it
   replaces, or for an insertion by the place it inserts at, between two
   tokens, so that one at either edge of the span stays with the tokens
   kept beside it. *)
let goes_with (edit : Emitter.edit) { span; _ } =
  let first = edit.range.first in
  if edit.range.count = 0 then span.first < first && first <= span.last
  else span.first <= first && Reader.end_token edit.range <= span.last

let dropped_edits tokens { span; text } =
  replace tokens ~location:tokens.(span.first).location text
    (grammar_tokens tokens span.first span.last)

(* A type declaration may hold another, in a statement expression of
   its definition, and a constructor's arguments other constructors, so
   the edits of all are sorted; an insertion before a token comes before
   an edit that replaces it. Two insertions before one token keep their
   order in [lowered]. Two statements that end at one token nest, and
   the inner one, which begins later, closes first, so the matchings go
   in reverse source order. The steering of a generic selection
   nests only because no other lowering inserts before the first token
   of its controlling expression or the comma after it. The edits inside a
   dropped range go, and the range's own edits replace them. *)
let edits (text : Reader.t) declarations constructions matchings answered =
  let tokens = text.tokens in
  let dropped = outermost (List.concat_map dropped_ranges answered) in
  let kept edit =
    not (List.exists (goes_with edit) dropped)
  in
  let lowered =
    List.concat_map (type_declaration tokens) declarations
    @ List.concat_map (construction tokens) constructions
    @ List.concat_map (matching tokens) (List.rev matchings)
    @ List.concat_map (steered_controlling tokens) answered
  in
  List.concat_map (dropped_edits tokens) dropped @ List.filter kept lowered
  |> List.stable_sort (fun (a : Emitter.edit) (b : Emitter.edit) ->
         compare (a.range.first, a.range.count) (b.range.first, b.range.count))
