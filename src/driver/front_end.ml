(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Declarations = Typec_sema.Declarations

let ( let* ) = Result.bind

type counts = {
  unit_bytes : int;
  instance_bytes : int;
  copy_bytes : int;
  output_bytes : int;
  output_limit : int;
  longest_instance_code : int;
  longest_name : int;
}

(* The assertions guard the types that the edits rest on; a unit without
   edits is the backend's own text, whose types the backend decides. *)
let assertions target = function
  | [] -> []
  | _ :: _ -> Typec_emit.Assumptions.assertions target

let lower dialect target text =
  let keywords = Typec_sema.Target.keywords target dialect in
  let* _unit, scopes = Typec_syntax.Parser.parse_with_scopes ~keywords text in
  let* declarations = Declarations.read target text scopes in
  let* edits, output_bytes = Typec_emit.Lowering.edits text declarations in
  let counts =
    {
      unit_bytes = Typec_cpp.Reader.length text;
      instance_bytes = Declarations.instance_bytes declarations;
      copy_bytes = Declarations.copy_bytes declarations;
      output_bytes;
      output_limit = Typec_sema.Output_limit.of_unit text;
      longest_instance_code = Declarations.longest_instance_code declarations;
      longest_name = scopes.longest_type_name;
    }
  in
  Ok
    ({ Typec_emit.Emitter.edits; assertions = assertions target edits }, counts)

let counts_line counts =
  Printf.sprintf
    "unit_bytes=%d instance_bytes=%d copy_bytes=%d output_bytes=%d \
     output_limit=%d longest_instance_code=%d longest_name=%d"
    counts.unit_bytes counts.instance_bytes counts.copy_bytes
    counts.output_bytes counts.output_limit counts.longest_instance_code
    counts.longest_name
