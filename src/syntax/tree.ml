(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The syntax tree of a translation unit: the declarations, expressions
    and statements of C11 (6.5, 6.7, 6.8, 6.9) and of the GNU profile
    (design 13.3), and the type declarations of Type-C (design 3.1). The
    body of a function that a system header defines is a span of tokens.

    Every node is {!spanned}: it records the tokens it was parsed from,
    which emission copies when it leaves the node untouched (design 13.4).
    A node's span holds the spans of its parts, in token order, which the
    parser's bound on the depth of the tree relies on.
    The tree holds what the grammar decides and nothing the tokens already
    say: the spelling of a constant or a string is read from its span.

    The parser is the one implementation of the scope rules (C11 6.2.1,
    6.2.3, 6.7.2.3), and the tree records their outcome: every
    declaration of an ordinary identifier or a tag carries its
    {!declared}, and every use of one the declaration it resolves to.
    It is also the one implementation of what a break or continue leaves,
    which each records as its {!jump_targets}, and of the scope of a
    label (6.2.1p3), which every mention of one records as its
    {!label_id}. Members, which belong to their structure, are names
    only, and so are the identifiers in the arguments of an attribute,
    which the parser does not read. *)

open Typec_cpp

(** Tokens [first] to [last] of [Reader.t.tokens], with [first <= last].
    Neither end is a pragma token; pragma tokens between the ends belong
    to the node. *)
type span = Spanned.span = { first : int; last : int }

