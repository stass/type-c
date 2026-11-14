(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The syntax tree of a translation unit: the declarations, expressions
    and statements of C11 (6.5, 6.7, 6.8, 6.9) and of the GNU profile
    (design 13.3). The body of a function that a system header defines is
    a span of tokens.

    Every node is {!spanned}: it records the tokens it was parsed from,
    which emission copies when it leaves the node untouched (design 13.4).
    The tree holds what the grammar decides and nothing the tokens already
    say: the spelling of a constant or a string is read from its span.

    The parser is the one implementation of the scope rules (C11 6.2.1,
    6.2.3, 6.7.2.3), and the tree records their outcome: every
    declaration of an ordinary identifier or a tag carries its
    {!declared}, and every use of one the declaration it resolves to.
    Members, which belong to their structure, and labels, which belong
    to their function, are names only, and so are the identifiers in the
    arguments of an attribute, which the parser does not read. *)

open Typec_cpp

(** Tokens [first] to [last] of [Reader.t.tokens], with [first <= last].
    Neither end is a pragma token; pragma tokens between the ends belong
    to the node. *)
type span = { first : int; last : int }

type 'a spanned = { span : span; node : 'a }
type identifier = string spanned

(** The identity of a declaration of an ordinary identifier made in the
    tree: the token of the identifier that it declares. The parser reads
    each token once, so no two declarations share an id. *)
type declaration_id = Ordinary_at of int

(** The identity of a declaration of a tag, which is another name space
    (6.2.3), so that no table of one can be read with an id of the
    other. *)
type tag_id = Tag_at of int

(** What a use of an ordinary identifier can refer to: a declaration in
    the tree, or a typedef name that GCC and Clang declare before the
    first token ({!Builtin_typedef.table}). *)
type reference = In_tree of declaration_id | Builtin of string

(** A declaration of an ordinary identifier, made where the identifier
    enters scope (6.2.1p7): its id, and the declaration of the same
    identifier in the same scope that it redeclares, if one entered scope
    before it, which an enumerator in a declarator's own array length
    does though its token comes later. A redeclaration denotes the same
    entity or breaks a constraint (6.7p3), which the declaration reader
    checks. *)
type declared = { id : declaration_id; earlier : reference option }

(** The declaration that a use of an ordinary identifier refers to: the
    one visible at the use (6.2.1p2), or none. A use of no declaration is
    an error unless the name is predefined, as [__func__] is (6.4.2.2),
    or a builtin function; C11 has no implicit declaration. *)
type resolution = Resolved of reference | Undeclared

(** A tag in a structure, union or enumeration specifier, and what it does
    (C11 6.7.2.3). *)
type tag = { name : identifier; binding : tag_binding }

and tag_binding =
  | Declares of { id : tag_id; earlier : tag_id option }
      (** declares the tag in the current scope: before a body or an
          enumerator list (p6), alone in a declaration (p7, and C23's
          [enum e : T;]), or where no tag of its name is visible (p8; for
          an enumeration a GNU forward reference, against p3). [earlier]
          is the tag of its name that the scope declares already, which
          it redeclares: the same tag (p4), or an error where it is
          another kind of tag (p2). *)
  | Names of tag_id  (** the visible tag, which it does not redeclare (p9) *)

