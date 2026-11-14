(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* unit = Typec_syntax.Parser.parse ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text unit in
  let type_declarations =
    Typec_sema.Declarations.type_declarations declarations
  in
  Ok (Typec_emit.Lowering.edits text type_declarations)
