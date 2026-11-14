(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A structural dump of a syntax tree for tests: an s-expression of the
   nodes, never C text (design 13.4), and a check of the spans that every
   dumped tree passes through. *)

open Typec_cpp
open Typec_syntax
open Tree

(* A node of the dump: a label, the span of the tree node it shows, if
   it shows one, and its parts in source order. *)
type sexp = { label : string; span : span option; parts : sexp list }

let node span label parts = { label; span = Some span; parts }
let leaf label = { label; span = None; parts = [] }
let group parts = { label = ""; span = None; parts }

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

let unary_label = function
  | Address -> "&"
  | Indirection -> "*"
  | Unary_plus -> "+"
  | Unary_minus -> "-"
  | Bitwise_not -> "~"
  | Logical_not -> "!"
  | Pre_increment -> "++"
  | Pre_decrement -> "--"

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

let rec expression reader (e : expression) =
  let here = node e.span in
  let sub = expression reader in
  match e.node with
  | Identifier name -> here name []
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
  | Cast { type_name = t; operand } ->
      here "cast" [ type_name reader t; sub operand ]
  | Binary (operator, left, right) ->
      here (binary_label operator) [ sub left; sub right ]
  | Conditional { condition; if_true; if_false } ->
      here "?:" [ sub condition; sub if_true; sub if_false ]
  | Assignment (operator, left, right) ->
      here (assignment_label operator) [ sub left; sub right ]
  | Comma (left, right) -> here "," [ sub left; sub right ]

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
  | Type_specifier (Basic basic) -> here (basic_label basic) []
  | Type_specifier (Typedef_name name) -> here name []
  | Type_specifier (Atomic_type t) -> here "atomic" [ type_name reader t ]
  | Type_specifier (Struct_or_union { kind; tag; members }) ->
      let label = match kind with Struct -> "struct" | Union -> "union" in
      here label
        (Option.to_list (Option.map identifier tag)
        @ List.map (member reader) (Option.value members ~default:[]))
  | Type_specifier (Enum { tag; enumerators }) ->
      here "enum"
        (Option.to_list (Option.map identifier tag)
        @ List.map (enumerator reader) (Option.value enumerators ~default:[]))

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
  | Field inner -> declarator reader inner
  | Bit_field { declarator = inner; width } ->
      node d.span "bits"
        (Option.to_list (Option.map (declarator reader) inner)
        @ [ expression reader width ])

and enumerator reader (e : enumerator) =
  node e.span e.node.name.node
    (Option.to_list (Option.map (expression reader) e.node.value))

and declarator reader (d : declarator) =
  let here = node d.span in
  let inner_part inner =
    Option.to_list (Option.map (declarator reader) inner)
  in
  match d.node with
  | Name name -> here name []
  | Parenthesized_declarator inner -> here "paren" [ declarator reader inner ]
  | Pointer { qualifiers = list; inner } ->
      here "pointer" (qualifiers list @ inner_part inner)
  | Array { inner; qualifiers = list; size } ->
      here "array" (inner_part inner @ qualifiers list @ array_size reader size)
  | Function { inner; parameters = Prototype { parameters; variadic } } ->
      here "function"
        (inner_part inner
        @ List.map (parameter reader) parameters
        @ if variadic then [ leaf "..." ] else [])
  | Function { inner; parameters = Identifier_list names } ->
      here "function"
        (inner_part inner
        @ [ group (leaf "identifiers" :: List.map identifier names) ])

and array_size reader = function
  | Unsized -> []
  | Sized e -> [ expression reader e ]
  | Static_sized e -> [ leaf "static"; expression reader e ]
  | Unspecified_variable -> [ leaf "*" ]

and parameter reader (p : parameter) =
  node p.span ""
    (specifiers reader p.node.specifiers
    @ Option.to_list (Option.map (declarator reader) p.node.declarator))

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
  | Member_designator name -> node d.span ("." ^ name.node) []

and static_assertion reader { condition; message } =
  [ expression reader condition; group (string_literal reader message) ]

let init_declarator reader (d : init_declarator) =
  match d.node.initialiser with
  | None -> declarator reader d.node.declarator
  | Some value ->
      node d.span "init"
        [ declarator reader d.node.declarator; initialiser reader value ]

let external_declaration reader = function
  | External_declaration { span; node = Static_assert assertion } ->
      node span "static-assert" (static_assertion reader assertion)
  | External_declaration
      { span; node = Declaration { specifiers = list; declarators } } ->
      node span "declaration"
        (group (specifiers reader list)
        :: List.map (init_declarator reader) declarators)
  | Function_definition { span; node = definition } ->
      node span "define"
        [
          group (specifiers reader definition.specifiers);
          declarator reader definition.declarator;
          node definition.body "{...}" [];
        ]

let translation_unit reader unit = List.map (external_declaration reader) unit
