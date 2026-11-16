(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

(* The assertions guard the types that the edits rest on; a unit without
   edits is the backend's own text, whose types the backend decides. *)
let assertions target = function
  | [] -> []
  | _ :: _ -> Typec_emit.Assumptions.assertions target

(* Lowering of a defer is incomplete (the defer items of TODO.md: the
   resolution check of design 6 rules 8 and 12, goto exits, the
   cleanups of a try, the refusals of the form of a return), so a unit
   that holds one stops before its text reaches the backend. *)
let refuse_defers (text : Typec_cpp.Reader.t) declarations =
  let typed = Typec_sema.Declarations.typed declarations in
  let sites (lowered : Typec_sema.Expressions.function_defers) =
    lowered.sites
  in
  match List.concat_map sites (Typec_sema.Expressions.defers typed) with
  | [] -> Ok ()
  | (first : Typec_sema.Reachability.defer_site) :: _ ->
      let diagnostic =
        Typec_syntax.Rule.message Not_implemented
          "lowering of `defer` is not complete yet (design 6 rule 8; work \
           package 2.5)"
      in
      let location = text.tokens.(first.keyword.first).location in
      Error
        { Typec_cpp.Reader.location;
          message = Typec_syntax.Rule.text diagnostic }

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* _, scopes = Typec_syntax.Parser.parse_with_scopes ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text scopes in
  let* () = refuse_defers text declarations in
  let edits = Typec_emit.Lowering.edits text declarations in
  Ok { Typec_emit.Emitter.edits; assertions = assertions target edits }
