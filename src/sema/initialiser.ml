(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type typing = {
  target : Target.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> string -> 'a;
  value : Ctype.t option -> Tree.expression -> Ctype.t;
  converts : Ctype.t -> Tree.expression -> unit;
  initialises : Tree.expression -> unit;
  source : Tree.expression -> Tree.expression Unknown.answer;
  initialises_whole : Ctype.t -> Tree.expression -> unit;
  type_c_text : Tree.span -> bool;
  index : Tree.expression -> (Integer_constant.t, Tree.span) result;
}

(* Clang's default limit on nested brackets, which the parser keeps. *)
let max_levels = 256

(* Variants (design 3.2 rules 6 and 7) *)

(* The zero initialiser: the braced list [{0}], one integer constant 0
   without a designator, or the empty list [{}] of GNU C and C23. The 0
   is read from its digits, as typing the constant here would give it a
   position before the walk reaches its subobject. It zeroes any object,
   so its 0 may reach the tag of a variant member through elided braces,
   as C programs that zero a structure rely on (design 3.2 rule 7). This
   is the one place that decides it. *)
let is_zero_initialiser typing (list : Tree.initialiser_list) =
  match list.node with
  | [] -> true
  | [ { node =
          { designators = [];
            initialiser =
              Expression_initialiser
                { node = Constant (Integer { base; digits; suffix }); _ } };
        _ } ] -> (
      match
        Integer_constant.of_integer_constant typing.target base digits suffix
      with
      | Ok { value = Known value; _ } ->
          Exact_integer.equal value Exact_integer.zero
      | Ok { value = Opaque; _ } | Error _ -> false)
  | _ -> false

(* Type-C text reaches the tag and fields of a variant only through
   constructors and matching (rule 6): an initialiser at [span] does not
   open a variant's members, but where [zeroes] says it is the zero
   initialiser that zeroes them (rule 7). The two functions that open a
   structure's or union's members, {!first_level} and {!designate}, ask
   it. *)
let refuse_opening typing ~zeroes (span : Tree.span) (t : Ctype.t) =
  match Ctype.as_variant t with
  | Some name when typing.type_c_text span && not zeroes ->
      typing.fail span
        (Rule.message Zero_value
           (Printf.sprintf
              "an initialiser reaches into the variant '%s'; the only braced \
               initialisers of a variant are {0} and {}"
              name))
  | Some _ | None -> ()

(* Subobjects (6.7.9p17) *)

(* The index of an array element; one that the backend computes is
   opaque (design P16). *)
type index = Index of int | Opaque_index

(* A subobject of an aggregate, by its place in it: an element of an
   array, or the member at a position of a structure or union
   ({!Ctype.member_at}). A level always has a subobject at its place. *)
type level =
  | Array_level of { element : Ctype.t; length : Ctype.length; index : index }
  | Record_level of { tag : Ctype.record_tag; position : int }

(* Where the next initialiser of a braced list goes: the subobject at the
   innermost level, then the level of each aggregate around it, of which
   the last is the list's own object; past the end of that object, where
   an initialiser is excess; or lost, where the place depends on what
   typec does not know. *)
type cursor = Position of level * level list | Past_end | Lost

(* One more than the highest index that a braced list initialises at its
   own level, which gives the length of an array of unknown size
   (6.7.9p22). *)
type extent = Extent of int | Opaque_extent

type walk = { cursor : cursor; extent : extent }

let member_at typing tag position =
  match Ctype.member_at typing.tags tag position with
  | Some member -> member
  | None -> invalid_arg "Initialiser: a level past the last member"

let subobject_type typing = function
  | Array_level { element; _ } -> element
  | Record_level { tag; position } ->
      (member_at typing tag position).member_type

(* The first subobject of an aggregate, where a braced list for it starts
   or its braces are elided, by an initialiser at [span]; [None] where it
   has none. *)
let first_level typing ~zeroes span (t : Ctype.t) =
  match t.shape with
  | Array { length = Constant 0; _ } -> None
  | Array { element; length } ->
      Some (Array_level { element; length; index = Index 0 })
  | Record tag -> (
      refuse_opening typing ~zeroes span t;
      match Ctype.member_at typing.tags tag 0 with
      | Some _ -> Some (Record_level { tag; position = 0 })
      | None -> None)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list | Function _
  | Unknown_type _ ->
      None

type step = Next of level | Exhausted | Unknown_step

(* The subobject after the one at [level] in its aggregate: none in a
   union, which takes one initialiser, and no end in an array of unknown
   size, which takes all, as a flexible array member does in GCC and
   Clang. *)
let step typing = function
  | Array_level ({ index = Index index; length; _ } as array) -> (
      let next = Next (Array_level { array with index = Index (index + 1) }) in
      match length with
      | Constant length -> if index + 1 < length then next else Exhausted
      (* An index past [max_int] has no value, nor a length with it. *)
      | Unknown -> if index + 1 < max_int then next else Unknown_step
      | Opaque | Variable -> Unknown_step)
  | Array_level { index = Opaque_index; _ } -> Unknown_step
  | Record_level { tag = { kind = Union; _ }; _ } -> Exhausted
  | Record_level { tag; position } -> (
      match Ctype.member_at typing.tags tag (position + 1) with
      | Some _ -> Next (Record_level { tag; position = position + 1 })
      | None -> Exhausted)

(* 6.7.9p17: initialisation continues with the subobject after the one
   just initialised, out through the aggregates that are full. *)
let rec advance typing = function
  | [] -> Past_end
  | level :: outer -> (
      match step typing level with
      | Next level -> Position (level, outer)
      | Exhausted -> advance typing outer
      | Unknown_step -> Lost)

let rec outermost level = function
  | [] -> level
  | next :: outer -> outermost next outer

let widen extent level =
  match (extent, level) with
  | Opaque_extent, _ | _, Array_level { index = Opaque_index; _ } ->
      Opaque_extent
  | Extent extent, Array_level { index = Index index; _ } ->
      Extent (max extent (index + 1))
  | Extent _, Record_level _ -> extent

let check_depth typing span depth =
  if depth > max_levels then
    typing.fail span
      (Printf.sprintf
         "an initialiser reaches a subobject more than %d levels deep"
         max_levels)

(* String literals (6.7.9p14, p15) *)

(* What decides how an expression initialises an array: whether it is a
   string literal or a compound literal, through parentheses, which GCC
   and Clang take, and generic selections. It is read from the tree, so
   asking it types none of the expression. *)
type form =
  | String_form
  | Compound_form
  | Other_form
  | Unknown_form of Unknown.t

let form typing expression =
  match typing.source expression with
  | Answer { node = String _; _ } -> String_form
  | Answer { node = Compound_literal _; _ } -> Compound_form
  | Answer _ -> Other_form
  | Depends_on unknown -> Unknown_form unknown

let is_character typing t : bool Unknown.answer =
  match Ctype.as_arithmetic typing.tags t with
  | Answer (Some (Integer (Char | Signed_char | Unsigned_char))) -> Answer true
  | Answer (Some (Integer _ | Real _ | Complex _) | None) -> Answer false
  | Depends_on unknown -> Depends_on unknown

(* The code units of the prefixed string literals, which initialise arrays
   of a type compatible with theirs (6.7.9p15). *)
let wide_units typing =
  let target = typing.target in
  List.filter_map
    (fun integer -> Result.to_option (Ctype.integer target integer))
    [ target.wchar_type; target.char16_type; target.char32_type ]

let compatible typing a b =
  Ctype.compatible typing.target typing.tags (Ctype.unqualified a) b

(* Whether a string literal initialises an array of [element]: one of a
   character type or of a code unit of a prefixed literal. *)
let takes_strings typing element : bool Unknown.answer =
  let answers =
    is_character typing element
    :: List.map (compatible typing element) (wide_units typing)
  in
  let is_unknown : bool Unknown.answer -> bool = function
    | Depends_on _ -> true
    | Answer _ -> false
  in
  if List.mem (Unknown.Answer true) answers then Answer true
  else
    match List.find_opt is_unknown answers with
    | Some unknown -> unknown
    | None -> Answer false

(* Whether an expression of [form] is a string literal that initialises a
   whole array of [element]. *)
let string_for typing element form : bool Unknown.answer =
  match form with
  | String_form -> takes_strings typing element
  | Unknown_form unknown -> Depends_on unknown
  | Compound_form | Other_form -> Answer false

(* The literal initialises an array of [element]: a character type from a
   literal of characters, without a prefix or with [u8], another from a
   literal of its own code unit. The length of the literal's type is the
   one it gives an array of unknown size (6.7.9p22). [target] is the
   literal's target type, as for any initialiser. *)
let string_initialiser typing ~target element literal =
  let literal_type = typing.value (Some target) literal in
  typing.initialises literal;
  match literal_type.shape with
  | Array { element = unit; length } ->
      let fits =
        if is_character typing unit = Answer true then
          is_character typing element <> Answer false
        else compatible typing element unit <> Answer false
      in
      if not fits then
        typing.fail literal.span
          "a string literal initialises an array of another character type \
           (C11 6.7.9p14, p15)";
      length
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Record _ | Va_list
  | Function _ | Unknown_type _ ->
      invalid_arg "Initialiser: a string literal that is not an array"

(* 6.7.9p22: an array of unknown size takes the length that its
   initialiser gives; any other type is complete already. *)
let completed typing (t : Ctype.t) length =
  match t.shape with
  | Array { element; length = Unknown } -> (
      match Ctype.array_of typing.tags element length with
      | Ok completed -> completed
      | Error _ -> invalid_arg "Initialiser: an array that its length breaks")
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Record _
  | Va_list | Array _
  | Function _ | Unknown_type _ ->
      t

(* Designators (6.7.9p6, p7, p17, p18) *)

(* An integer constant expression, not negative, and below the length of
   the array where it has one (6.7.9p6). *)
let array_index typing (length : Ctype.length) expression =
  match typing.index expression with
  | Error span ->
      typing.fail span
        "an array designator is not an integer constant expression (C11 \
         6.7.9p6)"
  | Ok { value = Opaque; _ } -> Opaque_index
  | Ok { value = Known value; _ } -> (
      if Exact_integer.is_negative value then
        typing.fail expression.span
          "an array designator is negative (C11 6.7.9p6)";
      match Exact_integer.to_int value with
      (* The index after it must have a value too. *)
      | Some index when index < max_int -> (
          match length with
          | Constant length when index >= length ->
              typing.fail expression.span
                "an array designator is past the end of the array (C11 \
                 6.7.9p6)"
          | Constant _ | Opaque | Unknown | Variable -> Index index)
      | Some _ | None -> typing.fail expression.span "an array is too large")

(* The index of an array designator, or of the last element of a GNU
   range, from which initialisation continues. *)
let designated_index typing length (designator : Tree.designator) =
  match designator.node with
  | Index expression -> array_index typing length expression
  | Index_range { low; high } -> (
      let first = array_index typing length low in
      match (first, array_index typing length high) with
      | Index first, Index last when first > last ->
          typing.fail designator.span "a range designator is empty (GNU C)"
      | _, last -> last)
  | Member_designator _ -> invalid_arg "Initialiser: a member as an index"

(* The levels from a structure or union down to the member at [path],
   through the anonymous members that hold it, innermost first onto
   [levels]; and the member's type. *)
let rec along typing tag path levels =
  match path with
  | [] -> invalid_arg "Initialiser: an empty member path"
  | position :: inner -> (
      let level = Record_level { tag; position } in
      let member_type = (member_at typing tag position).member_type in
      match (inner, member_type.shape) with
      | [], _ -> (member_type, level :: levels)
      | _ :: _, Record anonymous ->
          along typing anonymous inner (level :: levels)
      | _ :: _, _ ->
          invalid_arg "Initialiser: an anonymous member of no record")

let designator_expressions typing (designator : Tree.designator) =
  match designator.node with
  | Index expression -> ignore (array_index typing Unknown expression)
  | Index_range { low; high } ->
      ignore (array_index typing Unknown low);
      ignore (array_index typing Unknown high)
  | Member_designator _ -> ()

(* The subobject that [designators] name in the current object of a
   braced list, of type [t]. *)
let designate typing t designators =
  let rec enter (t : Ctype.t) levels = function
    | [] -> (
        match levels with
        | level :: outer -> Position (level, outer)
        | [] -> invalid_arg "Initialiser: no designator")
    | (designator : Tree.designator) :: rest -> (
        check_depth typing designator.span (List.length levels);
        match (designator.node, t.shape) with
        | Member_designator name, Record tag -> (
            refuse_opening typing ~zeroes:false designator.span t;
            match Ctype.find_member typing.tags tag name.node with
            | Some { path; _ } ->
                let member_type, levels = along typing tag path levels in
                enter member_type levels rest
            | None ->
                typing.fail name.span
                  "a member designator names no member of the structure or \
                   union (C11 6.7.9p7)")
        | (Index _ | Index_range _), Array { element; length } ->
            let index = designated_index typing length designator in
            enter element (Array_level { element; length; index } :: levels)
              rest
        | _, Unknown_type _ ->
            List.iter (designator_expressions typing) (designator :: rest);
            Lost
        | Member_designator _, _ ->
            typing.fail designator.span
              "a member designator for an object that is not a structure or \
               union (C11 6.7.9p7)"
        | (Index _ | Index_range _), _ ->
            typing.fail designator.span
              "an array designator for an object that is not an array (C11 \
               6.7.9p6)")
  in
  enter t [] designators

(* Initialisers without a subobject: excess ones, and those whose
   subobject typec does not know. Their expressions are typed. *)
let rec untargeted typing (initialiser : Tree.initialiser) =
  match initialiser with
  | Expression_initialiser expression -> ignore (typing.value None expression)
  | Braced list -> List.iter (untargeted_element typing) list.node

and untargeted_element typing (element : Tree.designated_initialiser) =
  List.iter (designator_expressions typing) element.node.designators;
  untargeted typing element.node.initialiser

(* Whether an object of type [t] is a variant or has one among its
   subobjects. *)
let rec holds_variant typing (t : Ctype.t) =
  match (Ctype.as_variant t, t.shape) with
  | Some _, _ -> true
  | None, Array { element; _ } -> holds_variant typing element
  | None, Record tag -> members_hold_variant typing tag 0
  | ( None,
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
      | Function _
      | Unknown_type _ ) ) ->
      false

and members_hold_variant typing tag position =
  match Ctype.member_at typing.tags tag position with
  | Some member ->
      holds_variant typing member.member_type
      || members_hold_variant typing tag (position + 1)
  | None -> false

(* Braced lists (6.7.9p17, p20) *)

(* What an expression initialises at a subobject of type [t]: all of it,
   or, its braces elided, its first subobject (6.7.9p13, p14, p20). *)
type reach = Whole | Elided | Unknown_reach

(* The first variant among [t] and the subobjects that its braces, then
   theirs, elided would put an initialiser in. *)
let rec first_variant typing (t : Ctype.t) =
  match (Ctype.as_variant t, t.shape) with
  | Some _, _ -> Some t
  | None, Array { length = Constant 0; _ } -> None
  | None, Array { element; _ } -> first_variant typing element
  | None, Record tag -> (
      match Ctype.member_at typing.tags tag 0 with
      | Some first -> first_variant typing first.member_type
      | None -> None)
  | ( None,
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Va_list
      | Function _
      | Unknown_type _ ) ) ->
      None

(* The target type (design 3.3) of an expression initialiser that the
   walk meets at a subobject of type [t]: the first variant inside [t]
   where its braces may be elided, else [t]. A constructor initialises
   that variant whole, as no initialiser in Type-C text enters a variant
   but the zero initialiser (3.2 rule 7); and a target that is no
   variant selects no constructor, so an expression that initialises an aggregate around
   the variant means there what it means with the variant as its target.
   The target stays the expression's as the walk elides braces. *)
(* Design 3.4: [{0}] gives an object of a distinct type the zero value of
   its representation, so its 0 converts to no type there; [zeroes] says
   that the 0 is that of [{0}]. *)
let scalar_target ~zeroes (t : Ctype.t) =
  if zeroes && Option.is_some (Ctype.as_distinct t) then None else Some t

let target_at typing (t : Ctype.t) =
  Option.value (first_variant typing t) ~default:t

let reach_of typing ~zeroes ~target (t : Ctype.t) expression =
  match t.shape with
  | Array { element; _ } -> (
      let form = form typing expression in
      match (string_for typing element form, form) with
      | Answer true, _ ->
          ignore (string_initialiser typing ~target element expression);
          Whole
      (* GCC takes a compound literal of an array type for a subarray, which
         Clang refuses. *)
      | Depends_on _, _ | Answer false, Compound_form ->
          ignore (typing.value (Some target) expression);
          Unknown_reach
      | Answer false, (String_form | Other_form | Unknown_form _) -> Elided)
  | Record _ -> (
      let value_type =
        Ctype.lvalue_conversion
          (typing.value (Some target) expression)
      in
      match compatible typing t value_type with
      | Answer true ->
          typing.initialises expression;
          Whole
      | Answer false -> Elided
      | Depends_on _ -> Unknown_reach)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Function _ ->
      ignore (typing.value (scalar_target ~zeroes target) expression);
      (* Where braces around the scalar are elided, the target is the
         aggregate around it, so the conversion to the scalar is
         checked here. *)
      Option.iter
        (fun scalar -> typing.converts scalar expression)
        (scalar_target ~zeroes t);
      typing.initialises expression;
      Whole
  | Va_list | Unknown_type _ ->
      ignore (typing.value (Some target) expression);
      Unknown_reach

(* Initialises the subobject at [level], within [outer], with
   [initialiser], entering it where its braces are elided; gives the
   levels of the subobject that it initialised, or [None] where that
   depends on what typec does not know. [elided] is the target type of
   an expression initialiser for which the walk has elided the braces of
   the subobjects around [level], [None] where it has elided none. [depth] counts the
   levels. *)
let rec place typing ~zeroes ~elided ~depth (level, outer)
    (initialiser : Tree.initialiser) =
  let t = subobject_type typing level in
  match initialiser with
  | Braced list ->
      ignore (braced typing t list);
      Some (level, outer)
  | Expression_initialiser expression -> (
      let target =
        match elided with
        | Some target -> target
        | None -> target_at typing t
      in
      match reach_of typing ~zeroes ~target t expression with
      | Whole ->
          if Option.is_none elided then typing.initialises_whole t expression;
          Some (level, outer)
      | Unknown_reach -> None
      | Elided -> (
          check_depth typing expression.span (depth + 1);
          match first_level typing ~zeroes expression.span t with
          | Some inner ->
              place typing ~zeroes ~elided:(Some target) ~depth:(depth + 1)
                (inner, level :: outer) initialiser
          | None -> None))

(* The braced list for an object of type [t], its current object; gives
   the type of the object, completed as for {!initialise}. *)
and braced typing (t : Ctype.t) (list : Tree.initialiser_list) =
  match (t.shape, list.node) with
  (* 6.7.9p14: a string literal in braces. *)
  | ( Array { element; _ },
      { node =
          { designators = []; initialiser = Expression_initialiser literal };
        _ }
      :: excess )
    when string_for typing element (form typing literal) = Answer true ->
      let length = string_initialiser typing ~target:t element literal in
      List.iter (untargeted_element typing) excess;
      completed typing t length
  | (Array _ | Record _), _ -> aggregate typing t list
  | ( (Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Function _),
      elements ) ->
      scalar typing ~zeroes:(is_zero_initialiser typing list) t elements;
      t
  | (Va_list | Unknown_type _), elements ->
      List.iter (untargeted_element typing) elements;
      t

and aggregate typing t (list : Tree.initialiser_list) =
  let zeroes = is_zero_initialiser typing list in
  let start =
    match first_level typing ~zeroes list.span t with
    | Some level -> Position (level, [])
    | None -> Past_end
  in
  let walked =
    List.fold_left (initialise_element typing ~zeroes t)
      { cursor = start; extent = Extent 0 }
      list.node
  in
  let length : Ctype.length =
    match walked.extent with
    | Extent length -> Constant length
    | Opaque_extent -> Opaque
  in
  completed typing t length

(* One initialiser of the braced list for [t]. Where the walk loses its
   place, the backend may open a variant that it holds (design 3.2 rule
   6), which typec cannot refuse, so Type-C text may not lose it there. *)
and initialise_element typing ~zeroes t walk
    (element : Tree.designated_initialiser) =
  let walked = place_element typing ~zeroes t walk element in
  (match walked.cursor with
  | Lost when typing.type_c_text element.span && not zeroes ->
      if holds_variant typing t then
        typing.fail element.span
          (Rule.message Zero_value
             "the subobject that an initialiser reaches depends on what \
              typec does not know, in an object that holds a variant")
  | Lost | Position _ | Past_end -> ());
  walked

(* One initialiser of the braced list for [t], at its designated
   subobject or at the cursor. *)
and place_element typing ~zeroes t walk
    (element : Tree.designated_initialiser) =
  let { Tree.designators; initialiser } = element.node in
  let cursor =
    match designators with
    | [] -> walk.cursor
    | _ :: _ -> designate typing t designators
  in
  match cursor with
  | Position (level, outer) -> (
      let extent = widen walk.extent (outermost level outer) in
      let depth = 1 + List.length outer in
      match
        place typing ~zeroes ~elided:None ~depth (level, outer) initialiser
      with
      | Some (level, outer) ->
          { cursor = advance typing (level :: outer); extent }
      | None -> { cursor = Lost; extent = Opaque_extent })
  | Past_end ->
      untargeted typing initialiser;
      walk
  | Lost ->
      untargeted typing initialiser;
      { cursor = Lost; extent = Opaque_extent }

(* 6.7.9p11: one initialiser, which GCC and Clang take in more braces, and
   after it excess ones, which they take with a warning. *)
and scalar typing ~zeroes t elements =
  match elements with
  | [] -> ()
  | first :: excess ->
      (match first.node.designators with
      | designator :: _ ->
          typing.fail designator.span
            "a designator in the initialiser of a scalar (C11 6.7.9p6, p7)"
      | [] -> ());
      (match first.node.initialiser with
      | Expression_initialiser expression ->
          ignore (typing.value (scalar_target ~zeroes t) expression);
          typing.initialises expression
      | Braced inner -> ignore (braced typing t inner));
      List.iter (untargeted_element typing) excess

(* Objects (6.7.9p3, p16) *)

(* 6.7.9p3: a complete object type or an array of unknown size. *)
let check_object typing span (t : Ctype.t) =
  match (t.shape, Ctype.is_complete typing.tags t) with
  | Array { length = Unknown; _ }, _ | _, (Answer true | Depends_on _) -> ()
  | _, Answer false ->
      typing.fail span "an object of incomplete type is initialised (C11 \
                        6.7.9p3)"

(* 6.7.9p16: an array takes a braced list or a string literal; GCC and
   Clang take a compound literal of an array type too, whose length an
   array of unknown size takes, and whose own initialiser is what the
   array's constancy depends on. *)
let array_from typing t expression =
  if form typing expression <> Compound_form then
    typing.fail expression.span
      "an array is initialised by an expression that is not a string \
       literal (C11 6.7.9p16)";
  match (typing.value (Some t) expression).shape with
  | Array { length; _ } -> completed typing t length
  | Unknown_type _ -> completed typing t Opaque
  | Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Record _ | Va_list
  | Function _ ->
      typing.fail expression.span
        "an array is initialised by a compound literal that is not an \
         array (C11 6.7.9p16)"

let array_initialiser typing t element expression =
  match string_for typing element (form typing expression) with
  | Answer true ->
      let length = string_initialiser typing ~target:t element expression in
      completed typing t length
  | Depends_on _ ->
      ignore (typing.value (Some t) expression);
      completed typing t Opaque
  | Answer false -> array_from typing t expression

let initialise typing (t : Ctype.t) (initialiser : Tree.initialiser) =
  let span =
    match initialiser with
    | Expression_initialiser expression -> expression.span
    | Braced list -> list.span
  in
  check_object typing span t;
  match (initialiser, t.shape) with
  | Braced list, _ -> braced typing t list
  | Expression_initialiser expression, Array { element; _ } ->
      array_initialiser typing t element expression
  | ( Expression_initialiser expression,
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Distinct _ | Record _
      | Va_list
      | Function _ | Unknown_type _ ) ) ->
      ignore (typing.value (Some t) expression);
      typing.initialises expression;
      typing.initialises_whole t expression;
      t
