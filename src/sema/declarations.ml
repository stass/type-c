(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

open Entity

type entity = Entity.t

type tag = Record_tag of Ctype.record_tag | Enum_tag of Ctype.enum_tag

type item =
  | Declaration of entity list
  | Static_assertion
  | Function_definition of entity
  | Type_declaration of entity
  | Generic_declaration
  | Generic_function_declaration of Tree.span

(* What a declaration of a generic function gives the declarations of it
   after it (design 7.1 rule 7), beside its entity, which holds the type
   it declares: the opaque records of its type parameters, in order. *)
type generic_function = { parameter_records : Ctype.record_tag list }

type argument_typedef = {
  name : string;
  line : string;
  tag_lines : Type_name.tag_line list;
}

type step =
  | Typedefs of argument_typedef list
  | Declared of { generic : Tree.type_declaration }
  | Prototype
  | Defined

type placement = {
  instance : Ctype.instance;
  step : step;
  at : Tree.anchor;
  application : Tree.span;
}

type generic_definition =
  | Type_generic of Tree.type_declaration
  | Function_generic of {
      span : Tree.span;
      type_parameters : Tree.parameter_name list;
      definition : Tree.function_definition;
    }

type instance_text = {
  generic : generic_definition;
  names : (Tree.span * string) list;
  void_field_spans : Tree.span list;
  typed : Expressions.t;
}

type function_instance = {
  generic_function : Tree.reference;
  instance : Ctype.instance;
  type_arguments : Ctype.t list;
  first_use : Tree.span;
  anchor : Tree.anchor;
}

module Encodings = Set.Make (String)

(* The instances used so far, the encodings of the arguments whose
   typedefs a text declares, the texts of instances met so far, latest
   first, the names that lowering writes for the applications of the
   unit's own text, the reading of each instance's definition, and the
   instances of generic functions used so far, latest first, as one
   value that a trial restores. *)
type placements = {
  used : unit Ctype.Instances.t;
  typedefs : Encodings.t;
  texts : placement list;
  names : (Tree.span * string) list;
  readings : instance_text Ctype.Instances.t;
  functions : function_instance list;
}

let no_placements =
  { used = Ctype.Instances.empty; typedefs = Encodings.empty; texts = [];
    names = [];
    readings = Ctype.Instances.empty;
    functions = [] }

type t = {
  tags : Ctype.tags;
  items : item list;
  placements : placements;
  entities : (Tree.reference, entity) Hashtbl.t;
  tag_types : (Tree.tag_id, tag) Hashtbl.t;
  linked : (string, entity) Hashtbl.t;
  typed : Expressions.t;
  type_declarations : (Tree.declaration_id, Tree.type_declaration) Hashtbl.t;
  instance_bytes : int;
  copy_bytes : int;
  longest_instance_code : int;
  zero_initialisers :
    (Tree.declaration_id, Expressions.zero_initialiser list) Hashtbl.t;
}

let tags result = result.tags
let items result = result.items
let placements result = List.rev result.placements.texts
let instance_names result = result.placements.names
let function_instances result = List.rev result.placements.functions

let zero_initialisers result (definition : Tree.function_definition) =
  Hashtbl.find_opt result.zero_initialisers definition.node.declared.id
  |> Option.value ~default:[]

let instance_text result instance =
  Ctype.Instances.find_opt instance result.placements.readings

let slice_checks result =
  let instances =
    Ctype.Instances.fold
      (fun _ (reading : instance_text) checks ->
        Expressions.slice_checks reading.typed @ checks)
      result.placements.readings []
  in
  Expressions.slice_checks result.typed @ instances

let selection_sizes result =
  Ctype.Instances.fold
    (fun _ (reading : instance_text) sizes ->
      Expressions.selection_sizes reading.typed @ sizes)
    result.placements.readings (Expressions.selection_sizes result.typed)

let type_declarations result =
  Hashtbl.to_seq_values result.type_declarations
  |> List.of_seq
  |> List.sort (fun (a : Tree.type_declaration) b ->
         compare a.span.first b.span.first)

let typed result = result.typed
let instance_bytes result = result.instance_bytes
let copy_bytes result = result.copy_bytes
let longest_instance_code result = result.longest_instance_code
let entity result reference = Hashtbl.find_opt result.entities reference
let tag result id = Hashtbl.find_opt result.tag_types id
let linked result name = Hashtbl.find_opt result.linked name
let expression result expression = Expressions.find result.typed expression
let constant result expression = Expressions.constant result.typed expression
let selection result expression = Expressions.selection result.typed expression

let types_compatible result expression =
  Expressions.types_compatible result.typed expression
type error = Reader.error = { location : Location.t; message : string }

(* The reader *)

(* The reader matches every tree record that holds attributes with a
   pattern that names each field, so that a field added to one is warning
   9 wherever the record is read rather than attributes no one checks. *)

(* Where a declarator is read, for the array lengths that 6.7.6.2p2 and
   p4 allow by the scope they are in: no variable length at file scope,
   and [*] only in a parameter list that is not that of a definition. *)
type place = At_file_scope | In_prototype | In_definition | In_block

(* A generic type: its latest declaration, and whether it is an alias
   whose text is inexact (design 3.5 rule 2), read where the definition
   stands, as nothing later changes what the text names there. *)
type generic = { declaration : Tree.type_declaration; inexact : bool }

(* The reader follows the links that the parser records in the tree
   (design 13.3): [entities] holds what each declaration that it has read
   declares, as of that declaration, [tag_types] the tag that each tag
   declaration declares, and [linked] the entity that each name with
   linkage denotes (6.2.2), which no scope hides, as of its last
   declaration, and [at_file_scope] as of its last one at file scope,
   which a block sees unless a declaration without linkage hides it.
   [beside] holds, for each declaration of an overload, the entity that a
   later declaration of its name without [overloadable] redeclares in its
   place, and [overloaded]
   each overload and each declaration with one before it in its scope,
   whose uses name the overload set (design 13.3). [typed] is the typed
   view of the expressions, and [type_names] the type of each type name
   read, which typing and constant evaluation both ask for and whose
   declarations are made once. [type_declarations] holds each type
   declaration read, by the id of its name.
   The reading of an instance (design 10.3) and the definition check of
   a generic have [typed] and [type_names] of their own, as they read
   the text of the generic's definition again.
   [generics] holds each generic type by its name, which names one type
   as a generic stands at file scope (design 3.5 rule 8), with the
   latest declaration, which is the variant that completes an incomplete
   one; [applied_at] the latest application of
   each instance, where an error of its definition is reported (design
   3.5 rule 5), and [nesting] the chain of instances whose definitions
   are being read (rule 7), none outside one.
   [instance_bytes] counts the bytes of the text that the readings for
   instances so far give their instances, those of definition checks
   included, which a trial does not undo, and [copy_bytes] those of the
   copies of deferred statements that the exits so far run.
   [longest_instance_code] is the most bytes of the code of one instance
   that the unit has encoded so far, which the bound of rule 7 holds.
   [external_facts] are those of the external declaration being read,
   and [placements] where the texts of the instances stand (design
   10.3).
   [views] are the parser's views of the unit's unread text, and
   [definition_views] holds the view in front of each declaration of a
   generic, by its id, which is the own place of its definition (design
   13.5). [moved] collects what the reading of a generic's definition
   finds in it, none outside one, and [found] the names that each moved
   text, or function definition, being read uses and declares,
   innermost first, and [read_moved] what each deferred statement and
   operand of a [return] of the function body being read found, by its
   span, for the checks of design 6 rules 8 and 12 at the end of the
   body. [redeclared_at]
   and [completed_at] are the events of the window of 13.5 that every
   reading so far has made ({!Resolution.context}). Those of a reading
   of a generic's definition stand at its tokens, not where its
   instances do, which is sound as they are of the text's own entities:
   moved text declares no entity with linkage (13.5). *)
type state = {
  target : Target.t;
  text : Reader.t;
  views : Parser.views;
  definition_views : (Tree.declaration_id, Parser.View.t) Hashtbl.t;
  mutable moved : moved option;
  mutable found : found list;
  read_moved : (Tree.span, found) Hashtbl.t;
  mutable redeclared_at : Resolution.redeclarations;
  mutable completed_at : Ctype.named_tag Resolution.Events.t;
  tags : Ctype.tags;
  entities : (Tree.reference, entity) Hashtbl.t;
  tag_types : (Tree.tag_id, tag) Hashtbl.t;
  linked : (string, entity) Hashtbl.t;
  at_file_scope : (string, entity) Hashtbl.t;
  beside : (Tree.reference, entity option) Hashtbl.t;
  overloaded : (Tree.reference, unit) Hashtbl.t;
  name_readings : (int, Expressions.name_reading) Hashtbl.t;
      (* how typing first read each name whose meaning a type decides,
         by its token: an identifier alone in a pattern, which the parser
         declared (design 4.7 rule 3), and an unqualified name that may
         be a constructor (3.3); an instance takes these readings (7.3
         rule 3) *)
  generic_functions : (Tree.reference, generic_function) Hashtbl.t;
      (* each declaration of a generic function (design 7.1) *)
  mutable generic_part : generic_part option;
      (* the part of a generic function that its check is reading, where
         a type in an expression may depend on a type parameter (design
         7.1 rule 4) *)
  mutable trial : bool;
      (* reading a trial ([in_trial]), which defines no instance for a
         later point (design 3.5 rule 7) *)
  generic_definitions : (string, generic_definition) Hashtbl.t;
      (* the definition of each generic function, by its name, which
         names one function at file scope (design 7.1 rule 1) *)
  state_pragmas : int array;
      (* by each token, the last at or before it that is a pragma line
         setting state ([latest_state_pragmas]) *)
  attribute_subjects : (int, bool) Hashtbl.t;
      (* by the first token of each attribute read, whether its subject
         mentions a type parameter (design 13.3) *)
  mutable typed : Expressions.t;
  mutable type_names : (Tree.span, Ctype.t) Hashtbl.t;
  type_declarations : (Tree.declaration_id, Tree.type_declaration) Hashtbl.t;
  incomplete_variants : (Tree.reference, Ctype.record_tag) Hashtbl.t;
      (* the structure of each [type N;], which its variant completes *)
  generics : (string, generic) Hashtbl.t;
  universe_aliases : (Tree.reference, Tree.type_name) Hashtbl.t;
      (* the type that each non-generic type declaration of the universe
         text names, as [str] names [slice(const char)] *)
  mutable applied_at : Tree.span Ctype.Instances.t;
  mutable slice_generic : Tree.type_declaration option;
      (** the universe generic [slice] (design section 8), once read *)
  mutable nesting : nesting option;
  mutable queued : queued_instance list;
      (* the function instances whose definitions are still to be read,
         latest first (design 7.3) *)
  mutable instance_bytes : int;
  mutable copy_bytes : int;
  mutable longest_instance_code : int;
  mutable external_facts : external_facts;
  mutable placements : placements;
  mutable place : place;
  mutable next_entity : int;
  zero_initialisers :
    (Tree.declaration_id, Expressions.zero_initialiser list) Hashtbl.t;
      (* those that the check of each generic function found, by the
         function's declaration (design 7.1 rule 3) *)
}

(* The part of a generic function that its check reads (design 7.1 rule
   3): the head, where the definition stands, and then the body, as a
   trial. *)
and generic_part = Generic_head | Generic_body

(* A chain of instances that each cause the next (design 3.5 rule 7):
   how many, the application or call that caused the first, that first
   instance, the instance whose definition is being read, the last, and
   the application or call that caused it. *)
and nesting = {
  depth : int;
  began : Tree.span;
  first : Ctype.instance;
  defining : Ctype.instance;
  applied : Tree.span;
}

(* A function instance whose definition is read once no other reading
   of a function definition is open: the generic function's definition
   and the chain of instances that the instance would extend. *)
and queued_instance = {
  used : function_instance;
  definition : Tree.function_definition;
  generic : generic_definition;
  outer : nesting option;
}

(* What a reading of a generic's definition is for: the generic's own
   definition check, or an instance, whose text lowering writes where
   the instance gets texts ({!gets_texts}). *)
and purpose = Definition_check | For_instance of Ctype.instance

(* What the reading of a generic's definition finds in its text besides
   its names: whether lowering writes the text itself, as it does for an
   instance that gets texts ({!gets_texts}) but not for a definition
   check. The instances that the text uses first get texts by
   {!gets_texts}, whether the text is written or not. [parameters] holds the
   name of the typedef of each type parameter's argument, by the
   parameter's reference, for the reading of an instance, and where
   lowering writes the text [names] collects the name that it writes for
   each use of a type parameter and each application.
   [void_field_spans] are the fields that a void argument removes (design
   3.5 rule 6). [of_type] says whether the text is a generic type's
   definition. *)
and moved = {
  written : bool;
  of_type : bool;
  parameters : (Tree.reference * string) list;
  mutable names : (Tree.span * string) list;
  mutable void_field_spans : Tree.span list;
}

(* The names that the reading of the text at [text_span] finds in it,
   latest first: those that it uses and those that it declares, which
   the resolution property checks of a moved text, and the form of a
   return in the scope of a defer of a function definition (design
   13.5). *)
and found = {
  text_span : Tree.span;
  mutable uses : Resolution.name list;
  mutable declares : Resolution.own list;
}

(* What the placement of instances (design 10.3) asks of the external
   declaration being read: the anchor where the texts of instances
   stand, none before the first, the moment it began,
   the tags that its own text completes, with where, the tags that a
   mention in a nested scope of it declares only because none is
   visible (C11 6.7.2.3p8), and the moment of its first block literal.
   [texts_at] is where the texts of instances stand, in front of it: the
   parser's view there, with what lowering declares there so far (design
   13.5). The sets are tables, as one declaration can hold many of each.
   A definition check adds to them and no trial removes that: a generic
   is a declaration of its own at file scope, which holds nothing else
   that the facts are asked about. *)
and external_facts = {
  anchor : Tree.anchor option;
  start : Ctype.moment;
  completed : (Ctype.named_tag, Location.t) Hashtbl.t;
  nested_tags : (string, unit) Hashtbl.t;
  mutable block_literal : Ctype.moment option;
  mutable texts_at : Resolution.place;
  mutable instance_uses : (Tree.span * Ctype.instance) list;
      (* the function instances that the unit's own text of the
         declaration uses, latest first, which an inline definition
         cannot (design 7.3 rule 1) *)
}

(* The record of a text that a reading of a generic's definition moves,
   before the reading finds anything in it. *)
let fresh_moved ~written ~of_type parameters =
  { written; of_type; parameters; names = []; void_field_spans = [] }

(* How the definition of an instance is read: [read declaration f] runs
   [f] with the type parameters of [declaration] bound to the instance's
   arguments, for an application or for the definition check. *)
type reader = { read : 'a. Tree.type_declaration -> (unit -> 'a) -> 'a }

(* Raised at the first error; caught in [read]. *)
exception Failed of error

(* An error of the definition of an instance, already reported at its
   application (design 3.5 rule 5), which no enclosing instance reports
   again at its own; caught in [read]. *)
exception Instance_failed of error

(* The index of the latest state-setting pragma line before the first
   token, which no token has. *)
let no_pragma = -1

(* Design 3.5 rule 7: a chain of instances that each cause the next holds
   at most this many. It is a rule of the language, so it is exact. *)
let max_nesting = 64

(* The instance budget of design 3.5 rule 7, a translation limit of
   typec on the bytes that the readings for a unit's instances count;
   lowering's output limit bounds the text it writes from them. The
   instances can grow exponentially with the source, as where each
   generic needs two instances of the one before it, and an instance
   grows with the encodings of its arguments as well as with its
   definition. Between
   four and five times the estimated text of a heavy C++ unit
   (provisional, P30). *)
let instance_budget = 16777216

(* The least that the front end charges the budget for a token of a
   definition it reads: 524288 tokens of one byte pass it, where without
   this charge 16 million would, and a reading of such tokens costs far
   more per byte than one of names. *)
let least_token_charge = 32

let next_link nesting application defining =
  match nesting with
  | None ->
      { depth = 1; began = application; first = defining; defining;
        applied = application }
  | Some { depth; began; first; defining = _; applied = _ } ->
      { depth = depth + 1; began; first; defining; applied = application }

let declaration_state tags (anchor : Tree.anchor option) view =
  (* Nothing is read before the first anchor, so no text stands there. *)
  let before = match anchor with Some { before } -> before | None -> 0 in
  { anchor; start = Ctype.now tags; completed = Hashtbl.create 16;
    nested_tags = Hashtbl.create 16; block_literal = None;
    texts_at = { view; before; typedef_names = []; tags = [] };
    instance_uses = [] }

(* An instance name is at most [Encoding.max_length] bytes; a message
   shows at most this many of them, cut at a character. *)
let max_shown_name = 200

let shown_instance instance =
  let name = Encoding.instance_name instance in
  let is_continuation index = Char.code name.[index] land 0xC0 = 0x80 in
  let rec cut length =
    if length > 0 && is_continuation length then cut (length - 1)
    else String.sub name 0 length ^ "..."
  in
  if String.length name <= max_shown_name then name else cut max_shown_name

let in_instance_definition state = Option.is_some state.nesting

(* The tokens of a generic's definition, which each reading of it reads
   again and each instance writes. *)
let definition_span = function
  | Type_generic (declaration : Tree.type_declaration) -> declaration.span
  | Function_generic { span; _ } -> span

let definition_declared : generic_definition -> Tree.declared = function
  | Type_generic declaration -> declaration.node.declared
  | Function_generic { definition; _ } -> definition.node.declared

let generic_parameters = function
  | Type_generic declaration -> declaration.node.type_parameters
  | Function_generic { type_parameters; _ } -> type_parameters

let location_of state (span : Tree.span) =
  state.text.tokens.(span.first).location

let fail state span diagnostic =
  let location = location_of state span in
  raise (Failed { location; message = Rule.text diagnostic })

(* [fail], with the diagnostic placed [within] a text that it names. *)
let fail_within state span within diagnostic =
  let location = location_of state span in
  raise
    (Failed { location; message = within ^ ": " ^ Rule.text diagnostic })

(* Whether the first use of [instance] here gives it texts, and its
   definition a reading that lowering writes (design 10.3). A trial
   defines no instance for a later point (3.5 rule 7), and no encoding
   writes an instance that mentions a type parameter of a definition
   check. Whether the text being read is written does not decide it: a
   generic function's head is not, and the instances that its check
   applies there to concrete types are real first uses. *)
let gets_texts state (instance : Ctype.instance) =
  (not state.trial) && not instance.mentions_parameter

(* Reading the check of a generic function, its head or its body. *)
let in_generic_function state = Option.is_some state.generic_part

let quote = Expressions.quote

let checked state span = function
  | Ok t -> t
  | Error error -> fail state span (Rule.c_text (Ctype.error_message error))

let integer_type state span integer =
  checked state span (Ctype.integer state.target integer)

(* Types that typec does not compute (design 13.3) *)

(* What the construct at [span] gives in place of a type. *)
let unknown_of state span construct kind : Unknown.t =
  { construct; location = location_of state span; kind; cause = Not_typed }

let unknown_type state span construct kind =
  Ctype.unknown (unknown_of state span construct kind)

(* The error where [need] depends on an unknown type: the first point that
   needs what typec does not know. *)
let fail_needing state span need unknown =
  fail state span (Expressions.needing need unknown)

let at_file_scope state = state.place = At_file_scope

let fresh_entity state =
  let entity = state.next_entity in
  state.next_entity <- entity + 1;
  entity

(* [read] with the declarators it reads in [place]. *)
let within state place read =
  let saved = state.place in
  state.place <- place;
  Fun.protect ~finally:(fun () -> state.place <- saved) read

(* Following the links of the tree *)

(* A declaration that the parser resolved a use to, but that the reader
   has not met, is in a place that the reader does not read yet: the body
   of a Clang block literal. *)
let not_read state span name =
  fail state span
    (Rule.message Profile
       (quote name
      ^ " is declared where typec does not read declarations yet"))

(* What the moved texts being read use and declare (design 13.5): every
   use of a name passes [note_use], and every declaration of one
   [note_own], with the scope that the parser declared it in. A name
   belongs to each text whose tokens hold it: a text inside another
   moves with it, and the definition of an instance that the operand of
   a try applies stands apart from the operand. *)
let holding state span =
  let holds found =
    found.text_span.first <= span.Tree.first
    && span.last <= found.text_span.last
  in
  List.filter holds state.found

let note_use state span name declaration =
  let note found =
    found.uses <- { Resolution.name; span; declaration } :: found.uses
  in
  List.iter note (holding state span)

let note_own state span name declaration ~scope ~implicit ~linked =
  let declared = { Resolution.name; span; declaration } in
  let own = { Resolution.declared; implicit; linked; scope } in
  let note found = found.declares <- own :: found.declares in
  List.iter note (holding state span)

(* [read] of the text at [text_span], with what it finds. *)
let finding state text_span read =
  let found = { text_span; uses = []; declares = [] } in
  let outer = state.found in
  state.found <- found :: outer;
  let result = Fun.protect ~finally:(fun () -> state.found <- outer) read in
  (result, found)

(* What [reference] denotes at the use of [name] at [span], if the reader
   has met its declaration. A use of a generic function is no name of the
   text where lowering writes it, which writes the name of an instance in
   its place (design 10.3), declared before the text by construction. *)
let entity_used state span name reference =
  if not (Hashtbl.mem state.generic_functions reference) then
    note_use state span name (Resolution.Ordinary reference);
  Hashtbl.find_opt state.entities reference

(* Design 4.7 rule 3: the parser declares an identifier alone in a
   pattern in the scope of the arm before typing reads it as a
   constructor, which declares nothing, so a use of the name there that
   no target type resolves (3.3) is refused. *)
let refuse_constructor_word state span name variant =
  fail state span
    (Rule.message Pattern
       (Printf.sprintf
          "%s is a constructor of %s in a pattern of this arm and binds \
           nothing; the arm writes it %s"
          (quote name) (quote variant)
          (quote (variant ^ "." ^ name))))

(* How typing read the name that [reference] declares, if it read it
   as a name whose meaning a type decides: an identifier alone in a
   pattern. *)
let declared_reading state (reference : Tree.reference) =
  match reference with
  | In_tree (Ordinary_at token) -> Hashtbl.find_opt state.name_readings token
  | Builtin _ -> None

(* The entity that [reference] denotes at the use of [name] at [span]. *)
let referenced state span name reference =
  match entity_used state span name reference with
  | Some entity -> entity
  | None -> (
      match declared_reading state reference with
      | Some (Constructor_word variant) ->
          refuse_constructor_word state span name variant
      | Some Ordinary_word | None -> not_read state span name)

(* Design 7.1 rule 7: when declarations of a generic function agree. *)
let refuse_generic_agreement state span name reason =
  fail state span
    (Rule.message Generic_function_agreement
       (Printf.sprintf "%s %s" (quote name) reason))

let other_declaration =
  "is a generic function, so no other declaration of its name stands at \
   file scope"

(* The entity that the declaration of [name] at [span] redeclares: none
   where it is the first in its scope. An overload in between is passed
   over. A declaration of a generic function makes no entity that
   another declaration redeclares: its declarations agree by rule 7 of
   design 7.1 alone, which [read_generic_function] checks. *)
let earlier_entity state span name (declared : Tree.declared) =
  match declared.earlier with
  | None -> None
  | Some earlier when Hashtbl.mem state.generic_functions earlier ->
      if in_generic_function state then None
      else refuse_generic_agreement state span name other_declaration
  | Some earlier -> (
      match Hashtbl.find_opt state.beside earlier with
      | Some passed_over -> passed_over
      | None -> Some (referenced state span name earlier))

(* Ordinary identifiers (6.2.2, 6.7p3, p4) *)

let is_overload = function
  | Function { overload; _ } -> overload
  | Object _ | Typedef _ | Enumerator _ -> false

let check_linkage state span name prior next =
  if linkage_of prior = No_linkage || linkage_of next = No_linkage then
    fail state span
      (Rule.c_text
         (quote name
        ^ " is declared twice in one scope without linkage (C11 6.7p3)"));
  if linkage_of prior <> linkage_of next then
    fail state span
      (Rule.c_text
         (quote name ^ " has both internal and external linkage (C11 6.2.2p7)"))

let composite state span name prior next =
  let location = location_of state span in
  match Ctype.composite state.target state.tags location prior next with
  | Ok composite -> composite
  | Error Ctype.Incompatible ->
      fail state span
        (Rule.c_text
           (quote name
          ^ " is redeclared with an incompatible type (C11 6.7p4)"))
  | Error error -> fail state span (Rule.c_text (Ctype.error_message error))

let refuse_other_kind state span name =
  fail state span
    (Rule.c_text
       (quote name ^ " is redeclared as a different kind of identifier \
                      (C11 6.7p3)"))

(* A declaration of [name] where [prior] is in the same scope. *)
let redeclared state span name prior next =
  match (prior, next) with
  | Typedef old, Typedef same -> (
      match
        Ctype.same_type state.target state.tags (location_of state span)
          old.typedef_type same.typedef_type
      with
      | Answer true | Depends_on _ -> Typedef same
      | Answer false ->
          fail state span
            (Rule.c_text
               (quote name
              ^ " is redefined as a typedef of another type (C11 6.7p3)")))
  | Object old, Object next ->
      check_linkage state span name prior (Object next);
      if old.storage <> next.storage then
        fail state span
          (Rule.c_text (quote name
         ^ " is declared both with and without _Thread_local (C11 6.7.1p3)"));
      let object_type =
        composite state span name old.object_type next.object_type
      in
      Object { next with object_type }
  | Function old, Function next ->
      check_linkage state span name prior (Function next);
      let function_type =
        composite state span name old.function_type next.function_type
      in
      Function
        {
          next with
          function_type;
          inline = old.inline || next.inline;
          inline_definition = old.inline_definition && next.inline_definition;
          noreturn = old.noreturn || next.noreturn;
          gnu_inline = old.gnu_inline || next.gnu_inline;
          targets = Entity.both_targets old.targets next.targets;
          marked = Entity.both_marks old.marked next.marked;
        }
  | (Object _ | Function _ | Typedef _ | Enumerator _), _ ->
      refuse_other_kind state span name

(* What [declared] declares [name] as, which the text of a generic's
   definition being read declares (design 13.5). *)
let bind_entity state name (declared : Tree.declared) entity =
  let reference = Tree.In_tree declared.id in
  let (Ordinary_at token) = declared.id in
  note_own state { first = token; last = token } name
    (Resolution.Ordinary reference) ~scope:declared.scope ~implicit:false
    ~linked:(linkage_of entity.declared <> No_linkage);
  Hashtbl.replace state.entities reference entity

(* An overload (design 13.3) is a new entity, which is not linked under
   its name, and stands beside what a declaration in its place would
   redeclare, which must be a function, as the name is one kind of
   identifier in its scope (C11 6.7p3). *)
let bind_overload state span name (declared : Tree.declared) ~inexact next =
  let earlier = earlier_entity state span name declared in
  (match earlier with
  | Some { declared = Object _ | Typedef _ | Enumerator _; _ } ->
      refuse_other_kind state span name
  | Some { declared = Function _; _ } | None -> ());
  let entity =
    { name; entity = fresh_entity state; declared = next; inexact }
  in
  let reference = Tree.In_tree declared.id in
  bind_entity state name declared entity;
  Hashtbl.replace state.beside reference earlier;
  Hashtbl.replace state.overloaded reference ();
  entity

let follows_overload state (declared : Tree.declared) =
  match declared.earlier with
  | Some earlier -> Hashtbl.mem state.overloaded earlier
  | None -> false

let record state name (declared : Tree.declared) entity =
  let reference = Tree.In_tree declared.id in
  bind_entity state name declared entity;
  if follows_overload state declared then
    Hashtbl.replace state.overloaded reference ();
  if linkage_of entity.declared <> No_linkage then
    Hashtbl.replace state.linked name entity;
  entity

(* [record] of a declaration of an entity declared before it, which the
   check of design 13.5 indexes: an inexact one is an event of the
   window. *)
let record_again state name (declared : Tree.declared) (entity : entity) =
  state.redeclared_at <-
    Resolution.add_redeclared declared entity state.redeclared_at;
  record state name declared entity

(* Records what [declared] declares [name] as: a new entity, or [prior],
   the visible declaration it redeclares, with the composite of their
   types. [inexact] is the declaration's own; after an inexact [prior]
   the entity stays inexact, as the backend may keep an attribute that
   a later declaration does not repeat. *)
let bind_to state span name (declared : Tree.declared) prior ~inexact next =
  if is_overload next then bind_overload state span name declared ~inexact next
  else
    match prior with
    | None ->
        record state name declared
          { name; entity = fresh_entity state; declared = next; inexact }
    | Some prior ->
        record_again state name declared
          { prior with
            declared = redeclared state span name prior.declared next;
            inexact = prior.inexact || inexact }

(* [bind_to] the declaration before [declared] in its scope. *)
let bind state span name declared ~inexact next =
  bind_to state span name declared (earlier_entity state span name declared)
    ~inexact next

(* A declaration with linkage of a name whose declarations with linkage
   it does not see, as one in a block of another function: the same
   entity (6.2.2p4, p5), of a compatible type (6.2.7p2), with its own
   type, as no declaration in scope composes with it (6.2.7p4). *)
let bind_unseen state span name declared (other : entity) ~inexact next =
  ignore (redeclared state span name other.declared next);
  record_again state name declared { other with declared = next; inexact }

(* Where a declaration of an ordinary identifier stands, for its linkage
   and storage duration (6.2.2, 6.2.4). *)
type scope = File_scope | Block_scope

(* The declaration that a declaration of [name] takes its linkage from
   (6.2.2p4): the one before it in its scope, or for one in a block the
   last with linkage in any scope. The parser links no declaration to one
   of an enclosing scope, so the tables of names with linkage stand for
   the visible one. *)
let linkage_source state scope span name declared =
  match (earlier_entity state span name declared, scope) with
  | Some prior, _ -> Some prior
  | None, Block_scope -> Hashtbl.find_opt state.linked name
  | None, File_scope -> None

(* 6.2.2p4, p5: [extern], or a function without a storage class, takes the
   linkage of the prior declaration where it has one. *)
let prior_linkage state scope span name declared =
  match linkage_source state scope span name declared with
  | Some { declared; _ } when linkage_of declared <> No_linkage ->
      linkage_of declared
  | Some _ | None -> External

(* Declaration specifiers *)

(* What the GNU attributes of a declaration say. [unknown_attribute] is
   the first without an entry in [attribute_effects], [effect_attribute]
   the first with an effect, [marked_attribute] the first with a mark,
   [targets] the [target] attributes, latest first, and [attributes]
   every one, in source order. *)
type attributed = {
  gnu_noreturn : bool;
  gnu_inline : bool;
  overloadable : bool;
  unknown_attribute : Tree.attribute option;
  effect_attribute : Tree.attribute option;
  marked_attribute : Tree.attribute option;
  targets : Tree.attribute list;
  attributes : Tree.attribute list;
}

(* What a list of declaration specifiers says. [storage] excludes
   [_Thread_local], which [thread_local] records; [noreturn] is
   [_Noreturn] only, which 6.7.4p1 allows on functions alone. *)
type specified = {
  storage : Tree.storage_class option;
  thread_local : bool;
  base_type : Ctype.t;
  inline : bool;
  noreturn : bool;
  alignments : Tree.span list;  (** Each alignment specifier, in order. *)
  attributed : attributed;
  untagged : bool;
      (** The type specifier is a structure, union or enumeration specifier
          without a tag, which a typedef declarator names (design 3.5 rule
          2). *)
  inexact : bool;
      (** The specifiers are inexact ([specifiers_are_inexact]);
          [for_declarator] adds its declarator's. *)
}

(* The declaration specifiers of each kind, in order. *)
type sorted = {
  storage_classes : Tree.storage_class list;
  basic : Tree.basic_type_specifier list;
  others : (Tree.span * Tree.type_specifier) list;
      (** each with the span of its specifier *)
  qualifiers : Tree.type_qualifier list;
  function_specifiers : Tree.function_specifier list;
  alignments : (Tree.span * Tree.alignment) list;
      (** each with the span of its specifier *)
  attributes : Tree.attribute list;
}

let sort_specifiers (specifiers : Tree.specifiers) =
  let add sorted (specifier : Tree.declaration_specifier Tree.spanned) =
    match specifier.node with
    | Storage_class c ->
        { sorted with storage_classes = c :: sorted.storage_classes }
    | Type_specifier (Basic b) -> { sorted with basic = b :: sorted.basic }
    | Type_specifier other ->
        { sorted with others = (specifier.span, other) :: sorted.others }
    | Type_qualifier q -> { sorted with qualifiers = q :: sorted.qualifiers }
    | Function_specifier f ->
        { sorted with function_specifiers = f :: sorted.function_specifiers }
    | Alignment_specifier a ->
        { sorted with alignments = (specifier.span, a) :: sorted.alignments }
    | Attributes list ->
        { sorted with attributes = List.rev_append list sorted.attributes }
  in
  let empty =
    { storage_classes = []; basic = []; others = []; qualifiers = [];
      function_specifiers = []; alignments = []; attributes = [] }
  in
  let sorted = List.fold_left add empty specifiers in
  { sorted with
    alignments = List.rev sorted.alignments;
    attributes = List.rev sorted.attributes }

(* 6.7.1p2: one storage class, but [_Thread_local] with [static] or
   [extern]. *)
let storage_class state span classes =
  let thread_local, others =
    List.partition (fun c -> c = Tree.Thread_local) classes
  in
  match (thread_local, others) with
  | ([] | [ _ ]), [] -> None
  | [], [ storage ] -> Some storage
  | [ _ ], [ ((Static | Extern) as storage) ] -> Some storage
  | _ ->
      fail state span
        (Rule.c_text
           "a declaration has storage classes that do not combine (C11 \
            6.7.1p2)")

(* The arithmetic types that type specifiers name (6.7.2p2): the integer
   ones, then the floating ones, each multiset sorted in the order of
   [Tree.basic_type_specifier]. *)
let basic_type (specifiers : Tree.basic_type_specifier list) :
    Arithmetic.t option =
  match (Integer.of_specifiers specifiers, List.sort compare specifiers) with
  | Some integer, _ -> Some (Integer integer)
  | None, [ Float ] -> Some (Real Float)
  | None, [ Double ] -> Some (Real Double)
  | None, [ Long; Double ] -> Some (Real Long_double)
  | None, [ Float; Complex ] -> Some (Complex Float)
  | None, [ Double; Complex ] -> Some (Complex Double)
  | None, [ Long; Double; Complex ] -> Some (Complex Long_double)
  | None, [ Complex ] -> Some (Complex Double) (* GNU *)
  | None, _ -> None

let is_optional_float : Tree.basic_type_specifier -> bool = function
  | Optional_float _ -> true
  | Void | Char | Short | Int | Long | Float | Double | Signed | Unsigned
  | Bool | Complex | Int128 ->
      false

let qualifiers_of (qualifiers : Tree.type_qualifier list) =
  let add (q : Qualifiers.t) (qualifier : Tree.type_qualifier) =
    match qualifier with
    | Const -> { q with const = true }
    | Restrict -> { q with restrict = true }
    | Volatile -> { q with volatile = true }
    | Atomic -> { q with atomic = true }
    (* Clang's nullability does not change a C type. *)
    | Nullability _ -> q
  in
  List.fold_left add Qualifiers.none qualifiers

(* Design 3.5 rule 2 holds Clang's nullability to be an attribute. *)
let is_nullability : Tree.type_qualifier -> bool = function
  | Nullability _ -> true
  | Const | Restrict | Volatile | Atomic -> false

let spanned_qualifiers (qualifiers : Tree.type_qualifier Tree.spanned list) =
  qualifiers_of (List.map (fun (q : _ Tree.spanned) -> q.node) qualifiers)

let record_kind : Tree.struct_or_union -> Ctype.record_kind = function
  | Struct -> Struct
  | Union -> Union

let wrong_kind_of_tag state (name : Tree.identifier) =
  fail state name.span
    (Rule.c_text
       (quote name.node
      ^ " is declared as a different kind of tag (C11 6.7.2.3p2)"))

(* Constant expressions (6.6) *)

(* The outcome of reading an expression as an integer constant
   expression. *)
type evaluation =
  | Constant of { integer_type : Integer.t; value : Integer_constant.t }
      (** The type that typing gives the expression, and its value. *)
  | Not_constant of Tree.span
      (** The operand or operator that 6.6p3 and p6 do not allow. *)

let spelling state (span : Tree.span) =
  Reader.spelling state.text state.text.tokens.(span.first)

(* Declarators *)

(* A declarator applied to a type, outside in. [parameter_qualifiers]
   are those between the brackets of the derivation that a parameter
   adjusts to a pointer (6.7.6.3p7); [defines] says that a function
   derivation is the one that a definition defines. *)
type derived = {
  name : string option;
  declared_type : Ctype.t;
  parameter_qualifiers : Qualifiers.t;
  defines : bool;
  inner : attributed;
      (* What the attributes inside the declarator say, which GCC and
         Clang move to a function that the declarator declares. *)
}

(* What a GNU attribute does to the declarations: [Neutral] changes
   nothing they compute, [Sets_noreturn] marks a function that does not
   return, as [_Noreturn] does (design 4.4), [Sets_gnu_inline] gives a
   function the GNU89 meaning of [inline] and [extern inline], and
   [Makes_overload] makes a function one of a Clang overload set. *)
type attribute_effect =
  | Neutral
  | Sets_noreturn
  | Sets_gnu_inline
  | Makes_overload

(* An attribute that the declarations accept. [clang_spelling] says that
   Clang also accepts it as [[clang::name]] in a C23 specifier; for any
   other name Clang ignores that spelling, as it does [clang::noreturn].
   [marked] says that on a declaration of a function it breaks on its own
   the property that the form of a [return] in the scope of a defer
   statement rests on, that the name names exactly one function which
   [__typeof__] may name (design 13.3, 13.5). [alike] says that both
   backends take it alike on a subject of every type, on every kind of
   subject and with every argument list, which a measurement with both
   showed: only such an attribute stands on what mentions a type
   parameter in the definition of a generic (design 13.3). *)
type attribute_entry = {
  gnu_name : string;
  attribute_effect : attribute_effect;
  clang_spelling : bool;
  marked : bool;
  alike : bool;
}

(* The attribute whose arguments name a version of a function (design
   13.5). *)
let target_attribute = "target"

(* The attribute that makes a function one of an overload set (design
   13.3). *)
let overloadable_attribute = "overloadable"

(* The GNU attributes that the declarations accept, each with its effect.
   [aligned] is neutral because typec leaves [_Alignof] and the sizes of
   records and arrays to the backend (design P16) and the attribute does
   not change the size of a scalar; it leaves this table once typec
   computes a layout. The rest shape diagnostics or code. Any other
   attribute may change a type, as [mode] and [vector_size] do, so the
   type it applies to is unknown (design 13.3). The entries with Clang's
   spelling are those for which Apple Clang 21 gives a nonzero
   [__has_c_attribute(clang::name)]. *)
let attribute_effects =
  let gnu_only gnu_name attribute_effect =
    { gnu_name; attribute_effect; clang_spelling = false; marked = false;
      alike = false }
  in
  let also_clang gnu_name attribute_effect =
    { (gnu_only gnu_name attribute_effect) with clang_spelling = true }
  in
  let mark entry = { entry with marked = true } in
  let alike entry = { entry with alike = true } in
  [
    gnu_only "alloc_align" Neutral;
    gnu_only "alloc_size" Neutral;
    gnu_only "aligned" Neutral;
    alike (also_clang "always_inline" Neutral);
    mark (also_clang "availability" Neutral);
    alike (gnu_only "cold" Neutral);
    gnu_only "const" Neutral;
    gnu_only "constructor" Neutral;
    mark (also_clang "cpu_dispatch" Neutral);
    mark (also_clang "cpu_specific" Neutral);
    gnu_only "deprecated" Neutral;
    gnu_only "destructor" Neutral;
    mark (gnu_only "diagnose_if" Neutral);
    also_clang "disable_tail_calls" Neutral;
    also_clang "enum_extensibility" Neutral;
    also_clang "flag_enum" Neutral;
    gnu_only "format" Neutral;
    gnu_only "format_arg" Neutral;
    gnu_only "gnu_inline" Sets_gnu_inline;
    gnu_only "hot" Neutral;
    gnu_only "leaf" Neutral;
    gnu_only "malloc" Neutral;
    also_clang "noescape" Neutral;
    alike (also_clang "noinline" Neutral);
    gnu_only "nonnull" Neutral;
    gnu_only "noreturn" Sets_noreturn;
    also_clang "not_tail_called" Neutral;
    gnu_only "nothrow" Neutral;
    mark (also_clang overloadable_attribute Makes_overload);
    gnu_only "pure" Neutral;
    gnu_only "returns_nonnull" Neutral;
    gnu_only "section" Neutral;
    gnu_only "sentinel" Neutral;
    gnu_only "swift_attr" Neutral;
    gnu_only "swift_name" Neutral;
    gnu_only target_attribute Neutral;
    mark (gnu_only "target_clones" Neutral);
    mark (gnu_only "target_version" Neutral);
    mark (also_clang "unavailable" Neutral);
    alike (gnu_only "unused" Neutral);
    gnu_only "used" Neutral;
    gnu_only "visibility" Neutral;
    gnu_only "warn_unused_result" Neutral;
    gnu_only "weak" Neutral;
  ]

(* The prefix that the parser keeps on Clang's spelling of an attribute
   (Tree.attribute). *)
let clang_prefix = "clang::"

(* The entry of the attribute that the parser names [name]: its GNU name,
   or Clang's spelling of one that has it. *)
let find_attribute_entry name =
  if String.starts_with ~prefix:clang_prefix name then
    let prefix_length = String.length clang_prefix in
    let gnu_name =
      String.sub name prefix_length (String.length name - prefix_length)
    in
    List.find_opt
      (fun entry -> entry.clang_spelling && entry.gnu_name = gnu_name)
      attribute_effects
  else List.find_opt (fun entry -> entry.gnu_name = name) attribute_effects

let no_attributes =
  { gnu_noreturn = false; gnu_inline = false; overloadable = false;
    unknown_attribute = None; effect_attribute = None;
    marked_attribute = None; targets = []; attributes = [] }

(* [onto] with the effects of [attributes] applied in source order. *)
let read_attributes ~onto (attributes : Tree.attribute list) =
  let first found attribute = if found = None then Some attribute else found in
  let with_effect attributed attribute =
    { attributed with
      effect_attribute = first attributed.effect_attribute attribute }
  in
  let with_effect_of attributed attribute = function
    | Neutral -> attributed
    | Sets_noreturn ->
        with_effect { attributed with gnu_noreturn = true } attribute
    | Sets_gnu_inline ->
        with_effect { attributed with gnu_inline = true } attribute
    | Makes_overload ->
        with_effect { attributed with overloadable = true } attribute
  in
  (* What design 13.5 reads of the attributes of a function. *)
  let with_form_facts attributed attribute entry =
    let marked_attribute =
      if entry.marked then first attributed.marked_attribute attribute
      else attributed.marked_attribute
    in
    let targets =
      if entry.gnu_name = target_attribute then attribute :: attributed.targets
      else attributed.targets
    in
    { attributed with marked_attribute; targets }
  in
  let apply attributed (attribute : Tree.attribute) =
    match find_attribute_entry attribute.node.name.node with
    | Some entry ->
        let attributed =
          with_effect_of attributed attribute entry.attribute_effect
        in
        with_form_facts attributed attribute entry
    | None ->
        { attributed with
          unknown_attribute = first attributed.unknown_attribute attribute }
  in
  let read = List.fold_left apply onto attributes in
  { read with attributes = onto.attributes @ attributes }

(* An attribute whose effect is not recorded where it stands, as only the
   declaration of a function at file scope records [noreturn],
   [gnu_inline] and [overloadable]: it makes the type it applies to
   unknown. One without an entry in the table is named before one with an
   effect. *)
let unrecorded attributed =
  match attributed.unknown_attribute with
  | Some attribute -> Some attribute
  | None -> attributed.effect_attribute

let first_unrecorded_attribute attributes =
  unrecorded (read_attributes ~onto:no_attributes attributes)

let attribute_unknown state (attribute : Tree.attribute) kind =
  let construct = "the attribute " ^ quote attribute.node.name.node in
  unknown_of state attribute.span construct kind

(* [t] as an attribute leaves it whose effect typec does not record
   there: unknown, but a function type still, as no attribute makes a
   function of an object or an object of a function. *)
let obscured state attribute (t : Ctype.t) =
  let kind_of t : Unknown.kind =
    match Ctype.is_function t with
    | Answer true -> Unknown_function
    | Answer false -> Unknown_object
    | Depends_on _ -> Object_or_function
  in
  match attribute with
  | Some attribute ->
      Ctype.unknown (attribute_unknown state attribute (kind_of t))
  | None -> t

(* Design 13.3: records whether the subject of the attributes or
   alignment specifiers at [firsts] mentions a type parameter. One with
   several subjects, as among the specifiers of a declaration with
   several declarators, mentions one where any of them does. *)
let note_subjects state (firsts : int list) ~mentions =
  let note first =
    let earlier =
      Option.value ~default:false
        (Hashtbl.find_opt state.attribute_subjects first)
    in
    Hashtbl.replace state.attribute_subjects first (earlier || mentions)
  in
  List.iter note firsts

let attribute_firsts (attributes : Tree.attribute list) =
  List.map (fun (attribute : Tree.attribute) -> attribute.span.first)
    attributes

let note_subject state attributes subject =
  note_subjects state (attribute_firsts attributes)
    ~mentions:(Ctype.mentions_opaque state.tags subject)

let obscured_by state attributes t =
  note_subject state attributes t;
  obscured state (first_unrecorded_attribute attributes) t

(* Whether the token at [index] lies in the definition at [definition]. *)
let in_definition (definition : Tree.span) index =
  definition.first <= index && index <= definition.last

(* The first identifier among the arguments of [attribute] that denotes,
   as an ordinary identifier or a tag, what the definition at
   [definition] declares, its parameters included (design 13.3). *)
let names_declared state definition (attribute : Tree.attribute) =
  let declares view name =
    let ordinary =
      match Parser.View.find view name with
      | Some { declaration = In_tree (Ordinary_at at); _ } ->
          in_definition definition at
      | Some { declaration = Builtin _; _ } | None -> false
    in
    let tag =
      match Parser.View.find_tag view name with
      | Some (Tag_at at) -> in_definition definition at
      | None -> false
    in
    ordinary || tag
  in
  let rec first_declared view (arguments : Tree.span) index =
    if index > arguments.last then None
    else
      match state.text.tokens.(index).kind with
      | Token.Identifier name when declares view name -> Some name
      | Identifier _ | Number | Character _ | String _ | Punctuator _
      | Pragma _ | Typec_pragma ->
          first_declared view arguments (index + 1)
  in
  match
    (attribute.node.arguments, Parser.attribute_view state.views attribute)
  with
  | Some arguments, Some view -> first_declared view arguments arguments.first
  | None, _ | Some _, None -> None

(* Design 13.3, "Attributes in a generic": in the definition at
   [definition], an attribute whose subject mentions a type parameter,
   or whose arguments name what the definition declares, stands only
   where the table records that both backends take it alike. One whose
   subject no reading noted is refused, so a construct that the reading
   misses costs a refusal and never an instance that the backend
   rejects. *)
let check_generic_attribute state definition (attribute : Tree.attribute) =
  let name = attribute.node.name.node in
  let refuse reason =
    fail state attribute.span
      (Rule.message Generic_attribute
         (Printf.sprintf
            "the attribute %s %s, and the table of attributes does not \
             record that both backends take it alike for every type"
            (quote name) reason))
  in
  let alike =
    match find_attribute_entry name with
    | Some entry -> entry.alike
    | None -> false
  in
  if not alike then begin
    Option.iter
      (fun declared ->
        refuse
          ("names " ^ quote declared ^ ", which the definition declares"))
      (names_declared state definition attribute);
    match Hashtbl.find_opt state.attribute_subjects attribute.span.first with
    | Some false -> ()
    | Some true -> refuse "stands on a subject that mentions a type parameter"
    | None -> refuse "stands where typec does not read its subject"
  end

let check_generic_attributes state definition =
  List.iter
    (check_generic_attribute state definition)
    (Parser.attributes_in state.views definition)

let with_inner_attributes derived attributes =
  { derived with inner = read_attributes ~onto:derived.inner attributes }

(* Identifiers declared at file scope or in a block *)

let no_function_specifiers state span specified =
  if specified.inline || specified.noreturn then
    fail state span
      (Rule.c_text
         "a function specifier in the declaration of an identifier that is not \
          a function (C11 6.7.4p1)")

let no_alignment state span (specified : specified) what =
  if specified.alignments <> [] then
    fail state span
      (Rule.c_text ("an alignment specifier for " ^ what ^ " (C11 6.7.5p2)"))

(* 6.2.2p3-p5, 6.7.1p7: the linkage of a function. [storage] is not
   [typedef], and at file scope neither [auto] nor [register]. *)
let function_linkage state scope span name declared storage =
  match ((storage : Tree.storage_class option), scope) with
  | Some Static, File_scope -> Internal
  | (None | Some Extern), _ -> prior_linkage state scope span name declared
  | Some (Static | Auto | Register | Typedef | Thread_local), Block_scope ->
      fail state span
        (Rule.c_text
           "a function declared in a block has a storage class other than \
            extern (C11 6.7.1p7)")
  | Some (Auto | Register | Typedef | Thread_local), File_scope ->
      invalid_arg "Declarations: a storage class refused at file scope"

(* A declarator has [Old_style] parameters only where it defines the
   function (6.7.6.3p3), so its type tells an old-style definition. *)
let is_old_style_definition (t : Ctype.t) =
  match t.shape with
  | Function { parameters = Old_style (_ :: _); _ } -> true
  | Function { parameters = Prototype _ | Unspecified | Old_style []; _ }
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ | Unknown_type _ ->
      false

(* The spellings of the argument tokens of a [target] attribute, which
   design 13.5 compares token for token. *)
let target_spellings state (attribute : Tree.attribute) =
  match attribute.node.arguments with
  | None -> []
  | Some { first; last } ->
      List.init (last - first + 1) (fun offset ->
          Reader.spelling state.text state.text.tokens.(first + offset))

(* What a declaration of a function says of the property that design
   13.5 rests on, from the attributes [outer] around its declarator and
   [inner] inside it: its [target] attributes, and its first marked
   attribute, or [overloadable] where it follows an overload of its name
   in its scope (design 13.3). *)
let form_facts state (declared : Tree.declared) ~outer ~inner =
  (* The arguments of each attribute run from [(] to [)], so the tokens
     of all of them, together, are one fact of the declaration. *)
  let targets =
    match List.rev outer.targets @ List.rev inner.targets with
    | [] -> Entity.Untargeted
    | attributes ->
        Targeted (List.concat_map (target_spellings state) attributes)
  in
  let marked =
    match (outer.marked_attribute, inner.marked_attribute) with
    | Some (attribute : Tree.attribute), _ | None, Some attribute ->
        Some attribute.node.name.node
    | None, None when follows_overload state declared ->
        Some overloadable_attribute
    | None, None -> None
  in
  (targets, marked)

let function_declared state scope span specified name declared
    (derived : derived) storage =
  (* Its noreturn, gnu_inline and overload would be guessed false. *)
  Option.iter
    (fun attribute ->
      fail_needing state span
        ("the declaration of the function " ^ quote name)
        (attribute_unknown state attribute Unknown_function))
    derived.inner.effect_attribute;
  if specified.thread_local then
    fail state span
      (Rule.c_text "a function declared _Thread_local (C11 6.7.1p4)");
  no_alignment state span specified "a function";
  let targets, marked =
    form_facts state declared ~outer:specified.attributed ~inner:derived.inner
  in
  (* An overload redeclares nothing, so it has no visible declaration to
     take a linkage from. *)
  let declared =
    if specified.attributed.overloadable then
      { declared with Tree.earlier = None }
    else declared
  in
  Function
    {
      function_type = derived.declared_type;
      linkage = function_linkage state scope span name declared storage;
      inline = specified.inline;
      inline_definition =
        scope <> File_scope || (specified.inline && storage <> Some Extern);
      noreturn = specified.noreturn || specified.attributed.gnu_noreturn;
      (* GCC and Clang ignore it on a declaration without inline. *)
      gnu_inline = specified.inline && specified.attributed.gnu_inline;
      overload = specified.attributed.overloadable;
      old_style_definition = is_old_style_definition derived.declared_type;
      targets;
      marked;
    }

(* 6.2.2p3-p6, 6.2.4, 6.7.1p3: the linkage and storage duration of an
   object. [storage] is as for [function_linkage]. *)
let object_declared state scope span specified name declared
    (derived : derived) storage =
  no_function_specifiers state span specified;
  let register = storage = Some Tree.Register in
  let duration =
    if specified.thread_local then Thread_storage else Static_storage
  in
  let linkage, storage =
    match ((storage : Tree.storage_class option), scope) with
    | Some Static, File_scope -> (Internal, duration)
    | Some Static, Block_scope -> (No_linkage, duration)
    | Some Extern, _ ->
        (prior_linkage state scope span name declared, duration)
    | None, File_scope -> (External, duration)
    | (None | Some (Auto | Register)), Block_scope ->
        if specified.thread_local then
          fail state span
            (Rule.c_text
               "_Thread_local in a block without static or extern (C11 \
                6.7.1p3)");
        (No_linkage, Automatic_storage)
    | Some (Auto | Register | Typedef | Thread_local), File_scope
    | Some (Typedef | Thread_local), Block_scope ->
        invalid_arg "Declarations: a storage class refused before"
  in
  Object { object_type = derived.declared_type; linkage; storage; register }

(* What a declarator declares [name] as in [scope] (6.2.2, 6.2.4, 6.7.1,
   6.9p2). *)
let declared_as state scope span specified name declared (derived : derived) =
  match (specified.storage, scope) with
  | Some Typedef, _ ->
      no_function_specifiers state span specified;
      no_alignment state span specified "a typedef";
      Typedef { typedef_type = derived.declared_type }
  | Some (Auto | Register | Thread_local), File_scope ->
      fail state span (Rule.c_text "auto or register at file scope (C11 6.9p2)")
  | storage, _ -> (
      match Ctype.is_function derived.declared_type with
      | Answer true ->
          function_declared state scope span specified name declared derived
            storage
      | Answer false ->
          object_declared state scope span specified name declared derived
            storage
      | Depends_on unknown ->
          fail_needing state span
            ("whether " ^ quote name ^ " is a function or an object")
            unknown)

let has_linkage declared =
  linkage_of declared <> No_linkage && not (is_overload declared)

(* A block sees the last declaration at file scope of a name with
   linkage. *)
let note_at_file_scope state scope (entity : entity) =
  if scope = File_scope && has_linkage entity.declared then
    Hashtbl.replace state.at_file_scope entity.name entity

(* Whether a declarator in [scope] declares the function of a generic
   function, which instances alone stand for in the lowered C (design 7.1
   rule 8): an entity that no declaration links to, nor a block sees. *)
let declares_generic_function state scope =
  in_generic_function state && scope = File_scope

(* Design 7.1 rule 3: every declaration of an identifier with linkage
   denotes one object or function (C11 6.2.2p2), which each instance of
   a generic function would declare again, and a type that the body
   declares is each instance's own, so the linkage alone decides. *)
let refuse_linked_declaration state scope span (declared : Entity.declared) =
  if in_generic_function state && scope = Block_scope
     && linkage_of declared <> No_linkage
  then
    fail state span
      (Rule.message Type_parameter_operation
         "a declaration in a generic function gives its identifier \
          linkage, so every instance would declare the one object or \
          function again")

let unlinked : Entity.declared -> Entity.declared = function
  | Function declared -> Function { declared with linkage = No_linkage }
  | (Object _ | Typedef _ | Enumerator _) as declared -> declared

(* Records what a declarator declares in [scope]. *)
let declare_in state scope span specified declared (derived : derived) =
  match derived.name with
  | Some name -> (
      let next =
        declared_as state scope span specified name declared derived
      in
      let next =
        if declares_generic_function state scope then unlinked next else next
      in
      refuse_linked_declaration state scope span next;
      let has_linkage = has_linkage next in
      let inexact = specified.inexact in
      let bind_after prior =
        bind_to state span name declared prior ~inexact next
      in
      let entity =
        match (earlier_entity state span name declared, scope) with
        | Some prior, _ -> bind_after (Some prior)
        | None, _ when not has_linkage -> bind_after None
        | None, Block_scope when Hashtbl.mem state.at_file_scope name ->
            bind_after (Hashtbl.find_opt state.at_file_scope name)
        | None, (File_scope | Block_scope) -> (
            match Hashtbl.find_opt state.linked name with
            | Some other ->
                bind_unseen state span name declared other ~inexact next
            | None -> bind_after None)
      in
      note_at_file_scope state scope entity;
      entity)
  | None -> invalid_arg "Declarations: a declarator without a name"

let is_untagged (others : (Tree.span * Tree.type_specifier) list) =
  match others with
  | [ (_, Struct_or_union { tag = None; _ }) ] | [ (_, Enum { tag = None; _ }) ]
    ->
      true
  | _ -> false

(* Design 3.5 rule 2: a declarator that derives another type names that
   type, not the type of its specifiers. *)
let rec derives_nothing (declarator : Tree.declarator) =
  match declarator.node with
  | Name _ -> true
  | Parenthesized_declarator { inner; _ } -> derives_nothing inner
  | Pointer _ | Block_pointer _ | Array _ | Function _ -> false

(* The name that a declarator gives the type of its specifiers, if any. *)
let naming_name (init_declarator : Tree.init_declarator) =
  let declarator = init_declarator.node.declarator in
  let declared = Tree.In_tree init_declarator.node.declared.id in
  if derives_nothing declarator then
    Option.map
      (fun name -> { Ctype.name; declared })
      (Tree.declared_name declarator)
  else None

(* The declarator of a parameter, which an abstract one may omit. *)
let parameter_declarator (parameter : Tree.parameter_declarator) =
  match parameter with
  | Named_parameter { declarator; declared = _ } -> Some declarator
  | Abstract_parameter declarator -> declarator

(* Whether the text that spells a type is inexact: it holds an
   attribute, an alignment specifier or a [__typeof__] of an expression
   at the depth of design 3.5 rule 2, where a typedef name's entity
   records its own. typec's types carry no attribute or alignment, and
   the backend gives an expression the type of the typedef that declared
   it, attribute included. *)
let rec specifiers_are_inexact state (specifiers : Tree.specifiers) =
  List.exists
    (fun (specifier : Tree.declaration_specifier Tree.spanned) ->
      specifier_is_inexact state specifier.node)
    specifiers

and specifier_is_inexact state : Tree.declaration_specifier -> bool =
  function
  | Attributes attributes -> attributes <> []
  | Type_qualifier qualifier -> is_nullability qualifier
  | Type_specifier specifier -> type_specifier_is_inexact state specifier
  | Alignment_specifier _ -> true
  | Storage_class _ | Function_specifier _ -> false

and type_specifier_is_inexact state : Tree.type_specifier -> bool =
  function
  | Atomic_type type_name | Typeof_type type_name ->
      type_name_is_inexact state type_name
  | Typedef_name { declaration; name = _ } -> (
      match Hashtbl.find_opt state.entities declaration with
      | Some { declared = Typedef _; inexact; _ } -> inexact
      | Some _ | None -> false)
  | Application { name; generic = _; arguments = _ } -> (
      match Hashtbl.find_opt state.generics name with
      | Some { inexact; declaration = _ } -> inexact
      | None -> false)
  | Typeof_expression _ -> true
  | Basic _ | Struct_or_union _ | Enum _ -> false

and type_name_is_inexact state (type_name : Tree.type_name) =
  let { Tree.specifier_qualifiers; abstract } = type_name.node in
  specifiers_are_inexact state specifier_qualifiers
  || optional_declarator_is_inexact state abstract

and optional_declarator_is_inexact state = function
  | Some declarator -> declarator_is_inexact state declarator
  | None -> false

and declarator_is_inexact state (declarator : Tree.declarator) =
  let holds_nullability qualifiers =
    List.exists
      (fun (qualifier : Tree.type_qualifier Tree.spanned) ->
        is_nullability qualifier.node)
      qualifiers
  in
  match declarator.node with
  | Name _ -> false
  | Parenthesized_declarator { attributes; inner } ->
      attributes <> [] || declarator_is_inexact state inner
  | Pointer { qualifiers; attributes; inner }
  | Block_pointer { qualifiers; attributes; inner } ->
      attributes <> []
      || holds_nullability qualifiers
      || optional_declarator_is_inexact state inner
  | Array { inner; qualifiers; size = _ } ->
      holds_nullability qualifiers
      || optional_declarator_is_inexact state inner
  | Function { inner; parameters } ->
      optional_declarator_is_inexact state inner
      || parameters_are_inexact state parameters

and parameters_are_inexact state : Tree.parameters -> bool = function
  | Prototype { parameters; variadic = _ } ->
      List.exists (parameter_is_inexact state) parameters
  | Identifier_list _ -> false

and parameter_is_inexact state (parameter : Tree.parameter) =
  let ({ specifiers; declarator; attributes } : Tree.parameter_node) =
    parameter.node
  in
  attributes <> []
  || specifiers_are_inexact state specifiers
  || optional_declarator_is_inexact state (parameter_declarator declarator)

(* Whether a generic's definition is an alias whose text is inexact. The
   parser lets a definition name only generics read before it, whose
   fact is then recorded; a type parameter in it adds nothing, as its
   argument is checked where the application is read. *)
let definition_is_inexact state (declaration : Tree.type_declaration) =
  match declaration.node.definition with
  | Alias type_name -> type_name_is_inexact state type_name
  | Incomplete_variant | Variant _ | Distinct _ | Record_alias _ -> false

(* The specifiers as they apply to one declarator, which [attributes]
   follow: a declaration is inexact when its specifiers, its declarator
   or these attributes are. *)
let for_declarator state specified attributes declarator =
  let onto = specified.attributed in
  { specified with
    attributed = read_attributes ~onto attributes;
    inexact =
      specified.inexact || attributes <> []
      || optional_declarator_is_inexact state declarator }

(* The one funnel of the unit's instances to their encodings, which
   keeps the longest code of one that it has met. *)
let encoded_instance state generic arguments =
  let encoded = Encoding.instance state.tags generic arguments in
  let longest instance =
    let length = Encoding.code_length instance in
    state.longest_instance_code <- max state.longest_instance_code length
  in
  Result.iter longest encoded;
  encoded

(* The return type of a defined function, or the unknown type of the
   function: a typedef name of an unknown type may declare it (6.9.1p2).
   The declarator of a definition ends in a function derivation, so the
   type is no other. *)
let return_type (function_type : Ctype.t) : Ctype.t Unknown.answer =
  match function_type.shape with
  | Function { return; _ } -> Answer return
  | Unknown_type unknown -> Depends_on unknown
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Array _ ->
      invalid_arg "Declarations: a function definition of no function type"

let rec read_specifiers state (specifiers : Tree.specifiers) =
  let span = (List.hd specifiers).span in
  let sorted = sort_specifiers specifiers in
  let attributed = read_attributes ~onto:no_attributes sorted.attributes in
  let storage = storage_class state span sorted.storage_classes in
  let base = base_type state span sorted in
  let qualifiers = qualifiers_of sorted.qualifiers in
  if qualifiers.atomic then (
    refuse_opaque state span base "the type qualified by `_Atomic`";
    needs_complete state base);
  let base_type = checked state span (Ctype.qualify qualifiers base) in
  List.iter (fun (_, a) -> alignment state a) sorted.alignments;
  {
    storage;
    thread_local = List.mem Tree.Thread_local sorted.storage_classes;
    base_type;
    inline = List.mem Tree.Inline sorted.function_specifiers;
    noreturn = List.mem Tree.Noreturn sorted.function_specifiers;
    alignments = List.map fst sorted.alignments;
    attributed;
    untagged = is_untagged sorted.others;
    inexact = specifiers_are_inexact state specifiers;
  }

and base_type state span sorted =
  match (sorted.basic, sorted.others) with
  | [], [] ->
      fail state span
        (Rule.c_text "a declaration has no type specifier (C11 6.7.2p2)")
  | [ Void ], [] -> Ctype.void
  | basic, [] when List.exists is_optional_float basic ->
      optional_float_type state span basic
  | basic, [] -> (
      match basic_type basic with
      | Some arithmetic ->
          checked state span (Ctype.arithmetic state.target arithmetic)
      | None -> complex_integer_type state span basic)
  | [], [ (own, other) ] -> other_type state span ~own other
  | _ ->
      fail state span
        (Rule.c_text "type specifiers that do not combine (C11 6.7.2p2)")

(* An optional floating type, such as [_Float16], real or complex, for
   which the target model has no size. The specifiers are sorted in the
   order of [Tree.basic_type_specifier], as in [basic_type]. *)
and optional_float_type state span basic =
  match List.sort compare basic with
  | [ Optional_float optional ] ->
      let name = Optional_float.spelling optional in
      unknown_type state span (quote name) Unknown_object
  | [ Complex; Optional_float optional ] ->
      let name = "_Complex " ^ Optional_float.spelling optional in
      unknown_type state span (quote name) Unknown_object
  | _ ->
      fail state span
        (Rule.c_text "type specifiers that do not combine (C11 6.7.2p2)")

(* GNU's complex integer types, such as [_Complex int], which typec does
   not type: one for each standard integer type, which GCC and Clang
   both have. Neither has [_Complex _Bool], and Clang has no
   [_Complex __int128]. *)
and complex_integer_type state span basic =
  let complex, real = List.partition (fun s -> s = Tree.Complex) basic in
  let excluded = [ Integer.Bool; Int128; Unsigned_int128 ] in
  match (complex, Integer.of_specifiers real) with
  | [ _ ], Some integer when not (List.mem integer excluded) ->
      let name = "_Complex " ^ Integer.name integer in
      unknown_type state span (quote name) Unknown_object
  | _ ->
      fail state span
        (Rule.c_text "type specifiers that do not combine (C11 6.7.2p2)")

(* An attribute of a structure, union or enumeration specifier that typec
   does not know makes the type it gives unknown. The tag is declared and
   defined as written: no attribute changes the identity, members or
   completeness of a record, the facts that typec computes of it, while
   one may change the integer type of an enumeration, which is then
   unknown wherever the tag names it. *)
and other_type state span ~(own : Tree.span) (specifier : Tree.type_specifier)
    =
  match specifier with
  | Basic _ -> invalid_arg "Declarations.other_type"
  | Atomic_type type_name ->
      let t = read_type_name state type_name in
      refuse_opaque state type_name.span t "the type name of `_Atomic( )`";
      needs_complete state t;
      checked state span (Ctype.atomic t)
  | Struct_or_union { kind; tag; members; attributes } ->
      let record = record_type state span (record_kind kind) tag members in
      obscured_by state attributes (Ctype.record record)
  | Enum { tag; enumerators; underlying; attributes } ->
      let fixed = Option.map (fixed_type state span) underlying in
      let attribute =
        first_unrecorded_attribute (enum_attributes ~fixed attributes)
      in
      let enum = enum_type state span ~attribute ~fixed tag enumerators in
      note_subject state attributes (Ctype.enum enum);
      obscured state attribute (Ctype.enum enum)
  | Typeof_type type_name ->
      let t = read_type_name state type_name in
      refuse_opaque state type_name.span t "the type name of `typeof( )`";
      t
  | Typeof_expression expression -> typeof_expression state expression
  | Application { name; generic = _; arguments } ->
      applied_type state own name arguments
  | Typedef_name { name; declaration } -> (
      match Hashtbl.find_opt state.universe_aliases declaration with
      | Some alias -> universe_alias state own alias
      | None -> typedef_type state span ~own name declaration)

(* A universe alias, [str], read at its use as the application that it
   names: the universe text is not emitted (design 3.6), so lowering
   writes the name of the instance for the typedef name. *)
and universe_alias state span (alias : Tree.type_name) =
  match alias.node with
  | {
   specifier_qualifiers =
     [
       { node = Type_specifier (Application { name; generic = _; arguments });
         _ };
     ];
   abstract = None;
  } ->
      applied_type state span name arguments
  | _ -> invalid_arg "Declarations.universe_alias"

and typedef_type state span ~own name declaration =
  match entity_used state span name declaration with
  | Some { declared = Typedef { typedef_type; _ }; _ } ->
      note_parameter_use state own declaration;
      typedef_type
  | Some _ | None ->
      fail state span (Rule.c_text (quote name ^ " is not a typedef name"))

(* GNU [typeof] of an expression is its type, unconverted. *)
and typeof_expression state expression =
  let typed = Expressions.typeof_value (typing state) expression in
  Expressions.refuse_instance_name (typing state) expression;
  typed.expression_type

(* 6.7.5p3: the value is the backend's to check, as layout is. A type
   names its alignment (6.7.5p6), which differs between arguments where
   the type mentions a type parameter (design 7.1 rule 4). *)
and alignment state (alignment : Tree.alignment) =
  match alignment with
  | Alignas_type type_name ->
      let t = read_type_name state type_name in
      if Ctype.mentions_opaque state.tags t then
        fail state type_name.span
          (Rule.message Type_parameter_constant
             "the type of `_Alignas` mentions a type parameter, so the \
              alignment differs between arguments");
      needs_complete state t
  | Alignas_expression expression -> (
      match constant_expression state expression with
      | Constant _ -> ()
      | Not_constant span ->
          fail state span
            (Rule.c_text
               "an alignment is not an integer constant expression (C11 \
                6.7.5p3)"))

(* Tags (6.7.2.3) *)

(* The tag that [tag] names (p9) or redeclares (p4), as the parser has
   decided; none where it declares the first tag of its name in its
   scope. *)
and prior_tag state (tag : Tree.tag) =
  let known id =
    match Hashtbl.find_opt state.tag_types id with
    | Some found -> found
    | None -> not_read state tag.name.span tag.name.node
  in
  let used id =
    note_use state tag.name.span tag.name.node (Resolution.Tag id);
    known id
  in
  match tag.binding with
  | Declares { earlier; _ } -> Option.map used earlier
  | Names id -> Some (used id)

(* A mention that declares its tag in a parameter list or a block only
   because none is visible (C11 6.7.2.3p8), which the placement of an
   instance (design 10.3) must not change. *)
and note_nested_mention state (tag : Tree.tag) =
  match tag.binding with
  | Declares { implicit = true; _ }
    when (not (at_file_scope state)) && not (in_instance_definition state) ->
      Hashtbl.replace state.external_facts.nested_tags tag.name.node ()
  | Declares _ | Names _ -> ()

(* [tag] is a declaration of [found] where it declares one. *)
and bind_tag state (tag : Tree.tag) found =
  match tag.binding with
  | Declares { id; scope; implicit; earlier = _ } ->
      note_own state tag.name.span tag.name.node (Resolution.Tag id) ~scope
        ~implicit ~linked:false;
      Hashtbl.replace state.tag_types id found
  | Names _ -> ()

and record_type state span kind (tag : Tree.tag option) members =
  let record =
    match tag with
    | None ->
        Ctype.declare_record state.tags kind None
          ~at_file_scope:(at_file_scope state)
    | Some tag ->
        let record =
          match prior_tag state tag with
          | Some (Record_tag record) when record.kind = kind -> record
          | Some (Record_tag _ | Enum_tag _) -> wrong_kind_of_tag state tag.name
          | None ->
              Ctype.declare_record state.tags kind (Some tag.name.node)
                ~at_file_scope:(at_file_scope state)
        in
        bind_tag state tag (Record_tag record);
        note_nested_mention state tag;
        record
  in
  Option.iter (define_record state span record) members;
  record

(* [span] is the specifier's: GNU C allows a body without members. *)
and define_record state span record
    (members : Tree.member_declaration list Tree.spanned) =
  let members = List.concat_map (read_member state) members.node in
  checked state span
    (Ctype.define_record state.target state.tags record members);
  note_completed state span (Ctype.Named_record record)

(* A tag that the source completes, an event of the window of design
   13.5, which no instance read in the same external declaration may
   need (design 10.3). *)
and note_completed state (span : Tree.span) tag =
  state.completed_at <-
    Resolution.Events.add span.first tag state.completed_at;
  if not (in_instance_definition state) then
    Hashtbl.replace state.external_facts.completed tag (location_of state span)

(* [fixed] is the fixed type of the specifier (C23 6.7.2.2), [attribute]
   its first attribute that typec does not know. *)
and enum_type state span ~attribute ~fixed (tag : Tree.tag option)
    enumerators =
  (* GNU: an enumeration declared before its list, which 6.7.2.3p3 does
     not allow, as both backends accept it. *)
  let enum =
    match tag with
    | None ->
        Ctype.declare_enum state.tags None ~at_file_scope:(at_file_scope state)
    | Some tag ->
        let enum =
          match prior_tag state tag with
          | Some (Enum_tag enum) -> enum
          | Some (Record_tag _) -> wrong_kind_of_tag state tag.name
          | None ->
              Ctype.declare_enum state.tags (Some tag.name.node)
                ~at_file_scope:(at_file_scope state)
        in
        bind_tag state tag (Enum_tag enum);
        note_nested_mention state tag;
        enum
  in
  (match (fixed, enumerators) with
  | Some fixed, _ ->
      let stated = attributed_integer state attribute fixed in
      let listed = enumerators <> None in
      let recorded =
        checked state span (Ctype.fix_enum state.tags enum stated ~listed)
      in
      (* An attribute applies to the list it stands with: Clang gives the
         enumerators the type that [mode] makes even after a declaration
         without it. *)
      let integer = if attribute = None then recorded else stated in
      Option.iter (define_fixed_enum state span enum integer) enumerators
  | None, Some enumerators ->
      checked state span (Ctype.check_unfixed_list state.tags enum);
      define_enum state span ~attribute enum enumerators
  | None, None -> ());
  enum

(* [packed] narrows the integer type of an enumeration to the narrowest
   that holds its values; a fixed type leaves it nothing to narrow, and
   GCC and Clang ignore it there. *)
and enum_attributes ~fixed attributes =
  match fixed with
  | None -> attributes
  | Some _ ->
      List.filter
        (fun (attribute : Tree.attribute) ->
          attribute.node.name.node <> "packed")
        attributes

(* The integer type of an enumeration, unknown where an attribute that
   typec does not know may change it, as [packed] and [mode] do. *)
and attributed_integer state attribute (integer : Integer.t Unknown.answer) :
    Integer.t Unknown.answer =
  match attribute with
  | Some attribute ->
      Depends_on (attribute_unknown state attribute Unknown_object)
  | None -> integer

(* C23 6.7.2.2: the fixed type of an enumeration names an integer type
   other than an enumerated type; its qualifiers do not count. *)
and fixed_type state span specifiers : Integer.t Unknown.answer =
  let specified = read_specifiers state specifiers in
  let fixed = declare_type state ~parameter:false specified None in
  match fixed.declared_type.shape with
  | Arithmetic (Integer integer) -> Answer integer
  | Unknown_type unknown -> Depends_on unknown
  | Void | Arithmetic (Real _ | Complex _) | Enum _ | Pointer _ | Record _
  | Distinct _ | Va_list | Array _ | Function _ ->
      fail state span
        (Rule.c_text
           "the fixed type of an enumeration is not an integer type (C23 \
            6.7.2.2)")

(* Members (6.7.2.1) *)

and read_member state (member : Tree.member_declaration) =
  match member.node with
  | Member_static_assert assertion ->
      static_assert state assertion;
      []
  | Members { specifiers; declarators = [] } ->
      let specified = read_specifiers state specifiers in
      if is_anonymous_record specifiers then
        let derived = declare_type state ~parameter:false specified None in
        [ { Ctype.member_name = None; member_type = derived.declared_type;
            bit_field_width = None } ]
      else []
  | Members { specifiers; declarators } ->
      let specified = read_specifiers state specifiers in
      List.map (read_member_declarator state specified) declarators

(* 6.7.2.1p13: an unnamed member whose type is a structure or union
   specifier without a tag. *)
and is_anonymous_record (specifiers : Tree.specifiers) =
  List.exists
    (fun (specifier : Tree.declaration_specifier Tree.spanned) ->
      match specifier.node with
      | Type_specifier
          (Struct_or_union
            { tag = None; members = Some _; kind = _; attributes = _ }) ->
          true
      | _ -> false)
    specifiers

and read_member_declarator state specified
    (declarator : Tree.member_declarator) =
  match declarator.node with
  | Field { declarator = field; attributes } ->
      let specified = for_declarator state specified attributes (Some field) in
      let derived =
        declare_type state ~parameter:false specified (Some field)
      in
      needs_complete state derived.declared_type;
      { Ctype.member_name = derived.name; member_type = derived.declared_type;
        bit_field_width = None }
  | Bit_field { declarator = field; width; attributes } ->
      let specified = for_declarator state specified attributes field in
      List.iter
        (fun span ->
          fail state span
            (Rule.c_text
               "a bit-field has an alignment specifier (C11 6.7.5p2)"))
        specified.alignments;
      let derived = declare_type state ~parameter:false specified field in
      refuse_opaque state declarator.span derived.declared_type
        "the type of a bit-field";
      let bit_field_width = Some (bit_field_width state width) in
      { Ctype.member_name = derived.name; member_type = derived.declared_type;
        bit_field_width }

(* Design 10.3: every point that needs a type complete passes it here,
   the one place that defines an instance, where the point stands: a
   member as it is read, so that the instances that members need are
   defined in the order of the text (design 3.5 rule 7). What a reading
   of an instance needs complete must be so before the external
   declaration that its text stands before. The point reports a type
   that stays incomplete, or leaves it to the backend. *)
and needs_complete state t =
  (* The application of the definition is one before its reading, not
     one that the definition holds. *)
  let applied_at = state.applied_at in
  (match Ctype.define_instance state.tags t with
  | Some instance ->
      let application = Ctype.Instances.find instance applied_at in
      note_text state instance Defined ~application
  | None -> ());
  let completed_here tag =
    Hashtbl.find_opt state.external_facts.completed tag
  in
  match (state.nesting, Option.bind (Ctype.needed_tag t) completed_here) with
  | Some nesting, Some completed ->
      fail_completed_here state nesting t completed
  | (Some _ | None), _ -> ()

(* A text of [instance] at the anchor of the external declaration being
   read, after every text met before it: what the reading of a
   definition puts there is met before the text of that definition, as
   it stands (design 10.3), so the order of the texts is the order in
   which they are met. *)
and note_text state (instance : Ctype.instance) step ~application =
  if gets_texts state instance then
    let placement =
      { instance; step; at = Option.get state.external_facts.anchor;
        application }
    in
    let placements = state.placements in
    state.placements <-
      { placements with texts = placement :: placements.texts }

(* The text of the instance being read stands before this external
   declaration, which completes [t] only after it, at [completed]. *)
and fail_completed_here state nesting t (completed : Location.t) =
  let message =
    Printf.sprintf
      "the instance %s needs %s complete where its text stands, before \
       the external declaration that completes it at %s:%d; complete it \
       in an earlier one"
      (quote (shown_instance nesting.defining))
      (quote (Type_name.of_ctype t))
      completed.file completed.line
  in
  raise
    (Instance_failed
       { location = location_of state nesting.began;
         message = Rule.text (Rule.message Instance_placement message) })

and bit_field_width state width =
  match constant_expression state width with
  | Constant { value = Known width_value; _ } -> (
      match Exact_integer.to_int width_value with
      | Some bits -> bits
      | None ->
          fail state width.span
            (Rule.c_text (Ctype.error_message Ctype.Invalid_bit_field)))
  | Constant { value = Opaque; _ } ->
      fail state width.span
        (Rule.message Profile
           "the width of a bit-field is one that typec does not evaluate")
  | Not_constant span ->
      fail state span
        (Rule.c_text
           "the width of a bit-field is not an integer constant expression \
            (C11 6.7.2.1p4)")

(* Enumerations (6.7.2.2) *)

(* An enumerator has a type and a value, which an attribute that typec
   does not know might change. Its declaration needs both: an opaque
   value needs its integer type. *)
and check_enumerator_attributes state (name : Tree.identifier) attributes =
  note_subjects state (attribute_firsts attributes) ~mentions:false;
  Option.iter
    (fun attribute ->
      fail_needing state name.span
        ("the enumerator " ^ quote name.node)
        (attribute_unknown state attribute Unknown_object))
    (first_unrecorded_attribute attributes)

(* The value of each enumerator is known: one the backend evaluates would
   decide the integer type of the enumeration, and with it the types and
   sizes that follow, which typec would have to guess (design P16). *)
and define_enum state span ~attribute enum (enumerators : Tree.enumerator list)
    =
  let declare (previous, read) (enumerator : Tree.enumerator) =
    let { Tree.name; declared; attributes; value } = enumerator.node in
    check_enumerator_attributes state name attributes;
    let ((integer, value) as typed) =
      enumerator_value state previous enumerator.span value
    in
    let enumerator_type = integer_type state name.span integer in
    let constant = Integer_constant.known state.target integer value in
    (* An enumerator holds only the attributes of the table, which change
       no type ([check_enumerator_attributes]). *)
    let entity =
      bind state name.span name.node declared ~inexact:false
        (Enumerator { enumerator_type; value = constant })
    in
    (Some typed, (declared.id, entity, value) :: read)
  in
  let _, read = List.fold_left declare (None, []) enumerators in
  let values = List.map (fun (_, _, value) -> value) read in
  let integer =
    attributed_integer state attribute (Answer (enum_integer state span values))
  in
  checked state span (Ctype.define_enum state.tags enum integer);
  note_completed state span (Ctype.Named_enum enum);
  (* At the closing brace every enumerator takes its final type (C23
     6.7.2.2): int when all values fit, else the enumerated type. *)
  let all_int = List.for_all (Integer_constant.fits state.target Int) values in
  let final_type, final_integer =
    match (all_int, integer) with
    | true, _ -> (integer_type state span Int, Integer.Int)
    | false, Answer integer -> (Ctype.enum enum, integer)
    | false, Depends_on unknown ->
        fail_needing state span
          "the type of enumerators that int does not hold" unknown
  in
  List.iter
    (fun (id, entity, value) ->
      let value = Integer_constant.known state.target final_integer value in
      let declared = Enumerator { enumerator_type = final_type; value } in
      Hashtbl.replace state.entities (In_tree id) { entity with declared })
    read

(* The enumerators of an enumeration with a fixed type have the enumerated
   type and values that the fixed type holds (C23 6.7.2.2). A value that
   the backend evaluates decides no type here, so it may be opaque. *)
and define_fixed_enum state span enum (integer : Integer.t Unknown.answer)
    enumerators =
  let integer =
    match integer with
    | Answer integer -> integer
    | Depends_on unknown ->
        fail_needing state span "the value of each enumerator" unknown
  in
  let declare previous (enumerator : Tree.enumerator) =
    let { Tree.name; declared; attributes; value } = enumerator.node in
    check_enumerator_attributes state name attributes;
    let value =
      fixed_enumerator_value state integer previous enumerator.span value
    in
    let enumerator = Enumerator { enumerator_type = Ctype.enum enum; value } in
    (* As in [define_enum], the attributes change no type. *)
    ignore (bind state name.span name.node declared ~inexact:false enumerator);
    Some value
  in
  ignore (List.fold_left declare None enumerators)

and fixed_enumerator_value state integer previous span
    (value : Tree.expression option) =
  let target = state.target in
  let held span value =
    if not (Integer_constant.fits target integer value) then
      fail state span
        (Rule.c_text
           "an enumerator value is not representable in the fixed type of its \
            enumeration (C23 6.7.2.2)");
    Integer_constant.known target integer value
  in
  match (value, previous) with
  | Some expression, _ -> (
      match constant_expression state expression with
      | Not_constant span ->
          fail state span
            (Rule.c_text
               "an enumerator value is not an integer constant expression (C11 \
                6.7.2.2p2)")
      | Constant { value = Opaque; _ } -> Opaque
      | Constant { value = Known value; _ } -> held expression.span value)
  | None, None -> held span Exact_integer.zero
  | None, Some Integer_constant.Opaque -> Opaque
  | None, Some (Known previous) ->
      held span (Exact_integer.add previous Exact_integer.one)

(* The type and value of an enumerator while its list is read: int when
   the value fits, else the type of its value (C23 6.7.2.2, as in GCC and
   Clang). *)
and enumerator_value state previous span (value : Tree.expression option) =
  let target = state.target in
  match (value, previous) with
  | Some expression, _ -> (
      match constant_expression state expression with
      | Not_constant span ->
          fail state span
            (Rule.c_text
               "an enumerator value is not an integer constant expression (C11 \
                6.7.2.2p2)")
      | Constant { value = Opaque; _ } ->
          fail state expression.span
            (Rule.message Profile
               "an enumerator value is one that typec does not evaluate")
      | Constant { value = Known value; _ }
        when Integer_constant.fits target Int value ->
          (Integer.Int, value)
      | Constant { integer_type; value = Known value } -> (integer_type, value))
  | None, None -> (Integer.Int, Exact_integer.zero)
  | None, Some previous -> successor state span previous

(* The previous value plus one in its type, or in the next standard type
   of its signedness that holds it. *)
and successor state span (previous_type, previous) =
  let target = state.target in
  let same_signedness =
    if Target.is_signed target previous_type then
      [ Integer.Int; Long; Long_long ]
    else [ Unsigned_int; Unsigned_long; Unsigned_long_long ]
  in
  let candidates =
    List.filter
      (fun integer -> Integer.rank integer >= Integer.rank previous_type)
      same_signedness
  in
  let next = Exact_integer.add previous Exact_integer.one in
  match
    List.find_opt (fun integer -> Integer_constant.fits target integer next)
      candidates
  with
  | Some integer -> (integer, next)
  | None ->
      fail state span
        (Rule.c_text
           "an enumerator value is too large for every integer type (C11 \
            6.7.2.2p2)")

(* The narrowest range of two's complement integers that holds the
   values. *)
and enum_integer state span values =
  let negative = List.exists Exact_integer.is_negative values in
  let width_of value =
    let magnitude =
      if Exact_integer.is_negative value then
        Exact_integer.sub (Exact_integer.neg value) Exact_integer.one
      else value
    in
    let sign_bit = if negative then 1 else 0 in
    Exact_integer.bit_length magnitude + sign_bit
  in
  let width =
    List.fold_left (fun width value -> Int.max width (width_of value)) 0 values
  in
  match Arithmetic.enum_compatible_type state.target { negative; width } with
  | Some integer -> integer
  | None ->
      fail state span
        (Rule.c_text
           "no integer type holds the values of the enumeration (C11 \
            6.7.2.2p4)")

(* Static assertions (6.7.10) *)

and static_assert state ({ condition; message } : Tree.static_assertion) =
  match constant_expression state condition with
  | Not_constant span ->
      fail state span
        (Rule.c_text
           "the condition of a static assertion is not an integer constant \
            expression (C11 6.7.10p2)")
  | Constant { value; _ } -> (
      match Integer_constant.truth value with
      | Some false ->
          let first = (List.hd message).span in
          fail state condition.span
            (Rule.c_text
               ("static assertion failed: " ^ quote (spelling state first)))
      | Some true | None -> ())

(* Declarators (6.7.6) *)

(* The one way from specifiers and a declarator to the name and type they
   declare: the derivations of the declarator applied to the type of the
   specifiers, then the attributes of both. [definition] is as in
   [derive]; [records_effects] says that the caller records the effects
   of the attributes for a function it declares. *)
and declare_type state ?definition ?(records_effects = false) ~parameter
    specified declarator =
  let underived =
    { name = None; declared_type = specified.base_type;
      parameter_qualifiers = Qualifiers.none; defines = false;
      inner = no_attributes }
  in
  let derived =
    match declarator with
    | Some declarator ->
        derive state ~parameter ~definition underived declarator
    | None -> underived
  in
  let attributed = specified.attributed in
  note_subjects state
    (attribute_firsts (attributed.attributes @ derived.inner.attributes)
    @ List.map (fun (span : Tree.span) -> span.first) specified.alignments)
    ~mentions:(Ctype.mentions_opaque state.tags derived.declared_type);
  let attribute =
    match Ctype.is_function derived.declared_type with
    | Answer true when records_effects -> attributed.unknown_attribute
    | Answer (true | false) | Depends_on _ -> unrecorded attributed
  in
  let declared_type = obscured state attribute derived.declared_type in
  { derived with declared_type }

(* The derivations of [declarator] applied to [underived], outside in,
   though they are read from the name outward, in the order of the text,
   as an array length or a parameter list may declare what a later one
   uses (6.2.1p7). Both walks are loops, so a long chain needs no stack.
   [definition] is the declaration list of a function definition, whose
   function derivation is the one nearest the name. *)
and derive state ~parameter ~definition underived declarator =
  let rec inward outer (declarator : Tree.declarator) =
    let outer = declarator :: outer in
    match declarator.node with
    | Name _ -> outer
    | Parenthesized_declarator { inner; attributes = _ } -> inward outer inner
    | Pointer { inner; _ }
    | Block_pointer { inner; _ }
    | Array { inner; _ }
    | Function { inner; _ } -> (
        match inner with Some inner -> inward outer inner | None -> outer)
  in
  (* [nearest] until a derivation other than a parenthesis is read. *)
  let read (nearest, applications) (declarator : Tree.declarator) =
    let apply =
      read_derivation state ~parameter ~definition ~nearest declarator
    in
    let nearest =
      match declarator.node with
      | Name _ | Parenthesized_declarator _ -> nearest
      | Pointer _ | Block_pointer _ | Array _ | Function _ -> false
    in
    (nearest, apply :: applications)
  in
  let _, applications =
    List.fold_left read (true, []) (inward [] declarator)
  in
  List.fold_left (fun derived apply -> apply derived) underived applications

(* Reads what a derivation holds that is not a type, and returns what
   applies the derivation to the type that the declarator around it
   derives. [nearest] says that no derivation but a parenthesis stands
   between it and the name, so that it derives the outermost type. The
   attributes of a derivation apply to the type it derives. *)
and read_derivation state ~parameter ~definition ~nearest
    (declarator : Tree.declarator) =
  let span = declarator.span in
  match declarator.node with
  | Name name -> fun derived -> { derived with name = Some name }
  | Parenthesized_declarator { attributes; inner = _ } ->
      fun derived ->
        let declared_type =
          obscured_by state attributes derived.declared_type
        in
        { (with_inner_attributes derived attributes) with declared_type }
  | Pointer { qualifiers; attributes; inner = _ } ->
      fun derived ->
        let pointer =
          checked state span (Ctype.pointer_to derived.declared_type)
        in
        let qualifiers = spanned_qualifiers qualifiers in
        let declared_type =
          checked state span (Ctype.qualify qualifiers pointer)
        in
        let declared_type = obscured_by state attributes declared_type in
        { (with_inner_attributes derived attributes) with declared_type }
  (* Clang's block pointer, whose type typec does not model. *)
  | Block_pointer { qualifiers = _; attributes; inner = _ } ->
      fun derived ->
        let declared_type =
          unknown_type state span "a block pointer" Unknown_object
        in
        let declared_type = obscured_by state attributes declared_type in
        { (with_inner_attributes derived attributes) with declared_type }
  | Array { inner = _; qualifiers; size } ->
      let adjusted = parameter && nearest in
      let qualified = qualifiers <> [] in
      let is_static = match size with Static_sized _ -> true | _ -> false in
      if (qualified || is_static) && not adjusted then
        fail state span
          (Rule.c_text
             "qualifiers or static in an array derivation that is not the \
              outermost of a parameter (C11 6.7.6.2p1)");
      let length = array_length state span size in
      fun derived ->
        needs_complete state derived.declared_type;
        let declared_type =
          checked state span
            (Ctype.array_of state.tags derived.declared_type length)
        in
        let parameter_qualifiers =
          if adjusted then spanned_qualifiers qualifiers
          else derived.parameter_qualifiers
        in
        { derived with declared_type; parameter_qualifiers }
  | Function { inner = _; parameters } ->
      let defines = definition <> None && nearest in
      let parameters =
        read_parameters state
          ~definition:(if defines then definition else None)
          parameters
      in
      fun derived ->
        let declared_type =
          checked state span
            (Ctype.function_returning derived.declared_type parameters)
        in
        { derived with declared_type; defines = derived.defines || defines }

and array_length state span (size : Tree.array_size) : Ctype.length =
  match size with
  | Unsized -> Unknown
  | Unspecified_variable when state.place = In_prototype -> Variable
  | Unspecified_variable ->
      fail state span
        (Rule.c_text "[*] outside function prototype scope (C11 6.7.6.2p4)")
  | Sized expression | Static_sized expression -> (
      match constant_expression state expression with
      | Constant { value = Known length; _ } -> (
          match Exact_integer.to_int length with
          | Some length -> Constant length
          | None ->
              fail state expression.span
                (Rule.c_text "an array is too large"))
      | Constant { value = Opaque; _ } -> Opaque
      | Not_constant _ when state.place <> At_file_scope -> Variable
      | Not_constant span ->
          fail state span
            (Rule.c_text
               "an array length that is not an integer constant expression \
                gives a variable length array, which cannot have file scope \
                (C11 6.7.6.2p2)"))

(* Parameters (6.7.6.3) *)

(* The parameter types; [definition] as in [derive]. *)
and read_parameters state ~definition (parameters : Tree.parameters) =
  match (parameters, definition) with
  | Identifier_list [], None -> Ctype.Unspecified
  | Identifier_list (first :: _), None ->
      fail state first.name.span
        (Rule.c_text
           "an identifier list in a function declarator that is not a \
            definition (C11 6.7.6.3p3)")
  | Identifier_list names, Some declarations ->
      old_style_parameters state names declarations
  | Prototype { parameters; variadic }, _ ->
      let place = if definition = None then In_prototype else In_definition in
      let types =
        within state place (fun () ->
            List.map (read_parameter state) parameters)
      in
      let types =
        match (parameters, types) with
        | ( [
              {
                node =
                  {
                    declarator = Abstract_parameter None;
                    specifiers = _;
                    attributes = _;
                  };
                _;
              };
            ],
            [ only ] )
          when only = Ctype.void ->
            []
        | _ -> types
      in
      Ctype.Prototype { types; variadic }

and read_parameter state (parameter : Tree.parameter) =
  let span = parameter.span in
  let ({ specifiers; declarator; attributes } : Tree.parameter_node) =
    parameter.node
  in
  let specified =
    for_declarator state
      (parameter_specifiers state span specifiers)
      attributes
      (parameter_declarator declarator)
  in
  match declarator with
  | Named_parameter { declarator; declared } ->
      let derived =
        declare_type state ~parameter:true specified (Some declarator)
      in
      Option.iter
        (fun name ->
          ignore
            (declare_parameter state span specified derived name declared))
        derived.name;
      derived.declared_type
  | Abstract_parameter declarator ->
      (declare_type state ~parameter:true specified declarator).declared_type

and parameter_specifiers state span specifiers =
  let specified = read_specifiers state specifiers in
  (match (specified.storage, specified.thread_local) with
  | (None | Some Register), false -> ()
  | _ ->
      fail state span
        (Rule.c_text
           "a parameter has a storage class other than register (C11 \
            6.7.6.3p2)"));
  if specified.inline || specified.noreturn then
    fail state span
      (Rule.c_text "a parameter has a function specifier (C11 6.7.4p1)");
  if specified.alignments <> [] then
    fail state span
      (Rule.c_text "a parameter has an alignment specifier (C11 6.7.5p2)");
  specified

(* Records the parameter and returns its type. *)
and declare_parameter state span specified derived name declared =
  let object_type = adjusted_parameter state span derived in
  if state.place = In_definition then needs_complete state object_type;
  let register = specified.storage = Some Tree.Register in
  let parameter =
    Object
      {
        object_type = parameter_object_type state span object_type;
        linkage = No_linkage;
        storage = Automatic_storage;
        register;
      }
  in
  ignore (bind state span name declared ~inexact:specified.inexact parameter);
  object_type

(* Design P20: a va_list parameter is adjusted as the target's va_list
   is, to a pointer where it is an array (x86-64), so in the body the
   parameter has a type that typec does not know. *)
and parameter_object_type state span (t : Ctype.t) =
  match t.shape with
  | Va_list -> unknown_type state span "a va_list parameter" Unknown_object
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Array _
  | Function _ | Unknown_type _ ->
      t

(* 6.9.1p6: the declaration list declares the names of the identifier list
   and no others, which are the parameters in the order of the list. A
   name of the list is no entity: [types] maps each to the type that the
   declarator that redeclares it gives, [None] until one does. *)
and old_style_parameters state (names : Tree.parameter_name list)
    declarations =
  let types = Hashtbl.create (List.length names) in
  List.iter
    (fun (listed : Tree.parameter_name) ->
      Hashtbl.replace types listed.declared.id None)
    names;
  within state In_definition (fun () ->
      List.iter (read_old_style_declaration state types) declarations);
  Ctype.Old_style (List.map (old_style_parameter_type state types) names)

and read_old_style_declaration state types
    (declaration : Tree.declaration) =
  let span = declaration.span in
  match declaration.node with
  | Static_assert assertion -> static_assert state assertion
  | Declaration { declarators = []; specifiers = _ } ->
      fail state span
        (Rule.c_text
           "a declaration before a function body declares no parameter (C11 \
            6.9.1p6)")
  | Declaration { specifiers; declarators } ->
      let specified = parameter_specifiers state span specifiers in
      List.iter (read_old_style_declarator state types specified) declarators

and read_old_style_declarator state types specified
    (init_declarator : Tree.init_declarator) =
  let span = init_declarator.span in
  let { Tree.declarator; declared; asm_label = _; attributes; initialiser } =
    init_declarator.node
  in
  if initialiser <> None then
    fail state span
      (Rule.c_text
         "a declaration before a function body has an initializer (C11 \
          6.9.1p6)");
  let specified =
    for_declarator state specified attributes (Some declarator)
  in
  let derived =
    declare_type state ~parameter:true specified (Some declarator)
  in
  match (derived.name, declared.earlier) with
  | Some name, Some (In_tree listed) when Hashtbl.mem types listed ->
      let first = { declared with earlier = None } in
      let object_type =
        declare_parameter state span specified derived name first
      in
      Hashtbl.replace types listed (Some object_type)
  (* What it redeclares is a parameter or an enumerator of the list's
     scope, so [bind] refuses it (6.7p3). *)
  | Some name, Some _ ->
      ignore (declare_parameter state span specified derived name declared)
  | Some _, None | None, _ ->
      fail state span
        (Rule.c_text
           "a declaration before a function body declares a name that is not \
            in its identifier list (C11 6.9.1p6)")

and old_style_parameter_type state types (name : Tree.parameter_name) =
  match Hashtbl.find_opt types name.declared.id with
  | Some (Some object_type) -> object_type
  | Some None | None ->
      fail state name.name.span
        (Rule.c_text
           (quote name.name.node
          ^ " in the identifier list is not declared (C11 6.9.1p6)"))

(* The type a parameter has in its function (6.7.6.3p7, p8). *)
and adjusted_parameter state span derived =
  let declared_type = derived.declared_type in
  match Ctype.is_array declared_type with
  | Answer true ->
      checked state span
        (Ctype.qualify derived.parameter_qualifiers (Ctype.decay declared_type))
  | Answer false | Depends_on _ -> Ctype.decay declared_type

(* Type names (6.7.7) *)

and read_type_name state (type_name : Tree.type_name) =
  match Hashtbl.find_opt state.type_names type_name.span with
  | Some t -> t
  | None ->
      let t = read_new_type_name state type_name in
      Hashtbl.replace state.type_names type_name.span t;
      t

and read_new_type_name state (type_name : Tree.type_name) =
  let span = type_name.span in
  let specified =
    read_specifiers state type_name.node.specifier_qualifiers
  in
  if specified.alignments <> [] then
    fail state span
      (Rule.c_text "a type name has an alignment specifier (C11 6.7.5p2)");
  let derived =
    declare_type state ~parameter:false specified type_name.node.abstract
  in
  derived.declared_type

(* Constant expressions *)

(* What the expression declares stays declared, as in C, though it is
   not a constant. *)
and constant_expression state expression =
  match Expressions.integer_constant (typing state) expression with
  | Ok (integer_type, value) -> Constant { integer_type; value }
  | Error span -> Not_constant span

(* Declarations in blocks and what typing asks of the reader *)

(* The asm label names a symbol, which no type depends on. The
   initialiser is read after the declarator, whose identifier it sees
   (6.2.1p7), and [holder] holds it. *)
and read_init_declarator state scope ~holder specified
    (init_declarator : Tree.init_declarator) =
  let { Tree.declarator; declared; asm_label = _; attributes; initialiser } =
    init_declarator.node
  in
  let specified =
    for_declarator state specified attributes (Some declarator)
  in
  (* The effects of attributes are recorded where design 13.3 places
     them: on a function declared at file scope, not on a typedef. *)
  let records_effects =
    scope = File_scope && specified.storage <> Some Typedef
  in
  let derived =
    declare_type state ~records_effects ~parameter:false specified
      (Some declarator)
  in
  let entity =
    declare_in state scope init_declarator.span specified declared derived
  in
  (* An object that the declaration defines needs its type complete: one
     that a block defines (6.7p7), one with an initialiser (6.7.9p3) and
     a tentative definition, which needs only instances complete (design
     10.3), as every need does here. *)
  (match entity.declared with
  | Object { object_type; _ }
    when specified.storage <> Some Extern || Option.is_some initialiser ->
      needs_complete state object_type
  | Object _ | Function _ | Typedef _ | Enumerator _ -> ());
  match initialiser with
  | None -> entity
  | Some initialiser ->
      initialised state scope ~holder init_declarator.span declared entity
        initialiser

(* 6.7.9: an initialised object, of static or thread storage duration
   with a constant initialiser (p4). The initialiser completes the type of
   an array of unknown size (p22), as a later declaration with the length
   would. *)
and initialised state scope ~holder span declared (entity : entity)
    initialiser =
  match entity.declared with
  | Object ({ object_type; linkage; storage; _ } as declared_object) -> (
      if scope = Block_scope && linkage <> No_linkage then
        fail state span
          (Rule.c_text
             "a declaration in a block of an identifier with linkage has an \
              initialiser (C11 6.7.9p5)");
      let constant = storage <> Automatic_storage in
      let completed =
        Expressions.initialiser (typing state) ~holder ~constant object_type
          initialiser
      in
      Expressions.note_object (typing state) (declared : Tree.declared).id
        object_type initialiser;
      match object_type.shape with
      | Array { length = Unknown; _ } ->
          let completed_object =
            Object { declared_object with object_type = completed }
          in
          let entity =
            record state entity.name declared
              { entity with declared = completed_object }
          in
          note_at_file_scope state scope entity;
          entity
      | _ -> entity)
  | Function _ | Typedef _ | Enumerator _ ->
      fail state span
        (Rule.c_text "an initialiser for what is not an object (C11 6.7.9p3)")

(* The specifiers of a declaration with declarators. The typedef
   declarators that derive no type name an untagged type of the specifiers
   (design 3.5 rule 2), which is recorded before any declarator is read, so
   that every use sees all its names. *)
and declaration_specifiers state specifiers
    (declarators : Tree.init_declarator list) =
  let specified = read_specifiers state specifiers in
  if specified.storage = Some Typedef && specified.untagged then
    Ctype.name_untagged state.tags specified.base_type
      (List.filter_map naming_name declarators);
  specified

and read_block_declaration state holder (declaration : Tree.declaration) =
  match declaration.node with
  | Static_assert assertion -> static_assert state assertion
  | Declaration { specifiers; declarators } ->
      let specified = declaration_specifiers state specifiers declarators in
      List.iter
        (fun declarator ->
          ignore
            (read_init_declarator state Block_scope ~holder specified
               declarator))
        declarators

(* Type declarations (design 3.1). The parser has made each the only
   declaration of its name in its scope (rule 5), so it declares a new
   entity: a typedef name of the type that it defines. *)

and read_type_declaration state (scoped : Tree.scoped_type_declaration) =
  let declaration = scoped.declaration in
  Hashtbl.replace state.type_declarations declaration.node.declared.id
    declaration;
  match declaration.node.type_parameters with
  | [] -> Some (read_named_type state scoped)
  | _ :: _ ->
      read_generic state scoped;
      None

and read_named_type state
    ({ declaration; scope_end } : Tree.scoped_type_declaration) =
  let { Tree.name = checked; declared; definition; _ } = declaration.node in
  let name = (checked :> Tree.identifier) in
  (* The name as a typedef name of the type that it defines. *)
  let bind_spelled ~inexact typedef_type =
    record state name.node declared
      { name = name.node; entity = fresh_entity state;
        declared = Typedef { typedef_type }; inexact }
  in
  let bind = bind_spelled ~inexact:false in
  match definition with
  | Incomplete_variant ->
      let record = variant_record state checked.node declared in
      Hashtbl.replace state.incomplete_variants (In_tree declared.id) record;
      bind (Ctype.record record)
  | Variant { is_private; constructors } ->
      let privacy = privacy state declaration ~is_private in
      let scope = { declaration.span with last = scope_end } in
      read_variant state declaration privacy ~scope constructors bind
  | Alias type_name ->
      let t = read_type_name state type_name in
      bind_spelled ~inexact:(type_name_is_inexact state type_name) t
  | Distinct { is_private; representation } ->
      let privacy = privacy state declaration ~is_private in
      bind (distinct_type state name.node privacy representation)
  | Record_alias specifier ->
      read_record_alias state name declared specifier bind

(* Design 9.2: a private type belongs to the file whose text declares
   it. *)
and privacy state (declaration : Tree.type_declaration) ~is_private :
    Ctype.privacy =
  if is_private then Private state.text.tokens.(declaration.span.first).owner
  else Public

(* Design 3.4: a new type over an unqualified arithmetic or pointer
   type. *)
and distinct_type ?instance state name privacy type_name =
  let representation = read_type_name state type_name in
  refuse_opaque state type_name.span representation
    "the representation after `distinct`";
  let complete = Ctype.is_complete state.tags representation <> Answer false in
  match
    Ctype.declare_distinct ?instance state.tags name privacy
      representation ~at_file_scope:(at_file_scope state)
  with
  | Ok t when complete -> t
  | Ok _ | Error Invalid_representation ->
      fail state type_name.span
        (Rule.message Distinct_representation
           (Printf.sprintf
              "the distinct type '%s' is not over an unqualified arithmetic \
               or pointer type"
              name))
  | Error error ->
      fail state type_name.span
        (Rule.c_text (Ctype.error_message error))

(* A variant is the structure that it lowers to (design 10.1): that of
   the incomplete variant it completes, or a new one under the tag that
   it claims. *)
and variant_record state name (declared : Tree.declared) =
  match declared.earlier with
  | Some forward -> Hashtbl.find state.incomplete_variants forward
  | None ->
      let record =
        Ctype.declare_variant state.tags name
          ~at_file_scope:(at_file_scope state)
      in
      Hashtbl.replace state.tag_types (Tree.claimed_tag declared.id)
        (Record_tag record);
      record

(* The structure has a tag of the enumeration of the constructors and,
   where one has fields, a union of the struct of each one's fields
   (design 10.1 rule 3). *)
and read_variant state (declaration : Tree.type_declaration) privacy ~scope
    constructors bind =
  let { Tree.name; declared; _ } = declaration.node in
  let record = variant_record state name.node declared in
  let entity = bind (Ctype.record record) in
  let tag_enum = variant_tag_enum state declaration constructors in
  let read, members =
    variant_members state declaration.span tag_enum constructors
  in
  checked state declaration.span
    (Ctype.define_variant state.target state.tags record privacy ~scope
       (List.map fst read) members);
  entity

(* The constructors read, and the members of the structure: the tag and
   the union of the payloads. *)
and variant_members state span tag_enum constructors =
  let tag = variant_member Tree.tag_member (Ctype.enum tag_enum) in
  let read = List.map (read_constructor state) constructors in
  match List.filter_map (constructor_payload state) read with
  | [] -> (read, [ tag ])
  | payloads ->
      let union = defined_record state span Ctype.Union payloads in
      (read, [ tag; variant_member Tree.union_member (Ctype.record union) ])

and variant_member name member_type =
  { Ctype.member_name = Some name; member_type; bit_field_width = None }

and defined_record state span kind members =
  let record =
    Ctype.declare_record state.tags kind None
      ~at_file_scope:(at_file_scope state)
  in
  checked state span
    (Ctype.define_record state.target state.tags record members);
  record

(* The enumeration of the tags, whose enumerators number the constructors
   from 0 in order (design 10.1 rule 1) and have type int, as C gives an
   enumerator that int holds. *)
and variant_tag_enum state (declaration : Tree.type_declaration)
    constructors =
  let span = declaration.span in
  let variant = Spelling.declared declaration.node.name.node in
  let enum =
    defined_tag_enum state span (Some (Tree.enum_tag_name variant))
      constructors
  in
  Hashtbl.replace state.tag_types
    (Tree.derived_enum_tag ~type_keyword:span.first)
    (Enum_tag enum);
  declare_tag_enumerators state span variant constructors
    ~scope:declaration.node.declared.scope;
  enum

and defined_tag_enum state span tag constructors =
  let enum =
    Ctype.declare_enum state.tags tag ~at_file_scope:(at_file_scope state)
  in
  let values =
    List.mapi (fun index _ -> Exact_integer.of_int index) constructors
  in
  checked state span
    (Ctype.define_enum state.tags enum
       (Answer (enum_integer state span values)));
  enum

(* The enumerator [N_C] of each constructor, whose value is its index,
   in the scope of the variant. *)
and declare_tag_enumerators state span variant constructors ~scope =
  let enumerator_type = integer_type state span Int in
  let declare index (constructor : Tree.constructor) =
    let name = Tree.enumerator_name ~variant constructor.node.name.node in
    let declared : Tree.declared =
      let token = constructor.node.name.span.first in
      { id = Tree.derived_enumerator token; scope; earlier = None }
    in
    let value =
      Integer_constant.known state.target Int (Exact_integer.of_int index)
    in
    let declared_as = Enumerator { enumerator_type; value } in
    ignore
      (record state name declared
         (* A constructor's tag spells no type. *)
         { name; entity = fresh_entity state; declared = declared_as;
           inexact = false })
  in
  List.iteri declare constructors

(* A constructor and its fields, with the span that a payload made of
   them is reported at. *)
and read_constructor state (constructor : Tree.constructor) =
  let fields, void_fields =
    List.partition_map (read_field state constructor) constructor.node.fields
  in
  ({ Ctype.constructor_name = constructor.node.name.node; fields;
     void_fields },
   constructor.span)

(* The member of the union for a constructor with fields: the struct of
   its fields in order, named after the constructor. *)
and constructor_payload state
    (({ constructor_name; fields; _ } : Ctype.constructor), span) =
  match fields with
  | [] -> None
  | _ :: _ ->
      let payload = defined_record state span Ctype.Struct fields in
      Some
        (variant_member (constructor_name :> string) (Ctype.record payload))

(* A field is the member of its payload, or, where its type is void in
   an instance, the name of a field that does not exist. *)
and read_field state constructor (field : Tree.field) =
  let specified = read_specifiers state field.node.specifiers in
  let derived =
    declare_type state ~parameter:false specified (Some field.node.declarator)
  in
  let name = Option.value derived.name ~default:"" in
  let subject =
    Printf.sprintf "the field %s of %s" (quote name)
      (quote (constructor.node.name.node :> string))
  in
  if is_void_in_instance state field subject derived then begin
    note_void_field state field.span;
    Either.Right name
  end
  else begin
    check_field_type state field subject derived;
    Either.Left
      { Ctype.member_name = derived.name; member_type = derived.declared_type;
        bit_field_width = None }
  end

(* Design 3.5 rule 6: a field whose type is void does not exist in an
   instance. The definition check refuses void written as a field type,
   so here only a type argument makes one void. *)
and is_void_in_instance state (field : Tree.field) subject (derived : derived)
    =
  in_instance_definition state
  &&
  match Ctype.is_void derived.declared_type with
  | Answer is_void -> is_void
  (* An argument that holds an unknown type is refused at its
     application (rule 2), so only a change there reaches this. *)
  | Depends_on unknown ->
      fail_needing state field.span ("whether " ^ subject ^ " is void")
        unknown

(* Lowering leaves out the text of a field that does not exist. An
   instance's definition is read only through {!read_definition}, which
   sets [moved]. *)
and note_void_field state span =
  match state.moved with
  | Some moved -> moved.void_field_spans <- span :: moved.void_field_spans
  | None -> invalid_arg "Declarations.note_void_field: no reading"

(* A field type is a value type (design 3.2 rule 4), so a variant holds
   itself only through a pointer (rule 5). *)
and check_field_type state (field : Tree.field) subject (derived : derived) =
  needs_complete state derived.declared_type;
  match Value_type.problem state.tags derived.declared_type with
  | Answer None -> ()
  | Answer (Some problem) ->
      fail state field.span
        (Rule.message Field_type
           (Printf.sprintf "%s %s, so it is not a value type" subject
              (Value_type.describe problem)))
  | Depends_on unknown ->
      fail_needing state field.span ("whether " ^ subject ^ " is a value type")
        unknown

(* The name denotes the record before its members are read, so that they
   may use it (rule 2). A specifier without a tag of its own declares the
   tag that the declaration claims. *)
and read_record_alias state name (declared : Tree.declared)
    (specifier : Tree.record_specifier Tree.spanned) bind =
  let { Tree.kind; attributes; tag; members } = specifier.node in
  let span = specifier.span and kind = record_kind kind in
  let record =
    match tag with
    | Some tag -> record_type state span kind (Some tag) None
    | None -> alias_record state kind name declared
  in
  let entity = bind (obscured_by state attributes (Ctype.record record)) in
  Option.iter (define_record state span record) members;
  entity

(* The untagged record of an alias, which design 10.3 encodes by the
   alias's name, under the tag that the declaration claims (10.2). *)
and alias_record state kind (name : Tree.identifier)
    (declared : Tree.declared) =
  let record =
    Ctype.declare_alias_record state.tags kind name.node
      ~at_file_scope:(at_file_scope state)
  in
  Hashtbl.replace state.tag_types (Tree.claimed_tag declared.id)
    (Record_tag record);
  record

(* Generic types (design 3.5) *)

(* A generic declares no entity, as its name alone is no type (rule 1).
   Its definition is checked once (rule 4) by reading the generic's own
   instance over a new opaque value type for each type parameter, where
   an error is reported at its place in the definition. The check is a
   trial: it defines no instance for any later point (rule 7). *)
and read_generic state (scoped : Tree.scoped_type_declaration) =
  let declaration = scoped.declaration in
  let { Tree.declared; type_parameters; _ } = declaration.node in
  refuse_unmovable state declaration.span;
  let generic =
    { declaration; inexact = definition_is_inexact state declaration }
  in
  Hashtbl.replace state.generics
    (declaration.node.name.node :> string)
    generic;
  Hashtbl.replace state.definition_views declared.id
    state.external_facts.texts_at.view;
  let parameter (written : Tree.parameter_name) =
    let opaque = Ctype.declare_opaque state.tags written.name.node in
    (written.name.span, Ctype.record opaque)
  in
  let parameters = List.map parameter type_parameters in
  let check =
    { read =
        (fun declaration read ->
          read_definition state (Type_generic declaration)
            (List.map snd parameters) Definition_check read) }
  in
  (* The check applies the generic at its own definition, which a
     placement of the trial names as its application. *)
  in_trial state (fun () ->
      let instance = instance_of state declaration parameters in
      state.applied_at <-
        Ctype.Instances.add instance declaration.span state.applied_at;
      needs_complete state (instance_type state declaration instance check));
  check_generic_attributes state declaration.span

(* Design 10.3, P25: every instance writes the definition as its tokens,
   and a pragma line or a [#] is none that moved text can hold. *)
and refuse_unmovable state (span : Tree.span) =
  let tokens = state.text.tokens in
  for index = span.first to span.last do
    if not (Token.is_movable tokens.(index).kind) then
      fail state { first = index; last = index }
        (Rule.message Generic_pragma
           "the definition of a generic holds a pragma or a `#`, \
            which the text of its instances cannot hold")
  done

(* [read ()] as a trial, after which the tags and the latest application
   of each instance are as they were before it. The entities and tags
   that the check declares stay, unreachable: each reading of the text
   declares them again, and rule 4 lets no body in it complete a tag
   declared outside. A trial is a check at file scope, where no reading
   has queued a function instance, and it reads those that it queues. *)
and in_trial : 'a. state -> (unit -> 'a) -> 'a =
 fun state read ->
  (* The drain below reads only what the trial queues. *)
  if state.queued <> [] then invalid_arg "Declarations.in_trial: queued";
  let applied_at = state.applied_at and placements = state.placements in
  let trial = state.trial in
  let restore () =
    state.applied_at <- applied_at;
    state.placements <- placements;
    state.trial <- trial
  in
  state.trial <- true;
  let read_all () =
    let result = read () in
    read_function_instances state;
    result
  in
  Fun.protect ~finally:restore (fun () -> Ctype.trial state.tags read_all)

(* A type application: its arguments, then the type that the generic's
   definition makes of them (rule 3). *)
and applied_type state span name written =
  let declaration = generic_declaration state span name in
  let argument (argument : Tree.type_name) =
    (argument.span, read_type_name state argument)
  in
  let arguments = List.map argument written in
  let instance = instance_of state declaration arguments in
  List.iter2 (refuse_inexact state) written arguments;
  let applied = application state span declaration instance arguments in
  note_name state span (Encoding.instance_name instance);
  applied

(* The type of an instance applied at [span], whose arguments are
   [arguments] with the places that an error in them is reported at. *)
and application state span declaration instance arguments =
  let first_use = note_application state instance arguments span in
  let types = List.map snd arguments in
  let applied =
    { read =
        (fun declaration read ->
          in_instance state (Type_generic declaration) instance types read)
    }
  in
  let applied_type = instance_type state declaration instance applied in
  if first_use then
    note_text state instance ~application:span
      (Declared { generic = declaration });
  applied_type

(* Design 7.2: [generic] applied to [types], which a substitution makes
   of the arguments of one of its instances, at the call at [span]; the
   call writes no application, so lowering writes no name for it. *)
and applied_again state span (generic : Spelling.type_name) types =
  let declaration = generic_declaration state span (generic :> string) in
  let arguments = List.map (fun t -> (span, t)) types in
  let instance = instance_of state declaration arguments in
  application state span declaration instance arguments

(* The instance of the universe [slice] of section 8 over [element],
   which a [slice_from_array] or a [slice_unchecked] at [span] yields:
   an application that no name writes. *)
and slice_instance state span element =
  match state.slice_generic with
  | Some declaration ->
      let arguments = [ (span, element) ] in
      let instance = instance_of state declaration arguments in
      application state span declaration instance arguments
  | None -> invalid_arg "Declarations.slice_instance: no universe slice"

(* Design 3.5 rule 2: an inexact argument, refused from its text, as
   its type, which encodes it, holds no attribute, while the backend's
   type of the same text may hold one. *)
and refuse_inexact state (written : Tree.type_name) (_, t) =
  if type_name_is_inexact state written then
    fail state written.span
      (Rule.message Type_argument
         (Printf.sprintf
            "the type argument may carry an attribute that no instance \
             name encodes, as it holds an attribute or `typeof` of an \
             expression, or a typedef name or an alias declared with one: \
             it would share the instance of %s"
            (quote (Type_name.of_ctype t))))

(* The latest declaration of the generic that an application names: the
   variant that completes an incomplete one, once read. *)
and generic_declaration state span name =
  match Hashtbl.find_opt state.generics name with
  | Some { declaration; inexact = _ } -> declaration
  | None -> not_read state span name

(* The latest application of each instance, where an error of its
   definition is reported (rule 5), and whether it is the first use,
   where its texts stand (10.3); a check forgets its own ([in_trial]).
   The declaration of the instance is noted after its type is read,
   which reads the definition of an alias or a distinct generic: what
   that puts before the declaration, which is the whole of such an
   instance, is met first. A mention that
   the forward declaration of a tag would change is refused at every
   application, as the tag line of an argument stands at the first use
   of its typedef, not of the instance; a later use in another external
   declaration finds the tag at file scope, where no mention is
   implicit. *)
and note_application state instance arguments span =
  state.applied_at <- Ctype.Instances.add instance span state.applied_at;
  List.iter (refuse_changed_mention state) arguments;
  let placements = state.placements in
  let first_use = not (Ctype.Instances.mem instance placements.used) in
  if first_use then (
    List.iter (refuse_undeclared_argument state) arguments;
    state.placements <-
      { placements with
        used = Ctype.Instances.add instance () placements.used };
    note_argument_typedefs state instance arguments ~application:span);
  first_use

(* The name that lowering writes for the text at [span] (design 10.3):
   in the unit's own text, or in the definition of the instance being
   read where lowering writes it. The reading of an instance counts it
   whether lowering writes it or not, so that the chain of a definition
   check counts as a definition does (3.5 rule 7). *)
and note_name state span name =
  Option.iter
    (fun link -> charge_reading state link (String.length name))
    state.nesting;
  match state.moved with
  | Some moved ->
      if moved.written then moved.names <- (span, name) :: moved.names
  | None ->
      let placements = state.placements in
      state.placements <-
        { placements with names = (span, name) :: placements.names }

(* A use of a type parameter in a definition that lowering writes is
   written as the typedef of its argument (design 10.3). *)
and note_parameter_use state span reference =
  match state.moved with
  | Some moved -> (
      match List.assoc_opt reference moved.parameters with
      | Some name -> note_name state span name
      | None -> ())
  | None -> ()

(* Design 10.3: the typedef of each argument that no earlier text
   declares stands at the first use of the instance, before the texts
   that the reading of its definition puts there. The tag of each line
   before it is declared at file scope where the texts stand (13.5). An
   instance that gets no texts gets no typedefs. *)
and note_argument_typedefs state (instance : Ctype.instance) arguments
    ~application =
  let fresh typedefs encoding (span, argument) =
    if Encodings.mem encoding state.placements.typedefs then typedefs
    else note_typedef state encoding span argument :: typedefs
  in
  if gets_texts state instance then
    match List.fold_left2 fresh [] instance.arguments arguments with
    | [] -> ()
    | typedefs ->
        note_text state instance (Typedefs (List.rev typedefs)) ~application

(* The typedef of an argument that no earlier text declares, now
   declared, with its tag lines noted at the place of the texts. *)
and note_typedef state encoding span argument =
  let name = Encoding.argument_name encoding in
  let lowered = Type_name.lowered_declaration state.tags argument name in
  let line = "typedef " ^ lowered.text ^ ";" in
  check_spelled_names state span lowered ~line;
  let placements = state.placements in
  state.placements <-
    { placements with typedefs = Encodings.add encoding placements.typedefs };
  let tag_lines = Type_name.tag_lines argument in
  List.iter (note_tag_line state span) tag_lines;
  { name; line; tag_lines }

and note_tag_line state span (tag_line : Type_name.tag_line) =
  let facts = state.external_facts in
  let lowered =
    { Resolution.lowered_name = tag_line.tag; written_for = span }
  in
  facts.texts_at <-
    { facts.texts_at with tags = lowered :: facts.texts_at.tags }

(* Design 10.3, 13.5: the typedef of an argument spells the one typedef
   name of each untagged type that the argument names, which must read
   where the typedef stands as at the declaration that gives the type
   its name, and be exact there. *)
and check_spelled_names state application (lowered : Type_name.lowered)
    ~line =
  let use (spelled : Ctype.typedef_name) =
    { Resolution.name = spelled.name; span = application;
      declaration = Ordinary spelled.declared }
  in
  match
    Resolution.check_spelled
      (resolution_context state application)
      (List.map use lowered.spelled) ~at:state.external_facts.texts_at
  with
  | Ok () -> ()
  | Error (_, diagnostic) ->
      fail_within state application
        (Printf.sprintf "in `%s`, which lowering writes for this application"
           line)
        diagnostic

(* Design 10.3: an enumeration, and an untagged type that a typedef
   names, have no forward declaration that lowering could write, so the
   source declares them before the external declaration of the first
   use. *)
and refuse_undeclared_argument state (span, argument) =
  let start = state.external_facts.start in
  let undeclared = function
    | Ctype.Named_enum tag -> not (Ctype.enum_declared_before tag start)
    | Named_record ({ record_name = Anonymous; _ } as tag) ->
        not (Ctype.record_declared_before tag start)
    | Named_record _ -> false
  in
  match List.find_opt undeclared (Ctype.named_tags argument) with
  | None -> ()
  | Some named ->
      fail state span
        (Rule.message Instance_placement
           (Printf.sprintf
              "the type argument names %s, which is declared in the \
               external declaration of the instance's first use; declare \
               it in an earlier one"
              (quote (Type_name.of_ctype (Ctype.named_type named)))))

(* Design 10.3: the forward declaration [struct X;] that lowering writes
   before this external declaration for a tag that an argument names
   would change a mention of [X] before the application that declares
   the tag in a nested scope only because none is visible there (C11
   6.7.2.3p8), and one in the body of a block literal, which typec does
   not read, unless the tag is declared before the literal. *)
and refuse_changed_mention state (span, argument) =
  let refuse tag why =
    let named = quote (Type_name.of_ctype (Ctype.record tag)) in
    fail state span
      (Rule.message Instance_placement
         (Printf.sprintf
            "the type argument names %s, and %s; declare the tag at file \
             scope before it"
            named why))
  in
  let facts = state.external_facts in
  let check = function
    | Ctype.Named_record ({ record_name = Named name; _ } as tag) -> (
        if Hashtbl.mem facts.nested_tags name then
          refuse tag
            "a mention before it in this external declaration declares the \
             tag in a nested scope (C11 6.7.2.3p8), which the forward \
             declaration of the instance would change";
        match facts.block_literal with
        | Some literal when not (Ctype.record_declared_before tag literal) ->
            refuse tag
              "a block literal stands before it in this external \
               declaration, whose body the forward declaration of the \
               instance could change"
        | Some _ | None -> ())
    | Named_record _ | Named_enum _ -> ()
  in
  List.iter check (Ctype.named_tags argument)

(* Design 3.5 rule 2: every type in an argument has a row in the table of
   10.3, which also makes it an object type, no array and not variably
   modified. An argument is refused at its place. *)
and instance_of state (declaration : Tree.type_declaration) arguments =
  let written =
    List.map (fun ((_, t) as argument) -> (argument, t)) arguments
  in
  match encoded_instance state declaration.node.name.node written with
  | Ok instance -> instance
  | Error ((span, argument), no_row) ->
      fail state span (no_row_diagnostic argument no_row)

(* The type that the definition of a generic makes of the arguments of
   [instance] (rule 3), whose definition [reading] reads. An instance of
   a transparent alias or a distinct generic is read once, at its first
   application, and a structure or union where it is first needed
   complete (10.3). *)
and instance_type state (declaration : Tree.type_declaration) instance
    reading =
  match declaration.node.definition with
  | Alias type_name ->
      Ctype.read_instance state.tags instance ~read:(fun () ->
          reading.read declaration (fun () -> read_type_name state type_name))
  | Distinct { is_private; representation } ->
      let privacy = privacy state declaration ~is_private in
      let name = Encoding.instance_name instance in
      Ctype.read_instance state.tags instance ~read:(fun () ->
          reading.read declaration (fun () ->
              distinct_type ~instance state name privacy representation))
  | Record_alias specifier ->
      let { Tree.kind; attributes; members; _ } = specifier.node in
      let define record =
        reading.read declaration (fun () ->
            Option.iter (define_record state specifier.span record) members)
      in
      let record =
        Ctype.declare_instance state.tags (record_kind kind) instance ~define
      in
      obscured_by state attributes (Ctype.record record)
  | Variant _ | Incomplete_variant ->
      let define = variant_instance state instance reading in
      Ctype.record (Ctype.declare_variant_instance state.tags instance ~define)

(* The definition of a variant instance, by the generic's latest
   declaration: one that completes an incomplete variant after the
   application defines it. While none does, the instance stays
   incomplete, and its definition deferred. The parser completes an
   incomplete variant only with a variant (design 3.1 rule 4). The
   instance derives its names from its instance name (design 10.3);
   typing declares none of them, as Type-C text names none. *)
and variant_instance state instance reading record =
  let { declaration; inexact = _ } =
    Hashtbl.find state.generics (instance.generic :> string)
  in
  let define privacy constructors () =
    let span = declaration.span in
    let variant = Encoding.variant_name (Applied instance) in
    let tag = Some (Tree.enum_tag_name variant) in
    let tag_enum = defined_tag_enum state span tag constructors in
    let read, members = variant_members state span tag_enum constructors in
    checked state span
      (Ctype.define_variant_instance state.target state.tags record privacy
         (List.map fst read) members)
  in
  match declaration.node.definition with
  | Incomplete_variant -> ()
  | Variant { is_private; constructors } ->
      let privacy = privacy state declaration ~is_private in
      reading.read declaration (define privacy constructors)
  | Alias _ | Distinct _ | Record_alias _ ->
      invalid_arg "Declarations.variant_instance"

(* [read] at file scope, where every instance stands (design 10.3), with
   each type parameter a typedef name of its argument, as the instance
   writes it. *)
and with_arguments :
      'a.
      state -> Tree.parameter_name list -> Ctype.t list -> (unit -> 'a) -> 'a
    =
 fun state parameters arguments read ->
  let bind (parameter : Tree.parameter_name) argument =
    let reference = Tree.In_tree parameter.declared.id in
    let saved = Hashtbl.find_opt state.entities reference in
    Hashtbl.replace state.entities reference
      (* [applied_type] has refused an inexact argument. *)
      { name = parameter.name.node; entity = fresh_entity state;
        declared =
          Typedef { typedef_type = argument }; inexact = false };
    (reference, saved)
  in
  let restore (reference, saved) =
    match saved with
    | Some entity -> Hashtbl.replace state.entities reference entity
    | None -> Hashtbl.remove state.entities reference
  in
  let bound = List.map2 bind parameters arguments in
  Fun.protect
    ~finally:(fun () -> List.iter restore bound)
    (fun () -> within state At_file_scope read)

(* [read] of the definition for an instance, as the next link of the
   chain of instances being defined (rule 7). An error in it is reported
   at the latest application of the chain's first instance and cites
   the definition (rule 5); one in a definition check stays in the
   generic's definition, where that application is. *)
and in_instance :
      'a.
      state ->
      generic_definition ->
      Ctype.instance ->
      Ctype.t list ->
      (unit -> 'a) ->
      'a =
 fun state generic instance arguments read ->
  in_link state generic instance arguments
    ~application:(Ctype.Instances.find instance state.applied_at)
    ~outer:state.nesting read

(* [read] of the definition for [instance], applied or called at
   [application], as the link after [outer]. The first error is reported
   at the chain's beginning, by the link that meets it, which gives the
   report that every link after the first would give. *)
and in_link :
      'a.
      state ->
      generic_definition ->
      Ctype.instance ->
      Ctype.t list ->
      application:Tree.span ->
      outer:nesting option ->
      (unit -> 'a) ->
      'a =
 fun state generic instance arguments ~application ~outer read ->
  let link = next_link outer application instance in
  if link.depth > max_nesting then
    fail_nesting state application instance link;
  charge_reading state link (token_charge state (definition_span generic));
  let purpose = For_instance instance in
  let enclosing = state.nesting in
  state.nesting <- Some link;
  let restore () = state.nesting <- enclosing in
  let read_instance () = read_definition state generic arguments purpose read in
  match Fun.protect ~finally:restore read_instance with
  | result -> result
  | exception Failed error ->
      raise (Instance_failed (instance_error state link.began link.first error))

(* Design 3.5 rule 7: [bytes] more of the text that the reading of the
   instance [link.defining] gives the instances of the unit, refused
   where they would pass the instance budget. *)
and charge_reading state link bytes =
  state.instance_bytes <-
    charged ~bound:instance_budget state.instance_bytes bytes (fun () ->
        instances_refusal state link)

(* Design 3.5 rule 7: one more exit that runs a copy of the deferred
   statement at [span], which the front end reads there for the check of
   13.5 and lowering writes there, refused where the copies of the unit
   would pass the output limit. The copies are text that lowering
   writes, so they are held to its limit and not to the instance budget;
   they are counted here because their number grows with the square of
   the source before lowering makes any text. *)
and charge_copy state span =
  state.copy_bytes <-
    charged ~bound:(Output_limit.of_unit state.text) state.copy_bytes
      (copy_charge state span) (fun () -> copies_refusal state span)

(* What lowering charges for a copy [{ S }] of the statement at [span]
   where each token of [S] stays a piece of its own, which is all that
   the front end can know of the edits inside it. *)
and copy_charge state (span : Tree.span) =
  let brace = Output_limit.piece_charge 1 in
  let charge = ref (2 * brace) in
  for index = span.first to span.last do
    let length = state.text.tokens.(index).length in
    charge := !charge + Output_limit.piece_charge length
  done;
  !charge

(* The deferred statement at [span] is where the count of copies would
   pass the limit; the count is of the whole unit. *)
and copies_refusal state span =
  let message =
    "the copies of the unit's deferred statements, one at each exit of \
     the scope of a defer, would pass "
    ^ Output_limit.described state.text
  in
  Failed
    { location = location_of state span;
      message = Rule.text (Rule.c_text message) }

(* The one funnel of the front end's counts of rule 7: [count] raised by
   [bytes], or the exception that [refusal ()] makes, where that would
   pass [bound]. *)
and charged ~bound count bytes refusal =
  let counted = count + bytes in
  if counted > bound then raise (refusal ());
  counted

(* What the reading of the tokens at [span] charges (rule 7): the bytes
   of each token, which lowering copies, and at least
   [least_token_charge] for each, as the work of reading a token does not
   shrink with its length. *)
and token_charge state (span : Tree.span) =
  let charge = ref 0 in
  for index = span.first to span.last do
    let length = state.text.tokens.(index).length in
    charge := !charge + max length least_token_charge
  done;
  !charge

(* [read] of the definition of a generic with its type parameters bound
   to [arguments], in views of its own, followed by the one check of the
   resolution property (design 13.5) on what the reading found, at the
   place in front of the external declaration being read, where the
   instance's text stands. A reading whose text lowering writes is
   recorded for it. The definition of a generic type is no part of a
   generic function whose check may read it, where an instance of a
   generic function that the check reads is part of the trial. *)
and read_definition :
      'a.
      state ->
      generic_definition ->
      Ctype.t list ->
      purpose ->
      (unit -> 'a) ->
      'a =
 fun state generic arguments purpose read ->
  let outer = state.moved and outer_part = state.generic_part in
  let parameters = generic_parameters generic in
  let of_type =
    match generic with
    | Type_generic _ -> true
    | Function_generic _ -> false
  in
  let moved =
    match purpose with
    | Definition_check -> fresh_moved ~written:false ~of_type []
    | For_instance instance ->
        fresh_moved
          ~written:(gets_texts state instance)
          ~of_type
          (argument_names generic instance)
  in
  state.moved <- Some moved;
  if of_type then state.generic_part <- None;
  let restore () =
    state.moved <- outer;
    state.generic_part <- outer_part
  in
  let read_and_check () =
    let (result, typed), found =
      finding state (definition_span generic) (fun () ->
          in_own_views state (fun () ->
              let result = with_arguments state parameters arguments read in
              (result, state.typed)))
    in
    check_resolution state moved found generic;
    (match purpose with
    | For_instance instance when moved.written ->
        note_instance_text state generic moved typed instance
    | For_instance _ | Definition_check -> ());
    result
  in
  Fun.protect ~finally:restore read_and_check

(* The name of the typedef of each argument of [instance], by the
   reference of its type parameter (design 10.3). *)
and argument_names generic (instance : Ctype.instance) =
  let named (parameter : Tree.parameter_name) encoding =
    (Tree.In_tree parameter.declared.id, Encoding.argument_name encoding)
  in
  List.map2 named (generic_parameters generic) instance.arguments

and note_instance_text state generic moved typed instance =
  let text =
    { generic; names = moved.names;
      void_field_spans = moved.void_field_spans; typed }
  in
  let placements = state.placements in
  state.placements <-
    { placements with
      readings = Ctype.Instances.add instance text placements.readings }

and check_resolution state moved found generic =
  let declared = definition_declared generic in
  let text =
    { Resolution.kind = Generic_definition;
      span = definition_span generic;
      (* The text is the declaration, which holds its own name. *)
      scope = declared.scope;
      own_place = Hashtbl.find state.definition_views declared.id;
      uses = List.rev found.uses;
      declares = List.rev found.declares }
  in
  let at = if moved.written then Some state.external_facts.texts_at else None in
  check_moved state text ~at

(* The one check of the resolution property on [text], whose failure is
   the error of the unit. *)
and check_moved state (text : Resolution.text) ~at =
  match Resolution.check (resolution_context state text.span) text ~at with
  | Ok () -> ()
  | Error (span, diagnostic) -> fail state span diagnostic

(* What the check of the resolution property (design 13.5) asks of the
   reader, for a text whose types are compared at [span]. *)
and resolution_context state span =
  { Resolution.tokens = state.text;
    views = state.views;
    entity = Hashtbl.find_opt state.entities;
    tag = tag_declared state;
    redeclared = state.redeclared_at;
    completed = state.completed_at;
    same_type =
      Ctype.same_type state.target state.tags (location_of state span) }

(* The tag that a tag declaration declares or names. *)
and tag_declared state id : Ctype.named_tag option =
  match Hashtbl.find_opt state.tag_types id with
  | Some (Record_tag record) -> Some (Named_record record)
  | Some (Enum_tag enum) -> Some (Named_enum enum)
  | None -> None

(* [read] in typed views of its own, as it reads the text of a generic's
   definition again, for an instance or for the check, whose types no
   later point asks for. *)
and in_own_views : 'a. state -> (unit -> 'a) -> 'a =
 fun state read ->
  let typed = state.typed and type_names = state.type_names in
  state.typed <- Expressions.create ();
  state.type_names <- Hashtbl.create 16;
  let restore () =
    state.typed <- typed;
    state.type_names <- type_names
  in
  Fun.protect ~finally:restore read

(* What causes [instance]: a use, a call or an explicit instance, for
   an instance of a generic function, an application for one of a
   generic type. *)
and cause state (instance : Ctype.instance) =
  if Hashtbl.mem state.generics (instance.generic :> string) then
    "application"
  else "use"

and instance_error state application instance (error : error) =
  {
    location = location_of state application;
    message =
      Printf.sprintf "in the instance %s that this %s names, at %s:%d: %s"
        (quote (shown_instance instance))
        (cause state instance) error.location.file error.location.line
        error.message;
  }

and fail_nesting state application instance (link : nesting) =
  let began = location_of state link.began in
  let diagnostic =
    Rule.message Instance_nesting
      (Printf.sprintf
         "the %s would define the instance %s after a chain of %d \
          instances that each define the next, which the %s at %s:%d \
          began; a chain holds at most %d"
         (cause state instance)
         (quote (shown_instance instance))
         max_nesting (cause state link.first) began.file began.line
         max_nesting)
  in
  raise
    (Instance_failed
       { location = location_of state application;
         message = Rule.text diagnostic })

(* The use of the instance whose reading passes the budget is the
   error, as where it would pass the nesting limit. *)
and instances_refusal state { depth = _; began; first; defining; applied } =
  let began = location_of state began in
  let message =
    Printf.sprintf
      "the %s would define the instance %s, whose reading would pass the \
       instance budget of typec, %d bytes of text for the instances of the \
       unit, those that definition checks read included, in a chain of \
       instances that the %s at %s:%d began"
      (cause state defining)
      (quote (shown_instance defining))
      instance_budget (cause state first) began.file began.line
  in
  Instance_failed
    { location = location_of state applied;
      message = Rule.text (Rule.c_text message) }

and no_row_diagnostic argument ({ part; reason } : Encoding.no_row) =
  let argument_name = quote (Type_name.of_ctype argument) in
  let holds what =
    Printf.sprintf "holds %s, %s" (quote (Type_name.of_ctype part)) what
  in
  let refused problem =
    Rule.message Type_argument
      (Printf.sprintf "the type argument %s %s" argument_name problem)
  in
  match reason with
  | Too_long ->
      Rule.c_text
        (Printf.sprintf
           "the encoding of the type argument %s in an instance name is \
            longer than %d bytes, the limit of typec"
           argument_name Encoding.max_length)
  | Array_not_under_pointer when part == argument -> refused "is an array"
  | Function_not_under_pointer when part == argument ->
      refused "is a function type, no object type"
  | Variable_length when part == argument -> refused "is variably modified"
  | Int128 | Va_list -> refused (holds "which no instance name encodes")
  | Unknown_type unknown ->
      refused
        (Printf.sprintf "holds a type that typec does not compute: %s"
           unknown.construct)
  | Array_not_under_pointer -> refused (holds "an array not under a pointer")
  | Function_not_under_pointer ->
      refused (holds "a function type not under a pointer")
  | Opaque_length ->
      refused (holds "whose array length typec does not compute")
  | Variable_length -> refused (holds "which is variably modified")
  | Unnamed -> refused (holds "which no declaration names")
  | Several_names names ->
      refused
        (holds
           ("which more than one declaration names: "
           ^ String.concat ", " (List.map quote names)))
  | Not_at_file_scope ->
      refused (holds "which is declared in a block or a parameter list")

(* Design 3.5 rule 4: the definition of a generic uses a type parameter
   only as a type. A type that depends on one is opaque in its definition
   check, where the constructs that call this refuse it. *)
and refuse_opaque state span t construct =
  if Ctype.is_opaque t then
    fail state span
      (Rule.message Generic_definition
         (Printf.sprintf "%s depends on a type parameter" construct))

(* A type name in an expression, which in the definition of a generic
   mentions no type parameter: the value of the expression would depend
   on one (design 7.1 rule 4), as that of [sizeof (T)] does. *)
and expression_type_name state (type_name : Tree.type_name) =
  let t = read_type_name state type_name in
  if Ctype.mentions_opaque state.tags t && not (in_generic_function state) then
    fail state type_name.span
      (Rule.message Generic_definition
         "a type in an expression in the definition of a generic type \
          depends on a type parameter");
  t

(* Design 7.2 rule 5: a type argument of a generic function is a value
   type that meets rule 2 of 3.5, checked as the argument of an
   application is, but for the text of a deduced one, which is none. *)
and check_type_argument state span (argument : Expressions.type_argument) =
  let t =
    match argument with
    | Written (written, t) ->
        refuse_inexact state written (span, t);
        t
    | Deduced t -> t
  in
  refuse_changed_mention state (span, t);
  (* A value type is complete, so the argument is a point that needs it
     so: an application that only a pointer has met is defined here. *)
  needs_complete state t;
  let refuse problem =
    fail state span
      (Rule.message Type_argument
         (Printf.sprintf "the type argument %s %s"
            (quote (Type_name.of_ctype t)) problem))
  in
  (match Value_type.problem state.tags t with
  | Answer None -> ()
  | Answer (Some problem) ->
      refuse (Value_type.describe problem ^ ", no value type")
  | Depends_on unknown ->
      refuse
        (Printf.sprintf
           "may be no value type, as that depends on %s, whose type \
            typec does not compute"
           unknown.construct));
  match Encoding.encode state.tags t with
  | Ok _ -> ()
  | Error no_row -> fail state span (no_row_diagnostic t no_row)

(* Design 7.3 rule 1: the instances that the unit's own text uses, the
   tokens [written] of each use written as the instance's name (10.3).
   The first use goes through the funnel of every instance
   ([note_application]) and queues the reading of the instance's
   definition. One that the check of a generic function's definition
   uses is caused by the definition of each of its instances (3.5 rule
   7), so the check follows the chain in a trial that writes no text; a
   generic defined later is read at the first use of each instance. *)
and use_function_instance state span ~written reference type_arguments =
  let generic = generic_function_name state reference in
  let encoded = List.map (fun t -> (t, t)) type_arguments in
  let instance =
    match encoded_instance state generic encoded with
    | Ok instance -> instance
    | Error (argument, no_row) ->
        fail state span (no_row_diagnostic argument no_row)
  in
  let used =
    { generic_function = reference; instance; type_arguments;
      first_use = span; anchor = Option.get state.external_facts.anchor }
  in
  refuse_misplaced_use state span;
  note_instance_use state span instance;
  note_name state written (Encoding.instance_name instance);
  if note_application state instance (used_arguments used) span then
    match Hashtbl.find_opt state.generic_definitions (generic :> string) with
    | Some (Function_generic { definition; _ } as generic) ->
        queue_function_instance state used definition generic
    | Some (Type_generic _) -> invalid_arg "Declarations: a generic type's call"
    | None ->
        if gets_texts state instance then
          fail_undefined_generic state span generic

(* Design 7.3 rule 2: a generic type's definition and a generic
   function's head use no generic function, as the instance that the use
   names would stand before its prototype (10.3). *)
and refuse_misplaced_use state span =
  let in_type_definition =
    match state.moved with Some moved -> moved.of_type | None -> false
  in
  let in_generic_head = state.generic_part = Some Generic_head in
  if in_type_definition || in_generic_head then
    fail state span
      (Rule.message Function_instance_place
         "a generic function is used in the definition of a generic type or \
          in the head of a generic function, where the instance that it \
          names would stand before its prototype")

and note_instance_use state span instance =
  let facts = state.external_facts in
  if Option.is_none state.moved then
    facts.instance_uses <- (span, instance) :: facts.instance_uses

(* Design 7.3 rule 1: an inline definition of a function with external
   linkage names no identifier with internal linkage (C11 6.7.4p3), as
   each instance has, in its head or its body. *)
and refuse_inline_uses state (entity : entity) =
  let is_inline_definition =
    match entity.declared with
    | Function { inline_definition; linkage = External; _ } ->
        inline_definition
    | Function { linkage = Internal | No_linkage; _ }
    | Object _ | Typedef _ | Enumerator _ ->
        false
  in
  match List.rev state.external_facts.instance_uses with
  | (span, instance) :: _ when is_inline_definition ->
      refuse_inline_use state span instance
  | _ -> ()

and refuse_inline_use state span instance =
  fail state span
    (Rule.message Instance_in_inline
       (Printf.sprintf
          "an inline definition of a function with external linkage uses \
           the instance %s, which has internal linkage (C11 6.7.4p3)"
          (quote (shown_instance instance))))

and used_arguments (used : function_instance) =
  List.map (fun t -> (used.first_use, t)) used.type_arguments

(* The definition of a function instance is read once the reading of
   the external declaration that uses it ends ([read_function_instances]),
   as the next link of the chain of instances being defined, so that no
   reading of a definition is open while another reading of it begins:
   each declares the same parameters and tags. *)
and queue_function_instance state (used : function_instance) definition
    generic =
  if gets_texts state used.instance then
    refuse_state_pragmas state used.first_use used (definition_span generic);
  let queued = { used; definition; generic; outer = state.nesting } in
  state.queued <- queued :: state.queued

(* Design 10.3: the instances queued by the reading just ended, and
   those that their readings queue in turn. The prototype of each stands
   after what the reading of its head puts there, and the definitions
   after every prototype, so that instances that call each other see
   each other's prototypes, and after what the readings of their bodies
   put there. *)
and read_function_instances state =
  let rec read_all read =
    match List.rev state.queued with
    | [] -> read
    | queued ->
        state.queued <- [];
        List.iter (read_queued_instance state) queued;
        read_all (read @ queued)
  in
  let define (queued : queued_instance) =
    note_text state queued.used.instance Defined
      ~application:queued.used.first_use
  in
  List.iter define (read_all [])

(* Design 7.3: the definition of the generic function read again for an
   instance, with its type parameters bound to the instance's arguments,
   under the instance's name. It declares no function, as the instance
   has no name in the unit's own text. The check of the definition has
   refused the form of its returns. *)
and read_queued_instance state (queued : queued_instance) =
  let { used; definition; generic; outer } = queued in
  let read () =
    let _, derived = function_head state definition in
    if gets_texts state used.instance then begin
      let placements = state.placements in
      state.placements <-
        { placements with functions = used :: placements.functions };
      note_text state used.instance Prototype ~application:used.first_use
    end;
    ignore
      (function_body state definition
         ~name:(Encoding.instance_name used.instance)
         derived.declared_type)
  in
  in_link state generic used.instance used.type_arguments
    ~application:used.first_use ~outer read

(* Design 7.3 rule 2: the definition of a generic function precedes the
   first use of each of its instances, which is defined there. *)
and fail_undefined_generic : 'a. state -> Tree.span -> Spelling.type_name -> 'a
    =
 fun state span generic ->
  fail state span
    (Rule.message Generic_undefined
       (Printf.sprintf
          "the first use of an instance of the generic function %s, which \
           is not defined before it: the instance is defined at its first \
           use"
          (quote (generic :> string))))

(* Design 7.3 rule 4: an instance is compiled under the pragmas in force
   at the definition of its generic, so no line that sets state stands
   between the definition, which ends at [definition], and the place in
   front of the external declaration being read where 10.3 writes the
   instance. *)
and refuse_state_pragmas state span (used : function_instance)
    (definition : Tree.span) =
  let latest =
    if used.anchor.before = 0 then no_pragma
    else state.state_pragmas.(used.anchor.before - 1)
  in
  if latest > definition.last then
    let { Token.location; _ } = state.text.tokens.(latest) in
    fail state span
      (Rule.message Instance_pragma
         (Printf.sprintf
            "the instance %s is written before this external declaration, \
             and the `#pragma` line at %s:%d, which sets state, stands \
             between that place and the definition of its generic, whose \
             pragmas the instance is compiled under"
            (quote (shown_instance used.instance))
            location.file location.line))

(* The head of a function definition: its specifiers and the type that
   its declarator derives, which declares its parameters (6.9.1). *)
and function_head state (definition : Tree.function_definition) =
  let { Tree.specifiers; declarator; declarations; attributes; _ } =
    definition.node
  in
  let span = definition.span in
  let specified =
    for_declarator state
      (read_specifiers state specifiers)
      attributes (Some declarator)
  in
  (match (specified.storage, specified.thread_local) with
  | (None | Some (Extern | Static)), false -> ()
  | _ ->
      fail state span
        (Rule.c_text
           "a function definition has a storage class other than extern or \
            static (C11 6.9.1p4)"));
  let derived =
    declare_type state ~definition:declarations ~records_effects:true
      ~parameter:false specified (Some declarator)
  in
  if not derived.defines then
    fail state span
      (Rule.c_text
         "the declarator of a function definition does not end in a function \
          derivation (C11 6.9.1p2)");
  (specified, derived)

(* The body of the function definition [name] of type [function_type],
   typed where the definition stands, so that it sees the unit as of
   that point: its return type and its defer statements, where it holds
   one. *)
and function_body state (definition : Tree.function_definition) ~name
    function_type =
  let { Tree.declarator; body; _ } = definition.node in
  let returned = return_type function_type in
  (match returned with
  | Answer t -> needs_complete state t
  | Depends_on _ -> ());
  let defers =
    match body with
    | Parsed block ->
        Hashtbl.reset state.read_moved;
        within state In_block (fun () ->
            Expressions.function_body (typing state) ~name
              ~in_generic:(in_generic_function state) ~declarator
              ~return_type:returned block)
    | Skipped _ -> None
  in
  Option.iter (check_deferred state) defers;
  (returned, defers)

(* The name of a generic function as instance names begin with it
   (design 10.3), which 7.1 rule 1 lets it be. *)
and generic_function_name state reference =
  let name =
    match Hashtbl.find_opt state.entities reference with
    | Some entity -> entity.name
    | None -> invalid_arg "Declarations: a generic function not read"
  in
  match Spelling.type_name ~at_file_scope:true name with
  | Ok generic -> generic
  | Error _ -> invalid_arg "Declarations: a generic function's name"

and typing state : Expressions.context =
  {
    typed = state.typed;
    target = state.target;
    text = state.text;
    tags = state.tags;
    fail = (fun span diagnostic -> fail state span diagnostic);
    entity = referenced state;
    overloaded = Hashtbl.mem state.overloaded;
    generic_definition = in_generic_function state;
    generic_function =
      (fun reference ->
        Option.map
          (fun generic -> generic.parameter_records)
          (Hashtbl.find_opt state.generic_functions reference));
    type_argument = check_type_argument state;
    use_instance =
      (fun span ~written -> use_function_instance state span ~written);
    apply_generic = applied_again state;
    type_name = expression_type_name state;
    declaration = read_block_declaration state;
    type_declaration =
      (fun declaration -> ignore (read_type_declaration state declaration));
    binding = bind_binding state;
    name_reading = name_reading state;
    needs_complete = needs_complete state;
    slice_instance = slice_instance state;
    block_literal = (fun () -> note_block_literal state);
    subjectless =
      (fun attributes ->
        note_subjects state (attribute_firsts attributes) ~mentions:false);
    views = state.views;
    hoisted_operands = type_hoisted_operands state;
    read_moved =
      (fun span read ->
        let (), found = finding state span read in
        Hashtbl.replace state.read_moved span found);
    array_operand = type_array_operand state;
    label_address =
      (fun { name; label } ->
        note_use state name.span name.node (Resolution.Label label));
    copy_deferred = charge_copy state;
  }

(* A holder of try typed with [type_holder], with what it finds in each
   of its hoisted [operands] (design 5.1 rule 3), and then the one check
   of the resolution property (design 13.5) on each, with the views that
   the parser took at it, at the place in front of the holder where
   lowering writes it. The operands are found side by side rather than
   one inside the typing of another, so that a deep nest of tries costs
   no stack of its own. Lowering declares nothing between the holder and
   that place: what it declares stands in front of the external
   declaration, where both places see it. *)
and type_hoisted_operands state operands type_holder =
  let found_in ((views : Parser.try_views), operand) =
    (views, { text_span = operand; uses = []; declares = [] })
  in
  let founds = List.map found_in operands in
  let outer = state.found in
  state.found <- List.map snd founds @ outer;
  Fun.protect ~finally:(fun () -> state.found <- outer) type_holder;
  let check ((views : Parser.try_views), found) =
    let text =
      { Resolution.kind = Try_operand;
        span = found.text_span;
        scope = views.depth;
        own_place = views.own;
        uses = List.rev found.uses;
        declares = List.rev found.declares }
    in
    let place =
      { Resolution.view = views.place; before = views.place_before;
        typedef_names = []; tags = [] }
    in
    check_moved state text ~at:(Some place)
  in
  List.iter check founds

(* The operand at [operand] of the [slice_from_array] at [whole], typed
   with [read], and then the third clause of the resolution property
   (design 13.5) on it: lowering writes it again, at its own place, as
   the operand of a [sizeof] (section 8 rule 2). *)
and type_array_operand state ~whole operand read =
  let typed, found = finding state operand read in
  let own : Parser.statement_view = statement_view state whole.Tree.first in
  let text =
    { Resolution.kind = Array_operand;
      span = operand;
      scope = own.depth;
      own_place = own.view;
      uses = List.rev found.uses;
      declares = List.rev found.declares }
  in
  check_moved state text ~at:None;
  typed

(* Design 6 rules 8 and 12, once the body is read: the statement of
   each defer at each exit of its scope, and the operand of each return
   in such a scope, whatever the function returns. *)
and check_deferred state (defers : Expressions.function_defers) =
  List.iter (check_deferred_statement state) defers.sites;
  List.iter (check_return_operand state)
    (Reachability.value_returns defers.sites);
  match Scope_pragma.refusal state.text.tokens defers.sites with
  | Some (index, diagnostic) ->
      fail state { first = index; last = index } diagnostic
  | None -> ()

(* What the reading of the moved text at [span] found, as [Resolution]
   reads it, of the [kind]. *)
and moved_text state kind (span : Tree.span) (own : Parser.statement_view) =
  let found = Hashtbl.find state.read_moved span in
  { Resolution.kind;
    span;
    scope = own.depth;
    own_place = own.view;
    uses = List.rev found.uses;
    declares = List.rev found.declares }

(* The view that the parser takes at each word and brace where lowering
   writes around a defer (Parser.statement_view). *)
and statement_view state index =
  match Parser.statement_view state.views index with
  | Some view -> view
  | None -> invalid_arg "Declarations.statement_view: no view at the token"

(* The clauses that hold whatever the place run once, without a place,
   so that they hold for a statement that no exit copies as well. *)
and check_deferred_statement state (site : Reachability.defer_site) =
  let own = statement_view state site.keyword.first in
  let found = moved_text state Deferred_statement site.deferred own in
  (* What typing found is keyed by [S], and the text that moves holds
     the pragma lines in front of it as well. *)
  let text =
    { found with
      span = Tree.deferred_text ~keyword:site.keyword ~statement:site.deferred }
  in
  check_moved state text ~at:None;
  List.iter
    (fun place -> check_moved state text ~at:(Some place))
    (exit_places state site)

(* The places where lowering writes the copies of the statement (design
   13.5): in front of the word of each jump that leaves the scope and of
   the [}] of a block that can complete, and, for the error path of a
   try, in front of the statement or declaration that holds the try,
   where its operand and test stand. *)
and exit_places state (site : Reachability.defer_site) =
  let place : Reachability.place -> Resolution.place option = function
    | Block_end closing -> Some (place_before state closing)
    | Left_by (Jump statement) -> Some (place_before state statement.first)
    | Left_by (Value_return { statement; operand }) ->
        Some (after_operand state statement operand)
    | Left_by (Error_path try_span) -> Some (error_path_place state try_span)
    | Trap _ -> None
  in
  List.filter_map place site.places

(* Lowering declares nothing at a place of writing that the source
   does not: every name that begins with [__tc_] is reserved (design
   2.3). *)
and place_before state index : Resolution.place =
  let { Parser.view; depth = _ } = statement_view state index in
  { view; before = index; typedef_names = []; tags = [] }

(* For a [return e;], the copies follow the initialiser or statement
   that holds [e], so the window of 13.5 runs past [e], while the names
   in scope are those at the [return] (design 6 rule 12). *)
and after_operand state (statement : Tree.span) (operand : Tree.span) =
  let at_return = place_before state statement.first in
  { at_return with before = operand.last + 1 }

and error_path_place state (try_span : Tree.span) : Resolution.place =
  match Parser.try_views state.views try_span.first with
  | Some views ->
      { view = views.place; before = views.place_before;
        typedef_names = []; tags = [] }
  | None -> invalid_arg "Declarations.error_path_place: no view at the try"

(* Lowering writes the return as a block that holds its operand (design
   6 rule 12), which stays at its own place: the third clause alone. *)
and check_return_operand state ((statement : Tree.span), operand) =
  let own = statement_view state statement.first in
  let text = moved_text state Return_operand operand own in
  check_moved state text ~at:None

and note_block_literal state =
  let facts = state.external_facts in
  if Option.is_none facts.block_literal && not (in_instance_definition state)
  then facts.block_literal <- Some (Ctype.now state.tags)

(* The reading of the name at [token] that typing recorded first, else
   [first ()], recorded: an instance of a generic function reads each
   name as the definition check did (design 7.3 rule 3). *)
and name_reading state token first =
  match Hashtbl.find_opt state.name_readings token with
  | Some reading -> reading
  | None ->
      let reading = first () in
      Hashtbl.replace state.name_readings token reading;
      reading

(* A binding of a match (design 4.1 rule 4): an object without linkage
   in the block scope of its arm. *)
and bind_binding state (name : Tree.identifier) declared object_type =
  let next =
    Entity.Object
      { object_type; linkage = No_linkage; storage = Automatic_storage;
        register = false }
  in
  let earlier = earlier_entity state name.span name.node declared in
  (* A binding spells no type, so nothing in it is inexact. *)
  ignore
    (bind_to state name.span name.node declared earlier ~inexact:false next)

(* External declarations (6.9) *)

let read_declaration state (declaration : Tree.declaration) =
  match declaration.node with
  | Static_assert assertion ->
      static_assert state assertion;
      Static_assertion
  | Declaration { specifiers; declarators } ->
      let specified = declaration_specifiers state specifiers declarators in
      Declaration
        (List.map
           (read_init_declarator state File_scope
              ~holder:(Expressions.Holder_at declaration.span.first) specified)
           declarators)

(* What reading a function definition gives: the entity, the type that
   the definition declares, its return type, and its defer statements
   where its body holds one. *)
type defined = {
  entity : entity;
  function_type : Ctype.t;
  return_type : Ctype.t Unknown.answer;
  defers : Expressions.function_defers option;
}

(* 6.9.1. The body is typed where the definition stands, so that it sees
   the unit as of that point, by [body_reading]: a generic function's
   check reads only its body as a trial ([check_generic_function]). *)
let read_definition state ~body_reading
    (definition : Tree.function_definition) =
  let { Tree.declared; _ } = definition.node in
  let specified, derived = function_head state definition in
  let entity =
    declare_in state File_scope definition.span specified declared derived
  in
  let read_body () =
    function_body state definition ~name:entity.name derived.declared_type
  in
  let return_type, defers = body_reading read_body in
  refuse_inline_uses state entity;
  { entity; function_type = derived.declared_type; return_type; defers }

(* Design 13.5: the refusals of the form of a [return e;] in the scope of
   a defer statement in a definition whose body holds one, which [owns]
   are the names it declares. *)
let refuse_return_form state (definition : Tree.function_definition)
    (defined : defined) ~owns defers =
  let { Tree.declared; declarations; _ } = definition.node in
  let targets, marked =
    match defined.entity.declared with
    | Function { targets; marked; _ } -> (targets, marked)
    | Object _ | Typedef _ | Enumerator _ ->
        invalid_arg "Declarations: a function definition of no function"
  in
  let (Ordinary_at token) = declared.id in
  let name =
    Spanned.identifier { first = token; last = token } defined.entity.name
  in
  (* The parameter list is the scope just inside the one that declares
     the function. *)
  let (Scope_depth depth) = declared.scope in
  let form =
    { Return_form.name; function_type = defined.function_type;
      return_type = defined.return_type; targets; marked;
      declaration_list =
        List.map (fun (declaration : Tree.declaration) -> declaration.span)
          declarations;
      scope = Scope_depth (depth + 1); owns; defers }
  in
  match Return_form.refusal state.typed form with
  | Some (span, diagnostic) -> fail state span diagnostic
  | None -> ()

(* The definition is read as a text whose own names [finding] collects,
   which the form of a return in the scope of a defer reads. *)
let define_function state ~body_reading
    (definition : Tree.function_definition) =
  let defined, found =
    finding state definition.span (fun () ->
        read_definition state ~body_reading definition)
  in
  Option.iter
    (refuse_return_form state definition defined ~owns:found.declares)
    defined.defers;
  defined.entity

let read_function_definition state definition =
  Function_definition
    (define_function state ~body_reading:(fun read -> read ()) definition)

(* Design 10.3: a variant, or a record alias, that is no generic lowers
   to a forward declaration [struct X; typedef struct X X;] first, which
   the instances that its body uses follow. *)
let note_forward_declaration state (scoped : Tree.scoped_type_declaration) =
  let { Tree.name; type_parameters; definition; _ } = scoped.declaration.node in
  match (type_parameters, definition) with
  | [], (Variant _ | Record_alias _) ->
      let facts = state.external_facts in
      let lowered =
        { Resolution.lowered_name = (name.node :> string);
          written_for = name.span }
      in
      facts.texts_at <-
        { facts.texts_at with
          typedef_names = lowered :: facts.texts_at.typedef_names;
          tags = lowered :: facts.texts_at.tags }
  | [], (Incomplete_variant | Alias _ | Distinct _) | _ :: _, _ -> ()

(* The texts of instances stand in front of an external declaration, or
   after the forward declaration that begins it, where its instances
   follow that ([note_forward_declaration]). *)
let texts_anchor item =
  match Tree.after_forward_declaration item with
  | Some after -> after
  | None -> Tree.anchor item

(* The declaration of the function of a generic function. *)
let generic_declared (form : Tree.generic_form) =
  match form with
  | Generic_definition { span; node = { declarator; declared; _ } } ->
      (span, declarator, declared)
  | Generic_prototype { declarator; specifiers = _ } ->
      (declarator.span, declarator.node.declarator, declarator.node.declared)

(* The generic function that the declaration [declared] of [name] at
   [span], with [count] type parameters, redeclares, if any: one that
   agrees in its number of type parameters and is not defined twice
   (design 7.1 rule 7). *)
let earlier_generic state span name (declared : Tree.declared) ~count
    ~definition =
  match declared.earlier with
  | None -> None
  | Some earlier -> (
      match Hashtbl.find_opt state.generic_functions earlier with
      | None -> refuse_generic_agreement state span name other_declaration
      | Some generic when List.length generic.parameter_records <> count ->
          refuse_generic_agreement state span name
            "is declared again with another number of type parameters"
      | Some _ when definition && Hashtbl.mem state.generic_definitions name ->
          refuse_generic_agreement state span name "is defined again"
      | Some generic -> Some (earlier, generic))

(* The type that the declaration [reference] of a generic function, read
   before, declares. *)
let generic_function_type state reference =
  match Hashtbl.find_opt state.entities reference with
  | Some { declared = Function { function_type; _ }; _ } -> function_type
  | Some { declared = Object _ | Typedef _ | Enumerator _; _ } | None ->
      invalid_arg "Declarations: a generic function that declares no function"

(* Design 7.1 rule 7: two declarations agree where, with each type
   parameter of one read as the one at the same position of the other,
   they declare the same type, as two definitions of a typedef name
   must; compatible types do not agree, so a use is checked against one
   type whichever declaration it follows. *)
let check_agreement state span name ~earlier ~later =
  match
    Ctype.same_type ~exact:true state.target state.tags
      (location_of state span)
      (generic_function_type state earlier)
      (generic_function_type state later)
  with
  | Answer true -> ()
  | Answer false ->
      refuse_generic_agreement state span name
        "is declared again with another type"
  | Depends_on unknown ->
      refuse_generic_agreement state span name
        (Printf.sprintf
           "is declared again, and whether with the same type depends on \
            %s, whose type typec does not compute"
           unknown.construct)

(* Design 7.1 rule 6: whether two variably modified types are the same
   rests on their bounds at run time, so rule 7 could not compare two
   declarations whose parameters have one. The parameter types are
   adjusted, so [T a[n]] is [T *a] and stands. A type that typec does
   not compute is left to rule 7, which agrees it with nothing. *)
let refuse_variable_parameters state span reference =
  let check parameter =
    if Ctype.is_variably_modified parameter = Answer true then
      fail state span
        (Rule.message Generic_function_form
           "no parameter of a generic function is variably modified")
  in
  match (generic_function_type state reference).shape with
  | Function { parameters = Prototype { types; _ }; _ } ->
      List.iter check types
  | Unknown_type _ -> ()
  | _ -> invalid_arg "Declarations: a generic function without a prototype"

(* Design 7.1 rule 3: the check of a generic function reads it against
   the opaque types of its type parameters and writes none of its text
   (3.5 rule 4). It reads the head where the definition stands, so that
   the instances that the head applies to concrete types are real first
   uses ({!gets_texts}) and its type outlives the check, and the body as
   a trial, which defines no instance (3.5 rule 7). It types the
   definition in views of its own, which no lowering reads: each
   instance is typed again, but the zero initialisers that the check
   finds are kept, as no instance, whose types are its arguments, finds
   them. *)
let check_generic_function state (declared : Tree.declared) read =
  let outer = state.moved in
  state.moved <- Some (fresh_moved ~written:false ~of_type:false []);
  state.generic_part <- Some Generic_head;
  let restore () =
    state.moved <- outer;
    state.generic_part <- None
  in
  let body_reading read_body =
    state.generic_part <- Some Generic_body;
    in_trial state read_body
  in
  let read_and_find () =
    read ~body_reading;
    Expressions.zero_initialisers state.typed
  in
  let found =
    Fun.protect ~finally:restore (fun () ->
        in_own_views state read_and_find)
  in
  Hashtbl.replace state.zero_initialisers declared.id found

(* Design 7.1 rule 9: each instance is the definition read again under
   its arguments, which a body that a system header defines, passed
   through unread (13.3), cannot be. *)
let refuse_system_body state (definition : Tree.function_definition) =
  match definition.node.body with
  | Parsed _ -> ()
  | Skipped span ->
      fail state span
        (Rule.message Generic_system_body
           "a system header defines the body of a generic function, which \
            typec passes through unread, while each instance reads it \
            again under its type arguments")

(* Design 7.1: each type parameter is a typedef name of an opaque value
   type (rule 2): its own in the first declaration, and in a later one
   that of the earlier declaration at the same position (rule 7). The
   function is read once, against those, where it stands (rule 3). *)
let read_generic_function state (generic : Tree.generic_function) =
  let { Tree.type_parameters; generic = form } = generic.node in
  let span, declarator, declared = generic_declared form in
  let name = Option.value ~default:"" (Tree.declared_name declarator) in
  let definition =
    match form with
    | Generic_definition _ -> true
    | Generic_prototype _ -> false
  in
  let earlier =
    earlier_generic state span name declared
      ~count:(List.length type_parameters) ~definition
  in
  let parameter_records =
    match earlier with
    | Some (_, earlier) -> earlier.parameter_records
    | None ->
        List.map
          (fun (parameter : Tree.parameter_name) ->
            Ctype.declare_opaque state.tags parameter.name.node)
          type_parameters
  in
  let bind (parameter : Tree.parameter_name) record =
    Hashtbl.replace state.entities (Tree.In_tree parameter.declared.id)
      { name = parameter.name.node; entity = fresh_entity state;
        declared = Typedef { typedef_type = Ctype.record record };
        inexact = false }
  in
  List.iter2 bind type_parameters parameter_records;
  let reference = Tree.In_tree declared.id in
  Hashtbl.replace state.generic_functions reference { parameter_records };
  (match form with
  | Generic_definition definition ->
      refuse_unmovable state generic.span;
      refuse_system_body state definition;
      Hashtbl.replace state.definition_views declared.id
        state.external_facts.texts_at.view;
      Hashtbl.replace state.generic_definitions name
        (Function_generic { span = generic.span; type_parameters; definition })
  | Generic_prototype _ -> ());
  let read ~body_reading =
    match form with
    | Generic_definition definition ->
        ignore (define_function state ~body_reading definition)
    | Generic_prototype { specifiers; declarator } ->
        let specified =
          declaration_specifiers state specifiers [ declarator ]
        in
        ignore
          (read_init_declarator state File_scope
             ~holder:(Expressions.Holder_at generic.span.first)
             specified declarator)
  in
  check_generic_function state declared read;
  check_generic_attributes state generic.span;
  Option.iter
    (fun (earlier, _) ->
      check_agreement state span name ~earlier ~later:reference)
    earlier;
  refuse_variable_parameters state span reference;
  Generic_function_declaration generic.span

let read_external_declaration state (declaration : Tree.external_declaration) =
  match declaration with
  | External_declaration declaration -> read_declaration state declaration
  | Function_definition definition -> read_function_definition state definition
  | Type_declaration declaration -> (
      note_forward_declaration state declaration;
      match read_type_declaration state declaration with
      | Some entity -> Type_declaration entity
      | None -> Generic_declaration)
  | Generic_function generic -> read_generic_function state generic
  | Top_level_asm _ | Empty_declaration _ -> Declaration []

let read_external state ((item : Tree.external_declaration Tree.item), view) =
  state.external_facts <-
    declaration_state state.tags (Some (texts_anchor item)) view;
  let read = read_external_declaration state item.declaration in
  read_function_instances state;
  Expressions.refuse_untested_outside (typing state);
  read

(* A generic of the universe text (design 3.6), which the emitted C does
   not hold: it is no type declaration that lowering replaces. Only its
   definition check, a trial, reads at its anchor, and a trial places no
   text, so every text of an instance stands in the unit's own. *)
let read_universe_generic state
    ((item : Tree.scoped_type_declaration Tree.item), view) =
  match item.declaration.declaration.node with
  | { type_parameters = []; definition = Alias alias; declared; _ } ->
      Hashtbl.replace state.universe_aliases (Tree.In_tree declared.id) alias
  | { name; _ } ->
      let anchor = Some (Tree.universe_anchor item) in
      state.external_facts <- declaration_state state.tags anchor view;
      read_generic state item.declaration;
      if (name.node :> string) = Ctype.universe_slice then
        state.slice_generic <- Some item.declaration.declaration

(* The location that GCC gives a name declared before the first token,
   which a diagnostic that depends on a builtin type cites. *)
let predeclared : Typec_cpp.Location.t =
  { file = "<built-in>"; line = 0; flags = No_flags }

(* An Arm vector type is unknown: a Neon vector is an object type of 8 or
   16 bytes, and an SVE type an object type without a size, whose size
   and use as an array element the backend refuses. *)
let arm_vector_type name =
  Ctype.unknown
    {
      construct = "the Arm vector type " ^ quote name;
      location = predeclared;
      kind = Unknown_object;
      cause = Not_typed;
    }

let builtin_type target name :
    Builtin_typedef.t -> (Ctype.t, Ctype.error) result = function
  | Va_list -> Ok Ctype.va_list
  | Int128 -> Ctype.integer target Integer.Int128
  | Unsigned_int128 -> Ctype.integer target Integer.Unsigned_int128
  | Arm_vector _ -> Ok (arm_vector_type name)

(* The builtin typedef names that the parser declares for the target's
   keywords ({!Builtin_typedef.declared}) are entities, so the two agree
   by construction. The dialect decides no builtin typedef name, and a
   declared name has its type on the target, so no error can come. *)
let declare_builtin_typedefs state =
  let keywords = Target.keywords state.target Gnu in
  let declare (name, builtin) =
    match builtin_type state.target name builtin with
    | Ok t ->
        (* No source text spells the type, the target's own. *)
        let entity =
          { name; entity = fresh_entity state;
            declared = Typedef { typedef_type = t }; inexact = false }
        in
        Hashtbl.replace state.entities (Builtin name) entity
    | Error error -> invalid_arg (Ctype.error_message error)
  in
  Builtin_typedef.table
  |> List.filter (fun (_, builtin) -> Builtin_typedef.declared keywords builtin)
  |> List.iter declare

(* The body of each function definition of the unit, a generic
   function's included, parsed or skipped. *)
let function_bodies declarations =
  let body (definition : Tree.function_definition) =
    match definition.node.body with
    | Parsed block -> block.span
    | Skipped span -> span
  in
  let item_body ((item : Tree.external_declaration Tree.item), _) =
    match item.declaration with
    | Function_definition definition
    | Generic_function
        { node = { generic = Generic_definition definition; _ }; _ } ->
        Some (body definition)
    | Generic_function { node = { generic = Generic_prototype _; _ }; _ }
    | External_declaration _ | Type_declaration _ | Top_level_asm _
    | Empty_declaration _ ->
        None
  in
  List.filter_map item_body declarations

(* Design 13.5: a pragma line sets state unless it is a [pack] or a
   diagnostic line, or a statement pragma inside a function body. *)
let sets_instance_state ~in_body (token : Token.t) =
  match token.kind with
  | Pragma (Identifiers names) when Statement_pragma.is_instance_free names ->
      false
  | Pragma (Identifiers names) when Statement_pragma.is_statement_scoped names
    ->
      not in_body
  | Pragma (Identifiers _ | Not_tokens _) | Typec_pragma -> true
  | Identifier _ | Number | Character _ | String _ | Punctuator _ -> false

(* Design 7.3 rule 4: by each token, the last at or before it that is a
   pragma line setting state, or [no_pragma], so that the check of each
   first use is one lookup. The bodies do not overlap, so marking them
   is linear in the unit. *)
let latest_state_pragmas (tokens : Token.t array) declarations =
  let in_body = Array.make (Array.length tokens) false in
  let mark (body : Tree.span) =
    Array.fill in_body body.first (body.last - body.first + 1) true
  in
  List.iter mark (function_bodies declarations);
  let latest = Array.make (Array.length tokens) no_pragma in
  let current = ref no_pragma in
  for index = 0 to Array.length tokens - 1 do
    if sets_instance_state ~in_body:in_body.(index) tokens.(index) then
      current := index;
    latest.(index) <- !current
  done;
  latest

let read target text (scopes : Parser.scopes) =
  let tags = Ctype.create_tags () in
  let state =
    {
      target;
      text;
      views = scopes.views;
      definition_views = Hashtbl.create 16;
      moved = None;
      found = [];
      read_moved = Hashtbl.create 16;
      redeclared_at = Resolution.no_redeclarations;
      completed_at = Resolution.Events.empty;
      tags;
      entities = Hashtbl.create 1024;
      tag_types = Hashtbl.create 256;
      linked = Hashtbl.create 1024;
      at_file_scope = Hashtbl.create 1024;
      beside = Hashtbl.create 64;
      overloaded = Hashtbl.create 64;
      name_readings = Hashtbl.create 16;
      generic_functions = Hashtbl.create 16;
      generic_part = None;
      trial = false;
      generic_definitions = Hashtbl.create 16;
      state_pragmas = latest_state_pragmas text.tokens scopes.declarations;
      attribute_subjects = Hashtbl.create 16;
      typed = Expressions.create ();
      type_names = Hashtbl.create 256;
      type_declarations = Hashtbl.create 16;
      incomplete_variants = Hashtbl.create 16;
      generics = Hashtbl.create 16;
      universe_aliases = Hashtbl.create 1;
      applied_at = Ctype.Instances.empty;
      slice_generic = None;
      instance_bytes = 0;
      copy_bytes = 0;
      longest_instance_code = 0;
      nesting = None;
      queued = [];
      external_facts = declaration_state tags None Parser.View.empty;
      placements = no_placements;
      place = At_file_scope;
      next_entity = 0;
      zero_initialisers = Hashtbl.create 8;
    }
  in
  declare_builtin_typedefs state;
  let read_all () =
    List.iter (read_universe_generic state) scopes.universe;
    List.map (read_external state) scopes.declarations
  in
  let end_deferral () = Ctype.end_deferral state.tags in
  match Fun.protect ~finally:end_deferral read_all with
  | items ->
      let { tags; entities; tag_types; linked; typed; type_declarations;
            placements; instance_bytes; copy_bytes; longest_instance_code;
            zero_initialisers; _ } =
        state
      in
      Ok { tags; items; placements; entities; tag_types; linked; typed;
           type_declarations; instance_bytes; copy_bytes;
           longest_instance_code; zero_initialisers }
  | exception (Failed error | Instance_failed error) -> Error error
