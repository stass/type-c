(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Parsing the tokens of preprocessed text into a {!Tree.translation_unit}
    (design 13.3): recursive descent over the complete token array.

    The parser is the one implementation of the scope rules of C11
    (6.2.1, the name spaces of 6.2.3 that scopes hold, and the tags of
    6.7.2.3): it decides where each scope begins and ends, records in the
    tree each declaration with the one it redeclares and each use with
    the declaration it resolves to ({!Tree.declared}), and reads a name
    as a typedef name where its visible declaration is one. It needs the
    kind of a name, never its type.

    The grammar is C11's declarations, expressions and statements (C11
    6.5, 6.7, 6.8, 6.9) and the GNU profile's (design 13.3). The body of
    a function that a system header defines is matched brace for brace
    and kept as a span, and so are the arguments of an attribute. A
    construct outside them, such as a C23 attribute ([[[nodiscard]]]), is
    an error that names the token where it starts.

    Pragma tokens ([#pragma] lines, including those that [_Pragma] writes
    in the middle of an expression, and [#pragma typec] lines) are not
    part of the grammar: the parser passes over them, and the node around
    them holds them in its span, so emission keeps them in place. In
    Type-C text it refuses a [#pragma] line whose text is no sequence of
    preprocessing tokens ({!Typec_cpp.Token.pragma_text}, design 13.5).

    Parsing takes time linear in the number of tokens, up to a logarithmic
    factor for each name it looks up, and its recursion is bounded by
    {!max_nesting}. The tree it gives is at most {!max_depth} nodes deep,
    so a stage that recurses over its nesting needs no bound of its own;
    a list in it, which has no bound on its length, is walked in a
    loop. *)

open Typec_cpp

(** Why the tokens are not a C11 translation unit: the presumed location
    of the token where parsing stopped, and a message that names what the
    grammar expected there and the token it found. *)
type error = Reader.error = { location : Location.t; message : string }

val max_nesting : int
(** The most brackets ([(], [[], [{]) and conditional operators that the
    parser accepts open at once; one more is an error. *)

val max_depth : int
(** The most nodes on a path from a top-level declaration of the tree to
    a leaf, chains that the parser reads in loops included; one more is
    an error. *)

val parse :
  keywords:Keyword_set.t ->
  Reader.t ->
  (Tree.translation_unit, error) result
(** [parse ~keywords text] parses [text] with [keywords], those that
    the backend reads it with ([Typec_sema.Target.keywords]). File scope
    holds the typedef names that GCC and Clang declare before the first
    token for a backend with [keywords] ({!Builtin_typedef.declared}).

    Where [text] holds the universe text in front of the unit's own
    ({!Reader.read}), its generics are declared in the
    universe scope (design 2.3), which encloses file scope: a declaration
    of the same name in any scope hides one and is no redeclaration of
    it. They are not in the tree, which holds the unit's own text alone,
    but in {!scopes}. *)

(** What file scope declares at the end of a unit (C11 6.2.1p4), sorted
    by name: each ordinary identifier and each tag with its last
    declaration there, wherever in the unit it is declared, including the
    tags and enumerators that a type declaration claims (design 10.1 rule
    6) and the builtin typedef names that {!parse} declares there. *)
type file_scope = {
  ordinary : (string * Tree.reference) list;
  tags : (string * Tree.tag_id) list;
}

(** How far the type declaration of a name has got: within a definition
    that may not use the name (design 3.1 rule 2), past its definition or
    within one that may use it, or declaring an incomplete variant that a
    variant definition may still complete (rule 4). *)
type stage = Defining | Defined | Awaiting_variant

(** The kind of an ordinary identifier in scope, which is what parsing
    needs of a name: never its type. *)
type kind =
  | Not_a_type  (** an object, a function or an enumerator of C *)
  | Typedef_name  (** of C, or one that GCC and Clang declare *)
  | Declared_type of { stage : stage; parameters : int }
      (** the typedef name to C that a type declaration declares, which is
          the only declaration of its name in its scope (design 3.1 rule
          5), with the number of its type parameters, which is not zero
          for a generic type (design 3.5) *)
  | Type_parameter  (** within the definition of its generic *)
  | Derived_enumerator
      (** an enumerator that a variant claims for C (design 10.1 rule 6) *)

(** What an ordinary identifier in scope denotes: its declaration and its
    kind. *)
type ordinary = { declaration : Tree.reference; kind : kind }

(** What lowering writes under a name of its own (design 13.5): a type
    parameter, a generic and a universe name. Unread text keeps the
    spelling of the source, so the backend does not read such a name as
    Type-C means it. *)
type own_name = Own_type_parameter | Own_generic | Own_universe_name

val own_name : ordinary option -> string -> own_name option
(** [own_name found name] is what the identifier [name] denotes, if it is
    an [own_name], where a scope finds [found] under it: a name that no
    scope declares may be a universe name, and a generic that has one is
    the universe's. *)

val own_name_kind : own_name -> string
(** The kind of name, as a message says it: ["a generic"]. *)

(** A view of the scopes open at a place of the unit (C11 6.2.1), as the
    parser resolved names there: what the resolution property of design
    13.5 compares between the place of moved text and a place where
    lowering writes it. A view holds what is declared in front of its
    place and nothing that is declared after it, and the generics of the
    universe scope (design 2.3) where the unit has the universe text; a
    name that no scope declares may be another name of {!Universe}. *)
module View : sig
  type t

  val empty : t
  (** A view in which nothing is declared. *)

  val find : t -> string -> ordinary option
  (** The declaration of an ordinary identifier that is visible: that of
      the innermost scope that declares it. *)

  val find_tag : t -> string -> Tree.tag_id option
  (** The tag of the name that is visible. *)

  val find_local_label : t -> string -> Tree.label_id option
  (** The GNU local label of the name that is visible, declared by
      [__label__] in a block around the place; [None] where the name
      denotes the label of that name of the function, or of the block
      literal, around the place (C11 6.2.1p3). *)
end

(** The views that the parser takes where unread text stands in a unit,
    at the [(] of the arguments of each attribute and at each pragma
    token, and at each [try], whose operand lowering moves (design 5.1
    rule 3). Typing does not read unread text, so a view says what each
    identifier in it denotes where it stands; a view at a [try] says it
    for the operand at its place and where lowering writes it. *)
type views

val attribute_view : views -> Tree.attribute -> View.t option
(** The view at the arguments of an attribute of the unit that [views]
    were taken in, or [None] for an attribute without arguments. *)

val attributes_within : views -> Tree.span -> (Tree.span * View.t) list
(** The arguments of each attribute whose arguments begin within the span,
    in source order, each with the view at them: every attribute of a
    text, wherever the grammar puts it. *)

val pragmas_within : views -> Tree.span -> (int * View.t) list
(** The index of each pragma token within the span, in source order, with
    the view at it, as {!pragma_view} gives it. *)

val pragma_view : views -> int -> View.t option
(** [pragma_view views index] is the view at the token at [index] in
    [Reader.t.tokens] of the unit that [views] were taken in, if it is a
    pragma token ([Token.Pragma] or [Token.Typec_pragma]), and [None]
    for any other token. A pragma stands between two grammar tokens, and
    its view is the one in front of the grammar token after it, or file
    scope as the unit leaves it after the last grammar token. In a
    function body that the parser passes through unread, it is the view
    where the body starts. *)

(** The two views at a [try] of Type-C text (design 5.1 rule 3), which
    the resolution property of design 13.5 compares for its operand.
    [place] is that of a statement or declaration of the positions of
    rule 3 only where the [try] stands in one; a [try] anywhere else is
    an error, and its [place] is in front of the innermost block item or
    statement without a substatement. *)
type try_views = {
  place : View.t;
      (** in front of the statement or declaration that holds the [try],
          after the labels of a statement but not those of a [match]
          arm, which are the arm's: where lowering writes the operand *)
  place_before : int;
      (** the index in [Reader.t.tokens] of the token that [place] stands
          in front of *)
  own : View.t;  (** at the operand, where the source reads it *)
}

val try_views : views -> int -> try_views option
(** [try_views views index] are the views at the token at [index] in
    [Reader.t.tokens] of the unit that [views] were taken in, if it is
    the word of a {!Tree.Try}, and [None] for any other token. *)

(** The view at a statement of a function body that lowering writes
    around for a defer (design 13.5), and the depth of the scope there,
    which a name that the text declares is in scope after where it is
    declared no deeper ({!Tree.scope_depth}). *)
type statement_view = { view : View.t; depth : Tree.scope_depth }

val statement_view : views -> int -> statement_view option
(** [statement_view views index] is the view at the token at [index] in
    [Reader.t.tokens] of the unit that [views] were taken in, if it is
    the word of a [defer], [break], [continue], [goto] or [return], or
    the [}] that ends a compound statement: the own place of a deferred
    statement and of the operand of a [return], and each place where
    lowering may write the copies of deferred statements (section 6 rule
    1). It is [None] for any other token. *)

(** What the parser records of the scopes of a unit beside its tree. *)
type scopes = {
  file_scope : file_scope;
  universe : (Tree.scoped_type_declaration Tree.item * View.t) list;
      (** the generics of the universe text in order, each with the
          view in front of it, the universe's generics before it; none
          where the unit has no universe text *)
  declarations : (Tree.external_declaration Tree.item * View.t) list;
      (** the unit's own external declarations in order, each with the
          view in front of it, which is file scope there *)
  views : views;
}

val parse_with_scopes :
  keywords:Keyword_set.t ->
  Reader.t ->
  (Tree.translation_unit * scopes, error) result
(** {!parse}, with what file scope declares where the unit ends and the
    views of its scopes. *)

val error_message : error -> string
(** ["file:line: message"], as {!Reader.error_message}. *)

val disputed_jump : string -> Rule.diagnostic
(** The refusal of a disputed [break] or [continue] (design 4.4), named by
    its keyword: the parser's in Type-C text and in the statement of a
    defer, and reachability's in the scope of one (6 rule 10). *)
