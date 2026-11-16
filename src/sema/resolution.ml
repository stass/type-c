(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

type declaration = Ordinary of Tree.reference | Tag of Tree.tag_id
type name = { name : string; span : Tree.span; declaration : declaration }
type own = { declared : name; implicit : bool; scope : Tree.scope_depth }

type text = {
  span : Tree.span;
  scope : Tree.scope_depth;
  own_place : Parser.View.t;
  uses : name list;
  declares : own list;
}

type lowered = { lowered_name : string; written_for : Tree.span }

type place = {
  view : Parser.View.t;
  typedef_names : lowered list;
  tags : lowered list;
}

type context = {
  tokens : Reader.t;
  views : Parser.views;
  entity : Tree.reference -> Entity.t option;
  same_tag : Tree.tag_id -> Tree.tag_id -> bool;
  same_type : Ctype.t -> Ctype.t -> bool Unknown.answer;
}

(* Raised at the first point of the text that breaks the property;
   caught in [check]. *)
exception Reads_otherwise of Tree.span * Rule.diagnostic

let quote = Expressions.quote

let refuse span rule message =
  raise (Reads_otherwise (span, Rule.message rule message))

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

(* Whether the entity is a typedef name whose type for the backend may
   hold an attribute that its typec type lacks (design 3.5 rule 2). *)
let is_inexact (entity : Entity.t) =
  match entity.declared with
  | Typedef { inexact; _ } -> inexact
  | Object _ | Function _ | Enumerator _ -> false

(* The backend reads a type with its attributes, which typec's types do
   not hold, so typec cannot tell that a typedef name declared again
   with one keeps the type it has at the text's own place; the
   exactness of a type argument (design 3.5 rule 2), read at that
   place, rests on this. *)
let check_same_attributes context span name ~cited there =
  if is_inexact there then
    refuse span Moved_text
      (Printf.sprintf
         "the declaration of %s at %s, between the text and a place where \
          lowering writes it, gives it a type that may hold an attribute or \
          `typeof` of an expression, which may change the type that the \
          text uses"
         (quote name) (declared_at context cited))

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
          check_same_type context span name ~declaration:cited used there;
          check_same_attributes context span name ~cited there
      | Some _, Some _ | None, _ | _, None ->
          refuse_other_entity context span name (Source (Ordinary declaration)))
  | None -> (
      match find_lowered place.typedef_names name with
      | Some lowered -> refuse_other_entity context span name (Lowered lowered)
      | None ->
          refuse span Moved_text
            (Printf.sprintf "%s is not visible where lowering writes the text"
               (quote name)))

let check_tag context place span name tag =
  match tag_at place name with
  | Some (Source (Tag found)) when found = tag || context.same_tag tag found ->
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

let check_use context text place (use : name) =
  if is_outside text use.declaration then
    match use.declaration with
    | Ordinary reference ->
        check_ordinary context place use.span use.name reference
    | Tag tag -> check_tag context place use.span use.name tag

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
let check_unread_identifier context text place view span name =
  let found = Parser.View.find view name in
  (match (Parser.own_name found name, found) with
  | Some own, _ -> check_own_spelling context place span name own
  | None, Some { declaration; _ } ->
      let use = { name; span; declaration = Ordinary declaration } in
      check_use context text place use
  | None, None -> ());
  match Parser.View.find_tag view name with
  | Some tag ->
      check_use context text place { name; span; declaration = Tag tag }
  | None -> ()

let check_unread context text place ((arguments : Tree.span), view) =
  for index = arguments.first to arguments.last do
    match context.tokens.tokens.(index).kind with
    | Identifier name ->
        let span = { Tree.first = index; last = index } in
        check_unread_identifier context text place view span name
    | Number | Character _ | String _ | Punctuator _ | Pragma _ | Typec_pragma
      ->
        ()
  done

(* The first two clauses, at a place where lowering writes the text. *)
let check_reading context text place =
  List.iter (check_use context text place) text.uses;
  List.iter (check_own context text place) text.declares;
  List.iter
    (check_unread context text place)
    (Parser.attributes_within context.views text.span)

let check context text ~at =
  match
    List.iter (check_scope text) text.declares;
    Option.iter (check_reading context text) at
  with
  | () -> Ok ()
  | exception Reads_otherwise (span, diagnostic) -> Error (span, diagnostic)
