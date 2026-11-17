(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

(* The tokens of the unit that [output] is made from. *)
let tokens_of output = (Emitter.unit output).tokens

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
let replace output ~location text indexes : Emitter.edit list =
  let tokens = tokens_of output in
  let code ~first ~count text =
    Emitter.code output (Reader.range tokens ~first ~count) ~location text
  in
  match indexes with
  | [] -> []
  | first :: _ when is_run tokens indexes ->
      [ code ~first ~count:(List.length indexes) text ]
  | first :: rest ->
      code ~first ~count:1 text
      :: List.map (fun index -> code ~first:index ~count:1 "") rest

let insert output ~before text =
  let tokens = tokens_of output in
  Emitter.code output
    (Reader.range tokens ~first:before ~count:0)
    ~location:tokens.(before).location text

(* [text] after token [after], as the end of the construct that ends
   there, so that it moves with that construct's tokens. *)
let close output ~after text =
  let location = (tokens_of output).(after).location in
  Emitter.closing output ~after ~location text

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
let alias output ~location (declaration : Tree.type_declaration) name
    (type_name : Tree.type_name) =
  let tokens = tokens_of output in
  let before_type = grammar_token_before tokens type_name.span.first in
  let name_before =
    match type_name.node.abstract with
    | Some abstract -> name_position abstract
    | None -> type_name.span.last + 1
  in
  replace output ~location "typedef"
    (grammar_tokens tokens declaration.span.first before_type)
  @ [ insert output ~before:name_before name ]

(* For a variant or a record alias [declaration]: the grammar tokens
   that its forward declaration replaces, and the first token after
   them, where {!Tree.after_forward_declaration} anchors. *)
let forward_declaration tokens (declaration : Tree.type_declaration) =
  let forward_end = Option.get (Tree.forward_declaration_end declaration) in
  (grammar_tokens tokens declaration.span.first (forward_end - 1), forward_end)

(* A specifier without a tag of its own takes [name], before its body. *)
let record_alias output ~location ~name (declaration : Tree.type_declaration)
    (specifier : Tree.record_specifier Tree.spanned) =
  let tokens = tokens_of output in
  let { Tree.kind; tag; members; _ } = specifier.node in
  let replace_head ~tag =
    replace output ~location
      (record_declarations kind ~tag name)
      (fst (forward_declaration tokens declaration))
  in
  let insert_tag (body : _ Tree.spanned) =
    insert output ~before:body.span.first name
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
let variant_head output ~location (variant : Spelling.c_name) ~has_union
    constructors =
  let name = (variant :> string) in
  let enumerator (constructor : Tree.constructor) =
    Tree.enumerator_name ~variant constructor.node.name.node
  in
  let tag_enum = "enum " ^ Tree.enum_tag_name variant in
  let union = if has_union then " union {" else "" in
  Printf.sprintf "%s { %s }; struct %s { %s %s;%s" tag_enum
    (Emitter.joined output location ~separator:", " enumerator constructors)
    name tag_enum Tree.tag_member union

let variant_tail ~has_union =
  if has_union then Printf.sprintf "} %s; };" Tree.union_member else "};"

(* The tokens at [indexes], the first of which is [first], replaced by
   [text] at the location of [first]. *)
let replace_at output ~first text indexes =
  let tokens = tokens_of output in
  replace output ~location:tokens.(first).location text (first :: indexes)

(* A constructor with fields becomes the struct of them that the union
   holds, named after it; [| C (] opens it, the [,] after each field
   ends that field, and the [)] closes the struct. The [,] or [)] after
   a void field ends no field, so it becomes nothing or only the close.
   A constructor without fields becomes nothing (rule 3), and so do its
   parentheses and commas where every field is void. *)
let constructor_edits output ~void_fields (constructor : Tree.constructor) =
  let tokens = tokens_of output in
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
    replace_at output ~first:after (ends ^ closes) []
  in
  match fields with
  | [] -> replace_at output ~first:bar "" [ name.span.first ]
  | _ :: _ ->
      let open_paren = grammar_token_after tokens name.span.first in
      let opens = if has_fields then "struct {" else "" in
      replace_at output ~first:bar opens [ name.span.first; open_paren ]
      @ List.concat_map field_end fields

(* [type N = ... ;]: the forward declaration replaces [type], the head
   [N =] and [private] where it follows, and the tail the [;]. *)
let variant output ~location ~lowered ~void_fields
    (declaration : Tree.type_declaration) constructors =
  let tokens = tokens_of output in
  let completes = declaration.node.declared.earlier <> None in
  let has_union = List.exists (has_fields void_fields) constructors in
  let first_bar = (List.hd constructors : Tree.constructor).span.first in
  let forward_tokens, forward_end = forward_declaration tokens declaration in
  replace output ~location (variant_forward ~completes lowered) forward_tokens
  @ replace output ~location
      (variant_head output ~location lowered ~has_union constructors)
      (grammar_tokens tokens forward_end (first_bar - 1))
  @ List.concat_map (constructor_edits output ~void_fields) constructors
  @ replace_at output ~first:declaration.span.last (variant_tail ~has_union)
      []

(* The type declaration under the name [lowered], which is its own or,
   for the definition of a generic, that of an instance (design 10.3). *)
let type_declaration output ~(lowered : Spelling.c_name)
    ~void_fields (declaration : Tree.type_declaration) =
  let tokens = tokens_of output in
  let name = (lowered :> string) in
  let location = tokens.(declaration.span.first).location in
  match declaration.node.definition with
  | Incomplete_variant ->
      replace output ~location
        (record_declarations Struct ~tag:name name)
        (grammar_tokens tokens declaration.span.first declaration.span.last)
  | Alias type_name -> alias output ~location declaration name type_name
  (* Design 10.2: the typedef of its representation. *)
  | Distinct { representation; _ } ->
      alias output ~location declaration name representation
  | Record_alias record ->
      record_alias output ~location ~name declaration record
  | Variant { constructors; _ } ->
      variant output ~location ~lowered ~void_fields declaration
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

(* The tokens up to the first that a construction replaces: its own
   first, or the first of the initialiser that its braced list replaces
   with the parentheses around the constructor. *)
let construction_outer (construction : Typec_sema.Expressions.construction) =
  Option.value construction.braced ~default:construction.span

let construction output
    (construction : Typec_sema.Expressions.construction) =
  let tokens = tokens_of output in
  let { Typec_sema.Expressions.span; variant; constructor; callee; braced; _ } =
    construction
  in
  let outer = construction_outer construction in
  let location = tokens.(span.first).location in
  let variant = Typec_sema.Encoding.variant_name variant in
  let braces = Option.is_some braced in
  let opening = if braces then "{ " else literal_opening variant in
  let closing = if braces then "}" else literal_closing in
  let tag = tag_designation ~variant constructor in
  match callee with
  | None ->
      replace output ~location
        (opening ^ tag ^ " " ^ closing)
        (grammar_tokens tokens outer.first outer.last)
  | Some callee ->
      let left_paren = grammar_token_after tokens callee.last in
      replace output ~location
        (opening ^ tag ^ fields_opening constructor)
        (grammar_tokens tokens outer.first left_paren)
      @ replace output
          ~location:tokens.(span.last).location
          (fields_closing ^ closing)
          (grammar_tokens tokens span.last outer.last)

(* The tokens that the head of a construction replaces: the callee and
   its [(], or the whole construction without arguments, from the first
   of the parentheses that its braced list replaces. A qualifying
   application in them goes with them. *)
let construction_head (tokens : Token.t array)
    (construction : Typec_sema.Expressions.construction) : Tree.span =
  let outer = construction_outer construction in
  match construction.callee with
  | None -> outer
  | Some callee ->
      { first = outer.first; last = grammar_token_after tokens callee.last }

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

(* Design 13.5: the pointer local numbered [local] of a nested match,
   where 0 is the scrutinee's. *)
let local_pointer local =
  match local with
  | 0 -> scrutinee_pointer
  | _ -> Printf.sprintf "__tc_p%d" local

(* The member of a variant's union that holds [field], as [u.Num.value]
   (design 10.1). *)
let member_text (field : Typec_sema.Expressions.pattern_field) =
  Printf.sprintf "%s.%s.%s" Tree.union_member
    (field.constructor :> string)
    field.field

(* The field that [reach] reaches, as [__tc_p1->u.Add.l] or
   [__tc_match->u.Err.error.u.Wrapped.inner]: a pointer local and the
   fields in place below it. *)
let field_text ({ base; path; field } : Typec_sema.Expressions.reach) =
  local_pointer base ^ "->"
  ^ String.concat "." (List.map member_text (path @ [ field ]))

(* The type of a binding is spelt [__typeof__] its field (design 2.4),
   because no name of the field's type that C11 can spell is sure to be
   visible, and not hidden, at the match. *)
let binding_declaration (binding : Typec_sema.Expressions.binding) =
  let field = field_text binding.field in
  Printf.sprintf " const __typeof__(%s) %s = %s;" field binding.name field

let binding_declarations output location bindings =
  Emitter.joined output location ~separator:"" binding_declaration bindings

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
let arm_block output location
    (bindings : Typec_sema.Expressions.binding list) =
  match bindings with
  | [] -> ("{", " " ^ trap ^ " }")
  | _ ->
      ( "{" ^ binding_declarations output location bindings ^ " {",
        " } " ^ trap ^ " }" )

(* The labels of an arm become the [case] labels that [cases] gives and
   open its block; a trap closes the block after its last item. *)
let matched_arm output ~cases (arm : Typec_sema.Expressions.matched_arm) =
  let tokens = tokens_of output in
  let location = tokens.(arm.labels.first).location in
  let opening, closing = arm_block output location arm.bindings in
  let cases = cases location arm in
  replace output ~location
    (cases ^ " " ^ opening)
    (grammar_tokens tokens arm.labels.first arm.labels.last)
  @ [ close output ~after:arm.arm.last closing ]

(* In a match whose selection tree has one node, the [case] of each
   constructor that an arm takes. *)
let constructor_cases output ~variant location
    (arm : Typec_sema.Expressions.matched_arm) =
  Emitter.joined output location ~separator:" " (case_label ~variant)
    arm.cases

(* Design 13.5: a selection tree of more than one node sets the local
   [__tc_arm] to the number of the arm that it selects, and a [switch] on
   the local holds the arms, each written once. *)
let arm_local = "__tc_arm"

(* A pointer local of a nested match, declared before the tree, of the
   type of the variant that it points to (design 13.5). The node that
   reads the tag of its position points it at the object there, which
   every path to a use passes (4.7 rule 6); the null pointer it starts
   as only spares a backend that cannot see this a warning of a value
   used uninitialized. *)
let local_declaration
    ({ local; local_variant } : Typec_sema.Expressions.pointer_local) =
  let variant = Typec_sema.Encoding.variant_name local_variant in
  Printf.sprintf "const struct %s *%s = 0;" (variant :> string)
    (local_pointer local)

(* The statement that points the local of a position under a [*] at the
   object there, before its tag is read. *)
let point_local add (at : Typec_sema.Expressions.read_at) =
  match at with
  | Position { position_object = Pointed_by { local; pointer }; _ } ->
      add
        (Printf.sprintf "%s = %s;" (local_pointer local) (field_text pointer))
  | Scrutinee _ | Position { position_object = In_place _; _ } -> ()

(* The variant whose tag a node reads, and the tag. *)
let read_tag (at : Typec_sema.Expressions.read_at) =
  match at with
  | Scrutinee variant -> (variant, scrutinee_pointer ^ "->" ^ Tree.tag_member)
  | Position { variant; position_object = In_place reach } ->
      (variant, field_text reach ^ "." ^ Tree.tag_member)
  | Position { variant; position_object = Pointed_by { local; _ } } ->
      (variant, local_pointer local ^ "->" ^ Tree.tag_member)

(* The statements of [tree], each added through [add]: a node under a
   [*] points the local of its position at the object there, then each
   node switches on its tag. *)
let rec write_selection add (tree : Typec_sema.Expressions.selection_tree) =
  match tree with
  | Arm arm -> add (Printf.sprintf "%s = %d;" arm_local arm)
  | Read { at; branches } ->
      point_local add at;
      let variant, tag = read_tag at in
      write_switch add ~variant ~tag branches

and write_switch add ~variant ~tag branches =
  let variant = Typec_sema.Encoding.variant_name variant in
  let write_branch (constructors, subtree) =
    List.iter (fun constructor -> add (case_label ~variant constructor))
      constructors;
    write_selection add subtree;
    add "break;"
  in
  add (Printf.sprintf "switch (%s) {" tag);
  List.iter write_branch branches;
  add invalid_tag;
  add "}"

let arm_case _location (arm : Typec_sema.Expressions.matched_arm) =
  Printf.sprintf "case %d:" arm.number

(* The text before the arms of a nested match: the local of the arm and
   the pointer locals, the tree, and the [switch] on the arm. *)
let nested_selection output location
    ({ locals; tree } : Typec_sema.Expressions.nested) =
  Emitter.assembled output location ~separator:" " (fun add ->
      add (Printf.sprintf "unsigned %s;" arm_local);
      List.iter (fun local -> add (local_declaration local)) locals;
      write_selection add tree;
      add (Printf.sprintf "switch (%s) {" arm_local))

(* The [switch] that holds the arms, and the [case] labels of an arm. *)
let arms_switch output location ~variant
    (arms : Typec_sema.Expressions.arms) =
  match arms.nested with
  | None ->
      ( Printf.sprintf "switch (%s->%s) {" scrutinee_pointer Tree.tag_member,
        constructor_cases output ~variant )
  | Some nested -> (nested_selection output location nested, arm_case)

let match_statement output matching (arms : Typec_sema.Expressions.arms) =
  let tokens = tokens_of output in
  let { Typec_sema.Expressions.statement; scrutinee; variant; _ } =
    matching
  in
  let variant = Typec_sema.Encoding.variant_name variant in
  let match_token = statement.first in
  let open_paren = grammar_token_after tokens match_token in
  let close_paren = grammar_token_after tokens scrutinee.last in
  let open_brace = grammar_token_after tokens close_paren in
  let opening, held = scrutinee_holder matching in
  let location = tokens.(close_paren).location in
  let switch, cases = arms_switch output location ~variant arms in
  replace output ~location:tokens.(match_token).location opening
    [ match_token; open_paren ]
  @ replace output ~location (held ^ switch) [ close_paren; open_brace ]
  @ List.concat_map (matched_arm output ~cases) arms.matched
  @ replace output
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

let tag_check output location ~variant constructors =
  Printf.sprintf "switch (%s) { %s break; %s } " tag_local
    (Emitter.joined output location ~separator:" " (case_label ~variant)
       constructors)
    invalid_tag

(* The false branch of a test of [form] after the statement that ends at
   [controlled_last]: the end of the block around that statement, the
   [check] of the tag, then the [else] statement of an [if], or the end
   of the loop of a [while]. *)
let false_branch output form ~controlled_last ~check =
  let tokens = tokens_of output in
  let after_controlled text =
    close output ~after:controlled_last (" }" ^ text)
  in
  match (form : Typec_sema.Expressions.test_form) with
  | If_test { otherwise = None } ->
      [ after_controlled (" else { " ^ check ^ "} }") ]
  | If_test { otherwise = Some otherwise } ->
      let else_token = grammar_token_before tokens otherwise.first in
      after_controlled ""
      :: replace output ~location:tokens.(else_token).location
          ("else { " ^ check)
          [ else_token ]
      @ [ close output ~after:otherwise.last " } }" ]
  | While_test -> [ after_controlled (" else { " ^ check ^ "break; } }") ]

let single_pattern_test output matching
    (test : Typec_sema.Expressions.test) =
  let tokens = tokens_of output in
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
  let location = tokens.(statement.first).location in
  let check = tag_check output location ~variant test.constructors in
  let held_location = tokens.(close_paren).location in
  replace output ~location (loop ^ opening)
    (grammar_tokens tokens statement.first equals)
  @ replace output ~location:held_location
      (held ^ tag_declaration ^ selected ^ "{"
      ^ binding_declarations output held_location test.bindings)
      [ close_paren ]
  @ false_branch output test.form ~controlled_last:test.controlled.last
      ~check

let matching output
    (matching : Typec_sema.Expressions.matching) =
  match matching.selects with
  | Arms arms -> match_statement output matching arms
  | Test test -> single_pattern_test output matching test

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
   a pragma line on a line of its own, and the text of each edit at the
   edit's. The moved text of an edit inside, such as the copies that a
   return in the operand of a try runs, moves with it. No [#pragma
   typec] line moves: one of C text is ignored, and Type-C text holds
   one only outside every function (design 13.5). *)
let moved_text output ordered ~first ~last =
  let tokens = tokens_of output in
  let written (edit : Emitter.edit) =
    match edit.text with
    | Emitter.Code { code = ""; _ } -> []
    | Emitter.Code { location; code } ->
        [ Emitter.Piece (Emitter.generated output location code) ]
    | Emitter.Bracketed _ -> invalid_arg "Lowering.moved_text: a bracket"
    | Emitter.Moved pieces -> Emitter.copied output pieces
  in
  let token index =
    match (tokens.(index).kind, Emitter.moved_token output index) with
    | Token.Typec_pragma, _ -> []
    | _, Some piece -> [ piece ]
    | _, None -> invalid_arg "Lowering.moved_text: an unmovable token"
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
    | _ -> from (index + 1) edits (token index :: pieces)
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

let steered_controlling output (answered : Typec_sema.Expressions.answered) =
  let tokens = tokens_of output in
  match answered.answer with
  | Compatible _ -> []
  | Selected { controlling; associations; result } ->
      let selected = steering_type (selected_number associations result) in
      [ insert output ~before:controlling.span.first "((void)(";
        insert output
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

let dropped_edits output { span; text } =
  let tokens = tokens_of output in
  replace output ~location:tokens.(span.first).location text
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
let try_piece output location text =
  Emitter.Piece (Emitter.generated output location text)

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
let error_path output ~location ~variant
    (site : Typec_sema.Expressions.try_site)
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
  [ try_piece output location test; try_piece output location trap_unless_err ]
  @ cleanups
  @ [ try_piece output location return ]

(* The text in front of the holder: the null statement of its labels,
   the temporary initialised with the operand, which moves with the
   edits inside it, and the error path, which runs [cleanups]. *)
let front output ordered ~location ~cleanups
    (site : Typec_sema.Expressions.try_site) =
  let variant =
    Typec_sema.Encoding.variant_name (Applied site.operand_instance)
  in
  let null_statement =
    match site.holder.labels with
    | Some _ -> [ try_piece output location ";" ]
    | None -> []
  in
  let declaration =
    Printf.sprintf "const struct %s %s =" (variant :> string)
      (temporary_name site.temporary)
  in
  let operand =
    moved_text output ordered ~first:site.operand.first
      ~last:site.operand.last
  in
  null_statement
  @ [ try_piece output location declaration ]
  @ operand
  @ [ try_piece output location ";" ]
  @ error_path output ~location ~variant site ~cleanups

(* The tokens that the try's value replaces: the try, or for [try e;]
   the whole statement, so that no read of the Ok field is left as a
   statement whose value goes unused (-Wunused-value). *)
let replaced_span (site : Typec_sema.Expressions.try_site) =
  match site.form with
  | Whole_statement -> site.holder.statement
  | Assigned | Initialiser -> site.try_span

(* What replaces [replaced_span]: the read of the Ok field, which an
   assignment or an initialiser takes only where T is not void, made a
   slice of the instance it converts to as [tested_conversion] does; the
   read has no side effect, so it needs no temporary. *)
let try_value (site : Typec_sema.Expressions.try_site) =
  let read field =
    field_read ~temporary:(temporary_name site.temporary) ok_constructor
      field
  in
  match (site.form, site.ok_field, site.converted_to) with
  | Whole_statement, _, _ -> ""
  | (Assigned | Initialiser), Some field, None -> read field
  | (Assigned | Initialiser), Some field, Some converted_to ->
      let read = read field in
      Printf.sprintf "(struct %s){ %s.data, %s.len }" converted_to read read
  | (Assigned | Initialiser), None, _ ->
      invalid_arg "Lowering: the void value of a try that is no statement"

(* The edits of a try: those in front of its holder and in place of the
   try, and those after the holder, which close the block of a
   substatement. *)
type try_lowering = {
  opening : Emitter.edit list;
  closing : Emitter.edit list;
}

let lower_try output ordered ~cleanups_of
    (site : Typec_sema.Expressions.try_site) =
  let tokens = tokens_of output in
  let { Typec_sema.Expressions.statement; labels; standing } = site.holder in
  let location = tokens.(site.try_span.first).location in
  let in_front =
    Emitter.moved output
      (Reader.range tokens ~first:statement.first ~count:0)
      (front output ordered ~location ~cleanups:(cleanups_of site) site)
  in
  let replaced = replaced_span site in
  let value =
    replace output ~location:tokens.(replaced.first).location
      (try_value site)
      (grammar_tokens tokens replaced.first replaced.last)
  in
  match standing with
  | Block_item -> { opening = in_front :: value; closing = [] }
  | Substatement ->
      let first = (Option.value labels ~default:statement).first in
      { opening = insert output ~before:first "{" :: in_front :: value;
        closing = [ close output ~after:statement.last "}" ] }

(* The edits of a text with its tries lowered. The edits inside the
   tokens that a try replaces go with its operand, which moves, and the
   try's own replace them. Where another construct inserts at the token
   where a try's holder begins or ends, the two nest: one that ends
   where the holder begins closes before the try's opening, and one
   around the holder closes after the try's block. So the closings of
   the tries go first and their openings last. [cleanups_of] gives the
   cleanups of the error path of a try. *)
let with_tries output edits tries ~cleanups_of =
  let replaced = cover (List.map replaced_span tries) in
  let ordered = order_edits edits in
  let lowered = List.map (lower_try output ordered ~cleanups_of) tries in
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

(* Each place of [sites] with the sites whose scopes it ends or leaves,
   the latest first, the order in which their copies run. *)
let places (sites : Reachability.defer_site list) =
  let pairs =
    List.concat_map
      (fun (site : Reachability.defer_site) ->
        List.map (fun place -> (place, site)) site.places)
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

let defer_piece output location text =
  Emitter.Piece (Emitter.generated output location text)

(* The copy of the statement of [site], [{ S }], from the edits [base]
   of the text. *)
let copy output base (site : Reachability.defer_site) =
  let tokens = tokens_of output in
  let deferred =
    Tree.deferred_text ~keyword:site.keyword ~statement:site.deferred
  in
  let location = tokens.(site.deferred.first).location in
  let moved =
    moved_text output base ~first:deferred.first ~last:deferred.last
  in
  (defer_piece output location "{" :: moved)
  @ [ defer_piece output location "}" ]

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
   copies of [leaving]; a trap stands once at the end of a block however
   many defers it holds. *)
let place_edits output base returns (place, leaving) =
  let tokens = tokens_of output in
  (* A trap and the error path of a try write no copies here. *)
  let copies () = List.concat_map (copy output base) leaving in
  let at index = tokens.(index).location in
  let insertion index = Reader.range tokens ~first:index ~count:0 in
  let token index = Reader.range tokens ~first:index ~count:1 in
  let piece index text = defer_piece output (at index) text in
  match (place : Reachability.place) with
  | Block_end closing ->
      [ Emitter.moved output (insertion closing) (copies ()) ]
  | Trap closing -> [ insert output ~before:closing trap ]
  | Left_by (Jump jump) ->
      [ Emitter.moved output (insertion jump.first)
          (piece jump.first "{" :: copies ());
        Emitter.code output (token jump.last) ~location:(at jump.last) "; }" ]
  | Left_by (Value_return { statement; operand = _ }) ->
      let form = return_form returns in
      [ Emitter.code output (token statement.first)
          ~location:(at statement.first) form.value_opening;
        Emitter.moved output (token statement.last)
          ((piece statement.last form.value_closing :: copies ())
          @ [ piece statement.last form.returned ]) ]
  | Left_by (Error_path _) -> []

(* The name of a parameter that the call of [__tc_ret] passes an lvalue
   of. The front end refuses a parameter without a name in a function
   that gets [__tc_ret] (Return_form), but that of [(void)]. *)
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
   parameter without a declarator that the front end lets through, and
   the named ones of a variadic function. *)
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

(* Design 13.5: [typedef __typeof__(call of f) __tc_ret;], which the
   block around the body declares ({!body_blocks}). *)
let return_typedef output (defers : Typec_sema.Expressions.function_defers) =
  let location = (tokens_of output).(defers.body.first).location in
  let lvalue name = Printf.sprintf "*(__typeof__(%s) *)0" name in
  let arguments =
    Emitter.joined output location ~separator:", " lvalue
      (parameter_names (Tree.defined_function defers.declarator).parameters)
  in
  Printf.sprintf "typedef __typeof__(((__typeof__(%s) *)0)(%s)) %s;"
    defers.function_name arguments return_type_name

let is_value_return : Reachability.place -> bool = function
  | Left_by (Value_return _) -> true
  | Block_end _ | Trap _ | Left_by (Jump _ | Error_path _) -> false

(* The edits of a function with its defers lowered: the copies at each
   exit, the traps, and [__tc_ret] where a [return e;] that runs copies
   needs it. A defer and an exit in text that lowering drops, such as
   a statement expression in an answered type name, go with that text:
   it never runs. *)
let kept_token dropped index = not (covers dropped ~first:index ~last:index)

let kept_sites dropped (sites : Reachability.defer_site list) =
  List.filter
    (fun (site : Reachability.defer_site) ->
      kept_token dropped site.keyword.first)
    sites

let function_edits output base ~dropped
    (defers : Typec_sema.Expressions.function_defers) =
  let tokens = tokens_of output in
  let kept_places =
    List.filter
      (fun (place, _) ->
        kept_token dropped (Reachability.place_token place))
      (places defers.sites)
  in
  let kept_sites = kept_sites dropped defers.sites in
  let declarations =
    if
      defers.returns = Returns_value
      && List.exists (fun (place, _) -> is_value_return place) kept_places
    then [ (defers.body, lazy (return_typedef output defers)) ]
    else []
  in
  (* Every token of [defer S] goes, its pragma lines too, which move to
     the copies; a [#pragma typec] line, which C text ignores, goes with
     them. *)
  let removal site =
    let span = defer_span site in
    List.init (span.last - span.first + 1) (fun offset -> span.first + offset)
    |> replace output ~location:tokens.(span.first).location ""
  in
  ( List.concat_map (place_edits output base defers.returns) kept_places
    @ List.concat_map removal kept_sites,
    declarations )

(* The cleanups of the error path of each try (13.5, the [try] row):
   the copies of the scopes of [functions] that it leaves, the latest
   first, from the edits [base] of the text. The sites are indexed by
   the span of the try once, so that each try finds its own in constant
   time. *)
let error_path_cleanups output base
    (functions : Typec_sema.Expressions.function_defers list) =
  let leaving = Hashtbl.create 16 in
  let index ((place : Reachability.place), sites) =
    match place with
    | Left_by (Error_path try_span) -> Hashtbl.replace leaving try_span sites
    | Block_end _ | Trap _ | Left_by (Jump _ | Value_return _) -> ()
  in
  List.iter
    (fun (defers : Typec_sema.Expressions.function_defers) ->
      List.iter index (places defers.sites))
    functions;
  fun (site : Typec_sema.Expressions.try_site) ->
    match Hashtbl.find_opt leaving site.try_span with
    | Some sites -> List.concat_map (copy output base) sites
    | None -> []

(* The edits of a text with the defers of its functions lowered, and
   the declarations of [__tc_ret] by body. The statements go, and the
   edits that their tokens own go with them, to their copies, which
   [base], the ordered [edits], gives. [dropped] is the text that
   lowering drops, whose own edits delete a defer in it. *)
let with_defers output edits ~base ~dropped
    (functions : Typec_sema.Expressions.function_defers list) =
  let sites =
    List.concat_map
      (fun (defers : Typec_sema.Expressions.function_defers) ->
        kept_sites dropped defers.sites)
      functions
  in
  let removed = cover (List.map defer_span sites) in
  let lowered, declarations =
    List.split (List.map (function_edits output base ~dropped) functions)
  in
  ( List.filter (fun edit -> not (goes_with removed edit)) edits
    @ List.concat lowered,
    List.concat declarations )

(* Slices (design 13.5, "The check of a slice") *)

module Expressions = Typec_sema.Expressions

(* The trap of design 10.5 as an expression of type void. *)
let slice_trap = "__builtin_trap()"

(* The order that numbers the temporaries of a function's tests: by the
   first token of each, the outer one first where two begin at one
   token. Edits that insert before one token apply in the same order. A
   conversion and the index or [slice_sub] that it converts span the same
   tokens, and the conversion is the outer one. *)
let source_order ((a : Expressions.slice_check), _)
    ((b : Expressions.slice_check), _) =
  let inner (check : Expressions.slice_check) =
    match check.check with
    | Conversion _ -> 0
    | Index _ | Sub _ -> 1
  in
  compare
    (a.whole.first, -a.whole.last, inner a)
    (b.whole.first, -b.whole.last, inner b)

(* The grammar tokens between two operands, or before the first one,
   which an edit replaces: the opening bracket or parenthesis and the
   commas. *)
let between tokens ~after:(left : Tree.span) (right : Tree.span) =
  grammar_tokens tokens (left.last + 1) (right.first - 1)

(* [s[i]] as the expression that holds its test, its operands written
   once where the source has them and their values assigned to the
   temporaries of test [n]. *)
let tested_index output n ~(whole : Tree.span) ~slice ~(index : Tree.span) =
  let tokens = tokens_of output in
  let location = tokens.(index.first).location in
  let s = Printf.sprintf "__tc_s%d" n and i = Printf.sprintf "__tc_i%d" n in
  insert output ~before:whole.first (Printf.sprintf "(*((void)(%s = (" s)
  :: replace output ~location
       (Printf.sprintf ")), (void)(%s = (__typeof__(%s))(" i i)
       (between tokens ~after:slice index)
  @ replace output ~location
      (Printf.sprintf
         ")), (void)(%s < %s.len ? (void)0 : %s), &%s.data[%s]))" i s
         slice_trap s i)
      [ whole.last ]

(* [slice_sub(s, lo, hi)] as the expression that holds its test and
   yields the slice, written as [tested_index] writes an index. *)
let tested_sub output n ~(whole : Tree.span) ~instance ~(slice : Tree.span)
    ~low ~high =
  let tokens = tokens_of output in
  let location = tokens.(whole.first).location in
  let s = Printf.sprintf "__tc_s%d" n in
  let lo = Printf.sprintf "__tc_lo%d" n in
  let hi = Printf.sprintf "__tc_hi%d" n in
  let assign name =
    Printf.sprintf ")), (void)(%s = (__typeof__(%s))(" name name
  in
  replace output ~location
    (Printf.sprintf "((void)(%s = (" s)
    (grammar_tokens tokens whole.first (slice.first - 1))
  @ replace output ~location (assign lo) (between tokens ~after:slice low)
  @ replace output ~location (assign hi) (between tokens ~after:low high)
  @ replace output ~location
      (Printf.sprintf
         ")), (void)(%s <= %s && %s <= %s.len ? (void)0 : %s), (struct %s){ \
          %s.data + %s, %s - %s })"
         lo hi hi s slice_trap instance s lo hi lo)
      [ whole.last ]

(* A check where C does not evaluate it: the trap, then its operands,
   with no test and no temporary. The unary plus keeps an index of type
   char from [-Wchar-subscripts]. *)
let untested output ((checked : Expressions.slice_check), _) =
  let tokens = tokens_of output in
  let whole = checked.whole in
  let location = tokens.(whole.first).location in
  match checked.check with
  | Index { slice; index } ->
      insert output ~before:whole.first "(*((void)__builtin_trap(), &("
      :: replace output ~location ").data[+("
           (between tokens ~after:slice index)
      @ replace output ~location ")]))" [ whole.last ]
  | Sub { slice; low; high } ->
      replace output ~location "((void)__builtin_trap(), (void)("
        (grammar_tokens tokens whole.first (slice.first - 1))
      @ replace output ~location "), (void)(" (between tokens ~after:slice low)
      @ replace output ~location "), (void)(" (between tokens ~after:low high)
      @ replace output ~location
          (Printf.sprintf "), (struct %s){ 0 })" checked.instance)
          [ whole.last ]
  | Conversion { converted_to } ->
      [ insert output ~before:whole.first "((void)__builtin_trap(), (void)(";
        close output ~after:whole.last
          (Printf.sprintf "), (struct %s){ 0 })" converted_to) ]

(* The conversion of section 8 rule 5 over the temporary of test [n]: the
   slice converted makes one of the instance [converted_to] from its
   members, as C converts the pointer. *)
let tested_conversion output n ~(whole : Tree.span) ~converted_to =
  let s = Printf.sprintf "__tc_s%d" n in
  [ insert output ~before:whole.first (Printf.sprintf "((void)(%s = (" s);
    close output ~after:whole.last
      (Printf.sprintf ")), (struct %s){ %s.data, %s.len })" converted_to s s) ]

(* Check [n] of a function body as its test, and the declarations of
   its temporaries, which {!body_blocks} spells only as it charges them,
   since each holds the name of an instance that the test may not. *)
let tested output n (checked : Expressions.slice_check) =
  let whole = checked.whole and instance = checked.instance in
  let size_temporary name =
    Printf.sprintf " __typeof__(__tc_s%d.len) __tc_%s%d;" n name n
  in
  (* The temporary of the slice, then one for each size named. *)
  let temporaries sizes =
    lazy
      (Printf.sprintf "struct %s __tc_s%d;" instance n
      ^ String.concat "" (List.map size_temporary sizes))
  in
  match checked.check with
  | Index { slice; index } ->
      (tested_index output n ~whole ~slice ~index, temporaries [ "i" ])
  | Sub { slice; low; high } ->
      ( tested_sub output n ~whole ~instance ~slice ~low ~high,
        temporaries [ "lo"; "hi" ] )
  | Conversion { converted_to } ->
      (tested_conversion output n ~whole ~converted_to, temporaries [])

(* The tests of one function body, in source order, each numbered, and
   the declarations of their temporaries, each with the body. *)
let function_tests output ((body : Tree.span), checks) =
  let edits, declarations = List.split (List.mapi (tested output) checks) in
  ( List.concat edits,
    List.map (fun declaration -> (body, declaration)) declarations )

(* Each body with its tested indexes, in source order. *)
let by_body indexes =
  let add grouped = function
    | indexed, Expressions.Tested { body } -> (
        match grouped with
        | (last, group) :: earlier when last = body ->
            (last, indexed :: group) :: earlier
        | _ -> (body, [ indexed ]) :: grouped)
    | _, Expressions.Untested -> grouped
  in
  List.fold_left add [] indexes
  |> List.rev_map (fun (body, group) -> (body, List.rev group))

(* The edits of the slice indexes of a text, and the declarations of
   their temporaries by body. *)
let slice_edits output indexes =
  let ordered = List.stable_sort source_order indexes in
  let untested = function
    | (_, Expressions.Untested) as check -> untested output check
    | _, Expressions.Tested _ -> []
  in
  let tested, declarations =
    List.split (List.map (function_tests output) (by_body ordered))
  in
  ( List.concat tested @ List.concat_map untested ordered,
    List.concat declarations )

(* [slice_from_array] and [slice_unchecked] (design 13.5) *)

(* [pieces] in place of the tokens at [indexes], as {!replace} puts
   text there. *)
let replace_moved output ~location pieces indexes =
  let tokens = tokens_of output in
  match indexes with
  | [] -> []
  | first :: rest ->
      let delete index =
        Emitter.code output
          (Reader.range tokens ~first:index ~count:1)
          ~location ""
      in
      Emitter.moved output (Reader.range tokens ~first ~count:1) pieces
      :: List.map delete rest

(* The length of [slice_from_array(a)]: the size of [a] over that of an
   element, which the typedef of the instance's argument names, plus a
   term of the value 0 whose array type has a negative size where an
   element has none, which the backend refuses (section 8 rule 2). *)
let array_length output ordered ~location ~element (operand : Tree.span) =
  let piece code = Emitter.Piece (Emitter.generated output location code) in
  let copy =
    moved_text output ordered ~first:operand.first ~last:operand.last
  in
  (piece "sizeof(" :: copy)
  @ [ piece
        (Printf.sprintf
           ") / sizeof(%s) + 0 * sizeof(char[sizeof(%s) != 0 ? 1 : -1])"
           element element) ]

(* The opening of the compound literal of a slice, or of its braced
   list, and the tokens up to its operands that it replaces: the name
   and [(], and the parentheses around them where the list replaces
   those too. *)
let slice_opening (making : Expressions.slice_making) =
  match making.braced with
  | Some outer -> (outer, "{ ")
  | None ->
      let name = Typec_sema.Encoding.instance_name making.instance in
      (making.span, Printf.sprintf "(struct %s){ " name)

(* A string literal that denotes a [str] (section 8 rule 6): its
   characters and their count, the size of the literal without its
   terminating NUL. The count writes the literal again, its pieces
   without the pragma lines between them, which would be repeated; the
   pieces are moved text, as generated code holds no quote. *)
let string_making output ~outer ~opening ~location (literal : Tree.span) =
  let tokens = tokens_of output in
  let moved index = Option.to_list (Emitter.moved_token output index) in
  let piece code = Emitter.Piece (Emitter.generated output location code) in
  let copy =
    List.concat_map moved (grammar_tokens tokens literal.first literal.last)
  in
  let length = (piece ", sizeof(" :: copy) @ [ piece ") - 1 }" ] in
  let before = grammar_tokens tokens outer.Tree.first (literal.first - 1) in
  let after = grammar_tokens tokens (literal.last + 1) outer.last in
  let opening_edits =
    match before with
    | [] -> [ insert output ~before:literal.first opening ]
    | _ -> replace output ~location opening before
  in
  (* Without parentheses to replace, the count follows the last piece,
     which it replaces with itself. *)
  let closing_edits =
    match after with
    | [] ->
        replace_moved output ~location (moved literal.last @ length)
          [ literal.last ]
    | _ -> replace_moved output ~location length after
  in
  opening_edits @ closing_edits

(* The edits of one slice made from an array or a pointer, whose name
   and [(] become the opening of its compound literal or braced list,
   and its [)], with the parentheses around a braced list, the closing.
   The operands keep their tokens, each in parentheses. *)
let operator_making output ordered ~outer ~opening ~location
    (making : Expressions.slice_making) first_operand =
  let tokens = tokens_of output and span = making.span in
  let opening_edits =
    replace output ~location (opening ^ "(")
      (grammar_tokens tokens outer.Tree.first (first_operand.Tree.first - 1))
  in
  let closing_tokens = grammar_tokens tokens span.last outer.last in
  let piece code = Emitter.Piece (Emitter.generated output location code) in
  match (making.making, making.instance.arguments) with
  | From_array { operand }, [ argument ] ->
      let element = Typec_sema.Encoding.argument_name argument in
      let length = array_length output ordered ~location ~element operand in
      opening_edits
      @ replace_moved output ~location
          ((piece "), " :: length) @ [ piece " }" ])
          closing_tokens
  | Unchecked { pointer; count }, [ _ ] ->
      opening_edits
      @ replace output ~location "), (" (between tokens ~after:pointer count)
      @ replace output ~location ") }" closing_tokens
  | (From_array _ | Unchecked _ | From_string _), _ ->
      invalid_arg "Lowering.operator_making: no operator over a slice"

(* The edits of one slice that [making] makes. *)
let slice_making output ordered (making : Expressions.slice_making) =
  let location = (tokens_of output).(making.span.first).location in
  let outer, opening = slice_opening making in
  match making.making with
  | From_string { literal } ->
      string_making output ~outer ~opening ~location literal
  | From_array { operand } ->
      operator_making output ordered ~outer ~opening ~location making operand
  | Unchecked { pointer; _ } ->
      operator_making output ordered ~outer ~opening ~location making pointer

(* [edits] with those of the slices that [makings] make, each innermost
   first, so that the copy of an operand holds the edits of those inside
   it; an edit that [kept] refuses goes, as from [undeferred]. *)
let with_slice_makings output edits ~kept makings =
  let width (making : Expressions.slice_making) =
    making.span.last - making.span.first
  in
  let innermost_first a b = compare (width a) (width b) in
  let add edits making =
    edits @ List.filter kept (slice_making output (order_edits edits) making)
  in
  List.fold_left add edits (List.stable_sort innermost_first makings)

(* Design 13.5: the block around a function body whose first
   declarations are those of the body's [__tc_ret] and the temporaries of
   its slices, in that order, before the body as written, so that no
   statement precedes them and no jump crosses them. This is the one
   place that writes the block; [declarations] pairs bodies with their
   declarations, in the order that the block declares them, each spelled
   only as {!Emitter.joined} holds it to the limit. *)
let body_blocks output (declarations : (Tree.span * string Lazy.t) list) =
  let tokens = tokens_of output in
  let bodies = List.sort_uniq compare (List.map fst declarations) in
  let block (body : Tree.span) =
    let own =
      List.filter_map
        (fun (owner, text) -> if owner = body then Some text else None)
        declarations
    in
    let location = tokens.(body.first).location in
    [ insert output ~before:body.first
        ("{ " ^ Emitter.joined output location ~separator:" " Lazy.force own);
      Emitter.code output
        (Reader.range tokens ~first:body.last ~count:1)
        ~location:tokens.(body.last).location "} }" ]
  in
  List.concat_map block bodies

(* Design 13.5: the list of a zero initialiser of 7.1 rule 3 is [{}],
   whichever of [{0}] and [{}] the text writes: what stands between its
   braces goes, and the braces stay with the edits that they own, as the
   end of a conversion that a compound literal's [}] owns. *)
let zero_list output (zero : Expressions.zero_initialiser) =
  let tokens = tokens_of output in
  let { Tree.first; last } = zero.list in
  let inside index = first < index && index < last in
  replace output ~location:tokens.(first).location ""
    (List.filter inside (grammar_tokens tokens first last))

(* The first tokens of the holders of [zero_initialisers], one each. *)
let zero_holders (zero_initialisers : Expressions.zero_initialiser list) =
  List.sort_uniq Int.compare
    (List.map
       (fun (zero : Expressions.zero_initialiser) -> zero.holder)
       zero_initialisers)

(* The [__extension__] that design 13.5 writes before each of [holders]
   begins the edit that replaces the holder's first token, so that each
   insertion before that token, the prelude of a try among them, goes
   ahead of it ({!Emitter.in_order}) and it stands next to what it
   holds. Gives [dropped] with the prefix on each range that begins at a
   holder, and an edit of its own for each other holder, which another
   edit that replaces the token would overlap, and emission refuses an
   overlap. *)
let with_extensions output holders dropped =
  let tokens = tokens_of output in
  let extension = "__extension__ " in
  let begins_at holder range = range.span.first = holder in
  let extended range =
    if List.exists (fun holder -> begins_at holder range) holders then
      { range with text = extension ^ range.text }
    else range
  in
  let own holder =
    if List.exists (begins_at holder) dropped then []
    else
      let spelling = Reader.spelling (Emitter.unit output) tokens.(holder) in
      replace output ~location:tokens.(holder).location (extension ^ spelling)
        [ holder ]
  in
  (List.map extended dropped, List.concat_map own holders)

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
   of one move with it. [zero_initialisers] are those of design 7.1
   rule 3 that the text holds, each [{}] with one [__extension__] before
   each holder ({!with_extensions}). *)
let text_edits output ~declarations ~void_field_spans ~replaced
    ~zero_initialisers typed =
  let holders = zero_holders zero_initialisers in
  let tokens = tokens_of output in
  let answered = Typec_sema.Expressions.answered typed in
  let constructions = Typec_sema.Expressions.constructions typed in
  let heads = cover (List.map (construction_head tokens) constructions) in
  let in_head { span; _ } = covers heads ~first:span.first ~last:span.last in
  (* An insertion before the first token of a void field would survive
     its removal ({!goes_with}); none stands there, since a field begins
     with a specifier, before which no lowering inserts. *)
  let removed span = { span; text = "" } in
  let dropped, extensions =
    with_extensions output holders
      (outermost
         (List.concat_map dropped_ranges answered
         @ List.map removed void_field_spans
         @ List.filter (fun range -> not (in_head range)) replaced))
  in
  let dropped_spans = cover (List.map (fun range -> range.span) dropped) in
  let kept edit = not (goes_with dropped_spans edit) in
  let void_fields = Spans.of_list void_field_spans in
  let declaration (lowered, declaration) =
    type_declaration output ~lowered ~void_fields declaration
  in
  (* A check in a dropped range declares no temporaries, which nothing
     would use. *)
  let kept_check ((check : Expressions.slice_check), _) =
    not (covers dropped_spans ~first:check.whole.first ~last:check.whole.last)
  in
  let slice_tests, slice_temporaries =
    slice_edits output
      (List.filter kept_check (Expressions.slice_checks typed))
  in
  let lowered =
    List.concat_map declaration declarations
    @ List.concat_map (construction output) constructions
    @ List.concat_map (matching output)
        (List.rev (Typec_sema.Expressions.matchings typed))
    @ List.concat_map (steered_controlling output) answered
    @ slice_tests
    @ List.concat_map (zero_list output) zero_initialisers
    @ extensions
  in
  let undeferred =
    with_slice_makings output
      (List.concat_map (dropped_edits output) dropped
      @ List.filter kept lowered)
      ~kept (Expressions.slice_makings typed)
  in
  let functions = Typec_sema.Expressions.defers typed in
  (* The copies of a deferred statement, at its exits and on the error
     path of a try, are its text with the edits that its tokens own,
     which lowering the defers moves out of the text. *)
  let base = order_edits undeferred in
  (* The defers go before the tries, so that a jump in the operand of a
     try runs its copies wherever the operand moves. *)
  let deferred, return_typedefs =
    with_defers output undeferred ~base ~dropped:dropped_spans functions
  in
  let blocks = body_blocks output (return_typedefs @ slice_temporaries) in
  with_tries output (deferred @ blocks)
    (Typec_sema.Expressions.tries typed)
    ~cleanups_of:(error_path_cleanups output base functions)

let named (span, name) = { span; text = name }

(* Instances (design 10.3). Each text of an instance stands at the
   anchor that its placement names, in a packing bracket; the texts at
   one anchor share one bracket, in the order of the placements. *)

(* The tokens of a generic's definition from [first] to [last] under
   [edits]. They stand in a bracket, which holds no pragma line: the
   front end refuses a generic whose definition holds one (design 10.3,
   P25). *)
let generic_text output edits ~first ~last =
  let bracketed : Emitter.moved_piece -> Emitter.piece = function
    | Piece piece -> piece
    | Pragma_line _ -> invalid_arg "Lowering: a pragma line in a generic"
  in
  moved_text output (order_edits edits) ~first ~last |> List.map bracketed

(* The generic type's definition under the instance's name, with each
   type parameter and application written as the name that the reading
   found for it, from token [first] to its end. *)
let instance_definition output instance ~first
    (reading : Typec_sema.Declarations.instance_text) =
  match reading.generic with
  | Type_generic generic ->
      let lowered = Typec_sema.Encoding.variant_name (Applied instance) in
      let edits =
        text_edits output
          ~declarations:[ (lowered, generic) ]
          ~void_field_spans:reading.void_field_spans
          ~replaced:(List.map named reading.names)
          ~zero_initialisers:[] reading.typed
      in
      generic_text output edits ~first ~last:generic.span.last
  | Function_generic _ -> invalid_arg "Lowering: a function as a type"

(* Every instance is static (design 7.3 rule 1): a [static] that the
   definition holds stays (7.1 rule 6), and one is written in front of
   the first specifier of a definition without it that is no attribute,
   as C23 6.7p1 puts an attribute that begins a declaration before its
   specifiers. *)
let added_static output (definition : Tree.function_definition) =
  let { Tree.specifiers; declarator; _ } = definition.node in
  let is_static (specifier : Tree.declaration_specifier Tree.spanned) =
    specifier.node = Storage_class Static
  in
  let is_attribute (specifier : Tree.declaration_specifier Tree.spanned) =
    match specifier.node with Attributes _ -> true | _ -> false
  in
  let before =
    match List.find_opt (fun s -> not (is_attribute s)) specifiers with
    | Some first -> first.span.first
    | None -> declarator.span.first
  in
  if List.exists is_static specifiers then []
  else [ insert output ~before "static" ]

(* A function instance (design 7.3, 10.3): the generic function's
   definition, without [generic(T)], as a [static] function under the
   instance's name, from its first token to [last], after which [ending]
   follows: the prototype ends before the body. *)
let function_instance output location instance ~last ~ending
    ~zero_initialisers (reading : Typec_sema.Declarations.instance_text)
    (definition : Tree.function_definition) =
  let (Ordinary_at name_token) = definition.node.declared.id in
  let name =
    { span = { first = name_token; last = name_token };
      text = Typec_sema.Encoding.instance_name instance }
  in
  let edits =
    added_static output definition
    @ text_edits output ~declarations:[] ~void_field_spans:[]
        ~replaced:(name :: List.map named reading.names)
        ~zero_initialisers
        reading.typed
  in
  generic_text output edits ~first:definition.span.first ~last
  @ List.map (Emitter.generated output location) ending

(* What the texts of the placements are written from: the output of the
   unit and what its reading found. *)
type instance_context = {
  output : Emitter.output;
  declarations : Typec_sema.Declarations.t;
}

(* Design 10.3: each typedef after the lines that declare its tags. *)
let argument_typedefs context location typedefs =
  let lines (typedef : Typec_sema.Declarations.argument_typedef) =
    List.map (fun (tag_line : Typec_sema.Type_name.tag_line) -> tag_line.line)
      typedef.tag_lines
    @ [ typedef.line ]
  in
  List.concat_map lines typedefs
  |> List.map (Emitter.generated context.output location)

(* Those that the check of the generic function found (design 7.1 rule
   3). *)
let zero_initialisers context definition =
  Typec_sema.Declarations.zero_initialisers context.declarations definition

let reading context instance =
  match Typec_sema.Declarations.instance_text context.declarations instance with
  | Some reading -> reading
  | None -> invalid_arg "Lowering: an instance text without its reading"

let function_definition context instance =
  match reading context instance with
  | { generic = Function_generic { definition; _ }; _ } as reading -> (
      definition, reading)
  | { generic = Type_generic _; _ } ->
      invalid_arg "Lowering: a type as a function"

(* Step 1: [struct I; typedef struct I I;] for a structure, union or
   variant, whose definition follows where it is needed; the whole
   typedef of 10.2 for an alias or a distinct generic. *)
let instance_declaration context location instance
    (generic : Tree.type_declaration) =
  let name = Typec_sema.Encoding.instance_name instance in
  let forward kind =
    [ Emitter.generated context.output location
        (record_declarations kind ~tag:name name) ]
  in
  match generic.node.definition with
  | Variant _ | Incomplete_variant -> forward Struct
  | Record_alias specifier -> forward specifier.node.kind
  | Alias _ | Distinct _ ->
      let reading = reading context instance in
      instance_definition context.output instance ~first:generic.span.first
        reading

(* Step 1 of a function instance: its prototype, the head of the
   generic's definition. *)
let function_prototype context location instance =
  let definition, reading = function_definition context instance in
  let body_first =
    match definition.node.body with
    | Parsed block -> block.span.first
    | Skipped span -> span.first
  in
  function_instance context.output location instance ~last:(body_first - 1)
    ~ending:[ ";" ]
    ~zero_initialisers:(zero_initialisers context definition)
    reading definition

(* Step 2: the rest of 10.1 or 10.2, after the forward declaration, or
   the whole definition of a function instance. *)
let instance_rest context location instance =
  let reading = reading context instance in
  match reading.generic with
  | Type_generic generic -> (
      match Tree.forward_declaration_end generic with
      | Some first -> instance_definition context.output instance ~first reading
      | None -> invalid_arg "Lowering.instance_rest: a typedef instance")
  | Function_generic { definition; _ } ->
      function_instance context.output location instance
        ~last:definition.span.last ~ending:[]
        ~zero_initialisers:(zero_initialisers context definition)
        reading definition

let application_location context
    (placement : Typec_sema.Declarations.placement) =
  (tokens_of context.output).(placement.application.first).location

let placement_text context (placement : Typec_sema.Declarations.placement) =
  match placement.step with
  | Typedefs typedefs ->
      argument_typedefs context (application_location context placement)
        typedefs
  | Declared { generic } ->
      instance_declaration context
        (application_location context placement)
        placement.instance generic
  | Prototype ->
      function_prototype context (application_location context placement)
        placement.instance
  | Defined ->
      instance_rest context (application_location context placement)
        placement.instance

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

(* The texts are made in the order of the placements, so the first that
   passes the output limit is the one that the earliest application
   needs. *)
let instance_brackets context =
  let bracket (at, run) =
    let location = application_location context (List.hd run) in
    let pieces = List.concat_map (placement_text context) run in
    Emitter.bracketed context.output ~at ~location pieces
  in
  List.map bracket
    (by_anchor (Typec_sema.Declarations.placements context.declarations))

(* The declarations of generic functions, which only their instances
   write (design 7.3 rule 1). *)
let generic_functions declarations =
  let generic_function : Typec_sema.Declarations.item -> dropped option =
    function
    | Generic_function_declaration span -> Some { span; text = "" }
    | Declaration _ | Static_assertion | Function_definition _
    | Type_declaration _ | Generic_declaration ->
        None
  in
  List.filter_map generic_function (Typec_sema.Declarations.items declarations)

(* The unit's own text: each type declaration that is no generic under
   its own name, each generic's definition removed, as only its
   instances write it, and each application and use of a function
   instance replaced by the name of its instance. *)
let unit_edits output declarations =
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
  text_edits output ~declarations:own ~void_field_spans:[]
    ~replaced:
      (generics
      @ generic_functions declarations
      @ List.map named (Typec_sema.Declarations.instance_names declarations))
    ~zero_initialisers:[]
    (Typec_sema.Declarations.typed declarations)

let edits (text : Reader.t) declarations =
  Emitter.limited text (fun output ->
      let brackets = instance_brackets { output; declarations } in
      brackets @ unit_edits output declarations)
