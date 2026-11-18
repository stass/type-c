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

(* [text] in front of token [before], as part of [extent], the construct
   that it lowers, so that it moves and goes with that construct's
   tokens ({!Emitter.edit}). *)
let insert output ~before ~extent text =
  let tokens = tokens_of output in
  Emitter.extended ~extent
    (Emitter.code output
       (Reader.range tokens ~first:before ~count:0)
       ~location:tokens.(before).location text)

(* [pieces], made when first forced ({!Emitter.moved}), in front of
   token [before], as part of [extent]. *)
let insert_moved output ~before ~extent pieces =
  let tokens = tokens_of output in
  Emitter.extended ~extent
    (Emitter.moved output (Reader.range tokens ~first:before ~count:0) pieces)

(* [text] after token [after], as the end of [extent], the construct
   that it lowers. *)
let close output ~after ~extent text =
  let location = (tokens_of output).(after).location in
  Emitter.extended ~extent (Emitter.closing output ~after ~location text)

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
  @ [ insert output ~before:name_before
        ~extent:{ first = type_name.span.first; last = name_before }
        name ]

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
    insert output ~before:body.span.first ~extent:specifier.span name
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
   enumeration of the tags, numbered from 0 in order (rule 1) and ended
   by the hidden enumerator of the value INT_MAX (rule 2), and the
   structure up to its union where it has one (rule 3). *)
let variant_head output ~tag_max ~location (variant : Spelling.c_name)
    ~has_union constructors =
  let name = (variant :> string) in
  let enumerator (constructor : Tree.constructor) =
    Tree.enumerator_name ~variant constructor.node.name.node
  in
  let tag_enum = "enum " ^ Tree.enum_tag_name variant in
  let tag_max = Typec_sema.Exact_integer.to_string tag_max in
  let union = if has_union then " union {" else "" in
  Printf.sprintf "%s { %s, %s = %s }; struct %s { %s %s;%s" tag_enum
    (Emitter.joined output location ~separator:", " enumerator constructors)
    (Tree.tag_max_name variant) tag_max name tag_enum Tree.tag_member union

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
let variant output ~tag_max ~location ~lowered ~void_fields
    (declaration : Tree.type_declaration) constructors =
  let tokens = tokens_of output in
  let completes = declaration.node.declared.earlier <> None in
  let has_union = List.exists (has_fields void_fields) constructors in
  let first_bar = (List.hd constructors : Tree.constructor).span.first in
  let forward_tokens, forward_end = forward_declaration tokens declaration in
  replace output ~location (variant_forward ~completes lowered) forward_tokens
  @ replace output ~location
      (variant_head output ~tag_max ~location lowered ~has_union
         constructors)
      (grammar_tokens tokens forward_end (first_bar - 1))
  @ List.concat_map (constructor_edits output ~void_fields) constructors
  @ replace_at output ~first:declaration.span.last (variant_tail ~has_union)
      []

(* The type declaration under the name [lowered], which is its own or,
   for the definition of a generic, that of an instance (design 10.3). *)
let type_declaration output ~tag_max ~(lowered : Spelling.c_name)
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
      variant output ~tag_max ~location ~lowered ~void_fields declaration
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
   through [__tc_matchN], a pointer to it or to a copy of it, or through
   [__tc_baseN], a pointer to the object that holds it as a member, and
   a [switch] on its tag. Each arm is a block after the [case] of every
   constructor it takes; the block declares the bindings and ends in a
   trap, and the [default] of the switch, which only an invalid tag
   reaches, traps (design 4.3, 4.5). A single-pattern test holds its
   operand in the same way. The scrutinee and the block items keep their
   tokens. *)

(* The trap of design 10.5 as an expression of type void, which every
   trap that lowering writes is, and as a statement. *)
let trap output = Emitter.trap_call output

let trap_statement output = trap output ^ ";"

(* Design 13.5: every local that a matching declares carries [number],
   the number of the matching in its text, so that one nested in the
   block of another hides none of the outer one's locals. *)
let scrutinee_pointer number = Printf.sprintf "__tc_match%d" number
let scrutinee_copy number = Printf.sprintf "__tc_copy%d" number
let scrutinee_base number = Printf.sprintf "__tc_base%d" number

(* The text that a member of the scrutinee's variant follows to read
   that member of the scrutinee: [__tc_matchN->], or, where the
   scrutinee is held through its base, [__tc_baseN->] and the member
   path from the base, as [__tc_baseN->state.]. *)
let scrutinee_object ~number (access : Typec_sema.Expressions.access) =
  match access with
  | Through_pointer | Through_copy -> scrutinee_pointer number ^ "->"
  | Through_base { members; _ } ->
      scrutinee_base number ^ "->" ^ String.concat "." members ^ "."

(* What replaces the tokens before and after the scrutinee of a match or
   the operand of a test, or before and after the base of a scrutinee
   held through its base: the opening of the block, and the declaration
   of the pointer around the scrutinee or the base. The pointer to the
   base is declared with [__auto_type], since no name of the base's type
   that C11 can spell is sure to be visible; [__extension__] keeps it
   from a warning under [-pedantic]. *)
let scrutinee_holder ~number
    (matching : _ Typec_sema.Expressions.matching_of) =
  let variant = Typec_sema.Encoding.variant_name matching.variant in
  let record = "struct " ^ (variant :> string) in
  let pointer = scrutinee_pointer number and copy = scrutinee_copy number in
  let base_pointer =
    Printf.sprintf "{ __extension__ __auto_type const %s = "
      (scrutinee_base number)
  in
  match matching.access with
  | Through_pointer ->
      (Printf.sprintf "{ const %s *const %s = &(" record pointer, "); ")
  | Through_base { base = Base_object _; _ } -> (base_pointer ^ "&(", "); ")
  | Through_base { base = Base_pointer _; _ } -> (base_pointer ^ "(", "); ")
  | Through_copy ->
      ( Printf.sprintf "{ const %s %s = (" record copy,
        Printf.sprintf "), *const %s = &%s; " pointer copy )

(* The tokens that the declaration of the pointer replaces, up to the
   [)] after the scrutinee at [close_paren]: that [)], and before it the
   member path of a scrutinee held through its base, which
   {!scrutinee_object} spells. *)
let held_tokens tokens ~close_paren
    (matching : _ Typec_sema.Expressions.matching_of) =
  match matching.access with
  | Through_pointer | Through_copy -> [ close_paren ]
  | Through_base { base = Base_object base | Base_pointer base; _ } ->
      grammar_tokens tokens (grammar_token_after tokens base.last) close_paren

(* Design 13.5: the pointer local numbered [local], from 1, of the
   nested match numbered [number]. *)
let local_pointer ~number local = Printf.sprintf "__tc_p%d_%d" number local

(* The text that a member follows to read it in the object that local
   [local] reaches, where 0 is the scrutinee's, which [scrutinee] reaches
   ({!scrutinee_object}). *)
let local_object ~number ~scrutinee_text local =
  match local with
  | 0 -> scrutinee_text
  | _ -> local_pointer ~number local ^ "->"

(* The member of a variant's union that holds [field], as [u.Num.value]
   (design 10.1). *)
let member_text (field : Typec_sema.Expressions.pattern_field) =
  Printf.sprintf "%s.%s.%s" Tree.union_member
    (field.constructor :> string)
    field.field

(* The field that [reach] reaches in the match numbered [number], as
   [__tc_pN_1->u.Add.l] or [__tc_matchN->u.Err.error.u.Wrapped.inner]: a
   pointer local and the fields in place below it. *)
let field_text ~number ~scrutinee_text
    ({ base; path; field } : Typec_sema.Expressions.reach) =
  local_object ~number ~scrutinee_text base
  ^ String.concat "." (List.map member_text (path @ [ field ]))

(* The type of a binding is spelt [__typeof__] its field (design 2.4),
   because no name of the field's type that C11 can spell is sure to be
   visible, and not hidden, at the match. *)
let binding_declaration ~number ~scrutinee_text
    (binding : Typec_sema.Expressions.binding)
    =
  let field = field_text ~number ~scrutinee_text binding.field in
  Printf.sprintf " const __typeof__(%s) %s = %s;" field binding.name field

let binding_declarations output ~number ~scrutinee_text location bindings =
  Emitter.joined output location ~separator:""
    (binding_declaration ~number ~scrutinee_text)
    bindings

