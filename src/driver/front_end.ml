(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

(* The assertions guard the types that the edits rest on; a unit without
   edits is the backend's own text, whose types the backend decides. *)
let assertions target = function
  | [] -> []
  | _ :: _ -> Typec_emit.Assumptions.assertions target

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* unit = Typec_syntax.Parser.parse ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text unit in
  let type_declarations =
    Typec_sema.Declarations.type_declarations declarations
  in
  let constructions = Typec_sema.Declarations.constructions declarations in
  let matchings = Typec_sema.Declarations.matchings declarations in
  let answered = Typec_sema.Declarations.answered declarations in
  let edits =
    Typec_emit.Lowering.edits text type_declarations constructions matchings
      answered
  in
  Ok { Typec_emit.Emitter.edits; assertions = assertions target edits }