(** Private, so that only {!Spanned} builds a node, which keeps the
    parser's bound on the depth of the tree for every node. *)
type +'a spanned = 'a Spanned.t = private { span : span; node : 'a }
type identifier = string spanned

(** The identity of a declaration of an ordinary identifier made in the
    tree: the token of the identifier that it declares. The parser reads
    each token once, so no two declarations share an id. *)
type declaration_id = Ordinary_at of int

(** The identity of a declaration of a tag, which is another name space
    (6.2.3), so that no table of one can be read with an id of the
    other. *)
type tag_id = Tag_at of int

(** The identity of a loop, switch or match statement, which a break or
    continue names as the statement it leaves: the first token of the
    statement, its keyword ({!jump_target_of}). *)
type jump_target = Statement_at of int

(** The statements that a break or continue may leave: [Only] one, or,
    for a disputed one in C text, in the condition of a loop or the step
    of a [for] (design 4.4), [Either] of two, as the backend chooses:
    Clang the [loop], GCC the statement [around] it. *)
type jump_targets =
  | Only of jump_target
  | Either of { loop : jump_target; around : jump_target }

(** The identity of a label in its scope, its function or the block of a
    GNU local label: the token of the first mention that resolves to it,
    which for a local label is its name in [__label__]. A goto may come
    before the label it names (C11 6.2.1p3), so the first mention may be
    a goto, an [asm goto] or an address. The parser resolves every goto
    and [asm goto] to a label that a statement in its scope defines; an
    address may name a label that none defines. *)
type label_id = Label_at of int

(** A mention of a label other than its definition, and the label it
    resolves to. *)
type label_name = { name : identifier; label : label_id }

(** What a use of an ordinary identifier can refer to: a declaration in
    the tree, or a typedef name that GCC and Clang declare before the
    first token ({!Builtin_typedef.table}). *)
type reference = In_tree of declaration_id | Builtin of string

(** The scope that a declaration declares its identifier in, as the
    number of scopes open there in the C that the text lowers to, file
    scope counted: [1] at file scope. The scope of a generic's type
    parameters stands for file scope while its definition is read
    (design 3.5 rule 8), and is a scope inside file scope where the
    parameters themselves are declared. Sibling scopes share a depth,
    so a depth identifies a scope only together with a point inside it,
    as the third clause of the resolution check compares it (design
    13.5). *)
type scope_depth = Scope_depth of int

(** A declaration of an ordinary identifier, made where the identifier
    enters scope (6.2.1p7): its id, the scope it declares the identifier
    in, and the declaration of the same identifier in the same scope that
    it redeclares, if one entered scope before it, which an enumerator in
    a declarator's own array length does though its token comes later. A
    redeclaration denotes the same entity or breaks a constraint (6.7p3),
    which the declaration reader checks, except where either is a Clang
    overload (design 13.3). *)
type declared = {
  id : declaration_id;
  scope : scope_depth;
  earlier : reference option;
}

(** The declaration that a use of an ordinary identifier refers to: the
    one visible at the use (6.2.1p2), or none. A use of no declaration is
    an error unless the name is predefined, as [__func__] is (6.4.2.2),
    or a builtin function; C11 has no implicit declaration. *)
type resolution = Resolved of reference | Undeclared

(** A tag in a structure, union or enumeration specifier, and what it does
    (C11 6.7.2.3). *)
type tag = { name : identifier; binding : tag_binding }

and tag_binding =
  | Declares of {
      id : tag_id;
      scope : scope_depth;
      earlier : tag_id option;
      implicit : bool;
    }
      (** declares the tag in the current scope, [scope]: before a body
          or an enumerator list (p6), alone in a declaration (p7, and C23's
          [enum e : T;]), or where no tag of its name is visible (p8; for
          an enumeration a GNU forward reference, against p3). [earlier]
          is the tag of its name that the scope declares already, which
          it redeclares: the same tag (p4), or an error where it is
          another kind of tag (p2). [implicit] where it declares the tag
          only because none of its name is visible (p8). *)
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
  | Qualified_constructor of { variant : type_name; constructor : identifier }
      (** [T.C] (design 3.3), in Type-C text only; [T.C(...)] is a [Call]
          of it. The type name denotes a variant where the expression is
          typed. *)
  | Subscript of { operand : expression; index : expression }
  | Slice_operation of slice_operation
      (** An operator of section 8 applied to its operands, where its
          universe name is not hidden (design 2.3). *)
  | Call of { callee : expression; arguments : expression list }
  | Instance of { generic : expression; type_arguments : type_name list }
      (** [f(T1, ..., Tn)], the instance of the generic function that
          [generic], an identifier, names (design 7.2 rule 4) *)
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
  | Try of { operand : expression; scope : scope_depth }
      (** Type-C's [try] (design 5.1), in Type-C text where no
          declaration hides the word: its operand, and the scope that
          holds it, which holds the operand that lowering moves (13.5).
          The parser reads one wherever it stands, and typing refuses
          one outside the positions of rule 3. *)
  | Statement_expression of block  (** GNU [(] compound-statement [)] *)
  | Label_address of label_name
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
  | Choose of {
      condition : expression;
      first : expression;
      second : expression;
    }
      (** [__builtin_choose_expr]: [first] where the integer constant
          expression [condition] is not zero, else [second] *)
  | Block_literal of { parameters : parameters option; body : block }
      (** Clang's [^ (] parameters [) {] ... [}], which the macOS SDK's
          callbacks take, or [^{] ... [}] without parameters. Clang
          reads both [^{] and [^()] as [^(void)]. The body
          is in the scope of the parameters, as a function's is
          (6.2.1p4), and its [return] statements give the return type. *)

(** Adjacent string literal tokens, which translation phase 6 joins
    (C11 5.1.1.2): at least one, each with its encoding prefix. *)
and string_literal = Token.encoding spanned list

(** The operands of an operator of section 8, each as its rule names
    it. *)
and slice_operation =
  | Slice_from_array of expression  (** rule 2 *)
  | Slice_sub of { slice : expression; low : expression; high : expression }
      (** rule 3 *)
  | Slice_unchecked of { pointer : expression; count : expression }
      (** rule 4 *)

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
  | Struct_or_union of record_specifier
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
      (** a typedef name is one only where its declaration is visible; a
          type parameter is one in the definition of its generic *)
  | Application of {
      name : string;
      generic : reference;  (** the type declaration of the generic *)
      arguments : type_name list;
          (** one for each type parameter of the generic, in order *)
    }
      (** [G(A1, ..., An)], a type application (design 3.5 rule 1) *)
  | Typeof_expression of expression  (** GNU [typeof (] expression [)] *)
  | Typeof_type of type_name  (** GNU [typeof (] type-name [)] *)

(** A structure or union specifier (C11 6.7.2.1). *)
and record_specifier = {
  kind : struct_or_union;
  attributes : attribute list;
      (** after the keyword and after the body, in source order *)
  tag : tag option;
  members : member_declaration list spanned option;
      (** [None] without a body; a GNU body may be empty; the span holds
          the braces *)
}

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
    scope, where the declaration list of a definition declares it again;
    or a type parameter, which a type declaration declares in a scope of
    its own around its definition (design 3.5). *)
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
      condition : condition;
      then_branch : statement;
      else_branch : statement option;
    }
  | Switch of { controlling : expression; body : statement }
  | While of { condition : condition; body : statement }
  | Do of { body : statement; condition : expression }
  | For of {
      clause : for_clause option;  (** clause-1 of 6.8.5.3 *)
      condition : expression option;
      step : expression option;
      body : statement;
    }
  | Goto of label_name
  | Computed_goto of expression  (** GNU [goto *] expression [;] *)
  | Continue of { loop : jump_targets }
      (** the innermost loop around it (C11 6.8.6.2p1), which may be
          outside a match around it (design 4.3 rule 2), or the two that
          a disputed one may continue *)
  | Break of { leaves : jump_targets }
      (** the innermost loop, switch or match around it, or the two that
          a disputed one may leave (C11 6.8.6.3p1, design 4.3 rule 2) *)
  | Return of expression option
  | Asm of assembler
  | Match of { scrutinee : expression; arms : arm list }
      (** design 4.1: [match (] scrutinee [) {] arms [}] *)

(** The condition of an [if] or a [while]: C's controlling expression,
    or a single-pattern test (design 4.6), whose statement is the [then]
    branch or the body, in the block scope that its bindings begin. *)
and condition =
  | Controlling of expression
  | Pattern_test of {
      pattern_span : span;
      pattern : pattern;
      operand : expression;
    }
      (** [case] pattern [=] operand; [pattern_span] runs from the [case]
          to the end of the pattern, which is not a node: its names are
          parts of the statement *)

(** C11 6.8.1. The span runs to the [:], and past the attributes of a
    named label. *)
and label = label_node spanned

and label_node =
  | Named_label of {
      name : string;
      label : label_id;
      attributes : attribute list;
    }  (** the GNU attributes after the [:] apply to the label *)
  | Case_label of expression
  | Case_range of { low : expression; high : expression }
      (** GNU [case low ... high] *)
  | Default_label

(** An arm of a match (design 4.1 rule 2): its labels and at least one
    block item, in a block scope of its own (rule 5) that its bindings
    begin. The span runs from the first label to the last item. *)
and arm = arm_node spanned

and arm_node = { labels : arm_label list; items : block_item list }

(** A label of an arm: [case] pattern [:], or [default:]. The span runs to
    the [:]. *)
and arm_label = arm_label_node spanned

and arm_label_node = Pattern_label of pattern | Default_arm_label

(** A constructor of the scrutinee's type, unqualified, and its
    sub-patterns in parentheses, [None] without them (design 4.1 rule 3,
    Appendix A). *)
and pattern = {
  constructor : identifier;
  sub_patterns : sub_pattern list option;
}

(** A sub-pattern: an identifier, which declares a binding where it
    enters scope, or [_], which binds nothing. *)
and sub_pattern =
  | Binding of { name : identifier; declared : declared }
  | Wildcard of span

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
and local_label_declaration = label_name list spanned

(** Declarations and statements in any order. *)
and block_item =
  | Block_declaration of declaration
  | Block_type_declaration of scoped_type_declaration
  | Block_statement of statement
  | Block_defer of { keyword : span; statement : statement }
      (** [defer S] or [_Defer S] (design section 6, Appendix A): [keyword]
          is the one token of the word, which identifies the statement,
          and [statement] is [S], read in a block scope of its own *)

(** A type declaration (design 3.1): [type], the name, which is in scope
    from the end of its identifier as a typedef name, the type parameters
    and the definition.
    It stands where an external declaration or a block item may, and
    nowhere else that a C declaration may (design Appendix A). *)
and type_declaration = type_declaration_node spanned

and type_declaration_node = {
  name : Spelling.type_name spanned;
  type_parameters : parameter_name list;
      (** in order, with distinct names; none unless the declaration is
          of a generic type (design 3.5), which stands at file scope.
          It claims no name that a variant derives, but every name
          that begins with its name and [__] (design 10.3) *)
  declared : declared;
      (** never a redeclaration (design 3.1 rule 5), except a [Variant]
          that completes the [Incomplete_variant] of its name in its
          scope (rule 4), which is its [earlier] *)
  definition : type_definition;
}

(** A type declaration and the last token of the scope that holds it, in
    [Reader.t.tokens], which the parser gives it where it closes that
    scope: of its block, its arm or the text, where the last may be a
    pragma token. The names that a variant derives denote it from the
    declaration to there (design 10.1 rule 6). *)
and scoped_type_declaration = {
  declaration : type_declaration;
  scope_end : int;
}

and type_definition =
  | Incomplete_variant
      (** [type N;], which claims the structure tag [N] that its
          lowering declares (design 10.1 rule 6), unless it is generic *)
  | Variant of { is_private : bool; constructors : constructor list }
      (** [= private? | C ... ;]: whether [private] restricts creating
          values to the owner (design 9.2), and the constructors in order,
          at least one, whose names are unique (design 3.2 rule 2). The
          definition may use the name. Unless it is generic, it claims the
          tag [N] where it completes no incomplete variant, and the
          enumeration tag and enumerators of the names {!enum_tag_name}
          and {!enumerator_name} give (design 10.1 rule 6). *)
  | Alias of type_name
      (** [= type-name;] for a type name that is not a [Record_alias]:
          the name denotes the type, as [typedef] makes it, and the
          definition does not use the name (design 3.1 rule 2) *)
  | Distinct of { is_private : bool; representation : type_name }
      (** [= private? distinct type-name;]: a new type with the
          representation of the type name (design 3.4), whose values only
          its owner creates where it is private (9.2); the definition
          does not use the name (design 3.1 rule 2) *)
  | Record_alias of record_specifier spanned
      (** [= struct-or-union-specifier;] with a body, which its
          [members] always hold, and nothing else; it may use the name.
          Without a tag of its own, the specifier takes the declared name
          as its tag, which the declaration claims (design 10.2), unless
          it is generic, where the specifier has no tag (design 3.5 rule
          4). *)

(** A constructor of a variant, from its [|] to its name or [)]. *)
and constructor = constructor_node spanned

