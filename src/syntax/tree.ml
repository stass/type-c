(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The syntax tree of a translation unit: the declarations, expressions
    and statements of C11 (6.5, 6.7, 6.8, 6.9) and of the GNU profile
    (design 13.3). The body of a function that a system header defines is
    a span of tokens.

    Every node is {!spanned}: it records the tokens it was parsed from,
    which emission copies when it leaves the node untouched (design 13.4).
    The tree holds what the grammar decides and nothing the tokens already
    say: the spelling of a constant or a string is read from its span. *)

open Typec_cpp

(** Tokens [first] to [last] of [Reader.t.tokens], with [first <= last].
    Neither end is a pragma token; pragma tokens between the ends belong
    to the node. *)
type span = { first : int; last : int }

type 'a spanned = { span : span; node : 'a }
type identifier = string spanned

(** A GNU attribute: its name, without the [__] around it that GCC allows
    ([__packed__] is [packed]), and the span of its arguments from [(] to
    [)], which the parser does not read: their grammar depends on the
    attribute. *)
type attribute = attribute_node spanned

and attribute_node = { name : identifier; arguments : span option }

(** C11 6.7.1. *)
type storage_class = Typedef | Extern | Static | Thread_local | Auto | Register

(** Clang's nullability qualifiers of a pointer type, which the macOS SDK
    writes where C11 writes type qualifiers. *)
type nullability = Nonnull | Nullable | Nullable_result | Null_unspecified

