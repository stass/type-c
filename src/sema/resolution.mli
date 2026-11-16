(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one check of the resolution property of moved text (design 13.5):
    that a text which lowering writes at a place other than its own reads
    there as it reads at its own place, and declares no name that the
    text after it would lose. The check compares what the parser
    resolved in the text with the scopes at a place of writing: a view
    of the parser's ({!Typec_syntax.Parser.View}), the file scope in
    front of an external declaration or any other scope that a view is
    taken in, with what lowering declares there.

    The reader that typed the text gives what it found there: each name
    that the text uses, with the declaration that the parser resolved it
    to, and each name that the text declares. The check reads the
    identifiers of the text's attribute arguments itself, which typing
    does not read (unread text). *)

open Typec_cpp
open Typec_syntax

(** The two name spaces that a view holds (C11 6.2.3), with the
    declaration of a name in one of them. *)
type declaration = Ordinary of Tree.reference | Tag of Tree.tag_id

(** A name of the text, at [span], with its declaration at the text's own
    place. *)
type name = { name : string; span : Tree.span; declaration : declaration }

(** A name that the text declares, in the scope [scope], as the parser
    recorded it. [implicit] holds for a tag that it declares only
    because none of its name is visible (C11 6.7.2.3p8), which a tag of
    the scope around the text would replace. [linked] holds for an
    object or a function with linkage. *)
type own = {
  declared : name;
  implicit : bool;
  linked : bool;
  scope : Tree.scope_depth;
}

(** The kinds of moved text that {!check} reads: the definition of a
    generic (design 3.5 rule 8) and the operand of a [try] (5.1 rule 3).
    A failure on the operand of a [try] carries the code of its kind,
    whichever clause fails; one on the definition of a generic carries
    the code of the clause. *)
type kind = Generic_definition | Try_operand

(** The moved text: its kind, its tokens, the scope that holds it, the
    view around it at its own place, which is that in front of the
    declaration that holds a generic's definition and at the operand of
    a [try], and what its reader found in it: each name that it uses, a
    use of a declaration within the text, such as of a type parameter,
    included, and each name that it declares. A name that the text
    declares in [scope], as a first mention of a tag in a member of a
    structure does, is in scope after the text ({!Tree.scope_depth}). *)
type text = {
  kind : kind;
  span : Tree.span;
  scope : Tree.scope_depth;
  own_place : Parser.View.t;
  uses : name list;
  declares : own list;
}

(** A name that lowering declares at a place of writing besides the
    source's declarations, which it writes for the text at [written_for]
    (design 10.3): the typedef name and tag of the variant or record
    alias whose forward declaration the instance follows, and the tag of
    the [struct T;] line of a tag that a type argument names. *)
type lowered = { lowered_name : string; written_for : Tree.span }

(** A place of writing: the view of the source's declarations there,
    which the parser takes in front of an external declaration or in any
    other scope, the index in [Reader.t.tokens] of the token that the
    place stands in front of, and the typedef names and tags that
    lowering declares after the source's declarations. *)
type place = {
  view : Parser.View.t;
  before : int;
  typedef_names : lowered list;
  tags : lowered list;
}

(** Values by the index of a token in [Reader.t.tokens]; a token holds
    at most one declarator's name or one specifier's first token. *)
module Events : Map.S with type key = int

(** What the check asks of the reader of the unit: its tokens, the
    parser's views of its unread text, what each declaration declares and
    each tag declaration names, as the reader records them, and whether
    two types are the same (6.7p3). The events of the window of design
    13.5 that the reader has met are kept apart, as a window after the
    text reads only the first kind: [redeclared] holds each inexact
    declaration of an entity declared before it, at its name, with the
    entity as that declaration records it, and [completed] each tag
    completed, at the first token of its specifier. *)
type context = {
  tokens : Reader.t;
  views : Parser.views;
  entity : Tree.reference -> Entity.t option;
  tag : Tree.tag_id -> Ctype.named_tag option;
  redeclared : Entity.t Events.t;
  completed : Ctype.named_tag Events.t;
  same_type : Ctype.t -> Ctype.t -> bool Unknown.answer;
}

val check :
  context ->
  text ->
  at:place option ->
  (unit, Tree.span * Rule.diagnostic) result
(** [check context text ~at] is [Ok ()] when [text] declares no name that
    is in scope after it, and, where lowering writes it at the place [at],
    reads there as at its own place; otherwise it is a point of the text
    that breaks the property, the first that the clauses meet in their
    order, with the diagnostic that cites the declaration that makes it
    so, under the code that the text's {!kind} gives. A text that
    lowering writes nowhere, as
    the definition of a generic is in its check, has no place [at]. *)

val check_spelled :
  context -> name list -> at:place -> (unit, Tree.span * Rule.diagnostic) result
(** [check_spelled context names ~at] is the first half of the property
    for a text that lowering makes rather than moves, and that spells
    [names] of the source at the place [at], as the typedef of a type
    argument does (design 10.3): each is a use of its declaration, which
    the text holds none of, and its declaration at [at] is exact, as no
    own place of the text vouches for it. The result is that of
    {!check}. *)