and constructor_node = {
  name : Spelling.constructor spanned;
  fields : field list;  (** in parentheses, at least one, or none *)
}

(** A field of a constructor: a declaration like a parameter's that names
    a member, not an ordinary identifier (design 3.2 rule 4). *)
and field = field_node spanned

and field_node = { specifiers : specifiers; declarator : declarator }

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
  labels : label_name list;  (** of [asm goto] *)
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
  | Name name -> Some (Spanned.identifier declarator.span name)
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

let rec names_directly (declarator : declarator) =
  match declarator.node with
  | Name _ -> true
  | Parenthesized_declarator { inner; _ } -> names_directly inner
  | Pointer _ | Block_pointer _ | Array _ | Function _ -> false

(** The function derivation of the name that a definition's declarator
    declares: its span, from the name to the [)] of its parameter list,
    and that list. *)
type defined_function = { derivation : span; parameters : parameters }

let rec defined_function (declarator : declarator) =
  match declarator.node with
  | Function { inner = Some inner; parameters } when names_directly inner ->
      { derivation = declarator.span; parameters }
  | Parenthesized_declarator { inner; _ }
  | Pointer { inner = Some inner; _ }
  | Block_pointer { inner = Some inner; _ }
  | Array { inner = Some inner; _ }
  | Function { inner = Some inner; _ } ->
      defined_function inner
  | Name _
  | Pointer { inner = None; _ }
  | Block_pointer { inner = None; _ }
  | Array { inner = None; _ }
  | Function { inner = None; _ } ->
      invalid_arg "Tree: a definition that declares no function"