(** A GNU attribute, or a C23 one read as the GNU attribute it means: its
    name, without the [__] around it that GCC allows ([__packed__] is
    [packed]) and with the prefix of a vendor other than GNU
    ([clang::noinline]), and the span of its arguments from [(] to [)],
    which the parser does not read: their grammar depends on the
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
  | Int128  (** [__int128] where the backend has it *)
  | Optional_float of Optional_float.t
      (** [_Float16] and the others that the backend has. It stays last:
          a sorted multiset lists it after the constant constructors,
          which [compare] orders first. *)

type struct_or_union = Struct | Union

(** C11 6.5.3, the prefix [++] and [--] of 6.5.3.1, and GNU [__real__]
    and [__imag__], the parts of a complex value. *)
type unary_operator =
  | Address
  | Indirection
  | Unary_plus
  | Unary_minus
  | Bitwise_not
  | Logical_not
  | Pre_increment
  | Pre_decrement
  | Real_part
  | Imaginary_part

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
  | Identifier of { name : string; resolution : resolution }
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
  | Alignof_expression of expression  (** GNU *)
  | Cast of { type_name : type_name; operand : expression }
  | Binary of binary_operator * expression * expression
  | Conditional of {
      condition : expression;
      if_true : expression option;
          (** [None] in GNU [a ?: b], whose value is [a]'s if it is not
              zero; [a] is evaluated once *)
      if_false : expression;
    }
  | Assignment of assignment_operator * expression * expression
  | Comma of expression * expression
  | Statement_expression of block  (** GNU [(] compound-statement [)] *)
  | Label_address of identifier
      (** GNU [&&] label: the label's address, a [void *] *)
  | Va_arg of { list : expression; type_name : type_name }
      (** [__builtin_va_arg], which [va_arg] expands to *)
  | Offsetof of {
      type_name : type_name;
      member : identifier;
      designators : designator list;
    }
      (** [__builtin_offsetof], which [offsetof] expands to: the member
          and the member designators and subscripts after it *)
  | Types_compatible of type_name * type_name
      (** [__builtin_types_compatible_p] *)
  | Block_literal of { parameters : parameters option; body : block }
      (** Clang's [^ (] parameters [) {] ... [}], which the macOS SDK's
          callbacks take, or [^{] ... [}] without parameters. Clang
          reads both [^{] and [^()] as [^(void)]. The body
          is in the scope of the parameters, as a function's is
          (6.2.1p4), and its [return] statements give the return type. *)

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
  | Attributes of attribute list
      (** one [__attribute__((...))] or C23 [[[...]]] *)

and type_specifier =
  | Basic of basic_type_specifier
  | Atomic_type of type_name  (** [_Atomic (] type-name [)] *)
  | Struct_or_union of {
      kind : struct_or_union;
      attributes : attribute list;
          (** after the keyword and after the body, in source order *)
      tag : tag option;
      members : member_declaration list option;
          (** [None] without a body; a GNU body may be empty *)
    }
  | Enum of {
      attributes : attribute list;
          (** after the keyword, the fixed type and the body, in source
              order *)
      tag : tag option;
      underlying : specifiers option;
          (** Clang's fixed underlying type, after a [:] (C23 6.7.2.2) *)
      enumerators : enumerator list option;
          (** [None] without a body; a body holds at least one *)
    }
  | Typedef_name of { name : string; declaration : reference }
      (** a typedef name is one only where its declaration is visible *)
  | Typeof_expression of expression  (** GNU [typeof (] expression [)] *)
  | Typeof_type of type_name  (** GNU [typeof (] type-name [)] *)

(** C11 6.7.5. *)
and alignment = Alignas_type of type_name | Alignas_expression of expression

(** A GNU [;] alone among the member declarations makes no node: the
    span of the structure holds it. *)
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
  declared : declared;  (** where the enumerator ends (6.2.1p7) *)
  attributes : attribute list;
  value : expression option;
}

(** A declarator (C11 6.7.6) is read from the outside in: [Pointer],
    [Array] and [Function] each derive a type from the type of the
    declarator around them and give it to [inner], down to the [Name].
    In [int *a[3]] the outer node is [Pointer] and its [inner] is
    [Array] of [Name a]: [a] is an array of pointers. [inner] is [None]
    where an abstract declarator ends without a name. [Block_pointer] is
    Clang's [^], which the macOS SDK declares callbacks with. The GNU
    attributes among the qualifiers of a pointer apply to the pointer
    type, and those at the start of a parenthesized declarator to the
    declarator inside. *)
and declarator = declarator_node spanned

and declarator_node =
  | Name of string
  | Parenthesized_declarator of {
      attributes : attribute list;
      inner : declarator;
    }
  | Pointer of {
      qualifiers : type_qualifier spanned list;
      attributes : attribute list;
      inner : declarator option;
    }
  | Block_pointer of {
      qualifiers : type_qualifier spanned list;
      attributes : attribute list;
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
  | Identifier_list of parameter_name list
      (** old style; [()] is the empty list *)

(** A name in an identifier list, which declares it in the prototype
    scope; the declaration list of a definition declares it again. *)
and parameter_name = { name : identifier; declared : declared }

and parameter = parameter_node spanned

and parameter_node = {
  specifiers : specifiers;
  declarator : parameter_declarator;
  attributes : attribute list;  (** after the declarator *)
}

and parameter_declarator =
  | Named_parameter of { declarator : declarator; declared : declared }
  | Abstract_parameter of declarator option
      (** [None] where no declarator follows the specifiers *)

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
    the attributes apply to that too. *)
and init_declarator = init_declarator_node spanned

and init_declarator_node = {
  declarator : declarator;
  declared : declared;  (** of the name that [declarator] declares *)
  asm_label : string_literal option;  (** GNU [asm (] string [)] *)
  attributes : attribute list;
      (** before a declarator after the first, and after the declarator
          and its asm label, in source order *)
  initialiser : initialiser option;
}

and declaration = declaration_node spanned

and declaration_node =
  | Declaration of {
      specifiers : specifiers;
      declarators : init_declarator list;
    }
      (** no declarators declares a tag or the members of an enumeration
          only. Specifiers that are all attributes, without declarators,
          are C23's attribute declaration, which GCC and Clang accept at
          file scope; in a block the same tokens are an
          [Attribute_statement]. *)
  | Static_assert of static_assertion

(** C11 6.8. A statement that ends in a substatement holds it whole, so
    the tree of [if (a) if (b) x;] is as deep as the chain is long. *)
and statement = statement_node spanned

and statement_node =
  | Labeled of { label : label; statement : statement }
  | Compound of block
  | Expression_statement of expression
  | Null_statement  (** [;] *)
  | Attribute_statement of attribute list
      (** GNU [__attribute__((...));] or C23 [[[...]];], a null statement
          with attributes, such as [fallthrough] before a [case] label *)
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
  | Computed_goto of expression  (** GNU [goto *] expression [;] *)
  | Continue
  | Break
  | Return of expression option
  | Asm of assembler

(** C11 6.8.1. The span runs to the [:], and past the attributes of a
    named label. *)
and label = label_node spanned

and label_node =
  | Named_label of { name : string; attributes : attribute list }
      (** the GNU attributes after the [:] apply to the label *)
  | Case_label of expression
  | Case_range of { low : expression; high : expression }
      (** GNU [case low ... high] *)
  | Default_label

(** The braces of a compound statement and what is between them: the
    GNU local label declarations, which come before everything else, and
    the block items (C11 6.8.2). *)
and block = block_node spanned

and block_node = {
  local_labels : local_label_declaration list;
  items : block_item list;
}

(** GNU [__label__ a, b;]: at least one label whose scope is the block,
    not the function. The span runs from [__label__] to the [;]. *)
and local_label_declaration = identifier list spanned

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

(** The identifier a declarator declares, if it is not abstract. The walk
    inward is a tail call, so a long chain of derivations needs no
    stack. *)
let rec declared_identifier declarator =
  match declarator.node with
  | Name name -> Some { span = declarator.span; node = name }
  | Parenthesized_declarator { inner; _ }
  | Pointer { inner = Some inner; _ }
  | Block_pointer { inner = Some inner; _ }
  | Array { inner = Some inner; _ }
  | Function { inner = Some inner; _ } ->
      declared_identifier inner
  | Pointer { inner = None; _ }
  | Block_pointer { inner = None; _ }
  | Array { inner = None; _ }
  | Function { inner = None; _ } ->
      None

let declared_name declarator =
  Option.map (fun name -> name.node) (declared_identifier declarator)

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
  declared : declared;  (** of the function *)
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