let case_label ~variant constructor =
  Printf.sprintf "case %s:" (Tree.enumerator_name ~variant constructor)

(* What a [switch] that lowering writes selects on, as the text of its
   operand: the tag of a variant, or the local that holds the number of
   the arm that a selection tree chose. *)
type switched =
  | Tag_of of { variant : Spelling.c_name; tag : string }
  | Arm_number of string

let switch_opening switched =
  let operand = match switched with Tag_of { tag; _ } | Arm_number tag -> tag in
  Printf.sprintf "switch (%s) {" operand

(* The end of every [switch] that lowering writes, the one place that
   writes its [default], which traps on a value that no [case] takes. A
   switch on a tag first names the hidden enumerator (design 10.1 rule
   2), so that -Wswitch-enum finds every enumerator handled. *)
let switch_ending output switched =
  let default = "default: " ^ trap_statement output ^ " }" in
  match switched with
  | Tag_of { variant; _ } ->
      Printf.sprintf "case %s: %s" (Tree.tag_max_name variant) default
  | Arm_number _ -> default

(* The text that opens the block of an arm and the text that closes it
   after the last item. An arm that binds holds its items in a block of
   their own after the bindings, so that they begin a block as written,
   where a pragma such as STDC FENV_ACCESS must stand; one that binds
   nothing begins its block with them already. A declaration in that
   inner block could hide a binding in C, but none redeclares one,
   since typec refuses it in the one scope of an arm (4.1 rule 5). *)
let arm_block output ~number ~scrutinee_text location
    (bindings : Typec_sema.Expressions.binding list) =
  let arm_end = trap_statement output in
  match bindings with
  | [] -> ("{", " " ^ arm_end ^ " }")
  | _ ->
      ( "{"
        ^ binding_declarations output ~number ~scrutinee_text location bindings
        ^ " {",
        " } " ^ arm_end ^ " }" )

(* The labels of an arm become the [case] labels that [cases] gives and
   open its block; a trap closes the block after its last item. *)
let matched_arm output ~number ~scrutinee_text ~cases
    (arm : Typec_sema.Expressions.matched_arm) =
  let tokens = tokens_of output in
  let location = tokens.(arm.labels.first).location in
  let opening, closing =
    arm_block output ~number ~scrutinee_text location arm.bindings
  in
  let cases = cases location arm in
  replace output ~location
    (cases ^ " " ^ opening)
    (grammar_tokens tokens arm.labels.first arm.labels.last)
  @ [ close output ~after:arm.arm.last
        ~extent:{ first = arm.labels.first; last = arm.arm.last }
        closing ]

(* In a match whose selection tree has one node, the [case] of each
   constructor that an arm takes. *)
let constructor_cases output ~variant location
    (arm : Typec_sema.Expressions.matched_arm) =
  Emitter.joined output location ~separator:" " (case_label ~variant)
    arm.cases

(* Design 13.5: a selection tree of more than one node sets the local
   [__tc_armN] to the number of the arm that it selects, and a [switch]
   on the local holds the arms, each written once. *)
let arm_local number = Printf.sprintf "__tc_arm%d" number

(* A pointer local of a nested match, declared before the tree, of the
   type of the variant that it points to (design 13.5). The node that
   reads the tag of its position points it at the object there, which
   every path to a use passes (4.7 rule 6); the null pointer it starts
   as only spares a backend that cannot see this a warning of a value
   used uninitialized. *)
let local_declaration ~number
    ({ local; local_variant } : Typec_sema.Expressions.pointer_local) =
  let variant = Typec_sema.Encoding.variant_name local_variant in
  Printf.sprintf "const struct %s *%s = 0;" (variant :> string)
    (local_pointer ~number local)

(* The statement that points the local of a position under a [*] at the
   object there, before its tag is read. *)
let point_local add ~number ~scrutinee_text
    (at : Typec_sema.Expressions.read_at) =
  match at with
  | Position { position_object = Pointed_by { local; pointer }; _ } ->
      add
        (Printf.sprintf "%s = %s;"
           (local_pointer ~number local)
           (field_text ~number ~scrutinee_text pointer))
  | Scrutinee _ | Position { position_object = In_place _; _ } -> ()

(* The variant whose tag a node reads, and the tag. *)
let read_tag ~number ~scrutinee_text (at : Typec_sema.Expressions.read_at) =
  match at with
  | Scrutinee variant ->
      (variant, scrutinee_text ^ Tree.tag_member)
  | Position { variant; position_object = In_place reach } ->
      ( variant,
        field_text ~number ~scrutinee_text reach ^ "." ^ Tree.tag_member )
  | Position { variant; position_object = Pointed_by { local; _ } } ->
      (variant, local_pointer ~number local ^ "->" ^ Tree.tag_member)

(* The statements of [tree], each added through [add]: a node under a
   [*] points the local of its position at the object there, then each
   node switches on its tag. *)
let rec write_selection output add ~number ~scrutinee_text
    (tree : Typec_sema.Expressions.selection_tree) =
  match tree with
  | Arm arm -> add (Printf.sprintf "%s = %d;" (arm_local number) arm)
  | Read { at; branches } ->
      point_local add ~number ~scrutinee_text at;
      let variant, tag = read_tag ~number ~scrutinee_text at in
      write_switch output add ~number ~scrutinee_text ~variant ~tag branches

and write_switch output add ~number ~scrutinee_text ~variant ~tag branches =
  let variant = Typec_sema.Encoding.variant_name variant in
  let write_branch (constructors, subtree) =
    List.iter (fun constructor -> add (case_label ~variant constructor))
      constructors;
    write_selection output add ~number ~scrutinee_text subtree;
    add "break;"
  in
  let switched = Tag_of { variant; tag } in
  add (switch_opening switched);
  List.iter write_branch branches;
  add (switch_ending output switched)

let arm_case _location (arm : Typec_sema.Expressions.matched_arm) =
  Printf.sprintf "case %d:" arm.number

(* The text of a selection tree before the statement that reads its
   arm: the local of the arm and the pointer locals, the tree, and
   [reader], the [switch] over the arms of a match or the [if] of a
   test. *)
let nested_selection output location ~number ~scrutinee_text ~reader
    ({ locals; tree } : Typec_sema.Expressions.nested) =
  Emitter.assembled output location ~separator:" " (fun add ->
      add (Printf.sprintf "unsigned %s;" (arm_local number));
      List.iter (fun local -> add (local_declaration ~number local)) locals;
      write_selection output add ~number ~scrutinee_text tree;
      add reader)

(* The [switch] that holds the arms, what it selects on, and the [case]
   labels of an arm. *)
let arms_switch output location ~number ~scrutinee_text ~variant
    (arms : Typec_sema.Expressions.arms) =
  match arms.nested with
  | None ->
      let switched =
        Tag_of { variant; tag = scrutinee_text ^ Tree.tag_member }
      in
      (switch_opening switched, switched, constructor_cases output ~variant)
  | Some nested ->
      let switched = Arm_number (arm_local number) in
      let reader = switch_opening switched in
      ( nested_selection output location ~number ~scrutinee_text ~reader nested,
        switched,
        arm_case )

let match_statement output ~number matching
    (arms : Typec_sema.Expressions.arms) =
  let tokens = tokens_of output in
  let { Typec_sema.Expressions.statement; variant; access; _ } = matching in
  let variant = Typec_sema.Encoding.variant_name variant in
  let scrutinee_text = scrutinee_object ~number access in
  let match_token = statement.first in
  let open_paren = grammar_token_after tokens match_token in
  let close_paren = grammar_token_after tokens matching.scrutinee.last in
  let open_brace = grammar_token_after tokens close_paren in
  let opening, held = scrutinee_holder ~number matching in
  let location = tokens.(close_paren).location in
  let switch, switched, cases =
    arms_switch output location ~number ~scrutinee_text ~variant arms
  in
  replace output ~location:tokens.(match_token).location opening
    [ match_token; open_paren ]
  @ replace output ~location (held ^ switch)
      (held_tokens tokens ~close_paren matching @ [ open_brace ])
  @ List.concat_map (matched_arm output ~number ~scrutinee_text ~cases)
      arms.matched
  @ replace output
      ~location:tokens.(statement.last).location
      (switch_ending output switched ^ " }")
      [ statement.last ]

