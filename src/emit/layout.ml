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

(* The applications that the unit's reading resolved are the edges: the
   walk spells each definition before those that it applies, in the
   order in which their applications first stand, and each once, which
   ends a cycle. A generic declared alone that a definition applies adds
   its declaration, so a header that reads it defined is refused with
   one that does not. *)
let applied_text declarations (unit : Reader.t) generic =
  let text = Buffer.create 256 in
  let spelt = Hashtbl.create 8 in
  let rec add generic =
    let span = definition_span generic in
    if not (Hashtbl.mem spelt span.first) then begin
      Hashtbl.add spelt span.first ();
      spell_definition text unit span;
      for index = span.first to span.last do
        Option.iter add (Declarations.applied_generic declarations index)
      done
    end
  in
  add generic;
  Buffer.contents text

let definition_text declarations unit
    (generic : Declarations.generic_definition) =
  match generic with
  | Type_generic { node = { definition = Incomplete_variant; _ }; _ } -> None
  | Type_generic _ | Function_generic _ ->
      Some (applied_text declarations unit generic)

(* The names of design 13.5: the tag names the digest, and the typedef
   the instance. *)
let typedef (instance : Spelling.c_name) ~definition =
  let digest = Digest.BLAKE128.to_hex (Digest.BLAKE128.string definition) in
  "typedef struct __tc_digest__" ^ digest ^ " *__tc_layout__"
  ^ (instance :> string) ^ ";"