(** The text of a defer statement that each copy writes (design 13.5):
    the tokens after the [keyword] to the end of the [statement] [S],
    so that a pragma line between the two moves with [S] and is read
    as part of it. *)
let deferred_text ~(keyword : span) ~(statement : span) =
  { first = keyword.last + 1; last = statement.last }

(** The identity that a break or continue leaving the loop, switch or
    match [statement] names. *)
let jump_target_of statement = Statement_at statement.span.first

(* The operands of a slice operation in the order of the source. *)
let slice_operands = function
  | Slice_from_array operand -> [ operand ]
  | Slice_sub { slice; low; high } -> [ slice; low; high ]
  | Slice_unchecked { pointer; count } -> [ pointer; count ]

(** Whether evaluating [expression] runs a call or a statement
    expression, which may return a second time (design section 8 rule
    10), read from the expression as written: an operand that C does not
    evaluate, as of [sizeof], counts, an upper bound. The expressions in
    its type names and the subscripts of an [__builtin_offsetof] are not
    looked at, which a call in a variable length array bound or in a
    non-constant subscript would need. *)
let rec holds_call (expression : expression) =
  match expression.node with
  | Call _ | Statement_expression _ -> true
  | Identifier _ | Constant _ | Character _ | String _ | Label_address _
  | Sizeof_type _ | Alignof _ | Qualified_constructor _ | Offsetof _
  | Types_compatible _ | Block_literal _ ->
      false
  | Parenthesized operand
  | Post_increment operand
  | Post_decrement operand
  | Unary (_, operand)
  | Sizeof_expression operand
  | Alignof_expression operand
  | Member { operand; _ }
  | Pointer_member { operand; _ }
  | Try { operand; _ }
  | Cast { operand; _ }
  | Instance { generic = operand; _ }
  | Va_arg { list = operand; _ } ->
      holds_call operand
  | Subscript { operand = left; index = right }
  | Binary (_, left, right)
  | Assignment (_, left, right)
  | Comma (left, right) ->
      holds_call left || holds_call right
  | Conditional { condition; if_true; if_false } ->
      List.exists holds_call
        (condition :: if_false :: Option.to_list if_true)
  | Choose { condition; first; second } ->
      List.exists holds_call [ condition; first; second ]
  | Slice_operation operation ->
      List.exists holds_call (slice_operands operation)
  | Generic { controlling; associations } ->
      let value (association : generic_association) =
        match association.node with
        | Association (_, value) | Default_association value -> value
      in
      holds_call controlling
      || List.exists (fun a -> holds_call (value a)) associations
  | Compound_literal { values; _ } -> initialiser_list_holds_call values

