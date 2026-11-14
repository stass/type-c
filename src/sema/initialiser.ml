(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_syntax

type typing = {
  target : Target.t;
  tags : Ctype.tags;
  fail : 'a. Tree.span -> string -> 'a;
  value : Tree.expression -> Ctype.t;
  initialises : Tree.expression -> unit;
  source : Tree.expression -> Tree.expression Unknown.answer;
  index : Tree.expression -> (Integer_constant.t, Tree.span) result;
}

(* Clang's default limit on nested brackets, which the parser keeps. *)
let max_levels = 256

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
   or its braces are elided; [None] where it has none. *)
let first_level typing (t : Ctype.t) =
  match t.shape with
  | Array { length = Constant 0; _ } -> None
  | Array { element; length } ->
      Some (Array_level { element; length; index = Index 0 })
  | Record tag -> (
      match Ctype.member_at typing.tags tag 0 with
      | Some _ -> Some (Record_level { tag; position = 0 })
      | None -> None)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Va_list | Function _
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
   and Clang take, and generic selections. *)
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

(* Whether [expression] is a string literal that initialises a whole
   array of [element]. *)
let string_for typing element expression : bool Unknown.answer =
  match form typing expression with
  | String_form -> takes_strings typing element
  | Unknown_form unknown -> Depends_on unknown
  | Compound_form | Other_form -> Answer false

(* The literal initialises an array of [element]: a character type from a
   literal of characters, without a prefix or with [u8], another from a
   literal of its own code unit. The length of the literal's type is the
   one it gives an array of unknown size (6.7.9p22). *)
let string_initialiser typing element literal =
  typing.initialises literal;
  match (typing.value literal).shape with
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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
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
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list | Array _
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
  | Expression_initialiser expression -> ignore (typing.value expression)
  | Braced list -> List.iter (untargeted_element typing) list.node

and untargeted_element typing (element : Tree.designated_initialiser) =
  List.iter (designator_expressions typing) element.node.designators;
  untargeted typing element.node.initialiser

(* Braced lists (6.7.9p17, p20) *)

(* What an expression initialises at a subobject of type [t]: all of it,
   or, its braces elided, its first subobject (6.7.9p13, p14, p20). *)
type reach = Whole | Elided | Unknown_reach

let reach_of typing (t : Ctype.t) expression =
  match t.shape with
  | Array { element; _ } -> (
      match (string_for typing element expression, form typing expression) with
      | Answer true, _ ->
          ignore (string_initialiser typing element expression);
          Whole
      (* GCC takes a compound literal of an array type for a subarray, which
         Clang refuses. *)
      | Depends_on _, _ | Answer false, Compound_form ->
          ignore (typing.value expression);
          Unknown_reach
      | Answer false, (String_form | Other_form | Unknown_form _) -> Elided)
  | Record _ -> (
      let value_type = Ctype.lvalue_conversion (typing.value expression) in
      match compatible typing t value_type with
      | Answer true ->
          typing.initialises expression;
          Whole
      | Answer false -> Elided
      | Depends_on _ -> Unknown_reach)
  | Void | Arithmetic _ | Enum _ | Pointer _ | Function _ ->
      ignore (typing.value expression);
      typing.initialises expression;
      Whole
  | Va_list | Unknown_type _ ->
      ignore (typing.value expression);
      Unknown_reach

(* Initialises the subobject at [level], within [outer], with
   [initialiser], entering it where its braces are elided; gives the
   levels of the subobject that it initialised, or [None] where that
   depends on what typec does not know. [depth] counts the levels. *)
let rec place typing ~depth (level, outer) (initialiser : Tree.initialiser) =
  let t = subobject_type typing level in
  match initialiser with
  | Braced list ->
      ignore (braced typing t list);
      Some (level, outer)
  | Expression_initialiser expression -> (
      match reach_of typing t expression with
      | Whole -> Some (level, outer)
      | Unknown_reach -> None
      | Elided -> (
          check_depth typing expression.span (depth + 1);
          match first_level typing t with
          | Some inner ->
              place typing ~depth:(depth + 1) (inner, level :: outer)
                initialiser
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
    when string_for typing element literal = Answer true ->
      let length = string_initialiser typing element literal in
      List.iter (untargeted_element typing) excess;
      completed typing t length
  | (Array _ | Record _), _ -> aggregate typing t list
  | (Void | Arithmetic _ | Enum _ | Pointer _ | Function _), elements ->
      scalar typing t elements;
      t
  | (Va_list | Unknown_type _), elements ->
      List.iter (untargeted_element typing) elements;
      t

and aggregate typing t (list : Tree.initialiser_list) =
  let start =
    match first_level typing t with
    | Some level -> Position (level, [])
    | None -> Past_end
  in
  let walked =
    List.fold_left (initialise_element typing t)
      { cursor = start; extent = Extent 0 }
      list.node
  in
  let length : Ctype.length =
    match walked.extent with
    | Extent length -> Constant length
    | Opaque_extent -> Opaque
  in
  completed typing t length

(* One initialiser of the braced list for [t], at its designated
   subobject or at the cursor. *)
and initialise_element typing t walk (element : Tree.designated_initialiser) =
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
      match place typing ~depth (level, outer) initialiser with
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
and scalar typing t elements =
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
          ignore (typing.value expression);
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
  match (typing.value expression).shape with
  | Array { length; _ } -> completed typing t length
  | Unknown_type _ -> completed typing t Opaque
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
  | Function _ ->
      typing.fail expression.span
        "an array is initialised by a compound literal that is not an \
         array (C11 6.7.9p16)"

let array_initialiser typing t element expression =
  match string_for typing element expression with
  | Answer true ->
      completed typing t (string_initialiser typing element expression)
  | Depends_on _ ->
      ignore (typing.value expression);
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
      ( Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Va_list
      | Function _ | Unknown_type _ ) ) ->
      ignore (typing.value expression);
      typing.initialises expression;
      t
