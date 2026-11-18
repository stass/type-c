(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
module Declarations = Typec_sema.Declarations

let definition_span : Declarations.generic_definition -> Tree.span =
  function
  | Type_generic declaration -> declaration.span
  | Function_generic { span; _ } -> span

(* The first token of a generic's definition names that generic alone. *)
let identity generic = (definition_span generic).first

(* Each token as [Reader.spelling] spells it and one space, so that
   neither white space nor universal character names change the text,
   and a line break after the definition, which no spelling holds. *)
let spelling (unit : Reader.t) generic =
  let span = definition_span generic in
  let text = Buffer.create 256 in
  for index = span.first to span.last do
    Buffer.add_string text (Reader.spelling unit unit.tokens.(index));
    Buffer.add_char text ' '
  done;
  Buffer.add_char text '\n';
  Buffer.contents text

let is_declared_alone : Declarations.generic_definition -> bool = function
  | Type_generic { node = { definition = Incomplete_variant; _ }; _ } -> true
  | Type_generic _ | Function_generic _ -> false

let digest text = Digest.BLAKE128.to_hex (Digest.BLAKE128.string text)

(* The edges of the application graph: the generic of each application
   in [generic]'s definition, as the unit's reading resolved it. *)
let edges declarations generic =
  let span = definition_span generic in
  List.init (span.last - span.first + 1) (fun offset -> span.first + offset)
  |> List.filter_map (Declarations.applied_generic declarations)

(* The strongly connected components of the generics that [roots] reach
   by [edges], each after every component that it reaches, by Tarjan's
   algorithm: each generic is numbered as it is entered and pushed on
   the stack, and [lowest] is the least number on the stack that it
   reaches; one that reaches none lower than its own closes the
   component of the generics above it. The walk keeps its own stack of
   frames, as a chain of generics is as long as the input allows. *)
let components edges roots =
  let number = Hashtbl.create 64 in
  let lowest = Hashtbl.create 64 in
  let on_stack = Hashtbl.create 64 in
  let stack = ref [] in
  let closed = ref [] in
  let lower generic bound =
    if bound < Hashtbl.find lowest (identity generic) then
      Hashtbl.replace lowest (identity generic) bound
  in
  (* A frame is a generic being walked and the edges it has yet to
     follow. *)
  let enter generic =
    let own = Hashtbl.length number in
    Hashtbl.add number (identity generic) own;
    Hashtbl.add lowest (identity generic) own;
    Hashtbl.add on_stack (identity generic) ();
    stack := generic :: !stack;
    (generic, edges generic)
  in
  let close root =
    let rec pop members =
      match !stack with
      | [] -> invalid_arg "Layout.components: the root left the stack"
      | top :: rest ->
          stack := rest;
          Hashtbl.remove on_stack (identity top);
          if identity top = identity root then top :: members
          else pop (top :: members)
    in
    closed := pop [] :: !closed
  in
  let leave generic callers =
    let own = Hashtbl.find number (identity generic) in
    if Hashtbl.find lowest (identity generic) = own then close generic;
    match callers with
    | [] -> ()
    | (caller, _) :: _ -> lower caller (Hashtbl.find lowest (identity generic))
  in
  let rec walk = function
    | [] -> ()
    | (generic, []) :: callers ->
        leave generic callers;
        walk callers
    | (generic, target :: rest) :: callers ->
        let frames = (generic, rest) :: callers in
        follow generic target frames
  and follow generic target frames =
    match Hashtbl.find_opt number (identity target) with
    | None -> walk (enter target :: frames)
    | Some target_number ->
        if Hashtbl.mem on_stack (identity target) then
          lower generic target_number;
        walk frames
  in
  let start root =
    if not (Hashtbl.mem number (identity root)) then walk [ enter root ]
  in
  List.iter start roots;
  List.rev !closed

(* A component's text holds every line of a definition with a space and
   no digest with one, so it parts in one way only (design 9.3). *)
let component_text unit ~members ~successors =
  let definitions = List.sort compare (List.map (spelling unit) members) in
  let line successor = successor ^ "\n" in
  String.concat "" definitions
  ^ String.concat "" (List.map line (List.sort_uniq compare successors))

(* The digest of each generic that [roots] reach, its component's. A
   component holding a generic declared alone, or applying one that has
   none, has none: the step defines an instance of a generic declared
   alone only behind a pointer, so its layout rests on no definition. *)
let digests declarations unit roots =
  let digests = Hashtbl.create 64 in
  let add members =
    let inside = Hashtbl.create 8 in
    List.iter (fun member -> Hashtbl.replace inside (identity member) ())
      members;
    let is_member generic = Hashtbl.mem inside (identity generic) in
    let successors =
      List.concat_map (edges declarations) members
      |> List.filter (fun generic -> not (is_member generic))
      |> List.map (fun generic -> Hashtbl.find digests (identity generic))
    in
    let component_digest =
      if List.exists is_declared_alone members || List.mem None successors
      then None
      else
        let successors = List.filter_map Fun.id successors in
        Some (digest (component_text unit ~members ~successors))
    in
    List.iter
      (fun member -> Hashtbl.add digests (identity member) component_digest)
      members
  in
  List.iter add (components (edges declarations) roots);
  fun generic -> Hashtbl.find digests (identity generic)

(* The names of design 13.5: the tag names the digest, and the typedef
   the instance. *)
let typedef (instance : Spelling.c_name) ~digest =
  "typedef struct __tc_digest__" ^ digest ^ " *__tc_layout__"
  ^ (instance :> string) ^ ";"

let typedefs declarations unit =
  let applications = Declarations.applications declarations in
  let generic (instance, _) =
    Declarations.instance_generic declarations instance
  in
  let digest_of = digests declarations unit (List.map generic applications) in
  let layout ((instance, application) as entry) =
    match digest_of (generic entry) with
    | None -> None
    | Some digest ->
        let name = Typec_sema.Encoding.instance_c_name instance in
        Some (application, typedef name ~digest)
  in
  List.filter_map layout applications