and initialiser_list_holds_call (values : initialiser_list) =
  let holds (value : designated_initialiser) =
    match value.node.initialiser with
    | Expression_initialiser value -> holds_call value
    | Braced nested -> initialiser_list_holds_call nested
  in
  List.exists holds values.node

(** The expression that a condition evaluates: the controlling
    expression, or the operand of a test. *)
let condition_value = function
  | Controlling value -> value
  | Pattern_test { operand; _ } -> operand

(** The tag that the type declaration [id] claims, where it claims one
    (design 10.1 rule 6, 10.2): a declaration of the tag at the token of
    its name, which is the token of [id]. *)
let claimed_tag (Ordinary_at token) = Tag_at token

(** The names that a variant that lowers to the structure [N] derives
    for C (design 10.1 rule 6), besides the structure tag
    {!claimed_tag}: the enumeration tag [N_tag], declared at the token
    [type], and an enumerator [N_C] for each constructor [C], declared
    at the constructor's name. No other declaration is made at either
    token. An instance of a variant generic derives both from its
    instance name, at no token of the tree. *)
let enum_tag_name (variant : Spelling.c_name) = (variant :> string) ^ "_tag"

let enumerator_name ~(variant : Spelling.c_name)
    (constructor : Spelling.constructor) =
  (variant :> string) ^ "_" ^ (constructor :> string)