(* Design 13.5: a single-pattern test becomes the block of a match that
   reads the tag once into [__tc_tagN] and has an [if] on it, or, where
   its pattern is nested, that writes its selection tree and has an [if]
   on [__tc_armN], which the leaf of the pattern sets to 1. Its true branch
   is a block that the [)] of the test opens, which declares the bindings
   and then holds the statement as written: a compound statement still
   begins a block, where a pragma such as STDC FENV_ACCESS must stand, a
   pragma before the statement still precedes it, and an [if] in the
   statement cannot take the [else] of the false branch. A declaration in
   a compound statement could hide a binding in C, but none redeclares
   one, since typec refuses it in the one scope of the bindings and the
   statement (4.6 rule 4). The false branch of a flat test traps on a tag
   that is no constructor's (4.5), with a [switch] whose cases are those
   of a match; that of a nested test checks nothing, since its tree has
   checked every tag that it read. Then the false branch runs the [else]
   statement of an [if]. A [while] test is the body of an endless loop
   whose false branch ends in [break], so that the operand is evaluated
   in that loop (4.4). *)

let tag_local number = Printf.sprintf "__tc_tag%d" number

let tag_declaration ~number ~scrutinee_text =
  Printf.sprintf "const __typeof__(%s%s) %s = %s%s; " scrutinee_text
    Tree.tag_member (tag_local number) scrutinee_text Tree.tag_member

let tag_check output location ~number ~variant constructors =
  let switched = Tag_of { variant; tag = tag_local number } in
  Printf.sprintf "%s %s break; %s " (switch_opening switched)
    (Emitter.joined output location ~separator:" " (case_label ~variant)
       constructors)
    (switch_ending output switched)

