(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type declaration =
  | Ordinary of Tree.reference
  | Tag of Tree.tag_id
  | Label of Tree.label_id
type name = { name : string; span : Tree.span; declaration : declaration }
type own = {
  declared : name;
  implicit : bool;
  linked : bool;
  scope : Tree.scope_depth;
}

type kind =
  | Generic_definition
  | Try_operand
  | Deferred_statement
  | Return_operand
  | Array_operand

type text = {
  kind : kind;
  span : Tree.span;
  scope : Tree.scope_depth;
  own_place : Parser.View.t;
  uses : name list;
  declares : own list;
}

type lowered = { lowered_name : string; written_for : Tree.span }

type place = {
  view : Parser.View.t;
  before : int;
  typedef_names : lowered list;
  tags : lowered list;
}

module Events = Map.Make (Int)
module By_entity = Map.Make (Int)
module Positions = Set.Make (Int)

(* The inexact redeclarations, indexed by how a check reads them. A use
   reads those of its own object or function: [objects] holds their
   tokens by entity. Every check reads those of typedef names in its
   window: [typedefs] keys each by the token of the name's first
   declaration, which [first_typedef] holds for each typedef name
   declared again, so that a check passes over the names first declared
   in its window ([typedefs_within]). *)
type redeclarations = {
  objects : Positions.t By_entity.t;
  typedefs : Entity.t Keyed_events.t;
  first_typedef : int By_entity.t;
}

let no_redeclarations =
  { objects = By_entity.empty;
    typedefs = Keyed_events.empty;
    first_typedef = By_entity.empty }

(* The token of a declaration; a builtin's stands before the first. *)
let token_of = function
  | Tree.In_tree (Ordinary_at index) -> index
  | Builtin _ -> -1

let add_inexact_object token (entity : Entity.t) events =
  let add positions =
    let known = Option.value positions ~default:Positions.empty in
    Some (Positions.add token known)
  in
  { events with objects = By_entity.update entity.entity add events.objects }

(* Each redeclaration of a typedef name names the declaration before it
   in its scope ([Tree.declared.earlier]), a typedef declaration of the
   same entity (C11 6.7p3), so the earliest that they name is the first.
   The declarations of one scope are read in order, so the first
   redeclaration, which names the first declaration, is added before
   any inexact one. A redeclaration that names none stands before every
   token, so every window reads it. *)
let add_typedef token (declared : Tree.declared) (entity : Entity.t) events =
  let follows =
    match declared.earlier with
    | Some earlier -> token_of earlier
    | None -> min_int
  in
  let first =
    match By_entity.find_opt entity.entity events.first_typedef with
    | Some known -> min known follows
    | None -> follows
  in
  let first_typedef = By_entity.add entity.entity first events.first_typedef in
  let typedefs =
    if entity.inexact then
      Keyed_events.add token ~key:first entity events.typedefs
    else events.typedefs
  in
  { events with first_typedef; typedefs }

let add_redeclared (declared : Tree.declared) (entity : Entity.t) events =
  let (Ordinary_at token) = declared.id in
  match entity.declared with
  | (Object _ | Function _) when entity.inexact ->
      add_inexact_object token entity events
  | Typedef _ -> add_typedef token declared entity events
  | Object _ | Function _ | Enumerator _ -> events

type context = {
  tokens : Reader.t;
  views : Parser.views;
  entity : Tree.reference -> Entity.t option;
  tag : Tree.tag_id -> Ctype.named_tag option;
  redeclared : redeclarations;
  completed : Ctype.named_tag Events.t;
  same_type : Ctype.t -> Ctype.t -> bool Unknown.answer;
}

(* Whether a failure rests on facts that typec knows, or on a type that
   it does not compute (P21), which carries one name across the kinds. *)
type ground = Known | Unknown_type

(* Raised at the first point of the text that breaks the property, with
   the ground of the failure; caught in [checking]. *)
exception Reads_otherwise of Tree.span * ground * string

let quote = Expressions.quote

let refuse span message = raise (Reads_otherwise (span, Known, message))

let refuse_unknown span message =
  raise (Reads_otherwise (span, Unknown_type, message))

(* The code of a kind of moved text, which a failure on it carries
   whichever clause fails (design 13.5). *)
let kind_rule : kind -> Rule.t = function
  | Generic_definition -> Generic_moved
  | Try_operand -> Try_moved_operand
  | Deferred_statement -> Deferred_moved
  | Return_operand -> Return_operand_moved
  | Array_operand -> Array_operand_moved

(* The one failure path: [run] of the clauses, with the failure made a
   diagnostic under the name of [kind], or under the one name of a
   failure on an unknown type. *)
let checking kind run =
  match run () with
  | () -> Ok ()
  | exception Reads_otherwise (span, ground, message) ->
      let rule =
        match ground with
        | Known -> kind_rule kind
        | Unknown_type -> Rule.Moved_text_unknown
      in
      Error (span, Rule.message rule message)

let location_of context index =
  let location = context.tokens.tokens.(index).location in
  Printf.sprintf "%s:%d" location.file location.line

(* Where the declaration stands, as a message cites it. *)
let declared_at context declaration =
  match declaration with
  | Ordinary (In_tree (Ordinary_at index))
  | Tag (Tag_at index)
  | Label (Label_at index) ->
      location_of context index
  | Ordinary (Builtin _) -> "before the first token"

(* A declaration at a place of writing, which a message cites: one of
   the source, or one that lowering writes. *)
type cited = Source of declaration | Lowered of lowered

let cite context = function
  | Source declaration ->
      "the one declared at " ^ declared_at context declaration
  | Lowered lowered ->
      "the one that lowering declares for the source at "
      ^ location_of context lowered.written_for.first

let find_lowered lowered name =
  List.find_opt (fun entry -> entry.lowered_name = name) lowered

(* A use of a declaration within the text is its own at every place.
   The first mention of a function's label declares it, wherever that
   stands, so a label name is checked at every place. *)
let is_outside text declaration =
  let within index = text.span.first <= index && index <= text.span.last in
  match declaration with
  | Ordinary (In_tree (Ordinary_at index)) | Tag (Tag_at index) ->
      not (within index)
  | Ordinary (Builtin _) | Label _ -> true

let type_of (entity : Entity.t) =
  match entity.declared with
  | Object { object_type; _ } -> object_type
  | Function { function_type; _ } -> function_type
  | Typedef { typedef_type; _ } -> typedef_type
  | Enumerator { enumerator_type; _ } -> enumerator_type

(* A C entity of the name, which lowering writes under that name. *)
let is_c_entity (found : Parser.ordinary option) =
  match found with
  | Some { kind; _ } -> not (Parser.has_own_name kind)
  | None -> false

(* What the backend reads as a typedef name: a Type-C type that is no
   generic lowers to the typedef of its name (design 10.1). *)
let is_c_typedef (found : Parser.ordinary option) =
  match found with
  | Some { kind; _ } -> Parser.names_type kind && is_c_entity found
  | None -> false

(* The declaration of the ordinary identifier [name] at the place, if
   [is_kind] holds of it there: the source's, or a typedef name that
   lowering declares, which follows no source declaration of its name in
   one scope, as C refuses that. *)
let ordinary_at is_kind place name =
  let found = Parser.View.find place.view name in
  match found with
  | Some { declaration; _ } when is_kind found ->
      Some (Source (Ordinary declaration))
  | Some _ -> None
  | None ->
      Option.map
        (fun entry -> Lowered entry)
        (find_lowered place.typedef_names name)

(* The tag [name] at the place, if any: the source's, or that of a line
   that lowering writes, which declares a tag of file scope again where
   the source has one. *)
let tag_at place name =
  match Parser.View.find_tag place.view name with
  | Some tag -> Some (Source (Tag tag))
  | None ->
      Option.map (fun entry -> Lowered entry) (find_lowered place.tags name)

(* The third clause: moved text declares no name that is in scope after
   it, which the text after its own place would lose and the text after
   a place of writing gain. A text closes every scope that opens in it,
   so a name it declares is in scope after it exactly when it is
   declared in the scope that holds the text, the only one no deeper. *)
let check_scope text (own : own) =
  let (Scope_depth declared) = own.scope in
  let (Scope_depth around) = text.scope in
  if declared <= around then
    let named =
      match own.declared.declaration with
      | Tag _ -> "the tag " ^ quote own.declared.name
      | Label _ -> "the label " ^ quote own.declared.name
      | Ordinary _ -> quote own.declared.name
    in
    let written =
      match text.kind with
      | Array_operand ->
          "which lowering writes again as the operand of `sizeof`, where \
           it would declare it a second time"
      | Generic_definition | Try_operand | Deferred_statement
      | Return_operand ->
          "which lowering writes elsewhere or in a block of its own, so \
           the text after it would lose the declaration"
    in
    refuse own.declared.span
      (Printf.sprintf
         "%s is declared in the scope around the text, %s; declare it \
          before the text"
         named written)

(* The third clause on a declaration with linkage, in any scope of the
   text: it declares an entity that the text around it sees, so what it
   says reaches that text where lowering writes it, and the window
   leaves out the text's own declarations. *)
let check_linkage (own : own) =
  if own.linked then
    refuse own.declared.span
      (Printf.sprintf
         "%s is declared with linkage in the text, which lowering writes \
          elsewhere, so the declaration may change it for the text around \
          it there; declare it outside the text"
         (quote own.declared.name))

let refuse_unread_declaration index what =
  refuse { first = index; last = index }
    (Printf.sprintf
       "%s in the arguments of an attribute, which typing does not read, \
        may declare a name that the text around it sees, and lowering \
        writes the text elsewhere"
       what)

let is_tag_keyword name = name = "struct" || name = "union" || name = "enum"

(* Whether the tag keyword at [index] declares its tag: it names none, or
   one that is not visible (C11 6.7.2.3p8). *)
let declares_tag context (arguments : Tree.span) view index =
  if index = arguments.last then true
  else
    match context.tokens.tokens.(index + 1).kind with
    | Identifier name -> Option.is_none (Parser.View.find_tag view name)
    | Number | Character _ | String _ | Punctuator _ | Pragma _ | Typec_pragma
      ->
        true

(* The same clauses where typing reads no declaration, in the arguments
   of an attribute: the only tokens there that can declare are a brace,
   which may open a block, and a tag keyword. Every brace is refused, as
   typec cannot tell a block from an initialiser's braces. *)
let check_unread_declarations context ((arguments : Tree.span), view) =
  for index = arguments.first to arguments.last do
    match context.tokens.tokens.(index).kind with
    | Punctuator Punctuator.Left_brace ->
        refuse_unread_declaration index "a brace"
    | Identifier name
      when is_tag_keyword name && declares_tag context arguments view index ->
        refuse_unread_declaration index
          "a tag keyword that names no visible tag"
    | Identifier _ | Number | Character _ | String _ | Punctuator _
    | Pragma _ | Typec_pragma ->
        ()
  done

(* The entity that the use denotes where the text is written has the
   type that it has at the text's own place. Completing a structure
   changes neither; a declaration whose effect on the type depends on an
   unknown type is refused (P21). *)
let check_same_type context span name ~declaration (used : Entity.t) there =
  let cited = declared_at context declaration in
  match context.same_type (type_of used) (type_of there) with
  | Answer true -> ()
  | Answer false ->
      refuse span
        (Printf.sprintf
           "the declaration of %s at %s, between the text and a place where \
            lowering writes it, changes the type that the text uses"
           (quote name) cited)
  | Depends_on unknown ->
      refuse_unknown span
        (Printf.sprintf
           "the declaration of %s at %s, between the text and a place where \
            lowering writes it, may change the type that the text uses: \
            that depends on %s, whose type typec does not compute"
           (quote name) cited unknown.construct)

let refuse_other_entity context span name cited =
  refuse span
    (Printf.sprintf
       "%s denotes another entity where lowering writes the text, %s"
       (quote name) (cite context cited))

(* The first half of the property for a use: the same entity where the
   text is written, with the same type. *)
let check_ordinary context place span name reference =
  match Parser.View.find place.view name with
  | Some { declaration; _ } when declaration = reference -> ()
  | Some { declaration; _ } -> (
      let there = context.entity declaration in
      match (context.entity reference, there) with
      | Some used, Some there when used.entity = there.entity ->
          let cited = Ordinary declaration in
          check_same_type context span name ~declaration:cited used there
      | Some _, Some _ | None, _ | _, None ->
          refuse_other_entity context span name (Source (Ordinary declaration)))
  | None -> (
      match find_lowered place.typedef_names name with
      | Some lowered -> refuse_other_entity context span name (Lowered lowered)
      | None ->
          refuse span
            (Printf.sprintf "%s is not visible where lowering writes the text"
               (quote name)))

let same_named_tag (first : Ctype.named_tag) (second : Ctype.named_tag) =
  match (first, second) with
  | Named_record a, Named_record b -> a.record_id = b.record_id
  | Named_enum a, Named_enum b -> a.enum_id = b.enum_id
  | (Named_record _ | Named_enum _), _ -> false

(* Whether two tag declarations declare one tag, as a completion or a
   redeclaration does (C11 6.7.2.3p4). *)
let same_tag context first second =
  match (context.tag first, context.tag second) with
  | Some a, Some b -> same_named_tag a b
  | Some _, None | None, _ -> false

(* Whether the tag of [name] at the place is [tag]. *)
let sees_tag context place name tag =
  match tag_at place name with
  | Some (Source (Tag found)) -> found = tag || same_tag context tag found
  | Some (Source (Ordinary _ | Label _) | Lowered _) | None -> false

let check_tag context place span name tag =
  if not (sees_tag context place name tag) then
    match tag_at place name with
    | Some cited ->
        refuse span
          (Printf.sprintf
             "the tag %s denotes another tag where lowering writes the text, \
              %s"
             (quote name) (cite context cited))
    | None ->
        refuse span
          (Printf.sprintf
             "the tag %s is not visible where lowering writes the text"
             (quote name))

let refuse_other_label (use : name) cited =
  refuse use.span
    (Printf.sprintf
       "the label %s denotes another label where lowering writes the text, \
        %s"
       (quote use.name) cited)

(* A label name denotes the innermost GNU local label of its name, or
   else the label of its name of the function, which is one label at
   every place of the body (C11 6.2.1p3). So the name of an [&&] reads
   one label at both places when the local labels of its name visible
   there agree. A text that declares the local label itself, in a
   statement expression, is held to the same and may be refused though
   it would read its own; a deferred statement declares none (design 6
   rule 9). *)
let check_label context text place (use : name) =
  let own = Parser.View.find_local_label text.own_place use.name in
  match Parser.View.find_local_label place.view use.name with
  | there when there = own -> ()
  | Some label ->
      refuse_other_label use (cite context (Source (Label label)))
  | None -> refuse_other_label use "the label of the function"

(* A place stands in front of the token [before], so an event at that
   token follows the place. *)
let place_precedes text place = place.before <= text.span.first

(* The window of design 13.5, the tokens from [first] to before [after]:
   between the text's own place and the place of writing, in either
   order, without the text itself, whose events move with it. *)
type window = { first : int; after : int }

let window_of text place =
  if place_precedes text place then
    { first = place.before; after = text.span.first }
  else { first = text.span.last + 1; after = place.before }

let within window events =
  Events.to_seq_from window.first events
  |> Seq.take_while (fun (index, _) -> index < window.after)

(* The inexact redeclarations of typedef names in the window, of names
   first declared before it. The earlier place stands at or before the
   window's first token and its view sees only the names declared
   before it, so the second clause refuses none of the rest. *)
let typedefs_within window redeclared =
  Keyed_events.between redeclared.typedefs ~from:window.first
    ~before:window.after ~key_below:window.first

(* The first inexact redeclaration of [entity] in the window, if any,
   which a refusal cites, as the typedef clause cites its first. *)
let redeclared_within context window (entity : Entity.t) =
  let positions =
    By_entity.find_opt entity.entity context.redeclared.objects
    |> Option.value ~default:Positions.empty
  in
  let at_or_after_first index = index >= window.first in
  match Positions.find_first_opt at_or_after_first positions with
  | Some index when index < window.after -> Some index
  | Some _ | None -> None

(* The view at the earlier of the two places, which sees what is
   declared before both. *)
let earlier_view text place =
  if place_precedes text place then place.view else text.own_place

(* The window's first clause: only a use of its name reads an object or
   a function, so one declared again inexactly in the window changes
   what the text reads where the text uses it. typec's types hold no
   attribute, so it cannot tell that the declaration keeps the type. *)
let check_redeclared context window (use : name) (used : Entity.t) =
  match redeclared_within context window used with
  | Some index ->
      refuse use.span
        (Printf.sprintf
           "the declaration of %s at %s, between the text and a place where \
            lowering writes it, gives it a type that may hold an attribute or \
            `typeof` of an expression, which may change the type that the \
            text uses"
           (quote use.name) (location_of context index))
  | None -> ()

(* Design 5.1 rule 3: a try runs before the rest of its holder, so its
   operand names nothing that the holder declares before it, which is
   what the window holds where the place of writing precedes the try. A
   label has function scope and is checked at the place instead. *)
let holder_declares context text place window (use : name) =
  let in_window index = window.first <= index && index < window.after in
  let precedes = place_precedes text place in
  match (text.kind, use.declaration) with
  | Try_operand, Ordinary (In_tree (Ordinary_at index)) ->
      precedes && in_window index
  (* A tag declared before the holder and completed in it is checked as
     a completion. *)
  | Try_operand, Tag (Tag_at index as tag) ->
      precedes && in_window index
      && not (sees_tag context place use.name tag)
  | Try_operand, (Ordinary (Builtin _) | Label _)
  | ( (Generic_definition | Deferred_statement | Return_operand
      | Array_operand),
      _ ) ->
      false

let is_object_entity context reference =
  match context.entity reference with
  | Some { declared = Object _; _ } -> true
  | Some { declared = Function _ | Typedef _ | Enumerator _; _ } | None ->
      false

(* A holder that declares an object is a declaration of that one object
   (design 5.1 rule 3), so the object is the one its try initialises. *)
let refuse_own_declarator (use : name) =
  let name = quote use.name in
  refuse use.span
    (Printf.sprintf
       "%s is declared by the declaration that holds this try, and the try \
        runs before that declaration, so its operand cannot use %s; declare \
        %s first, in a declaration of its own, and give it the try's value \
        after"
       name name name)

let refuse_declared_before_try (use : name) described =
  refuse use.span
    (Printf.sprintf
       "%s is declared before this try in the statement or declaration that \
        holds it, and the try runs before all of that, so its operand cannot \
        use %s; declare %s before that statement or declaration"
       described described described)

let refuse_holder_declared context (use : name) =
  match use.declaration with
  | Ordinary reference when is_object_entity context reference ->
      refuse_own_declarator use
  | Ordinary _ | Label _ -> refuse_declared_before_try use (quote use.name)
  | Tag _ -> refuse_declared_before_try use ("the tag " ^ quote use.name)

let check_use context window text place (use : name) =
  if holder_declares context text place window use then
    refuse_holder_declared context use;
  if is_outside text use.declaration then
    match use.declaration with
    | Ordinary reference ->
        check_ordinary context place use.span use.name reference;
        Option.iter
          (check_redeclared context window use)
          (context.entity reference)
    | Tag tag -> check_tag context place use.span use.name tag
    | Label _ -> check_label context text place use

(* Whether [view] gives the name of [entity] that entity. *)
let denotes context view (entity : Entity.t) =
  match Parser.View.find view entity.name with
  | Some { declaration; _ } -> (
      match context.entity declaration with
      | Some found -> found.entity = entity.entity
      | None -> false)
  | None -> false

(* The window's second clause, which holds whether or not the text uses
   the name: GCC changes a typedef name declared again inexactly in
   place, and with it every declaration and member written through it. *)
let check_typedef context text place (index, (typedef : Entity.t)) =
  if denotes context (earlier_view text place) typedef then
    refuse text.span
      (Printf.sprintf
         "the declaration of the typedef name %s at %s, between the text and \
          a place where lowering writes it, gives it a type that may hold an \
          attribute or `typeof` of an expression, which may change each type \
          written through it"
         (quote typedef.name) (location_of context index))

(* The name of [tag] if the place declares that tag under it. *)
let tag_at_place context place (tag : Ctype.named_tag) =
  let name =
    match tag with
    | Named_record { record_name = Named name; _ } -> Some name
    | Named_record _ -> None
    | Named_enum { enum_name; _ } -> enum_name
  in
  let declares name =
    match Parser.View.find_tag place.view name with
    | Some found -> (
        match context.tag found with
        | Some declared -> same_named_tag declared tag
        | None -> false)
    | None -> false
  in
  match name with
  | Some name when declares name -> Some name
  | Some _ | None -> None

(* The window's third clause, which holds whether or not the text names
   the tag: a tag completed after a place of writing is incomplete there,
   before the text. *)
let check_completion context text place (index, tag) =
  match tag_at_place context place tag with
  | Some name ->
      refuse text.span
        (Printf.sprintf
           "the tag %s is completed at %s, between a place where lowering \
            writes the text and the text, so it is incomplete there"
           (quote name) (location_of context index))
  | None -> ()

(* The second half: a name that the text declares for itself is read as
   a declarator, so it must not become a typedef name of the scope
   around it, and a tag that the text declares only because none is
   visible must not become one of that scope (C11 6.2.1p4, 6.7.2.3p8). *)
let check_own context text place (own : own) =
  let { name; span; declaration } = own.declared in
  match declaration with
  | Ordinary _ -> (
      let own_place = Parser.View.find text.own_place name in
      let typedef_before = is_c_typedef own_place in
      match ordinary_at is_c_typedef place name with
      | Some cited when not typedef_before ->
          refuse span
            (Printf.sprintf
               "the text declares %s for itself, but where lowering writes \
                it %s is a typedef name, %s"
               (quote name) (quote name) (cite context cited))
      | Some _ | None -> ())
  | Tag _ when own.implicit -> (
      match tag_at place name with
      | Some cited ->
          refuse span
            (Printf.sprintf
               "the text declares the tag %s in a scope of its own, but \
                where lowering writes it the tag is %s"
               (quote name) (cite context cited))
      | None -> ())
  | Tag _ | Label _ -> ()

(* The C entity of the ordinary identifier [name] that [view] sees, which
   a declaration of [name] in a scope inside it hides. *)
let hidden_in view name =
  match Parser.View.find view name with
  | Some { declaration; _ } as found when is_c_entity found ->
      Some (Source (Ordinary declaration))
  | Some _ | None -> None

(* A name that a deferred statement declares hides, at each copy, what it
   hides at the defer: a declaration of the scope that the copy lands in
   would be hidden there alone, and -Wshadow warns of most such copies
   of code that hides nothing as written (design 6 rule 8). Neither
   backend warns of a tag or label that hides another. *)
let check_hidden context text place (own : own) =
  let { name; span; declaration } = own.declared in
  match declaration with
  | Ordinary _ -> (
      match ordinary_at is_c_entity place name with
      | Some cited when Some cited <> hidden_in text.own_place name ->
          refuse span
            (Printf.sprintf
               "%s is declared in the statement of the defer, and at an \
                exit where lowering copies the statement, %s is %s, \
                which the copy would hide; rename one of them"
               (quote name) (quote name) (cite context cited))
      | Some _ | None -> ())
  | Tag _ | Label _ -> ()

(* Only the copies of a deferred statement are held to hiding what the
   text hides at its own place. *)
let keeps_what_it_hides = function
  | Deferred_statement -> true
  | Generic_definition | Try_operand | Return_operand | Array_operand ->
      false

(* Unread text of moved text, which a message names: the arguments of an
   attribute, or a [#pragma] line (design 13.5). *)
type unread = { within : string; unread_view : Parser.View.t }

(* Lowering writes a [Parser.own_name] under a name of its own, but
   leaves unread text as the source spells it: the backend reads the
   spelling as the place declares it. The parser refuses one in the
   arguments of an attribute of Type-C text, and a type parameter there
   in any text, so for an attribute this check reaches moved text that
   is C text; a pragma line is held to it in any moved text. *)
let check_own_spelling context place unread span name own =
  match ordinary_at is_c_entity place name with
  | Some cited ->
      refuse span
        (Printf.sprintf
           "%s in %s denotes %s, but where lowering writes the text the \
            backend reads the declaration of %s there, %s"
           (quote name) unread.within (Parser.own_name_kind own) (quote name)
           (cite context cited))
  | None -> ()

(* An identifier of unread text counts as a use of what it denotes at its
   own place, in either name space, as typec cannot tell which the
   backend reads; one that denotes nothing is a word of the attribute. *)
let check_unread_identifier context window text place unread span name =
  let found = Parser.View.find unread.unread_view name in
  (match (Parser.own_name found name, found) with
  | Some own, _ -> check_own_spelling context place unread span name own
  | None, Some { declaration; _ } ->
      let use = { name; span; declaration = Ordinary declaration } in
      check_use context window text place use
  | None, None -> ());
  match Parser.View.find_tag unread.unread_view name with
  | Some tag ->
      check_use context window text place { name; span; declaration = Tag tag }
  | None -> ()

let check_attribute context window text place
    ((arguments : Tree.span), unread_view) =
  let unread = { within = "the arguments of an attribute"; unread_view } in
  for index = arguments.first to arguments.last do
    match context.tokens.tokens.(index).kind with
    | Identifier name ->
        let span = { Tree.first = index; last = index } in
        check_unread_identifier context window text place unread span name
    | Number | Character _ | String _ | Punctuator _ | Pragma _ | Typec_pragma
      ->
        ()
  done

(* The identifiers of a pragma line are those among its preprocessing
   tokens, which the reader keeps on its one token. The parser refuses a
   line of moved text that is no sequence of them, and lowering moves no
   [#pragma typec] line. *)
let check_pragma context window text place (index, unread_view) =
  let unread = { within = "a `#pragma` line"; unread_view } in
  let span = { Tree.first = index; last = index } in
  match context.tokens.tokens.(index).kind with
  | Pragma (Identifiers names) ->
      List.iter (check_unread_identifier context window text place unread span)
        names
  | Pragma (Not_tokens _)
  | Typec_pragma | Identifier _ | Number | Character _ | String _
  | Punctuator _ ->
      ()

(* The first two clauses, the window and, for a deferred statement, what
   its names hide, at a place where lowering writes the text. *)
let check_reading context text place =
  let window = window_of text place in
  List.iter (check_use context window text place) text.uses;
  (* Both clauses on one name before the next, so that a failure cites
     the first name of the text that breaks either. *)
  let check_declared own =
    check_own context text place own;
    if keeps_what_it_hides text.kind then check_hidden context text place own
  in
  List.iter check_declared text.declares;
  List.iter
    (check_attribute context window text place)
    (Parser.attributes_within context.views text.span);
  List.iter
    (check_pragma context window text place)
    (Parser.pragmas_within context.views text.span);
  Seq.iter
    (check_typedef context text place)
    (typedefs_within window context.redeclared);
  (* A completion changes nothing for text written after it. *)
  if place_precedes text place then
    Seq.iter
      (check_completion context text place)
      (within window context.completed)

(* Lowering writes the operand of a return, and the second writing of
   the operand of a [slice_from_array], at its own place, so what it
   declares with linkage reaches no other text (design 13.5). *)
let moves = function
  | Generic_definition | Try_operand | Deferred_statement -> true
  | Return_operand | Array_operand -> false

let check context text ~at =
  checking text.kind (fun () ->
      List.iter (check_scope text) text.declares;
      if moves text.kind then List.iter check_linkage text.declares;
      List.iter
        (check_unread_declarations context)
        (Parser.attributes_within context.views text.span);
      Option.iter (check_reading context text) at)

(* A name that lowering spells in a text of its own has no own place
   whose exactness 3.5 rule 2 vouches for: the declarator that gives it
   may carry the attribute itself, so its declaration at the place must
   be exact as well. *)
let check_exact context place (use : name) =
  match Parser.View.find place.view use.name with
  | Some { declaration; _ } -> (
      match context.entity declaration with
      | Some there when there.inexact ->
          refuse use.span
            (Printf.sprintf
               "the declaration of %s at %s gives it a type that may hold an \
                attribute or `typeof` of an expression, which the text that \
                lowering writes would carry"
               (quote use.name)
               (declared_at context (Ordinary declaration)))
      | Some _ | None -> ())
  | None -> ()

(* Lowering spells no label. *)
let check_spelled_name context place (use : name) =
  match use.declaration with
  | Ordinary reference ->
      check_ordinary context place use.span use.name reference;
      check_exact context place use
  | Tag tag ->
      check_tag context place use.span use.name tag;
      check_exact context place use
  | Label _ -> ()

(* The first half of the property for a text that lowering makes and
   that spells [names] of the source. The one name of an untagged type
   is written into an instance, as the definition of a generic is, and
   is refused under the same name. *)
let check_spelled context names ~at =
  checking Generic_definition (fun () ->
      List.iter (check_spelled_name context at) names)