(** C11 6.7.3. [Atomic] is [_Atomic] not followed by [(] (6.7.2.4p4). *)
type type_qualifier =
  | Const
  | Restrict
  | Volatile
  | Atomic
  | Nullability of nullability

(** C11 6.7.4. *)
type function_specifier = Inline | Noreturn

(** The type specifiers of C11 6.7.2 that are one keyword. A list of them
    is a multiset (6.7.2p2) that the types interpret. *)
type basic_type_specifier =
  | Void
  | Char
  | Short
  | Int
  | Long
  | Float
  | Double
  | Signed
  | Unsigned
  | Bool
  | Complex
  | Float16  (** [_Float16] (ISO/IEC TS 18661-3), which the SDK uses *)

type struct_or_union = Struct | Union

(** C11 6.5.3, and the prefix [++] and [--] of 6.5.3.1. *)
type unary_operator =
  | Address
  | Indirection
  | Unary_plus
  | Unary_minus
  | Bitwise_not
  | Logical_not
  | Pre_increment
  | Pre_decrement

(** C11 6.5.5 to 6.5.14. *)
type binary_operator =
  | Multiply
  | Divide
  | Remainder
  | Add
  | Subtract
  | Shift_left
  | Shift_right
  | Less_than
  | Greater_than
  | Less_or_equal
  | Greater_or_equal
  | Equal_to
  | Not_equal_to
  | Bitwise_and
  | Bitwise_xor
  | Bitwise_or
  | Logical_and
  | Logical_or

(** C11 6.5.16. [Compound_assign op] is [op=], which the parser makes only
    for the multiplicative, additive, shift and bitwise operators. *)
type assignment_operator = Assign | Compound_assign of binary_operator

(* Statement expressions make expressions, declarations and statements one
   recursive group, whose records share field names such as [declarator]
   and [attributes]. Each use is disambiguated by its type, as it is for
   records of different groups, so warning 30 is off for the group. *)
[@@@warning "-30"]

type expression = expression_node spanned

and expression_node =
  | Identifier of string
  | Constant of Number.t  (** never [Number.Not_a_constant] *)
  | Character of Token.encoding  (** the value is the token's spelling *)
  | String of string_literal
  | Parenthesized of expression
  | Generic of {
      controlling : expression;
      associations : generic_association list;  (** at least one *)
    }
  | Compound_literal of { type_name : type_name; values : initialiser_list }
  | Subscript of { operand : expression; index : expression }
  | Call of { callee : expression; arguments : expression list }
  | Member of { operand : expression; member : identifier }  (** [.] *)
  | Pointer_member of { operand : expression; member : identifier }
      (** [->] *)
  | Post_increment of expression
  | Post_decrement of expression
  | Unary of unary_operator * expression
  | Sizeof_expression of expression
  | Sizeof_type of type_name
  | Alignof of type_name
  | Cast of { type_name : type_name; operand : expression }
  | Binary of binary_operator * expression * expression
  | Conditional of {
      condition : expression;
      if_true : expression;
      if_false : expression;
    }
  | Assignment of assignment_operator * expression * expression
  | Comma of expression * expression
  | Statement_expression of block  (** GNU [(] compound-statement [)] *)
  | Va_arg of { list : expression; type_name : type_name }
      (** [__builtin_va_arg], which [va_arg] expands to *)
  | Offsetof of {
      type_name : type_name;
      member : identifier;
      designators : designator list;
    }
      (** [__builtin_offsetof], which [offsetof] expands to: the member
          and the member designators and subscripts after it *)

(** Adjacent string literal tokens, which translation phase 6 joins
    (C11 5.1.1.2): at least one, each with its encoding prefix. *)
and string_literal = Token.encoding spanned list

and generic_association = generic_association_node spanned

and generic_association_node =
  | Association of type_name * expression
  | Default_association of expression

(** C11 6.7.7: a specifier-qualifier list and an abstract declarator. *)
and type_name = type_name_node spanned

and type_name_node = {
  specifier_qualifiers : specifiers;
  abstract : declarator option;
}

(** Declaration specifiers in source order, at least one. In a type name
    and a member declaration they are a specifier-qualifier list: no
    storage class or function specifier. *)
and specifiers = declaration_specifier spanned list

and declaration_specifier =
  | Storage_class of storage_class
  | Type_specifier of type_specifier
  | Type_qualifier of type_qualifier
  | Function_specifier of function_specifier
  | Alignment_specifier of alignment
  | Attributes of attribute list  (** one [__attribute__((...))] *)

and type_specifier =
  | Basic of basic_type_specifier
  | Atomic_type of type_name  (** [_Atomic (] type-name [)] *)
  | Struct_or_union of {
      kind : struct_or_union;
      attributes : attribute list;
          (** after the keyword and after the body, in source order *)
      tag : identifier option;
      members : member_declaration list option;
          (** [None] without a body; a GNU body may be empty *)
    }
  | Enum of {
      attributes : attribute list;
          (** after the keyword, the fixed type and the body, in source
              order *)
      tag : identifier option;
      underlying : specifiers option;
          (** Clang's fixed underlying type, after a [:] (C23 6.7.2.2) *)
      enumerators : enumerator list option;
          (** [None] without a body; a body holds at least one *)
    }
  | Typedef_name of string
  | Typeof_expression of expression  (** GNU [typeof (] expression [)] *)
  | Typeof_type of type_name  (** GNU [typeof (] type-name [)] *)

(** C11 6.7.5. *)
and alignment = Alignas_type of type_name | Alignas_expression of expression

and member_declaration = member_declaration_node spanned

and member_declaration_node =
  | Members of {
      specifiers : specifiers;
      declarators : member_declarator list;
    }
      (** no declarators for an anonymous structure or union (6.7.2.1p13) *)
  | Member_static_assert of static_assertion

and member_declarator = member_declarator_node spanned

(** The attributes after a member declarator apply to the member. *)
and member_declarator_node =
  | Field of { declarator : declarator; attributes : attribute list }
  | Bit_field of {
      declarator : declarator option;
      width : expression;
      attributes : attribute list;
    }

and enumerator = enumerator_node spanned

and enumerator_node = {
  name : identifier;
  attributes : attribute list;
  value : expression option;
}

(** A declarator (C11 6.7.6) is read from the outside in: [Pointer],
    [Array] and [Function] each derive a type from the type of the
    declarator around them and give it to [inner], down to the [Name].
    In [int *a[3]] the outer node is [Pointer] and its [inner] is
    [Array] of [Name a]: [a] is an array of pointers. [inner] is [None]
    where an abstract declarator ends without a name. [Block_pointer] is
    Clang's [^], which the macOS SDK declares callbacks with. *)
and declarator = declarator_node spanned

and declarator_node =
  | Name of string
  | Parenthesized_declarator of declarator
  | Pointer of {
      qualifiers : type_qualifier spanned list;
      inner : declarator option;
    }
  | Block_pointer of {
      qualifiers : type_qualifier spanned list;
      inner : declarator option;
    }
  | Array of {
      inner : declarator option;
      qualifiers : type_qualifier spanned list;
          (** only in a parameter (6.7.6.2p1) *)
      size : array_size;
    }
  | Function of { inner : declarator option; parameters : parameters }

and array_size =
  | Unsized  (** [[]] *)
  | Sized of expression
  | Static_sized of expression
      (** [[static n]]: the argument has at least [n] elements
          (6.7.6.3p7) *)
  | Unspecified_variable  (** [[*]] *)

and parameters =
  | Prototype of { parameters : parameter list; variadic : bool }
      (** at least one parameter, [(void)] being one, except in a [(...)]
          of C23, which Clang accepts *)
  | Identifier_list of identifier list
      (** old style; [()] is the empty list *)

and parameter = parameter_node spanned

and parameter_node = {
  specifiers : specifiers;
  declarator : declarator option;  (** named or abstract *)
  attributes : attribute list;  (** after the declarator *)
}

(** C11 6.7.9. *)
and initialiser =
  | Expression_initialiser of expression
  | Braced of initialiser_list

(** The values between braces, which GNU C allows to be none; the span
    holds the braces. *)
and initialiser_list = designated_initialiser list spanned

and designated_initialiser = designated_initialiser_node spanned

and designated_initialiser_node = {
  designators : designator list;
  initialiser : initialiser;
}

and designator = designator_node spanned
and designator_node =
  | Index of expression
  | Index_range of { low : expression; high : expression }
      (** GNU [[low ... high]] *)
  | Member_designator of identifier

(** C11 6.7.10. *)
and static_assertion = { condition : expression; message : string_literal }

(** The asm label names the symbol of what the declarator declares, and
    the attributes after it apply to that too. *)
and init_declarator = init_declarator_node spanned

and init_declarator_node = {
  declarator : declarator;
  asm_label : string_literal option;  (** GNU [asm (] string [)] *)
  attributes : attribute list;
  initialiser : initialiser option;
}

and declaration = declaration_node spanned

and declaration_node =
  | Declaration of {
      specifiers : specifiers;
      declarators : init_declarator list;
    }
      (** no declarators declares a tag or the members of an enumeration
          only; specifiers that are all attributes, without declarators,
          are GNU's attribute statement, such as
          [__attribute__((fallthrough));], which C23 calls an attribute
          declaration *)
  | Static_assert of static_assertion

(** C11 6.8. A statement that ends in a substatement holds it whole, so
    the tree of [if (a) if (b) x;] is as deep as the chain is long. *)
and statement = statement_node spanned

and statement_node =
  | Labeled of { label : label; statement : statement }
  | Compound of block
  | Expression_statement of expression
  | Null_statement  (** [;] *)
  | If of {
      condition : expression;
      then_branch : statement;
      else_branch : statement option;
    }
  | Switch of { controlling : expression; body : statement }
  | While of { condition : expression; body : statement }
  | Do of { body : statement; condition : expression }
  | For of {
      clause : for_clause option;  (** clause-1 of 6.8.5.3 *)
      condition : expression option;
      step : expression option;
      body : statement;
    }
  | Goto of identifier
  | Continue
  | Break
  | Return of expression option
  | Asm of assembler

(** C11 6.8.1. The span runs to the [:]. *)
and label = label_node spanned

and label_node =
  | Named_label of string
  | Case_label of expression
  | Case_range of { low : expression; high : expression }
      (** GNU [case low ... high] *)
  | Default_label

(** The braces of a compound statement and the block items between them
    (C11 6.8.2). *)
and block = block_item list spanned

(** Declarations and statements in any order. *)
and block_item = Block_declaration of declaration | Block_statement of statement

and for_clause =
  | Clause_declaration of declaration
  | Clause_expression of expression

(** GNU assembler, basic and extended (GCC manual 6.11): the qualifiers
    after [asm], the template, and the operands of extended assembler. *)
and assembler = {
  qualifiers : asm_qualifier spanned list;
  template : string_literal;
  operands : asm_operands option;  (** [None] for basic assembler *)
}

and asm_qualifier = Asm_volatile | Asm_inline | Asm_goto

(** The sections after the template, each after a [:]; a section that is
    not written is empty. *)
and asm_operands = {
  outputs : asm_operand list;
  inputs : asm_operand list;
  clobbers : string_literal list;
  labels : identifier list;  (** of [asm goto] *)
}

and asm_operand = asm_operand_node spanned

and asm_operand_node = {
  symbolic_name : identifier option;  (** [[name]] *)
  constraint_ : string_literal;
  value : expression;  (** in its parentheses *)
}

[@@@warning "+30"]

(** The name a declarator declares, if it is not abstract. The walk inward
    is a tail call, so a long chain of derivations needs no stack. *)
let rec declared_name declarator =
  match declarator.node with
  | Name name -> Some name
  | Parenthesized_declarator inner
  | Pointer { inner = Some inner; _ }
  | Block_pointer { inner = Some inner; _ }
  | Array { inner = Some inner; _ }
  | Function { inner = Some inner; _ } ->
      declared_name inner
  | Pointer { inner = None; _ }
  | Block_pointer { inner = None; _ }
  | Array { inner = None; _ }
  | Function { inner = None; _ } ->
      None

(** The body of a function definition: parsed, or, where a system header
    defines the function, matched brace for brace and kept as the span of
    its braces, which emission copies (design 13.3). *)
type function_body = Parsed of block | Skipped of span

(** C11 6.9.1. [declarations] is the declaration list of an old-style
    definition, which declares the names of its identifier list; it is
    empty after a parameter type list. *)
type function_definition = function_definition_node spanned

and function_definition_node = {
  specifiers : specifiers;
  declarator : declarator;
  attributes : attribute list;  (** after the declarator *)
  declarations : declaration list;
  body : function_body;
}

type external_declaration =
  | External_declaration of declaration
  | Function_definition of function_definition
  | Top_level_asm of assembler spanned  (** GNU [asm (...);] *)
  | Empty_declaration of span  (** a GNU [;] alone *)

(** The external declarations in order. It has no span: it is every token
    of the text, and may have none. *)
type translation_unit = external_declaration list
