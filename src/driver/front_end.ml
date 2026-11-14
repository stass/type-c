(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

let check target text =
  let* unit = Typec_syntax.Parser.parse text in
  let* _declarations = Typec_sema.Declarations.read target text unit in
  Ok ()
