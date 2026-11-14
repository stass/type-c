(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A structural dump of a syntax tree for tests: an s-expression of the
   nodes, never C text (design 13.4), a check of the spans that every
   dumped tree passes through, and the declarations and uses of names
   that the parser's scope rules recorded. *)

open Typec_cpp
open Typec_syntax
open Tree

type name_space = Ordinary | Tag

(* What an entry names: the token of a declaration in the tree, or a
   typedef name that GCC and Clang declare, in either name space. *)
type target = Token of int | Builtin_target

(* A declaration or a use of a name that a dump node shows, which only
   [resolutions] prints. A use of no declaration has no [target]. *)
type scope_entry =
  | Declaration_entry of {
      space : name_space;
      name : string;
      token : int;
      earlier : target option;
    }
  | Use_entry of { space : name_space; name : string; target : target option }

(* A node of the dump: a label, the span of the tree node it shows, if
   it shows one, its scope entry, and its parts in source order. *)
type sexp = {
  label : string;
  span : span option;
  entry : scope_entry option;
  parts : sexp list;
}

let node span label parts = { label; span = Some span; entry = None; parts }
let leaf label = { label; span = None; entry = None; parts = [] }
let group parts = { label = ""; span = None; entry = None; parts }
let section label parts = { label; span = None; entry = None; parts }
let noted entry sexp = { sexp with entry = Some entry }

let ordinary_target = function
  | In_tree (Ordinary_at token) -> Token token
  | Builtin _ -> Builtin_target

let tag_target (Tag_at token) = Token token

let declaration_entry name ({ id = Ordinary_at token; earlier } : declared) =
  Declaration_entry
    { space = Ordinary; name; token;
      earlier = Option.map ordinary_target earlier }

let use_entry name resolution =
  let target =
    match resolution with
    | Resolved reference -> Some (ordinary_target reference)
    | Undeclared -> None
  in
  Use_entry { space = Ordinary; name; target }

let rec to_string ~spans sexp =
  let head =
    match sexp.span with
    | Some { first; last } when spans ->
        Printf.sprintf "%s@%d-%d" sexp.label first last
    | Some _ | None -> sexp.label
  in
  match sexp.parts with
  | [] -> head
  | parts ->
      let parts = List.map (to_string ~spans) parts in
      let items = if head = "" then parts else head :: parts in
      "(" ^ String.concat " " items ^ ")"

(* The tokens a dump node covers: its span, or those of its parts. *)
let rec extent sexp =
  match sexp.span with
  | Some span -> Some span
  | None ->
      List.fold_left
        (fun covered part ->
          match (covered, extent part) with
          | None, part_extent -> part_extent
          | Some covered, None -> Some covered
          | Some covered, Some part ->
              Some
                {
                  first = min covered.first part.first;
                  last = max covered.last part.last;
                })
        None sexp.parts

(* The first node whose span is empty, or whose parts are not in order
   within it. *)
let rec span_violation sexp =
  let describe reason = Some (to_string ~spans:true sexp ^ ": " ^ reason) in
  let within span part =
    match extent part with
    | None -> true
    | Some inner -> span.first <= inner.first && inner.last <= span.last
  in
  let rec ordered previous = function
    | [] -> true
    | part :: rest -> (
        match (previous, extent part) with
        | Some previous, Some current when previous.last >= current.first ->
            false
        | _, Some current -> ordered (Some current) rest
        | _, None -> ordered previous rest)
  in
  match sexp.span with
  | Some span when span.first > span.last -> describe "empty span"
  | Some span when not (List.for_all (within span) sexp.parts) ->
      describe "a part outside the span"
  | Some _ | None when not (ordered None sexp.parts) ->
      describe "parts out of order"
  | Some _ | None -> List.find_map span_violation sexp.parts

let spelling (reader : Reader.t) index =
  Reader.spelling reader reader.tokens.(index)

let identifier (name : identifier) = node name.span name.node []

let storage_class_label = function
  | Typedef -> "typedef"
  | Extern -> "extern"
  | Static -> "static"
  | Thread_local -> "_Thread_local"
  | Auto -> "auto"
  | Register -> "register"

let qualifier_label = function
  | Const -> "const"
  | Restrict -> "restrict"
  | Volatile -> "volatile"
  | Atomic -> "_Atomic"
  | Nullability Nonnull -> "_Nonnull"
  | Nullability Nullable -> "_Nullable"
  | Nullability Nullable_result -> "_Nullable_result"
  | Nullability Null_unspecified -> "_Null_unspecified"

let basic_label = function
  | Void -> "void"
  | Char -> "char"
  | Short -> "short"
  | Int -> "int"
  | Long -> "long"
  | Float -> "float"
  | Double -> "double"
  | Signed -> "signed"
  | Unsigned -> "unsigned"
  | Bool -> "_Bool"
  | Complex -> "_Complex"
  | Int128 -> "__int128"
  | Optional_float optional -> Optional_float.spelling optional

let unary_label = function
  | Address -> "&"
  | Indirection -> "*"
  | Unary_plus -> "+"
  | Unary_minus -> "-"
  | Bitwise_not -> "~"
  | Logical_not -> "!"
  | Pre_increment -> "++"
  | Pre_decrement -> "--"
  | Real_part -> "__real__"
  | Imaginary_part -> "__imag__"

let binary_label = function
  | Multiply -> "*"
  | Divide -> "/"
  | Remainder -> "%"
  | Add -> "+"
  | Subtract -> "-"
  | Shift_left -> "<<"
  | Shift_right -> ">>"
  | Less_than -> "<"
  | Greater_than -> ">"
  | Less_or_equal -> "<="
  | Greater_or_equal -> ">="
  | Equal_to -> "=="
  | Not_equal_to -> "!="
  | Bitwise_and -> "&"
  | Bitwise_xor -> "^"
  | Bitwise_or -> "|"
  | Logical_and -> "&&"
  | Logical_or -> "||"

let assignment_label = function
  | Assign -> "="
  | Compound_assign operator -> binary_label operator ^ "="

let qualifiers list =
  List.map (fun (q : type_qualifier spanned) ->
      node q.span (qualifier_label q.node) [])
    list

let string_literal reader pieces =
  List.map
    (fun (piece : Token.encoding spanned) ->
      node piece.span (spelling reader piece.span.first) [])
    pieces

(* The parts in the order of their tokens, for a node whose fields do not
   follow the source, such as the attributes of a structure, which come
   before its tag and after its body. *)
let in_source_order parts =
  let first part =
    match extent part with Some span -> span.first | None -> max_int
  in
  List.stable_sort (fun a b -> compare (first a) (first b)) parts

(* An attribute's arguments are shown as their tokens. *)
let attribute reader (a : attribute) =
  let arguments { first; last } =
    let spellings = List.init (last - first + 1) (fun i -> first + i) in
    node { first; last }
      (String.concat " " (List.map (spelling reader) spellings))
      []
  in
  node a.span a.node.name.node
    (Option.to_list (Option.map arguments a.node.arguments))

(* One attribute among parts that it may come before or after. *)
let single_attribute reader a =
  section "attribute" [ attribute reader a ]

let attribute_group reader = function
  | [] -> []
  | attributes ->
      [ section "attributes" (List.map (attribute reader) attributes) ]

let asm_qualifier_label = function
  | Asm_volatile -> "volatile"
  | Asm_inline -> "inline"
  | Asm_goto -> "goto"

(* An absent part of a statement, so that the parts keep their places. *)
let absent = leaf "_"

let optional dump = function Some part -> dump part | None -> absent

let rec expression reader (e : expression) =
  let here = node e.span in
  let sub = expression reader in
  match e.node with
  | Identifier { name; resolution } ->
      noted (use_entry name resolution) (here name [])
  | Constant _ | Character _ -> here (spelling reader e.span.first) []
  | String pieces -> here "string" (string_literal reader pieces)
  | Parenthesized inner -> here "paren" [ sub inner ]
  | Generic { controlling; associations } ->
      here "generic"
        (sub controlling :: List.map (association reader) associations)
  | Compound_literal { type_name = t; values } ->
      here "literal" [ type_name reader t; initialiser_list reader values ]
  | Subscript { operand; index } -> here "index" [ sub operand; sub index ]
  | Call { callee; arguments } ->
      here "call" (sub callee :: List.map sub arguments)
  | Member { operand; member } -> here "." [ sub operand; identifier member ]
  | Pointer_member { operand; member } ->
      here "->" [ sub operand; identifier member ]
  | Post_increment operand -> here "post++" [ sub operand ]
  | Post_decrement operand -> here "post--" [ sub operand ]
  | Unary (operator, operand) -> here (unary_label operator) [ sub operand ]
  | Sizeof_expression operand -> here "sizeof" [ sub operand ]
  | Sizeof_type t -> here "sizeof-type" [ type_name reader t ]
  | Alignof t -> here "alignof" [ type_name reader t ]
  | Alignof_expression operand -> here "alignof-expression" [ sub operand ]
  | Cast { type_name = t; operand } ->
      here "cast" [ type_name reader t; sub operand ]
  | Binary (operator, left, right) ->
      here (binary_label operator) [ sub left; sub right ]
  | Conditional { condition; if_true; if_false } ->
      here "?:" [ sub condition; optional sub if_true; sub if_false ]
  | Assignment (operator, left, right) ->
      here (assignment_label operator) [ sub left; sub right ]
  | Comma (left, right) -> here "," [ sub left; sub right ]
  | Statement_expression body -> here "({})" [ block reader body ]
  | Label_address label -> here "label-address" [ identifier label ]
  | Va_arg { list; type_name = t } ->
      here "va_arg" [ sub list; type_name reader t ]
  | Offsetof { type_name = t; member; designators } ->
      here "offsetof"
        (type_name reader t :: identifier member
        :: List.map (designator reader) designators)
  | Types_compatible (first, second) ->
      here "types-compatible"
        [ type_name reader first; type_name reader second ]
  | Choose { condition; first; second } ->
      here "choose" [ sub condition; sub first; sub second ]
  | Block_literal { parameters = list; body } ->
      here "block-literal"
        (Option.fold ~none:[] ~some:(parameters reader) list
        @ [ block reader body ])

and association reader (a : generic_association) =
  match a.node with
  | Association (t, value) ->
      node a.span "case" [ type_name reader t; expression reader value ]
  | Default_association value ->
      node a.span "default" [ expression reader value ]

and type_name reader (t : type_name) =
  node t.span "type"
    (specifiers reader t.node.specifier_qualifiers
    @ Option.to_list (Option.map (declarator reader) t.node.abstract))

and specifiers reader list = List.map (specifier reader) list

and specifier reader (s : declaration_specifier spanned) =
  let here = node s.span in
  match s.node with
  | Storage_class storage_class -> here (storage_class_label storage_class) []
  | Type_qualifier qualifier -> here (qualifier_label qualifier) []
  | Function_specifier Inline -> here "inline" []
  | Function_specifier Noreturn -> here "_Noreturn" []
  | Alignment_specifier (Alignas_type t) ->
      here "alignas" [ type_name reader t ]
  | Alignment_specifier (Alignas_expression e) ->
      here "alignas" [ expression reader e ]
  | Attributes list -> here "attributes" (List.map (attribute reader) list)
  | Type_specifier (Basic basic) -> here (basic_label basic) []
  | Type_specifier (Typedef_name { name; declaration }) ->
      noted (use_entry name (Resolved declaration)) (here name [])
  | Type_specifier (Atomic_type t) -> here "atomic" [ type_name reader t ]
  | Type_specifier (Typeof_expression e) ->
      here "typeof" [ expression reader e ]
  | Type_specifier (Typeof_type t) -> here "typeof" [ type_name reader t ]
  | Type_specifier (Struct_or_union specifier) ->
      specifier_dump reader here ~claimed:[] specifier
  | Type_specifier (Enum { attributes; tag; underlying; enumerators }) ->
      let underlying_part list =
        section ":" (specifiers reader list)
      in
      here "enum"
        (in_source_order
           (Option.to_list (Option.map tag_part tag)
           @ Option.to_list (Option.map underlying_part underlying)
           @ List.map (enumerator reader)
               (Option.value enumerators ~default:[])
           @ List.map (single_attribute reader) attributes))

(* [claimed] is the part of a tag that a type declaration claims for the
   specifier, which comes first. *)
and specifier_dump reader here ~claimed
    ({ kind; attributes; tag; members } : record_specifier) =
  let label = match kind with Struct -> "struct" | Union -> "union" in
  let body =
    match members with
    | None -> []
    | Some { node = []; _ } -> [ leaf "{}" ]
    | Some { node = members; _ } -> List.map (member reader) members
  in
  here label
    (claimed
    @ in_source_order
        (Option.to_list (Option.map tag_part tag)
        @ body
        @ List.map (single_attribute reader) attributes))

and tag_part (tag : tag) =
  let name = tag.name.node in
  let entry =
    match tag.binding with
    | Declares { id = Tag_at token; earlier } ->
        Declaration_entry
          { space = Tag; name; token; earlier = Option.map tag_target earlier }
    | Names id ->
        Use_entry { space = Tag; name; target = Some (tag_target id) }
  in
  noted entry (identifier tag.name)

and member reader (m : member_declaration) =
  match m.node with
  | Members { specifiers = list; declarators } ->
      node m.span "member"
        (group (specifiers reader list)
        :: List.map (member_declarator reader) declarators)
  | Member_static_assert assertion ->
      node m.span "static-assert" (static_assertion reader assertion)

and member_declarator reader (d : member_declarator) =
  match d.node with
  | Field { declarator = inner; attributes = [] } -> declarator reader inner
  | Field { declarator = inner; attributes } ->
      node d.span "field"
        (declarator reader inner :: attribute_group reader attributes)
  | Bit_field { declarator = inner; width; attributes } ->
      node d.span "bits"
        (Option.to_list (Option.map (declarator reader) inner)
        @ (expression reader width :: attribute_group reader attributes))

and enumerator reader (e : enumerator) =
  let name = e.node.name.node in
  noted
    (declaration_entry name e.node.declared)
    (node e.span name
       (attribute_group reader e.node.attributes
       @ Option.to_list (Option.map (expression reader) e.node.value)))

and declarator reader (d : declarator) =
  let here = node d.span in
  let inner_part inner =
    Option.to_list (Option.map (declarator reader) inner)
  in
  match d.node with
  | Name name -> here name []
  | Parenthesized_declarator { attributes; inner } ->
      here "paren"
        (attribute_group reader attributes @ [ declarator reader inner ])
  | Pointer { qualifiers = list; attributes; inner } ->
      here "pointer"
        (pointer_qualifiers reader list attributes @ inner_part inner)
  | Block_pointer { qualifiers = list; attributes; inner } ->
      here "block-pointer"
        (pointer_qualifiers reader list attributes @ inner_part inner)
  | Array { inner; qualifiers = list; size } ->
      here "array" (inner_part inner @ qualifiers list @ array_size reader size)
  | Function { inner; parameters = list } ->
      here "function" (inner_part inner @ parameters reader list)

(* The qualifiers of a pointer and the attributes among them, one by
   one, so that they keep their order. *)
and pointer_qualifiers reader list attributes =
  in_source_order
    (qualifiers list @ List.map (single_attribute reader) attributes)

and parameters reader = function
  | Prototype { parameters; variadic } ->
      List.map (parameter reader) parameters
      @ if variadic then [ leaf "..." ] else []
  | Identifier_list names ->
      let name (listed : parameter_name) =
        noted
          (declaration_entry listed.name.node listed.declared)
          (identifier listed.name)
      in
      [ group (leaf "identifiers" :: List.map name names) ]

and array_size reader = function
  | Unsized -> []
  | Sized e -> [ expression reader e ]
  | Static_sized e -> [ leaf "static"; expression reader e ]
  | Unspecified_variable -> [ leaf "*" ]

and parameter reader (p : parameter) =
  let dump inner =
    node p.span ""
      (specifiers reader p.node.specifiers
      @ Option.to_list inner
      @ attribute_group reader p.node.attributes)
  in
  match p.node.declarator with
  | Named_parameter { declarator = inner; declared } ->
      dump (Some (declared_declarator reader inner declared))
  | Abstract_parameter inner -> dump (Option.map (declarator reader) inner)

(* A named declarator with the entry of its declaration, which keeps
   source order: nothing in a declarator before its name declares or
   uses a name. *)
and declared_declarator reader inner declared =
  let name = Option.value (declared_name inner) ~default:"(no name)" in
  noted (declaration_entry name declared) (declarator reader inner)

and initialiser reader = function
  | Expression_initialiser e -> expression reader e
  | Braced list -> initialiser_list reader list

and initialiser_list reader (list : initialiser_list) =
  node list.span "{}" (List.map (designated_initialiser reader) list.node)

and designated_initialiser reader (d : designated_initialiser) =
  match d.node.designators with
  | [] -> initialiser reader d.node.initialiser
  | designators ->
      node d.span "designate"
        (List.map (designator reader) designators
        @ [ initialiser reader d.node.initialiser ])

and designator reader (d : designator) =
  match d.node with
  | Index index -> node d.span "[]" [ expression reader index ]
  | Index_range { low; high } ->
      node d.span "[...]" [ expression reader low; expression reader high ]
  | Member_designator name -> node d.span ("." ^ name.node) []

and static_assertion reader { condition; message } =
  [ expression reader condition; group (string_literal reader message) ]

(* A declarator with nothing around it is shown alone; one with an
   initialiser as [init], and one with only an asm label or attributes as
   [declarator]. The attributes before it and after it are two groups. *)
and init_declarator reader (d : init_declarator) =
  let inner = d.node.declarator in
  let before (a : attribute) = a.span.last < inner.span.first in
  let leading, trailing = List.partition before d.node.attributes in
  let around =
    attribute_group reader leading
    @ (declared_declarator reader inner d.node.declared
      :: Option.to_list
           (Option.map
              (fun label -> section "asm" (string_literal reader label))
              d.node.asm_label))
    @ attribute_group reader trailing
  in
  match (d.node.initialiser, around) with
  | None, [ alone ] -> alone
  | None, around -> node d.span "declarator" around
  | Some value, around ->
      node d.span "init" (around @ [ initialiser reader value ])

and declaration reader (d : declaration) =
  match d.node with
  | Static_assert assertion ->
      node d.span "static-assert" (static_assertion reader assertion)
  | Declaration { specifiers = list; declarators } ->
      node d.span "declaration"
        (group (specifiers reader list)
        :: List.map (init_declarator reader) declarators)

and label reader (l : label) =
  match l.node with
  | Named_label { name; attributes } ->
      node l.span name (attribute_group reader attributes)
  | Case_label value -> node l.span "case" [ expression reader value ]
  | Case_range { low; high } ->
      node l.span "case-range"
        [ expression reader low; expression reader high ]
  | Default_label -> node l.span "default" []

and for_clause reader = function
  | Clause_declaration d -> declaration reader d
  | Clause_expression e -> expression reader e

and statement reader (s : statement) =
  let here = node s.span in
  let sub = statement reader in
  let value = expression reader in
  match s.node with
  | Labeled { label = l; statement = inner } ->
      here "label" [ label reader l; sub inner ]
  | Compound body -> block reader body
  | Expression_statement e -> here "expr" [ value e ]
  | Null_statement -> here ";" []
  | Attribute_statement attributes ->
      here "attribute-statement" (List.map (attribute reader) attributes)
  | If { condition; then_branch; else_branch } ->
      here "if" [ value condition; sub then_branch; optional sub else_branch ]
  | Switch { controlling; body } ->
      here "switch" [ value controlling; sub body ]
  | While { condition; body } -> here "while" [ value condition; sub body ]
  | Do { body; condition } -> here "do" [ sub body; value condition ]
  | For { clause; condition; step; body } ->
      here "for"
        [
          optional (for_clause reader) clause;
          optional value condition;
          optional value step;
          sub body;
        ]
  | Goto target -> here "goto" [ identifier target ]
  | Computed_goto target -> here "goto*" [ value target ]
  | Continue -> here "continue" []
  | Break -> here "break" []
  | Return e -> here "return" (Option.to_list (Option.map value e))
  | Asm a -> here "asm" (assembler reader a)

and block reader (b : block) =
  node b.span "block"
    (List.map local_labels b.node.local_labels
    @ List.map (block_item reader) b.node.items)

and local_labels (d : local_label_declaration) =
  node d.span "__label__" (List.map identifier d.node)

and block_item reader = function
  | Block_declaration d -> declaration reader d
  | Block_type_declaration d -> type_declaration reader d
  | Block_statement s -> statement reader s

(* A type declaration as [(type N definition)]; the tag that it claims
   is a [claims] part, whose entry is a declaration in the tag space. *)
and type_declaration reader (d : type_declaration) =
  let { name; declared; definition } = d.node in
  let declared_name =
    noted (declaration_entry name.node declared) (identifier name)
  in
  let (Tag_at token) = claimed_tag name in
  let claim =
    noted
      (Declaration_entry
         { space = Tag; name = name.node; token; earlier = None })
      (leaf "claims")
  in
  let parts =
    match definition with
    | Incomplete_variant -> [ claim ]
    | Alias t -> [ type_name reader t ]
    | Record_alias { span; node = specifier } ->
        let claimed = if specifier.tag = None then [ claim ] else [] in
        [ specifier_dump reader (node span) ~claimed specifier ]
  in
  node d.span "type" (declared_name :: parts)

(* The qualifiers, the template and, for extended assembler, its four
   sections. *)
and assembler reader (a : assembler) =
  let qualifier (q : asm_qualifier spanned) =
    node q.span (asm_qualifier_label q.node) []
  in
  let symbolic_name (name : identifier) =
    node name.span ("[" ^ name.node ^ "]") []
  in
  let operand (o : asm_operand) =
    node o.span "operand"
      (Option.to_list (Option.map symbolic_name o.node.symbolic_name)
      @ [
          group (string_literal reader o.node.constraint_);
          expression reader o.node.value;
        ])
  in
  let operands = function
    | None -> []
    | Some { outputs; inputs; clobbers; labels } ->
        [
          section "outputs" (List.map operand outputs);
          section "inputs" (List.map operand inputs);
          section "clobbers"
            (List.map (fun c -> group (string_literal reader c)) clobbers);
          section "labels" (List.map identifier labels);
        ]
  in
  List.map qualifier a.qualifiers
  @ (group (string_literal reader a.template) :: operands a.operands)

let function_body reader = function
  | Parsed body -> block reader body
  | Skipped span -> node span "{...}" []

let external_declaration reader = function
  | External_declaration d -> declaration reader d
  | Type_declaration d -> type_declaration reader d
  | Function_definition { span; node = definition } ->
      node span "define"
        ([
           group (specifiers reader definition.specifiers);
           declared_declarator reader definition.declarator
             definition.declared;
         ]
        @ attribute_group reader definition.attributes
        @ List.map (declaration reader) definition.declarations
        @ [ function_body reader definition.body ])
  | Top_level_asm { span; node = a } -> node span "asm" (assembler reader a)
  | Empty_declaration span -> node span ";" []

let translation_unit reader unit = List.map (external_declaration reader) unit

(* The scope entries of a dump in source order: a declaration as [x#n],
   [n] counting the declarations of [x] in its name space in token order,
   with [<#m] after it where it redeclares [x#m]; a use as [x->#n], or
   [x->?] where it resolves to no declaration and [x->builtin] where it
   resolves to a typedef name that GCC and Clang declare. A tag's entry
   begins with [tag]. *)
let resolutions dump =
  let rec entries sexp =
    Option.to_list sexp.entry @ List.concat_map entries sexp.parts
  in
  let all = List.concat_map entries dump in
  let declared_ids space name =
    List.filter_map
      (function
        | Declaration_entry entry when entry.space = space && entry.name = name
          ->
            Some entry.token
        | Declaration_entry _ | Use_entry _ -> None)
      all
    |> List.sort compare
  in
  let reference space name = function
    | Builtin_target -> "builtin"
    | Token token -> (
        let rec position index = function
          | [] -> None
          | declared :: _ when declared = token -> Some index
          | _ :: rest -> position (index + 1) rest
        in
        match position 1 (declared_ids space name) with
        | Some index -> "#" ^ string_of_int index
        | None -> "#unknown")
  in
  let prefix = function Ordinary -> "" | Tag -> "tag " in
  let show = function
    | Declaration_entry { space; name; token; earlier } ->
        let earlier =
          match earlier with
          | None -> ""
          | Some earlier -> "<" ^ reference space name earlier
        in
        prefix space ^ name ^ reference space name (Token token) ^ earlier
    | Use_entry { space; name; target } ->
        let target =
          match target with
          | Some target -> reference space name target
          | None -> "?"
        in
        prefix space ^ name ^ "->" ^ target
  in
  String.concat " " (List.map show all)
