(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

let ( let* ) = Result.bind

(* The assertions guard the types that the edits rest on; a unit without
   edits is the backend's own text, whose types the backend decides. *)
let assertions target = function
  | [] -> []
  | _ :: _ -> Typec_emit.Assumptions.assertions target

(* Instances of a generic function are not written yet (work package
   3.3), so a unit that holds one stops, after its definition is checked,
   before its text reaches the backend. *)
let refuse_generic_functions (text : Typec_cpp.Reader.t) unit =
  let generic = function
    | Typec_syntax.Tree.Generic_function generic -> Some generic.span.first
    | External_declaration _ | Type_declaration _ | Function_definition _
    | Top_level_asm _ | Empty_declaration _ ->
        None
  in
  match
    List.find_map generic (Typec_syntax.Tree.external_declarations unit)
  with
  | None -> Ok ()
  | Some first ->
      let diagnostic =
        Typec_syntax.Rule.message Not_implemented
          "a generic function is checked, but typec does not write its \
           instances yet (work package 3.3)"
      in
      Error
        { Typec_cpp.Reader.location = text.tokens.(first).location;
          message = Typec_syntax.Rule.text diagnostic }

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* unit, scopes = Typec_syntax.Parser.parse_with_scopes ~keywords text in
  let* declarations = Typec_sema.Declarations.read target text scopes in
  let* () = refuse_generic_functions text unit in
  let* edits = Typec_emit.Lowering.edits text declarations in
  Ok { Typec_emit.Emitter.edits; assertions = assertions target edits }
