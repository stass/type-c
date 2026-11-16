(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

(* The assertions guard the types that the edits rest on; a unit without
   edits is the backend's own text, whose types the backend decides. *)
let assertions target = function
  | [] -> []
  | _ :: _ -> Typec_emit.Assumptions.assertions target

(* Lowering writes no try yet (work package 2.4), so a unit that holds
   one stops before its text reaches the backend unlowered. *)
let refuse_tries (text : Typec_cpp.Reader.t) declarations =
  let typed = Typec_sema.Declarations.typed declarations in
  match Typec_sema.Expressions.tries typed with
  | [] -> Ok ()
  | first :: _ ->
      let diagnostic =
        Typec_syntax.Rule.message Not_implemented
          "lowering of `try` is not implemented yet (design 5.1; work \
           package 2.4)"
      in
      let location = text.tokens.(first.try_span.first).location in
      Error
        { Typec_cpp.Reader.location;
          message = Typec_syntax.Rule.text diagnostic }

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* _, scopes = Typec_syntax.Parser.parse_with_scopes ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text scopes in
  let* () = refuse_tries text declarations in
  let edits = Typec_emit.Lowering.edits text declarations in
  Ok { Typec_emit.Emitter.edits; assertions = assertions target edits }
