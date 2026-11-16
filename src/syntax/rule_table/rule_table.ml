(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* rule_table ocaml | rule_table catalogue: the module Rule of typec_syntax,
   or the Markdown catalogue of the diagnostics that it makes, both from
   the one table below. Generating the variant from the table is what
   lets the catalogue and the golden tests enumerate every rule: OCaml
   cannot list the constructors of a hand-written variant.

   A rule's number is written in the table, so that adding or removing a
   rule renumbers no other. A new rule takes a number above every number
   the table has ever held. A rule that is removed stays as a [Retired]
   row, never deleted: row i has code i + 1, so a deleted row fails the
   build. Only the last row, deleted, frees its number unseen. *)

open Rule_codegen

let rows =
  [
    Live { name = "Generated_name"; code = 1; clause = Some "design 2.3";
      meaning =
        "An identifier that begins with [__tc_]." };
    Live { name = "Own_name"; code = 2; clause = Some "design 3.1 rule 2";
      meaning =
        "A definition that uses the name it defines, other than a \
         structure or union specifier." };
    Live { name = "One_definition"; code = 3; clause = Some "design 3.1 rule 5";
      meaning =
        "A name declared twice in one scope where either is a type \
         declaration." };
    Live { name = "Claimed_name"; code = 4; clause = Some "design 10.1 rule 6";
      meaning =
        "A tag or enumerator that a type declaration claims for the C \
         it lowers to (also design 10.2), declared otherwise in its \
         scope or named in Type-C text; or a name that begins with a \
         generic's name and `__`, which the generic claims for its \
         instances (design 10.3), declared where the generic is in \
         scope or spelled in unread text there (design 13.5)." };
    Live { name = "Duplicate_constructor"; code = 5;
      clause = Some "design 3.2 rule 2";
      meaning =
        "Two constructors of one variant with one name." };
    Live { name = "Field_type"; code = 6; clause = Some "design 3.2 rule 4";
      meaning =
        "A field of a constructor whose type is not a value type; also \
         design 3.2 rule 5." };
    Live { name = "Variant_operation"; code = 7;
      clause = Some "design 3.2 rule 6";
      meaning =
        "An operation on a variant in Type-C text other than those that \
         design 3.2 rule 6 allows." };
    Live { name = "Zero_value"; code = 8; clause = Some "design 3.2 rule 7";
      meaning =
        "A braced initialiser of a variant other than [{0}] and [{}] in \
         Type-C text." };
    Live { name = "Constructor_expression"; code = 9;
      clause = Some "design 3.3";
      meaning =
        "A constructor expression that names no constructor, or whose \
         arguments do not match its fields." };
    Live { name = "Distinct_representation"; code = 10;
      clause = Some "design 3.4";
      meaning =
        "A distinct type over a type that is no unqualified arithmetic \
         or pointer type." };
    Live { name = "Distinct_operation"; code = 11; clause = Some "design 3.4";
      meaning =
        "An operation on a value of a distinct type in Type-C text that \
         the table of design 3.4 does not allow." };
    Live { name = "Distinct_conversion"; code = 12; clause = Some "design 3.4";
      meaning =
        "An implicit conversion to or from a distinct type in Type-C \
         text." };
    Live { name = "Private_creation"; code = 13;
      clause = Some "design 9.2 rule 1";
      meaning =
        "A constructor expression of a private variant, or a cast to a \
         private distinct type, in Type-C text that does not own the \
         type." };
    Live { name = "Match_scrutinee"; code = 14;
      clause = Some "design 4.1 rule 1";
      meaning =
        "A match whose scrutinee is no complete variant, or one outside \
         the scope of the declaration of the variant; also design 4.2 \
         rule 4. The same for a single-pattern test and its operand \
         (design 4.6 rule 2)." };
    Live { name = "Arm_form"; code = 15; clause = Some "design 4.1 rule 2";
      meaning =
        "A match body that is not a sequence of arms, each of labels \
         and at least one block item." };
    Live { name = "Pattern"; code = 16; clause = Some "design 4.1 rule 3";
      meaning =
        "A pattern that names no constructor of the scrutinee's type, \
         or whose sub-patterns do not match its fields, or a case label \
         that omits the field list of a constructor with fields; also \
         the pattern of a single-pattern test (design 4.6 rule 2)." };
    Live { name = "Shared_arm"; code = 17; clause = Some "design 4.1 rule 6";
      meaning =
        "An arm of several labels one of which binds." };
    Live { name = "Exhaustiveness"; code = 18;
      clause = Some "design 4.2 rule 1";
      meaning =
        "A constructor that a match covers twice or not at all." };
    Live { name = "Default_arm"; code = 19; clause = Some "design 4.2 rule 2";
      meaning =
        "A second [default] in a match, or one that covers no \
         constructor." };
    Live { name = "Enclosing_switch_label"; code = 20;
      clause = Some "design 4.3 rule 3";
      meaning =
        "A [case] or [default] label inside a match that is not one of \
         its own, or inside the statement of a single-pattern test \
         (design 4.6 rule 6)." };
    Live { name = "Arm_end"; code = 21; clause = Some "design 4.3 rule 1";
      meaning =
        "A match arm whose end can be reached; also design 4.4."
    };
    Live { name = "Arm_entry"; code = 22; clause = Some "design 4.3 rule 3";
      meaning =
        "A jump into a match arm or the statement of a single-pattern \
         test (design 4.6 rule 6) from outside it, or the address of a \
         label inside one." };
    Live { name = "Not_implemented"; code = 23; clause = None;
      meaning =
        "A construct that a later work package of the plan implements; \
         the text names the section of the design and the package." };
    Live { name = "Variant_scope"; code = 24; clause = Some "design 3.3";
      meaning =
        "A constructor expression outside the scope of the declaration \
         of its variant." };
    Live { name = "Reserved_constructor"; code = 25;
      clause = Some "design 3.2 rule 2";
      meaning =
        "A constructor named for a word of Type-C text (design 2.3) or \
         a universe name, or whose name contains [__] or begins with \
         [_]; and a field whose name C reserves for any use." };
    Live { name = "Disputed_jump"; code = 26; clause = Some "design 4.4";
      meaning =
        "A [break] or [continue] in a statement expression in the \
         condition of a loop or the step of a [for], outside every loop, \
         [switch] and match within it, which GCC and Clang take to leave \
         different statements: in Type-C text, and in a deferred \
         statement in any text (design 6 rule 10)." };
    Live { name = "Break_outside"; code = 27;
      clause = Some "C11 6.8.6.3p1, design 4.3 rule 2";
      meaning =
        "A [break] outside every loop, [switch] and match; also C11 \
         6.8.6.3p1." };
    Live { name = "Early_break"; code = 28; clause = Some "design 4.3 rule 5";
      meaning =
        "A [break] in Type-C text that leaves a match other than in \
         tail position of its arm." };
    Live { name = "Type_name_spelling"; code = 29;
      clause = Some "design 3.1 rules 6 and 7";
      meaning =
        "A type declaration of any form whose name contains [__], ends \
         with [_] or begins with [_] and an uppercase letter; or, at \
         file scope, begins with [_]." };
    Live { name = "Block_literal_text"; code = 30;
      clause = Some "design 13.3";
      meaning =
        "A Clang block literal that Type-C text writes, or that holds \
         Type-C text an include puts inside it." };
    Live { name = "Profile"; code = 31; clause = None;
      meaning =
        "A construct that the front end does not take (design 13.3): \
         outside the GNU profile, a builtin that the backend lacks or a \
         call that breaks the rule of a builtin, or one that needs a type, \
         a value or a declaration that typec does not compute; the text \
         names the clause." };
    Live { name = "System_body_text"; code = 32;
      clause = Some "design 13.3";
      meaning =
        "A token other than C text of a system header in a function \
         body whose [{] is C text of a system header, which is passed \
         through unread." };
    Live { name = "Generic_scope"; code = 33; clause = Some "design 3.1";
      meaning =
        "A type declaration with type parameters outside file scope." };
    Live { name = "Generic_universe_name"; code = 34;
      clause = Some "design 3.6";
      meaning =
        "A type declaration with type parameters whose name is a universe \
         name." };
    Live { name = "Generic_name"; code = 35; clause = Some "design 3.5 rule 1";
      meaning =
        "The name of a generic type other than in a type application \
         with one argument for each of its type parameters." };
    Live { name = "Completion_parameters"; code = 36;
      clause = Some "design 3.1 rule 4";
      meaning =
        "A variant definition that completes an incomplete variant with \
         a different number of type parameters." };
    Live { name = "Argument_tag"; code = 37; clause = Some "design 3.5 rule 2";
      meaning =
        "A tag that a type argument declares, or is the first to mention, \
         in a parameter list or a block." };
    Live { name = "Generic_definition"; code = 38;
      clause = Some "design 3.5 rule 4";
      meaning =
        "In the definition of a generic type: a type parameter, written \
         or through a transparent alias, directly after [distinct], as \
         the type of a bit-field, in [_Alignas], [_Atomic( )] or \
         [typeof( )], qualified by [_Atomic], in an expression or in the \
         arguments of an attribute; a structure or union specifier \
         with a body and a tag, or with a body where the definition of \
         an instance does not hold it; an enumeration specifier with a \
         body." };
    Live { name = "Moved_declaration"; code = 39;
      clause = Some "design 13.5";
      meaning =
        "A declaration in moved text of a name that is in scope after \
         the text, such as a tag that the definition of a generic type \
         is the first to mention in the scope around its structure, \
         which is file scope (design 3.5 rule 8)." };
    Live { name = "Pragma_tokens"; code = 40; clause = Some "design 13.5";
      meaning =
        "A [#pragma] line whose text after [pragma] is no sequence of \
         preprocessing tokens, in Type-C text or in a deferred statement \
         (design 6), which is moved text." };
    Live { name = "Type_argument"; code = 41;
      clause = Some "design 3.5 rule 2";
      meaning =
        "A type argument that is no object type, an array, variably \
         modified, holds a type without a row in the table of design \
         10.3, one declared outside file scope, an untagged type \
         without exactly one name or an attribute, written in it or in \
         the declaration of a typedef name or alias that it uses." };
    Live { name = "Instance_nesting"; code = 42;
      clause = Some "design 3.5 rule 7";
      meaning =
        "An application that would cause the 65th instance of a chain \
         in which each instance causes the next." };
    Live { name = "Instance_placement"; code = 43; clause = Some "design 10.3";
      meaning =
        "An application whose instance texts cannot stand before the \
         external declaration that holds it: a type that they name or \
         need complete is not ready there, or the forward declaration of \
         a tag that they write would change a mention before it." };
    Live { name = "Moved_text"; code = 44; clause = Some "design 13.5";
      meaning =
        "A declaration between moved text and a place where lowering \
         writes it that makes a name of the text read otherwise there: a \
         name that the text uses denotes another entity or tag, or an \
         entity of another type, as a typedef name declared again with \
         an attribute may be, or a name that the text declares for \
         itself is a typedef name or a tag of the scope around it." };
    Live { name = "Moved_text_unknown"; code = 45;
      clause = Some "design 13.5, P21";
      meaning =
        "A declaration between moved text and a place where lowering \
         writes it of an entity that the text uses, where whether the \
         entity keeps its type depends on a type that typec does not \
         compute." };
    Live { name = "Unread_own_name"; code = 46; clause = Some "design 13.5";
      meaning =
        "An identifier in the arguments of an attribute that denotes a \
         generic or a universe name, which lowering writes under a name \
         of its own: in Type-C text, and in moved text that is C text \
         where the place that lowering writes it at declares a C entity \
         of its spelling, which the backend would read." };
    Live { name = "Generic_pragma"; code = 47;
      clause = Some "design 10.3, P25";
      meaning =
        "A generic whose definition holds a [#pragma] line, which a \
         [_Pragma] operator also becomes, or a [#] punctuator, which the \
         text of an instance cannot hold." };
    Live { name = "Dropped_result"; code = 48; clause = Some "design 5.2";
      meaning =
        "A value of a [result] type that Type-C text discards other than \
         by a cast to [void]: as an expression statement, the left \
         operand of [,], or the first or third clause of [for]. An \
         assignment discards none, having stored it." };
    Live { name = "Unread_word"; code = 49;
      clause = Some "design 6 rule 13, 5.1 rule 3";
      meaning =
        "[_Defer] in unread text (design 13.5), or the word [defer] or \
         [try] in the arguments of an attribute of Type-C text where no \
         declaration hides it: typing does not read the text, so the \
         construct would reach the backend as written." };
    Live { name = "Excess_initialiser"; code = 50; clause = Some "design 5.2";
      meaning =
        "An initialiser in Type-C text that has no element or member \
         left to initialise (C11 6.7.9p2), other than the 0 of [{0}]." };
    Live { name = "Try_operand"; code = 51; clause = Some "design 5.1 rule 1";
      meaning =
        "A [try] whose operand is not of a [result] type, or that stands \
         in a function that does not return one." };
    Live { name = "Try_error_type"; code = 52;
      clause = Some "design 5.1 rule 1";
      meaning =
        "A [try] whose operand's error type is not the one that the \
         function returns, qualifiers at every level of it included." };
    Live { name = "Try_void"; code = 53; clause = Some "design 5.1 rule 2";
      meaning =
        "A [try] whose value is void other than as the statement \
         [try e;]." };
    Live { name = "Try_position"; code = 54; clause = Some "design 5.1 rule 3";
      meaning =
        "A [try] that is not the whole of an expression statement, the \
         whole right operand of a simple assignment that is one, or the \
         whole initialiser of the one declarator of a declaration that \
         is a block item; so also a [try] in a statement expression or in \
         a deferred statement (design 5.1 rule 4)." };
    Live { name = "Try_declaration"; code = 55;
      clause = Some "design 5.1 rule 3";
      meaning =
        "A [try] that initialises an object of static or thread storage \
         duration, or one of a variably modified type." };
    Live { name = "Try_pragma"; code = 56; clause = Some "design 5.1 rule 3";
      meaning =
        "A [try] in a statement or declaration that holds a pragma line \
         or directly follows one, its C labels included." };
    Live { name = "Defer_position"; code = 57;
      clause = Some "design 6 rule 11";
      meaning =
        "A [defer] statement that is no block item of a compound \
         statement or a match arm in a function body: the substatement \
         of a statement, the statement of a label, [case] or [default], \
         the deferred statement of another, a block item of the compound \
         statement of a statement expression, or outside every function \
         body." };
    Live { name = "Deferred_exit"; code = 58;
      clause = Some "design 6 rule 4";
      meaning =
        "A deferred statement that holds a [return], a [goto], a GNU \
         computed [goto *] or an [asm goto], or a [break] or [continue] \
         that leaves it; a [try] in one is refused as [Try_position]." };
    Live { name = "Deferred_declaration"; code = 59;
      clause = Some "design 6 rule 9, 13.5";
      meaning =
        "A deferred statement that holds an identifier label, a GNU \
         [__label__] declaration, the definition of an object with static \
         or thread storage duration, a structure, union or enumeration \
         specifier that has a body or declares its tag, a type \
         declaration or a block literal, which each copy of the statement \
         would define again." };
    Live { name = "Deferred_entry"; code = 60;
      clause = Some "design 6 rule 5";
      meaning =
        "A jump into a deferred statement from outside it, or into the \
         scope of a defer statement from outside the scope: a [case] or \
         [default] label there of a [switch] around it, a [goto] or [asm \
         goto] from outside to a label there, or the GNU address of a \
         label in the scope, which a computed [goto] could jump to from \
         anywhere in the function." };
    Live { name = "Try_moved_operand"; code = 61;
      clause = Some "design 5.1 rule 3, 13.5";
      meaning =
        "The operand of a [try], which is moved text, where it breaks \
         any clause of the resolution property: a name that it uses \
         reads otherwise in front of the statement or declaration that \
         holds the [try], as one that the holder declares does, or it \
         declares a name that is in scope after it." };
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
