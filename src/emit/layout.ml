(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
module Declarations = Typec_sema.Declarations

let definition_span : Declarations.generic_definition -> Tree.span =
  function
  | Type_generic declaration -> declaration.span
  | Function_generic { span; _ } -> span

(* Each token as [Reader.spelling] spells it and one space, so that
   neither white space nor universal character names change the text,
   and a line break after the definition, which no spelling holds, so
   that the definitions part the text in one way only. *)
let spell_definition text (unit : Reader.t) (span : Tree.span) =
  for index = span.first to span.last do
    Buffer.add_string text (Reader.spelling unit unit.tokens.(index));
    Buffer.add_char text ' '
  done;
  Buffer.add_char text '\n'

(* Where a generic of the walk is declared alone; [definition_text]
   catches it. *)
exception Declared_alone

let is_declared_alone : Declarations.generic_definition -> bool = function
  | Type_generic { node = { definition = Incomplete_variant; _ }; _ } -> true
  | Type_generic _ | Function_generic _ -> false

(* The applications that the unit's reading resolved are the edges: the
   walk spells each definition before those that it applies, in the
   order in which their applications first stand, and each once, which
   ends a cycle. A generic declared alone anywhere in the walk leaves no
   text, as one whose instance the step reads declared alone: a step
   defines such an instance only where the generic stands behind a
   pointer, so its layout rests on no definition of it, and how far
   another step completed the generic changes nothing (design 9.3). *)
let definition_text declarations (unit : Reader.t) generic =
  let text = Buffer.create 256 in
  let spelt = Hashtbl.create 8 in
  let rec add generic =
    if is_declared_alone generic then raise Declared_alone;
    let span = definition_span generic in
    if not (Hashtbl.mem spelt span.first) then begin
      Hashtbl.add spelt span.first ();
      spell_definition text unit span;
      for index = span.first to span.last do
        Option.iter add (Declarations.applied_generic declarations index)
      done
    end
  in
  match add generic with
  | () -> Some (Buffer.contents text)
  | exception Declared_alone -> None

(* The names of design 13.5: the tag names the digest, and the typedef
   the instance. *)
let typedef (instance : Spelling.c_name) ~definition =
  let digest = Digest.BLAKE128.to_hex (Digest.BLAKE128.string definition) in
  "typedef struct __tc_digest__" ^ digest ^ " *__tc_layout__"
  ^ (instance :> string) ^ ";"