(** The members of the structure of a variant: the tag, and the union of
    the fields where a constructor has fields (design 10.1 rule 3). *)
let tag_member = "tag"

let union_member = "u"

(** [type_keyword] is the token that begins the declaration's span. *)
let derived_enum_tag ~type_keyword = Tag_at type_keyword

(** [constructor_name] is the token of the constructor's name. *)
let derived_enumerator constructor_name = Ordinary_at constructor_name

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

(** A generic function (design 7.1): [generic], its type parameters,
    which are type names in the rest of it, and the one function that it
    defines or declares at file scope. *)
type generic_function = generic_function_node spanned

and generic_function_node = {
  type_parameters : parameter_name list;
      (** at least one, in order, with distinct names *)
  generic : generic_form;
}

and generic_form =
  | Generic_definition of function_definition
  | Generic_prototype of {
      specifiers : specifiers;
      declarator : init_declarator;
          (** the one declarator, which declares a function with a
              prototype, without an asm label or an initialiser *)
    }

type external_declaration =
  | External_declaration of declaration
  | Type_declaration of scoped_type_declaration
  | Function_definition of function_definition
  | Generic_function of generic_function
  | Top_level_asm of assembler spanned  (** GNU [asm (...);] *)
  | Empty_declaration of span  (** a GNU [;] alone *)

(** A place where emission may put a packing bracket (design 10.3): an
    insertion in front of the token [before]. Private, so that only the
    parser names one, at an {!item} ({!anchor},
    {!after_forward_declaration}), and none stands inside an
    expression. *)
type anchor = Anchor.t = private { before : int }

(** An external declaration of the unit. Private, so that only the
    parser makes one of a declaration that it read at file scope. *)
type 'a item = 'a Anchor.item = private { declaration : 'a }

(** The unit's own external declarations in order; the generics of the
    universe text, where the reader holds it, are not among them
    ({!Parser.scopes}). It has no span: it is every token of
    the unit's own text, and may have none. *)
type translation_unit = external_declaration item list

(** The external declarations of [unit] in order, without their
    anchors. *)
let external_declarations (unit : translation_unit) =
  List.map (fun (item : _ item) -> item.declaration) unit

(** The token that an external declaration begins with. *)
let first_token = function
  | External_declaration declaration -> declaration.span.first
  | Type_declaration { declaration; _ } -> declaration.span.first
  | Function_definition definition -> definition.span.first
  | Generic_function generic -> generic.span.first
  | Top_level_asm assembler -> assembler.span.first
  | Empty_declaration span -> span.first

(** The anchor in front of an external declaration. *)
let anchor (item : external_declaration item) =
  Anchor.before (first_token item.declaration)

(** The anchor in front of a generic of the universe text, which stands
    before the unit's own text at file scope. *)
let universe_anchor (item : scoped_type_declaration item) =
  Anchor.before item.declaration.declaration.span.first

(** The token in front of which the forward declaration ends that
    lowering writes for [declaration], where it writes one
    (design 10.1, 10.2): it replaces the tokens of a variant before its
    name, and those of a record alias before its specifier. A variant
    that completes an incomplete one has that declaration's forward
    declaration (design 10.1 rule 7), and lowering writes nothing in its
    place. *)
let forward_declaration_end (declaration : type_declaration) =
  match declaration.node.definition with
  | Variant _ -> Some declaration.node.name.span.first
  | Record_alias specifier -> Some specifier.span.first
  | Incomplete_variant | Alias _ | Distinct _ -> None

(** The anchor directly after the forward declaration of a type
    declaration at file scope, where the instances that its definition
    uses stand (design 10.3): for a variant or a record alias that is
    not generic, whose instances write their own text. *)
let after_forward_declaration (item : external_declaration item) =
  match item.declaration with
  | Type_declaration { declaration; _ }
    when declaration.node.type_parameters = [] ->
      Option.map Anchor.before (forward_declaration_end declaration)
  | Type_declaration _ | External_declaration _ | Function_definition _
  | Generic_function _ | Top_level_asm _ | Empty_declaration _ ->
      None