(* The text from the held operand to the [{] of the true branch, and the
   check of the tag on the false branch. *)
let test_condition output location ~number ~scrutinee_text ~variant
    (test : Typec_sema.Expressions.test) =
  match test.nested with
  | None ->
      ( Printf.sprintf "%sif (%s == %s) {"
          (tag_declaration ~number ~scrutinee_text)
          (tag_local number)
          (Tree.enumerator_name ~variant test.constructor),
        tag_check output location ~number ~variant test.constructors )
  | Some nested ->
      let reader = Printf.sprintf "if (%s == 1) {" (arm_local number) in
      ( nested_selection output location ~number ~scrutinee_text ~reader
          nested,
        "" )

(* The false branch of a test of [form] after the statement that ends at
   [controlled_last]: the end of the block around that statement, the
   [check] of the tag, then the [else] statement of an [if], or the end
   of the loop of a [while]. *)
let false_branch output form ~extent ~controlled_last ~check =
  let tokens = tokens_of output in
  let after_controlled text =
    close output ~after:controlled_last ~extent (" }" ^ text)
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
      @ [ close output ~after:otherwise.last ~extent " } }" ]
  | While_test -> [ after_controlled (" else { " ^ check ^ "break; } }") ]

let single_pattern_test output ~number matching
    (test : Typec_sema.Expressions.test) =
  let tokens = tokens_of output in
  let { Typec_sema.Expressions.statement; variant; access; _ } = matching in
  let variant = Typec_sema.Encoding.variant_name variant in
  let scrutinee_text = scrutinee_object ~number access in
  let equals = grammar_token_before tokens matching.scrutinee.first in
  let close_paren = grammar_token_after tokens matching.scrutinee.last in
  let opening, held = scrutinee_holder ~number matching in
  let loop = match test.form with If_test _ -> "" | While_test -> "for (;;) " in
  let location = tokens.(statement.first).location in
  let held_location = tokens.(close_paren).location in
  let selected, check =
    test_condition output location ~number ~scrutinee_text ~variant test
  in
  replace output ~location (loop ^ opening)
    (grammar_tokens tokens statement.first equals)
  @ replace output ~location:held_location
      (held ^ selected
      ^ binding_declarations output ~number ~scrutinee_text held_location
          test.bindings)
      (held_tokens tokens ~close_paren matching)
  @ false_branch output test.form ~extent:statement
      ~controlled_last:test.controlled.last
      ~check

(* The tokens of the patterns that a matching replaces whole: the
   labels of each arm, and a test from its keyword to the [=] before its
   operand. A name written inside them goes with them. *)
let pattern_spans tokens (matching : Typec_sema.Expressions.matching) =
  match matching.selects with
  | Arms arms ->
      List.map
        (fun (arm : Typec_sema.Expressions.matched_arm) -> arm.labels)
        arms.matched
  | Test _ ->
      let equals = grammar_token_before tokens matching.scrutinee.first in
      [ { Tree.first = matching.statement.first; last = equals } ]

(* The edits of matching [number] of the unit, which its locals carry. *)
let matching output (number, (matching : Typec_sema.Expressions.matching)) =
  match matching.selects with
  | Arms arms -> match_statement output ~number matching arms
  | Test test -> single_pattern_test output ~number matching test

(* Whether [edit] belongs to the tokens [first] to [last]: whether they
   hold its extent ({!Emitter.edit}). This is the one test of which
   edits a stretch of tokens carries along when its text is copied,
   moved or dropped. *)
let lies_within ~first ~last (edit : Emitter.edit) =
  first <= edit.extent.first && edit.extent.last <= last

(* The elements of [sorted], an array in order of [begins], the first
   token of each, that begin at tokens [first] to [last], found by a
   search, not a scan of all of them. *)
let beginning_within sorted ~begins ~first ~last =
  (* The number of elements that begin before [index]: those below
     [low] do, those from [high] on do not. *)
  let rec begun_before index low high =
    if low = high then low
    else
      let middle = (low + high) / 2 in
      if begins sorted.(middle) < index then
        begun_before index (middle + 1) high
      else begun_before index low middle
  in
  let count = Array.length sorted in
  let start = begun_before first 0 count in
  let stop = begun_before (last + 1) start count in
  Array.to_list (Array.sub sorted start (stop - start))

(* Edits by the first token of their extents. *)
type held_edits = Emitter.edit array

let hold edits : held_edits =
  let held = Array.of_list edits in
  let by_extent (a : Emitter.edit) (b : Emitter.edit) =
    compare a.extent.first b.extent.first
  in
  Array.stable_sort by_extent held;
  held

(* The edits of [held] that lie within tokens [first] to [last]. *)
let edits_within (held : held_edits) ~first ~last =
  let begins (edit : Emitter.edit) = edit.extent.first in
  beginning_within held ~begins ~first ~last
  |> List.filter (lies_within ~first ~last)

(* The tokens [first] to [last] of a text with [edits], those that lie
   within them, applied, as moved text: every token at its own location,
   a pragma line on a line of its own, and the text of each edit at the
   edit's. The moved text of an edit inside, such as the copies that a
   return in the operand of a try runs, moves with it. No [#pragma
   typec] line moves: one of C text is ignored, and Type-C text holds
   one only outside every function (design 13.5). *)
let moved_text output edits ~first ~last =
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
  from first (Emitter.in_order edits) []

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
      let extent = answered.construct in
      [ insert output ~before:controlling.span.first ~extent "((void)(";
        insert output ~extent
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

(* Whether [edit] goes with one of the [dropped] spans: whether one of
   them holds its extent, as {!lies_within} tells. *)
let goes_with dropped (edit : Emitter.edit) =
  covers dropped ~first:edit.extent.first ~last:edit.extent.last

(* A stretch of tokens whose text moves elsewhere or goes: an operand
   that a holder of try hoists, or a defer statement, which lowering
   removes. [mover] is the construct that moves it, the holder's
   statement or the defer statement, and [rank] its place among the
   moves of that construct, for a holder in the order of 5.1, which
   tells the later of two with one span. [replacement] are the edits
   that write what stands in its place ({!replacing}). *)
type move = {
  moved : Tree.span;
  mover : Tree.span;
  rank : int;
  replacement : Emitter.edit list;
}

(* Moves by first token. *)
type held_moves = move array

let hold_moves moves : held_moves =
  let held = Array.of_list moves in
  let by_first a b = compare a.moved.first b.moved.first in
  Array.stable_sort by_first held;
  held

(* The [moves] that no other holds, of two with one span the later: a
   hoisted operand that holds another follows it in the order of 5.1,
   and a first operand follows a try that is the whole of it. Sorted by
   first token, longest first and later first, a move is held exactly
   when it ends no later than the furthest one kept before it. *)
let outermost_moves moves =
  let order a b =
    compare
      (a.moved.first, b.moved.last, b.rank)
      (b.moved.first, a.moved.last, a.rank)
  in
  let keep (reach, kept) move =
    if move.moved.last <= reach then (reach, kept)
    else (move.moved.last, move :: kept)
  in
  snd (List.fold_left keep (-1, []) (List.sort order moves))

(* [edits] with the outermost of [moves] in place: the edits that lie
   within a move go with it, and its replacement takes their place. *)
let with_moves edits moves =
  let outer = outermost_moves moves in
  let spans = cover (List.map (fun move -> move.moved) outer) in
  List.filter (fun edit -> not (goes_with spans edit)) edits
  @ List.concat_map (fun move -> move.replacement) outer

(* The moves that a copy applies where they stand inside it: all of
   them, or in the copy of a hoisted operand all but those of its holder
   that the holder evaluates after it, of a rank not below the
   operand's. *)
type applied_moves =
  | Every_move
  | Ranked_below of { mover : Tree.span; rank : int }

(* Every edit that the lowering of one text makes and every move of its
   tokens: the whole from which the text and each copy of it are made,
   so that what a copy holds does not depend on the order in which
   lowering makes the edits. *)
type lowered_text = { held : held_edits; moves : held_moves }

let lowered_text edits moves = { held = hold edits; moves = hold_moves moves }

(* The edits of [text] as they apply to the whole of it, with the
   outermost of its moves in place. *)
let text_in_place { held; moves } =
  with_moves (Array.to_list held) (Array.to_list moves)

(* The one way to copy source text: tokens [first] to [last] of [text]
   as moved text, with exactly the edits that lie within them
   ({!lies_within}), and the moves inside them that the copy [applies]
   in place, each applied once. The copy is made from the whole of
   [text], so it forces it: while a text is lowered, only the pieces of
   a moved edit ({!Emitter.moved}) make one, and a copy forced before
   [text] is complete raises [Lazy.Undefined]. A caller writes the copy
   outside tokens [first] to [last], since the locals of a matching in
   them keep their names in the copy (design 13.5). *)
let copy_text output (text : lowered_text Lazy.t) applies ~first ~last =
  let { held; moves } = Lazy.force text in
  let begins move = move.moved.first in
  let applies_move move =
    match applies with
    | Every_move -> true
    | Ranked_below { mover; rank } -> move.mover <> mover || move.rank < rank
  in
  let applied move = applies_move move && move.moved.last <= last in
  let inside =
    List.filter applied (beginning_within moves ~begins ~first ~last)
  in
  moved_text output (with_moves (edits_within held ~first ~last) inside)
    ~first ~last

let dropped_edits output { span; text } =
  let tokens = tokens_of output in
  replace output ~location:tokens.(span.first).location text
    (grammar_tokens tokens span.first span.last)

(* Design 5.1, 13.5: the prelude of a holder of try expressions stands
   directly before it and evaluates its hoisted operands in the order of
   5.1: a try as a temporary of the operand's result type and a test of
   its tag that only Ok passes, a first operand as its truth in an int
   temporary that conditions what its operator evaluates under an if,
   and the left operand of a comma as a statement. The holder reads the
   Ok field, the truth or nothing where each stood. The labels of the
   holder stay in place on a null statement before the prelude, and a
   holder that is the substatement of another becomes a block around
   the labels, the prelude and itself, so that the labels stay under
   the statement around it. A temporary has no qualifier: the value of a
   try may hold an array that the holder reads through a pointer. *)

let truth_name number = Printf.sprintf "__tc_c%d" number
let temporary_name number = Printf.sprintf "__tc_t%d" number
let value_name number = Printf.sprintf "__tc_v%d" number

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
      (trap_statement output)
  in
  let return =
    Printf.sprintf "return %s; }"
      (returned_err ~returned ~temporary site.err_field)
  in
  [ try_piece output location test; try_piece output location trap_unless_err ]
  @ cleanups
  @ [ try_piece output location return ]

module Plan = Typec_sema.Try_plan

let ok_read (site : Typec_sema.Expressions.try_site) field =
  field_read ~temporary:(temporary_name site.temporary) ok_constructor field

(* What the holder reads where a try stood: the Ok field, made a slice of
   the instance it converts to as [tested_conversion] does, the temporary
   that holds it converted to an arithmetic type, or nothing where T is
   void; the read has no side effect, so it needs no temporary. *)
let try_value (site : Typec_sema.Expressions.try_site) =
  match site.value with
  | No_value -> "((void)0)"
  | Read { field; conversion = Unconverted } -> ok_read site field
  | Read { field; conversion = To_slice converted_to } ->
      let read = ok_read site field in
      Printf.sprintf "(struct %s){ %s.data, %s.len }" converted_to read read
  | Read { field = _; conversion = To_arithmetic _ } ->
      value_name site.temporary

(* The read of the Ok field of a try that initialises an object in a
   braced list, and the arithmetic type of the object, in keywords,
   where the prelude converts the value to it (design 13.5). *)
let converted_value (site : Typec_sema.Expressions.try_site) =
  match site.value with
  | Read { field; conversion = To_arithmetic into } ->
      Some (ok_read site field, Typec_sema.Arithmetic.name into)
  | Read { conversion = Unconverted | To_slice _; _ } | No_value -> None

(* The typed try of a holder that a hoisted operand replaces. *)
let site_of (holder : Typec_sema.Expressions.try_holder)
    (hoisted : Plan.hoisted) =
  match
    List.find_opt
      (fun (site : Typec_sema.Expressions.try_site) ->
        site.try_span = hoisted.replaced)
      holder.tries
  with
  | Some site -> site
  | None -> invalid_arg "Lowering: a hoisted try that typing did not type"

(* The edits that write what the holder reads in place of a hoisted
   operand: the read of a try, the truth of a first operand, or nothing
   of the left operand of a comma. *)
let replacing output holder (hoisted : Plan.hoisted) =
  let tokens = tokens_of output in
  let text =
    match hoisted.form with
    | Tried _ -> try_value (site_of holder hoisted)
    | Truth { number } -> truth_name number
    | Discarded_left -> "(void)0"
  in
  replace output ~location:tokens.(hoisted.replaced.first).location text
    (grammar_tokens tokens hoisted.replaced.first hoisted.replaced.last)

(* The moves of the hoisted operands of [holder], in its order. *)
let holder_moves output (holder : Typec_sema.Expressions.try_holder) =
  List.mapi
    (fun rank (hoisted : Plan.hoisted) ->
      { moved = hoisted.replaced;
        mover = holder.holder.statement;
        rank;
        replacement = replacing output holder hoisted })
    holder.hoisted

(* The text of the operand of the hoisted operand at [rank] of [holder],
   with the earlier ones that it holds in place, from [lowered], the
   whole of the text. *)
let operand_text output lowered (holder : Typec_sema.Expressions.try_holder)
    rank (hoisted : Plan.hoisted) =
  copy_text output lowered
    (Ranked_below { mover = holder.holder.statement; rank })
    ~first:hoisted.operand.first ~last:hoisted.operand.last

(* The temporary of a try, of the operand's result type named by its
   claimed tag. *)
let try_temporary (site : Typec_sema.Expressions.try_site) =
  let variant =
    Typec_sema.Encoding.variant_name (Applied site.operand_instance)
  in
  (variant, Printf.sprintf "struct %s %s" (variant :> string)
              (temporary_name site.temporary))

(* Whether the value of the try of [site] is a read of its temporary,
   rather than nothing or the converted value: a read that may stand
   outside the if that assigns the temporary. *)
let holder_reads_temporary (site : Typec_sema.Expressions.try_site) =
  match site.value with
  | Read { conversion = Unconverted | To_slice _; _ } -> true
  | Read { conversion = To_arithmetic _; _ } | No_value -> false

(* The prelude of [holder] (design 13.5), from the text of each hoisted
   operand, [text_of], and the cleanups of the error path of each try,
   [cleanups_of]. What a truth conditions stands under an if on it. A
   temporary that the holder reads and an if assigns is declared before
   the outermost if with the value 0, and every other one where it is
   assigned, with its value, so that no path reads one that it has not
   assigned: GCC 16 from -O1 cannot tell that the holder reads such a
   temporary only where the if assigned it, and warns. *)
let prelude output (holder : Typec_sema.Expressions.try_holder) ~text_of
    ~cleanups_of =
  let tokens = tokens_of output in
  let piece (hoisted : Plan.hoisted) text =
    try_piece output tokens.(hoisted.replaced.first).location text
  in
  let zero_declared (hoisted : Plan.hoisted) declaration zero =
    piece hoisted (Printf.sprintf "%s = %s;" declaration zero)
  in
  (* Whether the temporary of the try of [site] at [hoisted] is declared
     before the outermost if over it rather than where it is assigned. *)
  let declared_before_if (hoisted : Plan.hoisted) site =
    hoisted.conditions <> [] && holder_reads_temporary site
  in
  let declared (hoisted : Plan.hoisted) =
    match hoisted.form with
    | Tried { number } ->
        let site = site_of holder hoisted in
        let _, declaration = try_temporary site in
        let temporary =
          if declared_before_if hoisted site then
            [ zero_declared hoisted declaration "{ 0 }" ]
          else []
        in
        let value =
          match converted_value site with
          | Some (_, type_name) ->
              [ zero_declared hoisted
                  (Printf.sprintf "%s %s" type_name (value_name number))
                  "0" ]
          | None -> []
        in
        temporary @ value
    | Truth { number } ->
        [ zero_declared hoisted ("int " ^ truth_name number) "0" ]
    | Discarded_left -> []
  in
  (* The conversion of the value of a try in a braced list after its
     test, an initialisation or an assignment and no cast, so that C
     converts there as it would in the list (13.5). *)
  let converted ~outside number site =
    match converted_value site with
    | None -> []
    | Some (read, type_name) ->
        let name = value_name number in
        let target =
          if outside then Printf.sprintf "const %s %s" type_name name
          else name
        in
        [ try_piece output tokens.(site.try_span.first).location
            (Printf.sprintf "%s = %s;" target read) ]
  in
  (* The form of a hoisted operand, which declares its temporary where
     it is assigned unless that is under an if and the holder reads it. *)
  let evaluated ~outside (hoisted : Plan.hoisted) =
    let taken ~declared_here ~declaration ~name ~after =
      let target = if declared_here then declaration else name in
      [ piece hoisted (target ^ " = (") ]
      @ text_of hoisted
      @ [ piece hoisted after ]
    in
    match hoisted.form with
    | Tried { number } ->
        let site = site_of holder hoisted in
        let variant, declaration = try_temporary site in
        let declared_here = not (declared_before_if hoisted site) in
        taken ~declared_here ~declaration ~name:(temporary_name number)
          ~after:");"
        @ error_path output
            ~location:tokens.(hoisted.replaced.first).location ~variant site
            ~cleanups:(cleanups_of site)
        @ converted ~outside number site
    | Truth { number } ->
        let name = truth_name number in
        taken ~declared_here:outside ~declaration:("const int " ^ name) ~name
          ~after:") ? 1 : 0;"
    | Discarded_left ->
        [ piece hoisted "(void)(" ] @ text_of hoisted @ [ piece hoisted ");" ]
  in
  (* The temporaries of the operands under the outermost condition of
     [truth], declared before its if; 5.1 evaluates what a first operand
     conditions right after it, so they follow one another. *)
  let outermost_truth (hoisted : Plan.hoisted) =
    match List.rev hoisted.conditions with
    | [] -> None
    | (condition : Plan.condition) :: _ -> Some condition.truth
  in
  let declarations truth run =
    let rec gather written = function
      | hoisted :: later when outermost_truth hoisted = Some truth ->
          gather (List.rev_append (declared hoisted) written) later
      | _ -> List.rev written
    in
    gather [] run
  in
  (* The prelude is written in one pass, with the ifs open around the
     last operand, innermost first, each with the operand that opened
     it, whose location its braces take. An operand closes the ifs that
     it does not stand under and opens the rest of its conditions. *)
  let shared_depth opened (conditions : Plan.condition list) =
    let rec drop count list =
      if count <= 0 then list else drop (count - 1) (List.tl list)
    in
    let opened_depth = List.length opened in
    let depth = List.length conditions in
    let common = min opened_depth depth in
    (* Equal innermost conditions name equal lists. *)
    let rec meet depth opened (conditions : Plan.condition list) =
      match (opened, conditions) with
      | (condition, _) :: _, other :: _ when condition = other -> depth
      | _ :: opened, _ :: conditions -> meet (depth - 1) opened conditions
      | _ -> 0
    in
    meet common
      (drop (opened_depth - common) opened)
      (drop (depth - common) conditions)
  in
  (* The conditions above the outermost [depth] of [conditions],
     outermost first. *)
  let above ~depth conditions =
    let rec take count conditions outermost_first =
      match conditions with
      | condition :: outer when count > 0 ->
          take (count - 1) outer (condition :: outermost_first)
      | _ -> outermost_first
    in
    take (List.length conditions - depth) conditions []
  in
  let rec close count opened written =
    match opened with
    | (_, opener) :: outer when count > 0 ->
        close (count - 1) outer (piece opener "}" :: written)
    | _ -> written
  in
  let if_of opener (condition : Plan.condition) =
    let name = truth_name condition.truth in
    match condition.branch with
    | When_true -> piece opener (Printf.sprintf "if (%s) {" name)
    | When_false -> piece opener (Printf.sprintf "if (!%s) {" name)
  in
  (* The outermost if that an operand opens: the else of the one that
     it has just closed on the same truth, or an if of its own, after
     the declarations of what it conditions where it is outside every
     other. *)
  let first_opening ~closed ~depth run (hoisted : Plan.hoisted)
      (condition : Plan.condition) =
    match closed with
    | Some ((closed_condition : Plan.condition), opener)
      when closed_condition.truth = condition.truth
           && closed_condition.branch = When_true
           && condition.branch = When_false ->
        (opener, [ piece opener "else {" ])
    | _ ->
        let declared =
          if depth = 0 then declarations condition.truth run else []
        in
        (hoisted, declared @ [ if_of hoisted condition ])
  in
  let rec pass opened written = function
    | [] -> List.rev (close (List.length opened) opened written)
    | (hoisted : Plan.hoisted) :: later as run ->
        let depth = shared_depth opened hoisted.conditions in
        let closing = List.length opened - depth in
        let closed =
          if closing = 0 then None else List.nth_opt opened (closing - 1)
        in
        let written = close closing opened written in
        let kept = List.filteri (fun index _ -> index >= closing) opened in
        let opened, written =
          match above ~depth hoisted.conditions with
          | [] -> (kept, written)
          | outermost :: inner ->
              let opener, pieces =
                first_opening ~closed ~depth run hoisted outermost
              in
              let opened = (outermost, opener) :: kept in
              let written = List.rev_append pieces written in
              List.fold_left
                (fun (opened, written) condition ->
                  ( (condition, hoisted) :: opened,
                    if_of hoisted condition :: written ))
                (opened, written) inner
        in
        let evaluated =
          evaluated ~outside:(hoisted.conditions = []) hoisted
        in
        pass opened (List.rev_append evaluated written) later
  in
  pass [] [] holder.hoisted

(* The edits of a holder: its prelude, after the null statement of its
   labels, in front of it, and around it the braces of a substatement. *)
let lower_holder output lowered ~cleanups_of
    (holder : Typec_sema.Expressions.try_holder) =
  let tokens = tokens_of output in
  let { Typec_sema.Expressions.statement; labels; standing } =
    holder.holder
  in
  let location = tokens.(statement.first).location in
  let prelude_pieces () =
    let texts =
      List.mapi
        (fun rank (hoisted : Plan.hoisted) ->
          (hoisted.operand, operand_text output lowered holder rank hoisted))
        holder.hoisted
    in
    let text_of (hoisted : Plan.hoisted) = List.assoc hoisted.operand texts in
    let null_statement =
      match labels with
      | Some _ -> [ try_piece output location ";" ]
      | None -> []
    in
    null_statement @ prelude output holder ~text_of ~cleanups_of
  in
  let first = (Option.value labels ~default:statement).first in
  let extent = { statement with first } in
  (* The prelude and the braces stand around the holder as lowered. *)
  let around edit = Emitter.enclosing edit ~extent in
  let in_front =
    around
      (insert_moved output ~before:statement.first ~extent
         (lazy (prelude_pieces ())))
  in
  match standing with
  | Block_item -> [ in_front ]
  | Substatement ->
      [ around (insert output ~before:first ~extent "{");
        in_front;
        around (close output ~after:statement.last ~extent "}") ]

(* The casts to void of the discarded values of [holder] whose tries
   may leave them reading values with no effect, which would draw
   -Wunused-value. They lower the source in place, so one inside a
   hoisted operand moves with it like the other edits inside the tokens
   that it replaces. *)
let void_casts output (holder : Typec_sema.Expressions.try_holder) =
  let cast (value : Tree.span) =
    [ insert output ~before:value.first ~extent:value "(void)(";
      close output ~after:value.last ~extent:value ")" ]
  in
  List.concat_map cast holder.void_casts

(* The edits of the holders of try of a text, each copy in them made
   from [lowered], the whole of the text, and the casts to void in
   them; the moves of their hoisted operands are {!holder_moves}.
   [cleanups_of] gives the cleanups of the error path of a try. *)
let holder_edits output lowered holders ~cleanups_of =
  List.concat_map (lower_holder output lowered ~cleanups_of) holders
  @ List.concat_map (void_casts output) holders

(* Design 6 and 13.5: a defer statement is removed, and a copy of its
   statement [S], as a block, runs at each exit of its scope. An exit
   that leaves several scopes runs their copies latest first. The end of
   a block that can complete gets the copies before its [}]; one that
   cannot gets a trap there instead (6 rule 1), and the end of a match
   arm has its own. A jump that runs copies becomes a block that holds
   them and then the jump, [{ copies jump; }], after the labels of its
   statement; a [return e;] holds [e] first, in the temporary [__tc_rN]
   of the type [__tc_ret], or in a function that returns void as an
   expression statement. The error path of a try gets its copies where
   the try is lowered ({!holder_edits}). A copy of [S] is the text of [S]
   with the edits that lie within it; [S] holds no defer (design 6 rule
   11). *)

module Reachability = Typec_sema.Reachability

let return_type_name = "__tc_ret"

(* Design 13.5: the temporary of [return e;] number [number] of its
   function, in source order, which keeps it apart from that of a
   [return] in a statement expression of [e]. *)
let return_temporary number = Printf.sprintf "__tc_r%d" number

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

(* The copy of the statement of [site], [{ S }], from [lowered], the
   whole of the text. *)
let copy output lowered (site : Reachability.defer_site) =
  let tokens = tokens_of output in
  let deferred =
    Tree.deferred_text ~keyword:site.keyword ~statement:site.deferred
  in
  let location = tokens.(site.deferred.first).location in
  let moved =
    copy_text output lowered Every_move ~first:deferred.first
      ~last:deferred.last
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

let return_form ~number (returns : Typec_sema.Expressions.returns) =
  match returns with
  | Returns_value ->
      let temporary = return_temporary number in
      { value_opening =
          Printf.sprintf "{ %s %s = (" return_type_name temporary;
        value_closing = ");";
        returned = Printf.sprintf "return %s; }" temporary }
  | Returns_void ->
      { value_opening = "{"; value_closing = ";"; returned = "return; }" }

(* The edits of one place of a function that [returns], which runs the
   copies of [leaving]; a trap stands once at the end of a block however
   many defers it holds. A [return e;] holds [e] in the temporary
   numbered [number]. *)
let place_edits output lowered returns ~number (place, leaving) =
  let tokens = tokens_of output in
  (* A trap and the error path of a try write no copies here. *)
  let copies () = List.concat_map (copy output lowered) leaving in
  let at index = tokens.(index).location in

  let token index = Reader.range tokens ~first:index ~count:1 in
  let piece index text = defer_piece output (at index) text in
  match (place : Reachability.place) with
  | Block_end closing ->
      [ insert_moved output ~before:closing
          ~extent:{ first = closing; last = closing } (lazy (copies ())) ]
  | Trap closing ->
      [ insert output ~before:closing
          ~extent:{ first = closing; last = closing } (trap_statement output) ]
  | Left_by (Jump jump) ->
      [ insert_moved output ~before:jump.first ~extent:jump
          (lazy (piece jump.first "{" :: copies ()));
        Emitter.code output (token jump.last) ~location:(at jump.last) "; }" ]
  | Left_by (Value_return { statement; operand = _ }) ->
      let form = return_form ~number returns in
      [ Emitter.code output (token statement.first)
          ~location:(at statement.first) form.value_opening;
        Emitter.moved output (token statement.last)
          (lazy
            ((piece statement.last form.value_closing :: copies ())
            @ [ piece statement.last form.returned ])) ]
  | Left_by (Error_path _) -> []

(* Design 13.5: [typedef __typeof__(call of f) __tc_ret;], which the
   block around the body declares ({!body_blocks}). *)
let return_typedef output (defers : Typec_sema.Expressions.function_defers) =
  let location = (tokens_of output).(defers.body.first).location in
  let lvalue name = Printf.sprintf "*(__typeof__(%s) *)0" name in
  let arguments =
    Emitter.joined output location ~separator:", " lvalue defers.parameters
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

(* Each place with the number of the [return e;] places before it, which
   names the temporary of a [return e;] (design 13.5). *)
let numbered_returns places =
  let number count ((place, _) as entry) =
    let next = if is_value_return place then count + 1 else count in
    (next, (count, entry))
  in
  snd (List.fold_left_map number 0 places)

let function_edits output lowered ~dropped
    (defers : Typec_sema.Expressions.function_defers) =
  let kept_places =
    List.filter
      (fun (place, _) ->
        kept_token dropped (Reachability.place_token place))
      (places defers.sites)
  in
  let declarations =
    if
      defers.returns = Returns_value
      && List.exists (fun (place, _) -> is_value_return place) kept_places
    then [ (defers.body, lazy (return_typedef output defers)) ]
    else []
  in
  let place (number, entry) =
    place_edits output lowered defers.returns ~number entry
  in
  (List.concat_map place (numbered_returns kept_places), declarations)

(* The removal of each defer statement of [functions]: every token of
   [defer S] goes, its pragma lines too, which move to the copies, and
   so do the edits that lie within it; a [#pragma typec] line, which C
   text ignores, goes with them. *)
let defer_moves output
    (functions : Typec_sema.Expressions.function_defers list) =
  let tokens = tokens_of output in
  let removal site =
    let span = defer_span site in
    let replacement =
      List.init (span.last - span.first + 1) (fun offset -> span.first + offset)
      |> replace output ~location:tokens.(span.first).location ""
    in
    { moved = span; mover = span; rank = 0; replacement }
  in
  List.concat_map
    (fun (defers : Typec_sema.Expressions.function_defers) ->
      List.map removal defers.sites)
    functions

(* The cleanups of the error path of each try (13.5, the [try] row):
   the copies of the scopes of [functions] that it leaves, the latest
   first, from [lowered], the whole of the text. The sites are indexed
   by the span of the try once, so that each try finds its own in
   constant time. *)
let error_path_cleanups output lowered
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
    | Some sites -> List.concat_map (copy output lowered) sites
    | None -> []

(* The edits that lower the defers of [functions], each copy in them
   made from [lowered], the whole of the text, and the declarations of
   [__tc_ret] by body; the statements go by {!defer_moves}. [dropped] is
   the text that lowering drops, whose own edits delete a defer in
   it. *)
let defer_edits output lowered ~dropped
    (functions : Typec_sema.Expressions.function_defers list) =
  let edits, declarations =
    List.split (List.map (function_edits output lowered ~dropped) functions)
  in
  (List.concat edits, List.concat declarations)

(* Slices (design 13.5, "The check of a slice") *)

module Expressions = Typec_sema.Expressions

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
  insert output ~before:whole.first ~extent:whole
    (Printf.sprintf "(*((void)(%s = (" s)
  :: replace output ~location
       (Printf.sprintf ")), (void)(%s = (__typeof__(%s))(" i i)
       (between tokens ~after:slice index)
  @ replace output ~location
      (Printf.sprintf
         ")), (void)(%s < %s.len ? (void)0 : %s), &%s.data[%s]))" i s
         (trap output) s i)
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
         lo hi hi s (trap output) instance s lo hi lo)
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
      insert output ~before:whole.first ~extent:whole
        (Printf.sprintf "(*((void)%s, &(" (trap output))
      :: replace output ~location ").data[+("
           (between tokens ~after:slice index)
      @ replace output ~location ")]))" [ whole.last ]
  | Sub { slice; low; high } ->
      replace output ~location
        (Printf.sprintf "((void)%s, (void)(" (trap output))
        (grammar_tokens tokens whole.first (slice.first - 1))
      @ replace output ~location "), (void)(" (between tokens ~after:slice low)
      @ replace output ~location "), (void)(" (between tokens ~after:low high)
      @ replace output ~location
          (Printf.sprintf "), (struct %s){ 0 })" checked.instance)
          [ whole.last ]
  | Conversion { converted_to } ->
      [ insert output ~before:whole.first ~extent:whole
          (Printf.sprintf "((void)%s, (void)(" (trap output));
        close output ~after:whole.last ~extent:whole
          (Printf.sprintf "), (struct %s){ 0 })" converted_to) ]

(* The conversion of section 8 rule 5 over the temporary of test [n]: the
   slice converted makes one of the instance [converted_to] from its
   members, as C converts the pointer. *)
let tested_conversion output n ~(whole : Tree.span) ~converted_to =
  let s = Printf.sprintf "__tc_s%d" n in
  [ insert output ~before:whole.first ~extent:whole
      (Printf.sprintf "((void)(%s = (" s);
    close output ~after:whole.last ~extent:whole
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

(* [pieces], made when first forced ({!Emitter.moved}), in place of the
   tokens at [indexes], as {!replace} puts text there. *)
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
let array_length output lowered ~location ~element (operand : Tree.span) =
  let piece code = Emitter.Piece (Emitter.generated output location code) in
  let copy =
    copy_text output lowered Every_move ~first:operand.first
      ~last:operand.last
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
    | [] -> [ insert output ~before:literal.first ~extent:outer opening ]
    | _ -> replace output ~location opening before
  in
  (* Without parentheses to replace, the count follows the last piece,
     which it replaces with itself. *)
  let closing_edits =
    match after with
    | [] ->
        replace_moved output ~location
          (Lazy.from_val (moved literal.last @ length))
          [ literal.last ]
    | _ -> replace_moved output ~location (Lazy.from_val length) after
  in
  opening_edits @ closing_edits

(* The edits of one slice made from an array or a pointer, whose name
   and [(] become the opening of its compound literal or braced list,
   and its [)], with the parentheses around a braced list, the closing.
   The operands keep their tokens, each in parentheses; the length of
   an array copies its operand from [lowered], the whole of the text. *)
let operator_making output lowered ~outer ~opening ~location
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
      let closing () =
        (piece "), " :: array_length output lowered ~location ~element operand)
        @ [ piece " }" ]
      in
      opening_edits
      @ replace_moved output ~location (lazy (closing ())) closing_tokens
  | Unchecked { pointer; count }, [ _ ] ->
      opening_edits
      @ replace output ~location "), (" (between tokens ~after:pointer count)
      @ replace output ~location ") }" closing_tokens
  | (From_array _ | Unchecked _ | From_string _), _ ->
      invalid_arg "Lowering.operator_making: no operator over a slice"

(* The edits of one slice that [making] makes, each copy in them made
   from [lowered], the whole of the text. *)
let slice_making output lowered (making : Expressions.slice_making) =
  let location = (tokens_of output).(making.span.first).location in
  let outer, opening = slice_opening making in
  match making.making with
  | From_string { literal } ->
      string_making output ~outer ~opening ~location literal
  | From_array { operand } ->
      operator_making output lowered ~outer ~opening ~location making operand
  | Unchecked { pointer; _ } ->
      operator_making output lowered ~outer ~opening ~location making pointer

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
    [ insert output ~before:body.first ~extent:body
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
   inside one go, and the range's own edits replace them. The operand
   of a try that its holder hoists and a defer statement move
   ({!move}), and the edits that lie within them go with them.
   [zero_initialisers] are those of design 7.1 rule 3 that the text
   holds, each [{}] with one [__extension__] before each holder
   ({!with_extensions}).

   Each copy of source text, of a slice's operand, a deferred statement
   or a hoisted operand, is made from the whole of the text, every edit
   and move that the lowering of it makes ({!lowered_text}), once all
   are made: the text is tied to the copies in it through [lowered],
   which no copy forces before it is complete, so no copy depends on
   the order in which the constructs are lowered. *)
let text_edits output ~tag_max ~declarations ~void_field_spans ~replaced
    ~zero_initialisers typed =
  let holders = zero_holders zero_initialisers in
  let tokens = tokens_of output in
  let answered = Typec_sema.Expressions.answered typed in
  let constructions = Typec_sema.Expressions.constructions typed in
  (* A name inside tokens that a construct replaces whole is written by
     the construct, if at all, and an edit of its own would overlap. *)
  let replaced_whole =
    cover
      (List.map (construction_head tokens) constructions
      @ List.concat_map (pattern_spans tokens)
          (Typec_sema.Expressions.matchings typed))
  in
  let written_whole { span; _ } =
    covers replaced_whole ~first:span.first ~last:span.last
  in
  let removed span = { span; text = "" } in
  let dropped, extensions =
    with_extensions output holders
      (outermost
         (List.concat_map dropped_ranges answered
         @ List.map removed void_field_spans
         @ List.filter (fun range -> not (written_whole range)) replaced))
  in
  let dropped_spans = cover (List.map (fun range -> range.span) dropped) in
  let kept edit = not (goes_with dropped_spans edit) in
  let void_fields = Spans.of_list void_field_spans in
  let declaration (lowered, declaration) =
    type_declaration output ~tag_max ~lowered ~void_fields declaration
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
  (* Each matching is numbered in source order, which tells its locals
     apart from those of every other (design 13.5). *)
  let numbered_matchings =
    List.mapi
      (fun number matching -> (number, matching))
      (Typec_sema.Expressions.matchings typed)
  in
  let constructs =
    List.concat_map declaration declarations
    @ List.concat_map (construction output) constructions
    @ List.concat_map (matching output) (List.rev numbered_matchings)
    @ List.concat_map (steered_controlling output) answered
    @ slice_tests
    @ List.concat_map (zero_list output) zero_initialisers
    @ extensions
  in
  let try_holders = Typec_sema.Expressions.try_holders typed in
  let functions = Typec_sema.Expressions.defers typed in
  (* Every edit and move of the text, each copy in them made from
     [lowered]; nothing inside a dropped range is lowered or moves. *)
  let kept_move move =
    not (covers dropped_spans ~first:move.moved.first ~last:move.moved.last)
  in
  let whole_text lowered =
    let defers, return_typedefs =
      defer_edits output lowered ~dropped:dropped_spans functions
    in
    let edits =
      constructs
      @ List.concat_map (slice_making output lowered)
          (Expressions.slice_makings typed)
      @ defers
      @ body_blocks output (return_typedefs @ slice_temporaries)
      @ holder_edits output lowered try_holders
          ~cleanups_of:(error_path_cleanups output lowered functions)
    in
    let moves =
      List.concat_map (holder_moves output) try_holders
      @ defer_moves output functions
    in
    lowered_text
      (List.concat_map (dropped_edits output) dropped
      @ List.filter kept edits)
      (List.filter kept_move moves)
  in
  let rec lowered = lazy (whole_text lowered) in
  text_in_place (Lazy.force lowered)

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
  copy_text output (Lazy.from_val (lowered_text edits [])) Every_move ~first
    ~last
  |> List.map bracketed

(* The generic type's definition under the instance's name, with each
   type parameter and application written as the name that the reading
   found for it, from token [first] to its end. *)
let instance_definition output ~tag_max instance ~first
    (reading : Typec_sema.Declarations.instance_text) =
  match reading.generic with
  | Type_generic generic ->
      let lowered = Typec_sema.Encoding.variant_name (Applied instance) in
      let edits =
        text_edits output ~tag_max
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
  else
    (* It belongs to the token it precedes, which each text of the
       declaration, the prototype and the definition, holds. *)
    [ insert output ~before ~extent:{ first = before; last = before }
        "static" ]

(* The type declarations of the unit: those with no type parameters,
   under their own names, which each text lowers where it holds them,
   and the generic ones, which only their instances write. Those in
   function bodies are among the first, as design 3.1 puts a generic
   one at file scope only. *)
let split_type_declarations declarations =
  let split (declaration : Tree.type_declaration) =
    match declaration.node.type_parameters with
    | [] ->
        Either.Left
          (Spelling.declared declaration.node.name.node, declaration)
    | _ :: _ -> Either.Right declaration
  in
  List.partition_map split
    (Typec_sema.Declarations.type_declarations declarations)

(* What the texts of the placements are written from: the output of the
   unit, what its reading found, and its type declarations with no type
   parameters. *)
type instance_context = {
  output : Emitter.output;
  declarations : Typec_sema.Declarations.t;
  named_types : (Spelling.c_name * Tree.type_declaration) list;
}

let context_tag_max context =
  Typec_sema.Declarations.tag_max context.declarations

(* Design 10.3: each typedef after the lines that declare its tags. *)
let argument_typedefs context location typedefs =
  let lines (typedef : Typec_sema.Declarations.argument_typedef) =
    List.map (fun (tag_line : Typec_sema.Type_name.tag_line) -> tag_line.line)
      typedef.tag_lines
    @ [ typedef.line ]
  in
  List.concat_map lines typedefs
  |> List.map (Emitter.generated context.output location)

(* The type declarations that the definition of a generic function
   holds, which each of its instances declares as the definition does
   (design 3.5 rule 8). *)
let definition_type_declarations context
    (definition : Tree.function_definition) =
  let { first; last } : Tree.span = definition.span in
  let in_definition (_, (declaration : Tree.type_declaration)) =
    first <= declaration.span.first && declaration.span.last <= last
  in
  List.filter in_definition context.named_types

(* Those that the check of the generic function found (design 7.1 rule
   3). *)
let zero_initialisers context definition =
  Typec_sema.Declarations.zero_initialisers context.declarations definition

(* A function instance (design 7.3, 10.3): the generic function's
   definition, without [generic(T)], as a [static] function under the
   instance's name, from its first token to [last], after which [ending]
   follows: the prototype ends before the body. *)
let function_instance context location instance ~last ~ending
    (reading : Typec_sema.Declarations.instance_text)
    (definition : Tree.function_definition) =
  let output = context.output in
  let (Ordinary_at name_token) = definition.node.declared.id in
  let name =
    { span = { first = name_token; last = name_token };
      text = Typec_sema.Encoding.instance_name instance }
  in
  let edits =
    added_static output definition
    @ text_edits output ~tag_max:(context_tag_max context)
        ~declarations:(definition_type_declarations context definition)
        ~void_field_spans:[]
        ~replaced:(name :: List.map named reading.names)
        ~zero_initialisers:(zero_initialisers context definition)
        reading.typed
  in
  generic_text output edits ~first:definition.span.first ~last
  @ List.map (Emitter.generated output location) ending

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
      instance_definition context.output ~tag_max:(context_tag_max context)
        instance ~first:generic.span.first reading

(* Step 1 of a function instance: its prototype, the head of the
   generic's definition. *)
let function_prototype context location instance
    ((definition : Tree.function_definition), reading) =
  let body_first =
    match definition.node.body with
    | Parsed block -> block.span.first
    | Skipped span -> span.first
  in
  function_instance context location instance ~last:(body_first - 1)
    ~ending:[ ";" ] reading definition

(* Step 2: the rest of 10.1 or 10.2, after the forward declaration, or
   the whole definition of a function instance. *)
let instance_rest context location instance =
  let reading = reading context instance in
  match reading.generic with
  | Type_generic generic -> (
      match Tree.forward_declaration_end generic with
      | Some first ->
          instance_definition context.output
            ~tag_max:(context_tag_max context) instance ~first reading
      | None -> invalid_arg "Lowering.instance_rest: a typedef instance")
  | Function_generic { definition; _ } ->
      function_instance context location instance
        ~last:definition.span.last ~ending:[] reading definition

let application_location context
    (placement : Typec_sema.Declarations.placement) =
  (tokens_of context.output).(placement.application.first).location

(* C lets a unit define an instance once, and a header guards each
   definition so that two headers that define one can be included
   together (design 9.3); the rest of the texts may be repeated. *)
let definition_text context instance pieces : Emitter.bracketed_text =
  match Typec_sema.Declarations.product context.declarations with
  | Unit_text -> Unguarded pieces
  | Header_text ->
      Guarded
        { instance = Typec_sema.Encoding.instance_c_name instance; pieces }

(* A header declares each instance with its layout typedef, where its
   step reads the generic defined (design 9.3); a C unit writes none. *)
let layout_typedef context location instance generic =
  let output = context.output in
  let declarations = context.declarations in
  match Typec_sema.Declarations.product declarations with
  | Unit_text -> []
  | Header_text -> (
      match
        Layout.definition_text declarations (Emitter.unit output) generic
      with
      | None -> []
      | Some definition ->
          let name = Typec_sema.Encoding.instance_c_name instance in
          let typedef = Layout.typedef name ~definition in
          [ Emitter.generated output location typedef ])

let placement_text context (placement : Typec_sema.Declarations.placement) :
    Emitter.bracketed_text =
  let location = application_location context placement in
  let instance = placement.instance in
  match placement.step with
  | Typedefs typedefs ->
      Unguarded (argument_typedefs context location typedefs)
  | Declared { generic } ->
      let latest =
        Typec_sema.Declarations.latest_generic context.declarations generic
      in
      Unguarded
        (instance_declaration context location instance generic
        @ layout_typedef context location instance (Type_generic latest))
  | Prototype ->
      let ((_, reading) as definition) = function_definition context instance in
      Unguarded
        (function_prototype context location instance definition
        @ layout_typedef context location instance reading.generic)
  | Defined ->
      definition_text context placement.instance
        (instance_rest context location placement.instance)

(* The texts of the placements at one anchor, in order: those with no
   guard between them are one, so that their pieces of one location share
   a line, and a guard alone parts them. *)
let anchor_texts context run =
  let add earlier placement =
    match (placement_text context placement, earlier) with
    | Unguarded pieces, Emitter.Unguarded before :: rest ->
        Emitter.Unguarded (before @ pieces) :: rest
    | (Unguarded _ | Guarded _) as text, _ -> text :: earlier
  in
  List.rev (List.fold_left add [] run)

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
    let texts = anchor_texts context run in
    Emitter.bracketed context.output ~at ~location texts
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
let unit_edits context ~generic_types =
  let declarations = context.declarations in
  let removed (declaration : Tree.type_declaration) =
    { span = declaration.span; text = "" }
  in
  text_edits context.output ~tag_max:(context_tag_max context)
    ~declarations:context.named_types
    ~void_field_spans:[]
    ~replaced:
      (List.map removed generic_types
      @ generic_functions declarations
      @ List.map named (Typec_sema.Declarations.instance_names declarations))
    ~zero_initialisers:[]
    (Typec_sema.Declarations.typed declarations)

let all_edits output declarations =
  let named_types, generic_types = split_type_declarations declarations in
  let context = { output; declarations; named_types } in
  instance_brackets context @ unit_edits context ~generic_types

(* The product was decided when the declarations were read, so an entry
   given those of the other product is a bug of its caller's. *)
let check_product ~caller product declarations =
  if Typec_sema.Declarations.product declarations <> product then
    invalid_arg (caller ^ ": declarations read for another product")

let edits (text : Reader.t) ~trap declarations =
  check_product ~caller:"Lowering.edits" Typec_sema.Declarations.Unit_text
    declarations;
  Emitter.limited text ~trap (fun output -> all_edits output declarations)

let lowered_header output ~target ~header_module declarations =
  Emitter.header_text output ~target ~header_module
    (all_edits output declarations)

let header_text (text : Reader.t) ~target ~trap ~header_module declarations
    =
  check_product ~caller:"Lowering.header_text"
    Typec_sema.Declarations.Header_text declarations;
  Emitter.limited text ~trap (fun output ->
      lowered_header output ~target ~header_module declarations)

(* The header is written from the lowered text read again, so that the
   writer meets each token it writes as a token. The text is emission's
   own output, so a failure to read it is a bug of typec's. *)
let read_lowered ~source text =
  match Reader.read_interface ~name:source text with
  | Ok read -> read
  | Error error ->
      invalid_arg
        ("Lowering.header: the lowered text of the interface does not \
          read: " ^ Reader.error_message error)

(* The header is written for the output that the lowered text was made
   for, so its lines are charged after the lowered text, to one limit. *)
let header (text : Reader.t) ~target ~trap ~source ~name declarations =
  check_product ~caller:"Lowering.header" Typec_sema.Declarations.Header_text
    declarations;
  let header_module = Header.module_name name in
  let write output =
    lowered_header output ~target ~header_module declarations
    |> read_lowered ~source
    |> Header.write output ~source name
  in
  match Emitter.limited text ~trap write with
  | Ok (Ok header, charged) -> Ok (header, charged)
  | Ok (Error refusal, _) | Error refusal -> Error refusal
