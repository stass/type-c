(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* rule_table ocaml | rule_table catalogue: the module Rule of typec_syntax,
   or the Markdown catalogue of the diagnostics that it makes, both from
   the one table below. Generating the variant from the table is what
   lets the catalogue and the golden tests enumerate every rule: OCaml
   cannot list the constructors of a hand-written variant.

   A rule's name is what a diagnostic ends with and what users and tools
   match, as GCC and Clang name their warnings, so a name is never
   changed; review keeps it so, since no check sees a row renamed or
   deleted. Pick a new rule's name as a user reads it in the brackets
   after the message: the thing refused in two or three lowercase words,
   joined by hyphens, as [match-arm-end] or [discarded-result]; not the
   constructor spelled with hyphens when that reads badly. A rule that
   is removed stays as a [Retired] row, never deleted, and a name used
   by two rows fails the build, so no rule takes a removed rule's name.
   [clause] is where the design or the plan states the rule, which the
   catalogue cites; a message never cites the design. *)

open Rule_codegen

let rows =
  [
    Live { constructor = "Generated_name"; name = "generated-name";
      clause = "design 2.3";
      meaning =
        "An identifier that begins with [__tc_]." };
    Live { constructor = "Own_name"; name = "self-reference";
      clause = "design 3.1 rule 2";
      meaning =
        "A definition that uses the name it defines, other than a \
         structure or union specifier." };
    Live { constructor = "One_definition"; name = "type-redeclaration";
      clause = "design 3.1 rule 5";
      meaning =
        "A name declared twice in one scope where either is a type \
         declaration." };
    Live { constructor = "Claimed_name"; name = "claimed-name";
      clause = "design 10.1 rule 6";
      meaning =
        "A tag or enumerator that a type declaration claims for the C \
         it lowers to (also design 10.2), declared otherwise in its \
         scope or named in Type-C text; or a name that begins with a \
         generic's name and `__`, which the generic claims for its \
         instances (design 10.3), declared where the generic is in \
         scope or spelled in unread text there (design 13.5)." };
    Live { constructor = "Duplicate_constructor";
      name = "duplicate-constructor";
      clause = "design 3.2 rule 2";
      meaning =
        "Two constructors of one variant with one name." };
    Live { constructor = "Field_type"; name = "field-type";
      clause = "design 3.2 rule 4";
      meaning =
        "A field of a constructor whose type is not a value type; also \
         design 3.2 rule 5." };
    Live { constructor = "Variant_operation"; name = "variant-operation";
      clause = "design 3.2 rule 6";
      meaning =
        "An operation on a variant in Type-C text other than those that \
         design 3.2 rule 6 allows." };
    Live { constructor = "Zero_value"; name = "variant-initializer";
      clause = "design 3.2 rule 7";
      meaning =
        "A braced initialiser of a variant other than [{0}] and [{}] in \
         Type-C text." };
    Live { constructor = "Constructor_expression";
      name = "constructor-expression";
      clause = "design 3.3";
      meaning =
        "A constructor expression that names no constructor, or whose \
         arguments do not match its fields." };
    Live { constructor = "Distinct_representation"; name = "distinct-base";
      clause = "design 3.4";
      meaning =
        "A distinct type over a type that is no unqualified arithmetic \
         or pointer type." };
    Live { constructor = "Distinct_operation"; name = "distinct-operation";
      clause = "design 3.4";
      meaning =
        "An operation on a value of a distinct type in Type-C text that \
         the table of design 3.4 does not allow." };
    Live { constructor = "Distinct_conversion"; name = "distinct-conversion";
      clause = "design 3.4";
      meaning =
        "An implicit conversion to or from a distinct type in Type-C \
         text." };
    Live { constructor = "Private_creation"; name = "private-creation";
      clause = "design 9.2 rule 1";
      meaning =
        "A constructor expression of a private variant, or a cast to a \
         private distinct type, in Type-C text that does not own the \
         type." };
    Live { constructor = "Match_scrutinee"; name = "match-scrutinee";
      clause = "design 4.1 rule 1";
      meaning =
        "A match whose scrutinee is no complete variant, or one outside \
         the scope of the declaration of the variant; also design 4.2 \
         rule 4. The same for a single-pattern test and its operand \
         (design 4.6 rule 2)." };
    Live { constructor = "Arm_form"; name = "match-arm-form";
      clause = "design 4.1 rule 2";
      meaning =
        "A match body that is not a sequence of arms, each of labels \
         and at least one block item." };
    Live { constructor = "Pattern"; name = "match-pattern";
      clause = "design 4.1 rule 3";
      meaning =
        "A pattern that names no constructor of the scrutinee's type, \
         or whose sub-patterns do not match its fields, or a case label \
         that omits the field list of a constructor with fields; also \
         the pattern of a single-pattern test (design 4.6 rule 2)." };
    Live { constructor = "Shared_arm"; name = "shared-arm-binding";
      clause = "design 4.1 rule 6";
      meaning =
        "An arm of several labels one of which binds." };
    Live { constructor = "Exhaustiveness"; name = "match-coverage";
      clause = "design 4.2 rule 1";
      meaning =
        "A constructor that a match covers twice or not at all." };
    Live { constructor = "Default_arm"; name = "match-default";
      clause = "design 4.2 rule 2";
      meaning =
        "A second [default] in a match, or one that covers no \
         constructor." };
    Live { constructor = "Enclosing_switch_label"; name = "stray-case-label";
      clause = "design 4.3 rule 3";
      meaning =
        "A [case] or [default] label inside a match that is not one of \
         its own, or inside the statement of a single-pattern test \
         (design 4.6 rule 6)." };
    Live { constructor = "Arm_end"; name = "match-arm-end";
      clause = "design 4.3 rule 1";
      meaning =
        "A match arm whose end can be reached; also design 4.4."
    };
    Live { constructor = "Arm_entry"; name = "match-arm-entry";
      clause = "design 4.3 rule 3";
      meaning =
        "A jump into a match arm or the statement of a single-pattern \
         test (design 4.6 rule 6) from outside it, or the address of a \
         label inside one." };
    Retired { name = "not-implemented";
      meaning =
        "A construct that a later work package of the plan implements; \
         the text names the package." };
    Live { constructor = "Variant_scope"; name = "constructor-scope";
      clause = "design 3.3";
      meaning =
        "A constructor expression outside the scope of the declaration \
         of its variant." };
    Live { constructor = "Reserved_constructor"; name = "reserved-constructor";
      clause = "design 3.2 rule 2";
      meaning =
        "A constructor named for a word of Type-C text (design 2.3) or \
         a universe name, or whose name contains [__] or begins with \
         [_]; and a field whose name C reserves for any use." };
    Live { constructor = "Disputed_jump"; name = "ambiguous-jump";
      clause = "design 4.4";
      meaning =
        "A [break] or [continue] in a statement expression in the \
         condition of a loop or the step of a [for], outside every loop, \
         [switch] and match within it, which GCC and Clang take to leave \
         different statements: in Type-C text, and in a deferred \
         statement or the scope of a defer statement in any text \
         (design 6 rule 10)." };
    Live { constructor = "Break_outside"; name = "break-outside";
      clause = "C11 6.8.6.3p1, design 4.3 rule 2";
      meaning =
        "A [break] outside every loop, [switch] and match; also C11 \
         6.8.6.3p1." };
    Live { constructor = "Early_break"; name = "early-break";
      clause = "design 4.3 rule 5";
      meaning =
        "A [break] in Type-C text that leaves a match other than in \
         tail position of its arm." };
    Live { constructor = "Type_name_spelling"; name = "reserved-type-name";
      clause = "design 3.1 rules 6 and 7";
      meaning =
        "A type declaration of any form whose name contains [__], ends \
         with [_] or begins with [_] and an uppercase letter; or, at \
         file scope, begins with [_]." };
    Live { constructor = "Block_literal_text"; name = "block-literal";
      clause = "design 13.3";
      meaning =
        "A Clang block literal that Type-C text writes, or that holds \
         Type-C text an include puts inside it." };
    Live { constructor = "Profile"; name = "unsupported";
      clause = "design 13.3, P16";
      meaning =
        "A construct that the front end does not take: outside the GNU \
         profile, a builtin that the backend lacks or a call that breaks \
         the rule of a builtin, or one that needs a type, a value or a \
         declaration that typec does not compute." };
    Live { constructor = "System_body_text"; name = "system-body-text";
      clause = "design 13.3";
      meaning =
        "A token other than C text of a system header in a function \
         body whose [{] is C text of a system header, which is passed \
         through unread." };
    Live { constructor = "Generic_scope"; name = "generic-scope";
      clause = "design 3.1";
      meaning =
        "A type declaration with type parameters outside file scope." };
    Live { constructor = "Generic_universe_name";
      name = "generic-universe-name";
      clause = "design 3.6";
      meaning =
        "A type declaration with type parameters whose name is a universe \
         name." };
    Live { constructor = "Generic_name"; name = "generic-type-use";
      clause = "design 3.5 rule 1";
      meaning =
        "The name of a generic type other than in a type application \
         with one argument for each of its type parameters." };
    Live { constructor = "Completion_parameters";
      name = "completion-parameter-count";
      clause = "design 3.1 rule 4";
      meaning =
        "A variant definition that completes an incomplete variant with \
         a different number of type parameters." };
    Live { constructor = "Argument_tag"; name = "type-argument-tag";
      clause = "design 3.5 rule 2";
      meaning =
        "A tag that a type argument declares, or is the first to mention, \
         in a parameter list or a block." };
    Live { constructor = "Generic_definition"; name = "generic-definition";
      clause = "design 3.5 rule 4";
      meaning =
        "In the definition of a generic type: a type parameter, written \
         or through a transparent alias, directly after [distinct], as \
         the type of a bit-field, in [_Alignas], [_Atomic( )] or \
         [typeof( )], qualified by [_Atomic], in an expression or in the \
         arguments of an attribute; a structure or union specifier \
         with a body and a tag, or with a body where the definition of \
         an instance does not hold it; an enumeration specifier with a \
         body." };
    Live { constructor = "Pragma_tokens"; name = "pragma-tokens";
      clause = "design 13.5";
      meaning =
        "A [#pragma] line whose text after [pragma] is no sequence of \
         preprocessing tokens, in Type-C text or in a deferred statement \
         (design 6), which is moved text." };
    Retired { name = "pragma-word";
      meaning =
        "An identifier among the arguments of a [#pragma] line of a \
         pragma whose arguments are its own words and numbers alone, as \
         [pack] is, that is none of those words; [pragma-macro] took its \
         place." };
    Live { constructor = "Pragma_macro"; name = "pragma-macro";
      clause = "design 13.5";
      meaning =
        "An identifier of a [#pragma] line, in any text and of any \
         pragma, that names a macro in force at that line: Clang replaces \
         a macro in many pragmas when it compiles C, and the line stays \
         as written in the preprocessed text that typec compiles." };
    Live { constructor = "Type_argument"; name = "type-argument";
      clause = "design 3.5 rule 2";
      meaning =
        "A type argument that is no object type, an array, variably \
         modified, holds a type without a row in the table of design \
         10.3, one declared outside file scope, an untagged type \
         without exactly one name or an attribute, written in it or in \
         the declaration of a typedef name or alias that it uses; and a \
         type argument of a generic function, deduced or explicit, that \
         is no value type (design 7.2 rule 5)." };
    Live { constructor = "Instance_nesting"; name = "instance-nesting";
      clause = "design 3.5 rule 7";
      meaning =
        "An application that would cause the 65th instance of a chain \
         in which each instance causes the next." };
    Live { constructor = "Instance_placement"; name = "instance-placement";
      clause = "design 10.3";
      meaning =
        "An application whose instance texts cannot stand before the \
         external declaration that holds it: a type that they name or \
         need complete is not ready there, or the forward declaration of \
         a tag that they write would change a mention before it." };
    Live { constructor = "Moved_text_unknown"; name = "name-capture-unknown";
      clause = "design 13.5, P21";
      meaning =
        "A declaration between moved text of any kind and a place where \
         lowering writes it of an entity that the text uses, where \
         whether the entity keeps its type depends on a type that typec \
         does not compute." };
    Live { constructor = "Unread_own_name"; name = "unread-renamed-name";
      clause = "design 13.5";
      meaning =
        "An identifier in the arguments of an attribute that denotes a \
         generic or a universe name, which lowering writes under a name \
         of its own, in Type-C text. In moved text that is C text, where \
         the place that lowering writes it at declares a C entity of its \
         spelling, the refusal carries the name of the kind of text." };
    Live { constructor = "Generic_pragma"; name = "generic-pragma";
      clause = "design 10.3, P25";
      meaning =
        "A generic whose definition holds a [#pragma] line, which a \
         [_Pragma] operator also becomes, or a [#] punctuator, which the \
         text of an instance cannot hold." };
    Live { constructor = "Dropped_result"; name = "discarded-result";
      clause = "design 5.2";
      meaning =
        "A value of a [result] type that Type-C text discards other than \
         by a cast to [void]: as an expression statement, the left \
         operand of [,], or the first or third clause of [for]. An \
         assignment discards none, having stored it." };
    Live { constructor = "Unread_word"; name = "unread-word";
      clause = "design 6 rule 13, 5.1 rule 3";
      meaning =
        "[_Defer] in unread text (design 13.5), or the word [defer] or \
         [try] in the arguments of an attribute of Type-C text where no \
         declaration hides it: typing does not read the text, so the \
         construct would reach the backend as written." };
    Live { constructor = "Excess_initialiser"; name = "excess-initializer";
      clause = "design 5.2";
      meaning =
        "An initialiser in Type-C text that has no element or member \
         left to initialise (C11 6.7.9p2), other than the 0 of [{0}]." };
    Live { constructor = "Try_operand"; name = "try-operand";
      clause = "design 5.1 rule 1";
      meaning =
        "A [try] whose operand is not of a [result] type, or that stands \
         in a function that does not return one." };
    Live { constructor = "Try_error_type"; name = "try-error-type";
      clause = "design 5.1 rule 1";
      meaning =
        "A [try] whose operand's error type is not the one that the \
         function returns, qualifiers at every level of it included." };
    Live { constructor = "Try_void"; name = "try-void";
      clause = "design 5.1 rule 2";
      meaning =
        "A [try] whose value is void where it is not discarded (design \
         5.2) or cast to [void]." };
    Live { constructor = "Try_position"; name = "try-position";
      clause = "design 5.1 rule 3";
      meaning =
        "A [try] under an operator or in a place that rule 3 does not \
         name between it and its holder: outside a function body, in a \
         declaration of more than one declarator, in what C does not \
         evaluate as a value (a constant expression, a type name, the \
         operand of [sizeof], [_Alignof] or [__typeof__], an operand of \
         [_Generic] or [__builtin_choose_expr], the last operand of \
         [?:] without its second, an argument of a builtin that inspects \
         more than the values of its arguments), in a statement \
         expression or in a deferred statement (design 5.1 rule 4)." };
    Live { constructor = "Try_loop"; name = "try-loop";
      clause = "design 5.1 rule 3";
      meaning =
        "A [try] in the condition of a [while], a [do] or a [for], in a \
         single-pattern test that is the condition of a [while], or in \
         the first or third clause of a [for], which a loop evaluates \
         once for each iteration." };
    Live { constructor = "Try_lvalue"; name = "try-lvalue";
      clause = "design 5.1 rule 2";
      meaning =
        "A [try], or a member of its value, where C asks for an lvalue: \
         the operand of [&], [++] or [--] and the left operand of an \
         assignment." };
    Live { constructor = "Try_list"; name = "try-list";
      clause = "design 5.1 rule 3";
      meaning =
        "An initialiser of a braced list, of a declaration or of a \
         compound literal, that holds a [try] and is not itself a [try] \
         expression, in parentheses or not." };
    Live { constructor = "Try_declaration"; name = "try-declaration";
      clause = "design 5.1 rule 3";
      meaning =
        "A [try] that initialises an object of static or thread storage \
         duration, or one of a variably modified type." };
    Live { constructor = "Try_pragma"; name = "try-pragma";
      clause = "design 5.1 rule 3";
      meaning =
        "A [try] in a statement or declaration that holds a pragma line \
         or directly follows one, its C labels included." };
    Live { constructor = "Try_lifetime"; name = "try-lifetime";
      clause = "design 5.1 rule 3";
      meaning =
        "A hoisted operand of a holder of [try] that holds an array \
         member of a value that is no lvalue, other than a member of the \
         value of a [try], or that is evaluated under a condition and \
         holds a compound literal." };
    Live { constructor = "Defer_position"; name = "defer-position";
      clause = "design 6 rule 11";
      meaning =
        "A [defer] statement that is no block item of a compound \
         statement or a match arm in a function body: the substatement \
         of a statement, the statement of a label, [case] or [default], \
         a block item of the compound statement of a statement \
         expression, or outside every function body." };
    Live { constructor = "Deferred_exit"; name = "deferred-exit";
      clause = "design 6 rule 4";
      meaning =
        "A deferred statement that holds a [return], a [goto], a GNU \
         computed [goto *] or an [asm goto], or a [break] or [continue] \
         that leaves it; a [try] in one is refused as [Try_position]." };
    Live { constructor = "Deferred_declaration"; name = "deferred-declaration";
      clause = "design 6 rule 9, 13.5";
      meaning =
        "A deferred statement that holds an identifier label, a GNU \
         [__label__] declaration, the definition of an object with static \
         or thread storage duration, a structure, union or enumeration \
         specifier that has a body or declares its tag, a type \
         declaration or a block literal, which each copy of the statement \
         would define again." };
    Live { constructor = "Deferred_entry"; name = "deferred-entry";
      clause = "design 6 rule 5";
      meaning =
        "A jump into a deferred statement from outside it, or into the \
         scope of a defer statement from outside the scope: a [case] or \
         [default] label there of a [switch] around it, a [goto] or [asm \
         goto] from outside to a label there, or the GNU address of a \
         label in the scope, which a computed [goto] could jump to from \
         anywhere in the function." };
    Live { constructor = "Try_moved_operand"; name = "try-name-capture";
      clause = "design 5.1 rule 3, 13.5";
      meaning =
        "A hoisted operand of a holder of [try] (design 5.1 rule 3), \
         which is moved text, where it breaks \
         any clause of the resolution property: a name that it uses \
         reads otherwise in front of the statement or declaration that \
         holds the [try], as one that the holder declares does, or it \
         declares a name that is in scope after it or an object or a \
         function with linkage, or holds a brace or a tag keyword of a \
         tag that is not visible in the arguments of an attribute." };
    Live { constructor = "Defer_scope_jump"; name = "defer-scope-jump";
      clause = "design 6 rule 10";
      meaning =
        "A GNU computed [goto *] or an [asm goto] in the scope of a \
         defer statement, in any text, which no deferred statement can \
         precede; a disputed [break] or [continue] there is refused as \
         [Disputed_jump]." };
    Live { constructor = "Deferred_moved"; name = "defer-name-capture";
      clause = "design 6 rule 8, 13.5";
      meaning =
        "The statement of a defer, which is moved text, where it breaks \
         a clause of the resolution property at an exit of its scope on a \
         fact that typec knows: a declaration between the defer and the \
         exit makes a name of the statement read otherwise there, or is \
         one that a name the statement declares would hide there." };
    Live { constructor = "Return_operand_moved";
      name = "defer-return-name-capture";
      clause = "design 6 rule 12, 13.5";
      meaning =
        "The operand of a [return] in the scope of a defer statement, \
         which lowering writes in a block of its own, where it declares a \
         name that is in scope after the [return]." };
    Live { constructor = "Return_own_name"; name = "defer-return-own-name";
      clause = "design 13.5";
      meaning =
        "A function that returns a value and holds a [return e;] in the \
         scope of a defer statement, whose parameter list declares the \
         function's own name, as a parameter or an enumeration \
         constant." };
    Live { constructor = "Return_parameter_redeclared";
      name = "defer-return-parameter-redeclared";
      clause = "design 13.5";
      meaning =
        "A declaration in the outermost block of the body of a function \
         that returns a value and holds a [return e;] in the scope of a \
         defer statement, of a name that the parameter list declares in \
         the same name space: a tag, as C refuses an ordinary \
         identifier there (C11 6.7p3)." };
    Live { constructor = "Return_target_versions";
      name = "defer-return-target-versions";
      clause = "design 13.5";
      meaning =
        "A function that returns a value and holds a [return e;] in the \
         scope of a defer statement, two of whose declarations in scope at \
         the definition carry [target] attributes whose arguments differ \
         token for token." };
    Live { constructor = "Return_marked_attribute";
      name = "defer-return-marked-attribute";
      clause = "design 13.5";
      meaning =
        "A function that returns a value and holds a [return e;] in the \
         scope of a defer statement, one of whose declarations in scope at \
         the definition carries an attribute that the table of attributes \
         marks (design 13.3), or that follows a Clang overload of its \
         name." };
    Live { constructor = "Return_unnamed_parameter";
      name = "defer-return-unnamed-parameter";
      clause = "design 13.5";
      meaning =
        "A function that returns a value and holds a [return e;] in the \
         scope of a defer statement, with a parameter that has no name." };
    Live { constructor = "Return_void_value"; name = "defer-return-void-value";
      clause = "design 13.5";
      meaning =
        "A [return e;] in the scope of a defer statement, in a function \
         that returns void, where [e] is not a void expression or has a \
         type that typec does not know (design 13.3)." };
    Live { constructor = "Generic_moved"; name = "generic-name-capture";
      clause = "design 13.5";
      meaning =
        "The definition of a generic, or the one name of an untagged \
         type that the typedef of a type argument spells, where it breaks \
         a clause of the resolution property on a fact that typec knows: \
         a name of the text reads otherwise where lowering writes it, as \
         another entity or tag, an entity of another type, or a typedef \
         name or tag of the scope around it in place of a name that the \
         text declares for itself, or the text declares a name that is in \
         scope after it, such as a tag that the definition of a generic \
         type is the first to mention in file scope (design 3.5 rule 8)." };
    Live { constructor = "Defer_in_deferred"; name = "nested-defer";
      clause = "design 6 rule 11";
      meaning =
        "A [defer] statement anywhere in the deferred statement of \
         another, which lowering copies to each exit of its scope." };
    Live { constructor = "Return_operand_jump"; name = "defer-return-jump";
      clause = "design 6 rule 12";
      meaning =
        "A [goto], [break] or [continue] that leaves the operand of a \
         [return] in the scope of a defer statement, which lowering \
         writes in a block of its own." };
    Live { constructor = "Deferred_pragma"; name = "deferred-pragma";
      clause = "design 6 rule 9";
      meaning =
        "A [#pragma] line in the deferred statement of a defer statement \
         that is not one of the pragmas that apply to the statement that \
         follows them (design 13.5): lowering copies the statement to each \
         exit of its scope, and a pragma that sets state for the rest of \
         the text would be in force once per copy. Or a [#pragma] line \
         directly before a defer statement, which lowering removes, so \
         that the pragma would apply to the statement after it. Or a \
         [#pragma] line in the scope of a defer statement that is not one \
         of the pragmas that annotate only the loop after them, or that \
         stands directly before an exit of the scope, the end of its \
         block or a statement or declaration that holds an exit: a copy \
         of the deferred statement would be compiled under other pragmas \
         than the defer statement." };
    Live { constructor = "Type_parameter_operation";
      name = "type-parameter-operation";
      clause = "design 7.1 rule 3";
      meaning =
        "In a generic function, a use of a value of a type parameter \
         that C refuses of a structure, or that would have another type \
         or meaning where the argument is another value type: an \
         operand of an operator other than unary [&], [sizeof], \
         [_Alignof], the comma and assignment; a member access, a call \
         or a truth test of it; a cast of it other than to void, and a \
         cast to the type parameter; an argument that no parameter type \
         receives, which the default argument promotions take, through \
         [...] or to a function without a prototype, or a builtin reads \
         by its type, and [va_arg] of the type parameter; a \
         branch of the conditional operator (provisional); a braced \
         initialiser of it other than [{0}] and [{}]; a builtin that \
         reads the object a pointer to it points to; two pointers to \
         incompatible types that meet, by a conversion or an operation \
         on both, where one mentions a type parameter, such as a \
         function type with a parameter of the type parameter and one \
         without a prototype; an [asm] operand whose type mentions a \
         type parameter, as design 7.1 rule 4 defines mentioning; a \
         declaration in the body that gives its identifier linkage; and \
         [__func__], [__FUNCTION__] or [__PRETTY_FUNCTION__] in the \
         body where an operation reads its array whole." };
    Live { constructor = "Type_parameter_constant";
      name = "type-parameter-constant";
      clause = "design 7.1 rule 4";
      meaning =
        "In a generic function, an expression that depends on a type \
         parameter, holding [sizeof], [_Alignof] or [offsetof] of a type \
         that mentions one, where C asks for a constant expression: an \
         array bound, a [case] value, a static initialiser, the width of \
         a bit-field, the value of an enumerator, the operand of \
         [_Static_assert] or of [_Alignas]; and [_Alignas] of a type \
         that mentions a type parameter; and [_Generic] or \
         [__builtin_types_compatible_p] where a type parameter meets \
         another type in a comparison that decides." };
    Live { constructor = "Zero_initialiser_vla";
      name = "zero-initializer-vla";
      clause = "design 7.1 rule 3";
      meaning =
        "In a generic function, the zero initialiser [{0}] or [{}] of a \
         variable length array whose type mentions a type parameter." };
    Live { constructor = "Zero_initialiser_in_for";
      name = "zero-initializer-in-for";
      clause = "design 7.1 rule 3";
      meaning =
        "In a generic function, the zero initialiser [{0}] or [{}] of an \
         object or subobject whose type mentions a type parameter, in a \
         declaration in the first clause of a [for] statement, outside a \
         compound literal." };
    Live { constructor = "Zero_initialiser_atomic";
      name = "zero-initializer-atomic";
      clause = "design 7.1 rule 3";
      meaning =
        "In a generic function, the zero initialiser [{0}] or [{}] of an \
         object or subobject whose own type is atomic and mentions a type \
         parameter." };
    Live { constructor = "Initialiser_place_lost";
      name = "initializer-place-lost";
      clause = "design 7.1 rule 3";
      meaning =
        "In a generic function, an initialiser without a designator in a \
         braced list for an object whose type mentions a type parameter, \
         where the subobject that it reaches depends on what typec does \
         not know: it follows an element of an array whose length or \
         index the backend computes, or an initialiser whose own reach \
         typec does not know." };
    Live { constructor = "Initialiser_type_unknown";
      name = "initializer-type-unknown";
      clause = "design 7.1 rule 3";
      meaning =
        "In a generic function, a braced initialiser of an object whose \
         type typec does not compute or holds a member or element of such \
         a type." };
    Live { constructor = "Generic_function_form";
      name = "generic-function-form";
      clause = "design 7.1 rule 6";
      meaning =
        "What follows [generic( )] is not one function that an instance \
         can be written from: a definition, or a declaration with one \
         declarator that declares a function, with a prototype and \
         neither [()] nor an identifier list, no storage-class specifier \
         but [static], no assembler label, no parameter of a variably \
         modified type, no type parameter or type that typec does not \
         compute as the type of the last named parameter before an \
         ellipsis, no function type that typec does not compute, no \
         structure, union or enumeration tag declared or body defined \
         in the head, and on a declaration that is not a definition \
         neither [_Noreturn] nor an attribute anywhere in it." };
    Live { constructor = "Generic_function_agreement";
      name = "generic-function-agreement";
      clause = "design 7.1 rule 7";
      meaning =
        "Two declarations of a generic function that do not agree: they \
         have different numbers of type parameters, or, with each type \
         parameter of one read as the one at the same position of the \
         other, declare different types; or a second definition of it; \
         or another declaration of its name at file scope, before it or \
         after it." };
    Live { constructor = "Generic_attribute"; name = "generic-attribute";
      clause = "design 13.3";
      meaning =
        "In the definition of a generic type or a generic function, an \
         attribute or an alignment specifier, read as the attribute \
         [aligned], whose subject mentions a type parameter or whose \
         arguments name what the definition declares, where the table \
         of attributes does not record that both backends take it alike \
         for every type, kind of subject and argument list." };
    Live { constructor = "Generic_function_use"; name = "generic-function-use";
      clause = "design 7.2";
      meaning =
        "The name of a generic function other than as the called \
         expression of a call or before the type arguments of an \
         explicit instance." };
    Live { constructor = "Deduction_mismatch"; name = "deduction-mismatch";
      clause = "design 7.2 rule 2";
      meaning =
        "An argument of a call of a generic function whose type, after \
         lvalue, array and function conversion, differs from the type of \
         its parameter where that mentions a type parameter that no \
         argument before it deduces, other than by qualifiers that a \
         pointer parameter adds to the pointed-to type; or in which a \
         type parameter that occurs twice meets two different types." };
    Live { constructor = "Undeduced_type_parameter";
      name = "undeduced-type-parameter";
      clause = "design 7.2 rule 3";
      meaning =
        "A call of a generic function that leaves a type parameter that \
         no argument deduces." };
    Live { constructor = "Instance_arguments"; name = "instance-arguments";
      clause = "design 7.2 rule 4";
      meaning =
        "An explicit instance of a generic function with a number of \
         type arguments other than the number of its type parameters." };
    Live { constructor = "Slice_index"; name = "slice-index";
      clause = "design 8 rules 1, 3 and 4";
      meaning =
        "An index of a slice, a bound of a [slice_sub] or the count of a \
         [slice_unchecked], whose type is no integer type, or an integer \
         type wider than [size_t]." };
    Live { constructor = "Slice_test_place"; name = "slice-check-place";
      clause = "design 8 rule 9";
      meaning =
        "An index of a slice, a [slice_sub] or a conversion of a slice \
         that C evaluates outside a function body, where no function \
         declares the temporaries of its test." };
    Live { constructor = "Slice_operand"; name = "slice-operand";
      clause = "design 8 rules 2 to 4";
      meaning =
        "An operand of [slice_from_array], [slice_sub] or \
         [slice_unchecked] that the operator does not take: a first \
         operand of [slice_sub] of no slice type, an operand of \
         [slice_from_array] that is no lvalue of a complete array type \
         that is not variably modified or that holds a pragma line, or \
         a pointer operand of [slice_unchecked] of no pointer type." };
    Live { constructor = "Array_operand_moved";
      name = "array-operand-name-capture";
      clause = "design 8 rule 2, 13.5";
      meaning =
        "The operand of a [slice_from_array], which lowering writes a \
         second time as the operand of [sizeof], where it declares a tag \
         or an enumeration constant in the scope around it, or defines a \
         label whose scope reaches beyond it." };
    Live { constructor = "Instance_pragma"; name = "instance-pragma";
      clause = "design 7.3 rule 4, P27";
      meaning =
        "The first use of a function instance where a [#pragma] line \
         that sets state stands between the definition of its generic \
         and the place where the instance is written." };
    Live { constructor = "Instance_in_inline"; name = "instance-in-inline";
      clause = "design 7.3 rule 1";
      meaning =
        "A use of a function instance in the head or the body of an \
         inline definition of a function with external linkage, which \
         C11 6.7.4p3 forbids, as the instance has internal linkage." };
    Live { constructor = "Generic_system_body";
      name = "generic-system-body";
      clause = "design 7.1 rule 9";
      meaning =
        "A generic function whose body is C text of a system header, \
         which typec passes through unread." };
    Live { constructor = "Generic_block_literal";
      name = "generic-block-literal";
      clause = "design 7.1 rule 9";
      meaning =
        "A block literal in a generic function, written by C text that an \
         include puts there; its body is not read." };
    Live { constructor = "Function_instance_place";
      name = "function-instance-place";
      clause = "design 7.3 rule 2";
      meaning =
        "A use of a generic function in the definition of a generic type \
         or in the head of a generic function." };
    Live { constructor = "Generic_undefined"; name = "generic-undefined";
      clause = "design 7.3 rule 2";
      meaning =
        "The first use of an instance of a generic function that is not \
         defined before it." };
  ]

let () =
  let generate =
    match Sys.argv with
    | [| _; "ocaml" |] -> ocaml
    | [| _; "catalogue" |] -> catalogue
    | _ ->
        prerr_endline "usage: rule_table ocaml | rule_table catalogue";
        exit 2
  in
  match generate rows with
  | text -> print_string text
  | exception Invalid_table reason ->
      prerr_endline ("rule_table: " ^ reason);
      exit 1
