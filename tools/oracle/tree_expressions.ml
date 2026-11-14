(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax
open Tree

let option visit_node visit = Option.iter (visit_node visit)
let list visit_node visit = List.iter (visit_node visit)

let rec expression visit (e : Tree.expression) =
  visit e;
  match e.node with
  | Identifier _ | Constant _ | Character _ | String _ | Label_address _ -> ()
  | Parenthesized operand
  | Post_increment operand
  | Post_decrement operand
  | Unary (_, operand)
  | Sizeof_expression operand
  | Alignof_expression operand ->
      expression visit operand
  | Generic { controlling; associations } ->
      expression visit controlling;
      list generic_association visit associations
  | Compound_literal { type_name = name; values } ->
      type_name visit name;
      initialiser_list visit values
  | Subscript { operand; index } ->
      expression visit operand;
      expression visit index
  | Call { callee; arguments } ->
      expression visit callee;
      list expression visit arguments
  | Member { operand; member = _ } | Pointer_member { operand; member = _ }
    ->
      expression visit operand
  | Sizeof_type name | Alignof name -> type_name visit name
  | Cast { type_name = name; operand } ->
      type_name visit name;
      expression visit operand
  | Binary (_, left, right) | Assignment (_, left, right) | Comma (left, right)
    ->
      expression visit left;
      expression visit right
  | Conditional { condition; if_true; if_false } ->
      expression visit condition;
      option expression visit if_true;
      expression visit if_false
  | Statement_expression body | Block_literal { parameters = None; body } ->
      block visit body
  | Block_literal { parameters = Some list; body } ->
      parameters visit list;
      block visit body
  | Va_arg { list = operand; type_name = name } ->
      expression visit operand;
      type_name visit name
  | Offsetof { type_name = name; member = _; designators } ->
      type_name visit name;
      list designator visit designators
  | Types_compatible (left, right) ->
      type_name visit left;
      type_name visit right
  | Choose { condition; first; second } ->
      expression visit condition;
      expression visit first;
      expression visit second

and generic_association visit (association : generic_association) =
  match association.node with
  | Association (name, value) ->
      type_name visit name;
      expression visit value
  | Default_association value -> expression visit value

and type_name visit (name : type_name) =
  specifiers visit name.node.specifier_qualifiers;
  option declarator visit name.node.abstract

and specifiers visit (list : specifiers) =
  List.iter (fun (specifier : declaration_specifier spanned) ->
      declaration_specifier visit specifier.node)
    list

and declaration_specifier visit = function
  | Storage_class _ | Type_qualifier _ | Function_specifier _ | Attributes _
    ->
      ()
  | Type_specifier specifier -> type_specifier visit specifier
  | Alignment_specifier (Alignas_type name) -> type_name visit name
  | Alignment_specifier (Alignas_expression value) -> expression visit value

and type_specifier visit = function
  | Basic _ | Typedef_name _ -> ()
  | Atomic_type name | Typeof_type name -> type_name visit name
  | Struct_or_union { kind = _; attributes = _; tag = _; members } ->
      option (fun visit (body : _ spanned) ->
          list member_declaration visit body.node) visit members
  | Enum { attributes = _; tag = _; underlying; enumerators } ->
      option specifiers visit underlying;
      option (list enumerator) visit enumerators
  | Typeof_expression value -> expression visit value

and member_declaration visit (member : member_declaration) =
  match member.node with
  | Members { specifiers = member_specifiers; declarators } ->
      specifiers visit member_specifiers;
      list member_declarator visit declarators
  | Member_static_assert assertion -> static_assertion visit assertion

and member_declarator visit (member : member_declarator) =
  match member.node with
  | Field { declarator = field; attributes = _ } -> declarator visit field
  | Bit_field { declarator = field; width; attributes = _ } ->
      option declarator visit field;
      expression visit width

and enumerator visit (constant : enumerator) =
  option expression visit constant.node.value

and declarator visit (d : declarator) =
  match d.node with
  | Name _ -> ()
  | Parenthesized_declarator { attributes = _; inner } ->
      declarator visit inner
  | Pointer { qualifiers = _; attributes = _; inner }
  | Block_pointer { qualifiers = _; attributes = _; inner } ->
      option declarator visit inner
  | Array { inner; qualifiers = _; size } ->
      option declarator visit inner;
      array_size visit size
  | Function { inner; parameters = list } ->
      option declarator visit inner;
      parameters visit list

and array_size visit = function
  | Unsized | Unspecified_variable -> ()
  | Sized length | Static_sized length -> expression visit length

and parameters visit = function
  | Prototype { parameters = list; variadic = _ } ->
      List.iter (parameter visit) list
  | Identifier_list _ -> ()

and parameter visit (p : parameter) =
  specifiers visit p.node.specifiers;
  match p.node.declarator with
  | Named_parameter { declarator = named; declared = _ } ->
      declarator visit named
  | Abstract_parameter abstract -> option declarator visit abstract

and initialiser visit = function
  | Expression_initialiser value -> expression visit value
  | Braced values -> initialiser_list visit values

and initialiser_list visit (values : initialiser_list) =
  List.iter (designated_initialiser visit) values.node

and designated_initialiser visit (value : designated_initialiser) =
  list designator visit value.node.designators;
  initialiser visit value.node.initialiser

and designator visit (d : designator) =
  match d.node with
  | Index index -> expression visit index
  | Index_range { low; high } ->
      expression visit low;
      expression visit high
  | Member_designator _ -> ()

and static_assertion visit assertion = expression visit assertion.condition

and init_declarator visit (d : init_declarator) =
  declarator visit d.node.declarator;
  option initialiser visit d.node.initialiser

and declaration visit (d : declaration) =
  match d.node with
  | Declaration { specifiers = declared; declarators } ->
      specifiers visit declared;
      list init_declarator visit declarators
  | Static_assert assertion -> static_assertion visit assertion

and statement visit (s : statement) =
  match s.node with
  | Labeled { label = l; statement = labeled } ->
      label visit l;
      statement visit labeled
  | Compound body -> block visit body
  | Expression_statement value | Computed_goto value | Return (Some value) ->
      expression visit value
  | Null_statement | Attribute_statement _ | Goto _ | Continue | Break
  | Return None ->
      ()
  | If { condition; then_branch; else_branch } ->
      expression visit condition;
      statement visit then_branch;
      option statement visit else_branch
  | Switch { controlling = condition; body }
  | While { condition; body }
  | Do { body; condition } ->
      expression visit condition;
      statement visit body
  | For { clause; condition; step; body } ->
      option for_clause visit clause;
      option expression visit condition;
      option expression visit step;
      statement visit body
  | Asm code -> assembler visit code

and label visit (l : label) =
  match l.node with
  | Named_label _ | Default_label -> ()
  | Case_label value -> expression visit value
  | Case_range { low; high } ->
      expression visit low;
      expression visit high

and block visit (b : block) =
  List.iter
    (function
      | Block_declaration d -> declaration visit d
      | Block_type_declaration d -> type_declaration visit d
      | Block_statement s -> statement visit s)
    b.node.items

and type_declaration visit (d : type_declaration) =
  match d.node.definition with
  | Incomplete_variant -> ()
  | Alias name -> type_name visit name
  | Record_alias specifier ->
      type_specifier visit (Struct_or_union specifier.node)

and for_clause visit = function
  | Clause_declaration d -> declaration visit d
  | Clause_expression value -> expression visit value

and assembler visit code =
  Option.iter
    (fun operands ->
      List.iter
        (fun (operand : asm_operand) -> expression visit operand.node.value)
        (operands.outputs @ operands.inputs))
    code.operands

let function_definition visit (definition : function_definition) =
  specifiers visit definition.node.specifiers;
  declarator visit definition.node.declarator;
  list declaration visit definition.node.declarations;
  match definition.node.body with
  | Parsed body -> block visit body
  | Skipped _ -> ()

let external_declaration visit = function
  | External_declaration d -> declaration visit d
  | Type_declaration d -> type_declaration visit d
  | Function_definition definition -> function_definition visit definition
  | Top_level_asm code -> assembler visit code.node
  | Empty_declaration _ -> ()

let iter visit unit = List.iter (external_declaration visit) unit
