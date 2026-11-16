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
  let* _, scopes = Typec_syntax.Parser.parse_with_scopes ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text scopes in
  let edits = Typec_emit.Lowering.edits text declarations in
  Ok { Typec_emit.Emitter.edits; assertions = assertions target edits }
