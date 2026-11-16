(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type declaration = Ordinary of Tree.reference | Tag of Tree.tag_id
type name = { name : string; span : Tree.span; declaration : declaration }
type own = {
  declared : name;
  implicit : bool;
  linked : bool;
  scope : Tree.scope_depth;
}

type kind = Generic_definition | Try_operand

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

type context = {
  tokens : Reader.t;
  views : Parser.views;
  entity : Tree.reference -> Entity.t option;
  tag : Tree.tag_id -> Ctype.named_tag option;
  redeclared : Entity.t Events.t;
  completed : Ctype.named_tag Events.t;
  same_type : Ctype.t -> Ctype.t -> bool Unknown.answer;
}

(* Raised at the first point of the text that breaks the property, with
   the rule of the clause that it breaks; caught in [checking]. *)
exception Reads_otherwise of Tree.span * Rule.t * string

let quote = Expressions.quote

let refuse span rule message = raise (Reads_otherwise (span, rule, message))

(* The rule whose code a failure on a text of [kind] carries, for the
   rule [clause] of the clause that fails: the code of the kind (design
   13.5), where the kind has one. *)
let kind_rule kind clause =
  match kind with
  | Generic_definition -> clause
  | Try_operand -> Rule.Try_moved_operand

(* The one failure path: [run] of the clauses, with the failure made a
   diagnostic under the rule that [rule_of] gives for its clause. *)
let checking rule_of run =
  match run () with
  | () -> Ok ()
  | exception Reads_otherwise (span, clause, message) ->
      Error (span, Rule.message (rule_of clause) message)

let location_of context index =
  let location = context.tokens.tokens.(index).location in
  Printf.sprintf "%s:%d" location.file location.line

(* Where the declaration stands, as a message cites it. *)
let declared_at context declaration =
  match declaration with
  | Ordinary (In_tree (Ordinary_at index)) | Tag (Tag_at index) ->
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

(* A use of a declaration within the text is its own at every place. *)
let is_outside text declaration =
  let within index = text.span.first <= index && index <= text.span.last in
  match declaration with
  | Ordinary (In_tree (Ordinary_at index)) | Tag (Tag_at index) ->
      not (within index)
  | Ordinary (Builtin _) -> true

let type_of (entity : Entity.t) =
  match entity.declared with
  | Object { object_type; _ } -> object_type
  | Function { function_type; _ } -> function_type
  | Typedef { typedef_type; _ } -> typedef_type
  | Enumerator { enumerator_type; _ } -> enumerator_type

(* What the backend reads as a typedef name: a Type-C type that is no
   generic lowers to the typedef of its name (design 10.1). *)
let is_c_typedef (found : Parser.ordinary option) =
  match found with
  | Some { kind = Typedef_name | Declared_type { parameters = 0; _ }; _ } ->
      true
  | Some
      { kind = Not_a_type | Declared_type _ | Type_parameter
             | Derived_enumerator; _ }
  | None ->
      false

(* A C entity of the name, which lowering writes under that name. *)
let is_c_entity (found : Parser.ordinary option) =
  match found with
  | Some
      { kind = Not_a_type | Typedef_name | Declared_type { parameters = 0; _ }
             | Derived_enumerator; _ } ->
      true
  | Some { kind = Declared_type _ | Type_parameter; _ } | None -> false

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
      | Ordinary _ -> quote own.declared.name
    in
    refuse own.declared.span Moved_declaration
      (Printf.sprintf
         "%s is declared in the scope around the text, which lowering \
          writes elsewhere, so the text after it would lose the \
          declaration; declare it before the text"
         named)

(* The third clause on a declaration with linkage, in any scope of the
   text: it declares an entity that the text around it sees, so what it
   says reaches that text where lowering writes it, and the window
   leaves out the text's own declarations. *)
let check_linkage (own : own) =
  if own.linked then
    refuse own.declared.span Moved_declaration
      (Printf.sprintf
         "%s is declared with linkage in the text, which lowering writes \
          elsewhere, so the declaration may change it for the text around \
          it there; declare it outside the text"
         (quote own.declared.name))

let refuse_unread_declaration index what =
  refuse { first = index; last = index } Moved_declaration
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
      refuse span Moved_text
        (Printf.sprintf
           "the declaration of %s at %s, between the text and a place where \
            lowering writes it, changes the type that the text uses"
           (quote name) cited)
  | Depends_on unknown ->
      refuse span Moved_text_unknown
        (Printf.sprintf
           "the declaration of %s at %s, between the text and a place where \
            lowering writes it, may change the type that the text uses: \
            that depends on %s, whose type typec does not compute"
           (quote name) cited unknown.construct)

let refuse_other_entity context span name cited =
  refuse span Moved_text
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
          refuse span Moved_text
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

let check_tag context place span name tag =
  match tag_at place name with
  | Some (Source (Tag found)) when found = tag || same_tag context tag found ->
      ()
  | Some cited ->
      refuse span Moved_text
        (Printf.sprintf
           "the tag %s denotes another tag where lowering writes the text, %s"
           (quote name) (cite context cited))
  | None ->
      refuse span Moved_text
        (Printf.sprintf
           "the tag %s is not visible where lowering writes the text"
           (quote name))

let check_name context place (use : name) =
  match use.declaration with
  | Ordinary reference ->
      check_ordinary context place use.span use.name reference
  | Tag tag -> check_tag context place use.span use.name tag

(* A place stands in front of the token [before], so an event at that
   token follows the place. *)
let place_precedes text place = place.before <= text.span.first

(* The events of [events] in the window of design 13.5: between the
   text's own place and the place of writing, in either order, without
   those of the text itself, which move with it. *)
let within_window text place events =
  let first, after =
    if place_precedes text place then (place.before, text.span.first)
    else (text.span.last + 1, place.before)
  in
  Events.to_seq_from first events
  |> Seq.take_while (fun (index, _) -> index < after)

(* The window as the check reads it: the index of a declaration of each
   object or function declared again inexactly in it, by entity, so that
   each use costs one lookup; the typedef names declared so; and the tags
   completed in it, which only a place before the text reads. *)
type window = {
  objects : (int, int) Hashtbl.t;
  typedefs : (int * Entity.t) list;
  completions : (int * Ctype.named_tag) list;
}

let window context text place =
  let objects = Hashtbl.create 8 and typedefs = ref [] in
  let sort (index, (again : Entity.t)) =
    match again.declared with
    | Object _ | Function _ -> Hashtbl.replace objects again.entity index
    | Typedef _ -> typedefs := (index, again) :: !typedefs
    | Enumerator _ -> ()
  in
  Seq.iter sort (within_window text place context.redeclared);
  let completions =
    if place_precedes text place then
      List.of_seq (within_window text place context.completed)
    else []
  in
  { objects; typedefs = !typedefs; completions }

(* The view at the earlier of the two places, which sees what is
   declared before both. *)
let earlier_view text place =
  if place_precedes text place then place.view else text.own_place

(* The window's first clause: only a use of its name reads an object or
   a function, so one declared again inexactly in the window changes
   what the text reads where the text uses it. typec's types hold no
   attribute, so it cannot tell that the declaration keeps the type. *)
let check_redeclared context window (use : name) (used : Entity.t) =
  match Hashtbl.find_opt window.objects used.entity with
  | Some index ->
      refuse use.span Moved_text
        (Printf.sprintf
           "the declaration of %s at %s, between the text and a place where \
            lowering writes it, gives it a type that may hold an attribute or \
            `typeof` of an expression, which may change the type that the \
            text uses"
           (quote use.name) (location_of context index))
  | None -> ()

let check_use context window text place (use : name) =
  if is_outside text use.declaration then (
    check_name context place use;
    match use.declaration with
    | Ordinary reference ->
        Option.iter
          (check_redeclared context window use)
          (context.entity reference)
    | Tag _ -> ())

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
    refuse text.span Moved_text
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
      refuse text.span Moved_text
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
          refuse span Moved_text
            (Printf.sprintf
               "the text declares %s for itself, but where lowering writes \
                it %s is a typedef name, %s"
               (quote name) (quote name) (cite context cited))
      | Some _ | None -> ())
  | Tag _ when own.implicit -> (
      match tag_at place name with
      | Some cited ->
          refuse span Moved_text
            (Printf.sprintf
               "the text declares the tag %s in a scope of its own, but \
                where lowering writes it the tag is %s"
               (quote name) (cite context cited))
      | None -> ())
  | Tag _ -> ()

(* Lowering writes a [Parser.own_name] under a name of its own, but
   leaves unread text as the source spells it: the backend reads the
   spelling as the place declares it. The parser refuses one in the
   arguments of an attribute of Type-C text, and a type parameter there
   in any text, so this check reaches moved text that is C text. *)
let check_own_spelling context place span name own =
  match ordinary_at is_c_entity place name with
  | Some cited ->
      refuse span Unread_own_name
        (Printf.sprintf
           "%s in the arguments of an attribute denotes %s, but where \
            lowering writes the text the backend reads the declaration of \
            %s there, %s"
           (quote name) (Parser.own_name_kind own) (quote name)
           (cite context cited))
  | None -> ()

(* An identifier of unread text counts as a use of what it denotes at its
   own place, in either name space, as typec cannot tell which the
   backend reads; one that denotes nothing is a word of the attribute. *)
let check_unread_identifier context window text place view span name =
  let found = Parser.View.find view name in
  (match (Parser.own_name found name, found) with
  | Some own, _ -> check_own_spelling context place span name own
  | None, Some { declaration; _ } ->
      let use = { name; span; declaration = Ordinary declaration } in
      check_use context window text place use
  | None, None -> ());
  match Parser.View.find_tag view name with
  | Some tag ->
      check_use context window text place { name; span; declaration = Tag tag }
  | None -> ()

let check_unread context window text place ((arguments : Tree.span), view) =
  for index = arguments.first to arguments.last do
    match context.tokens.tokens.(index).kind with
    | Identifier name ->
        let span = { Tree.first = index; last = index } in
        check_unread_identifier context window text place view span name
    | Number | Character _ | String _ | Punctuator _ | Pragma _ | Typec_pragma
      ->
        ()
  done

(* The first two clauses, with the window, at a place where lowering
   writes the text. *)
let check_reading context text place =
  let window = window context text place in
  List.iter (check_use context window text place) text.uses;
  List.iter (check_own context text place) text.declares;
  List.iter
    (check_unread context window text place)
    (Parser.attributes_within context.views text.span);
  List.iter (check_typedef context text place) window.typedefs;
  List.iter (check_completion context text place) window.completions

let check context text ~at =
  checking (kind_rule text.kind) (fun () ->
      List.iter (check_scope text) text.declares;
      List.iter check_linkage text.declares;
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
          refuse use.span Moved_text
            (Printf.sprintf
               "the declaration of %s at %s gives it a type that may hold an \
                attribute or `typeof` of an expression, which the text that \
                lowering writes would carry"
               (quote use.name)
               (declared_at context (Ordinary declaration)))
      | Some _ | None -> ())
  | None -> ()

let check_spelled_name context place use =
  check_name context place use;
  check_exact context place use

(* The first half of the property for a text that lowering makes and
   that spells [names] of the source. *)
let check_spelled context names ~at =
  checking Fun.id (fun () -> List.iter (check_spelled_name context at) names)
