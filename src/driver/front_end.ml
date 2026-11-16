(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

(* The assertions guard the types that the edits rest on; a unit without
   edits is the backend's own text, whose types the backend decides. *)
let assertions target = function
  | [] -> []
  | _ :: _ -> Typec_emit.Assumptions.assertions target

(* Lowering writes no instance yet (design 10.3; work package 2.1), and the
   definition of a generic stands at no place of its own, so a unit that
   declares a generic type is refused before any of it reaches the
   backend. *)
let refuse_generics (text : Typec_cpp.Reader.t) type_declarations =
  let generic (declaration : Typec_syntax.Tree.type_declaration) =
    declaration.node.type_parameters <> []
  in
  match List.find_opt generic type_declarations with
  | None -> Ok ()
  | Some declaration ->
      let diagnostic =
        Typec_syntax.Rule.message Not_implemented
          "lowering generic types is not implemented yet (design 10.3; work \
           package 2.1)"
      in
      Error
        { Typec_cpp.Reader.location =
            text.tokens.(declaration.span.first).location;
          message = Typec_syntax.Rule.text diagnostic }

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* _, scopes = Typec_syntax.Parser.parse_with_scopes ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text scopes in
  let type_declarations =
    Typec_sema.Declarations.type_declarations declarations
  in
  let* () = refuse_generics text type_declarations in
  let constructions = Typec_sema.Declarations.constructions declarations in
  let matchings = Typec_sema.Declarations.matchings declarations in
  let answered = Typec_sema.Declarations.answered declarations in
  let edits =
    Typec_emit.Lowering.edits text type_declarations constructions matchings
      answered
  in
  Ok { Typec_emit.Emitter.edits; assertions = assertions target edits }
