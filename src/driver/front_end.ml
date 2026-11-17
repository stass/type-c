(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Declarations = Typec_sema.Declarations
module Expressions = Typec_sema.Expressions
module Selection = Typec_sema.Selection

let ( let* ) = Result.bind

(* How many slice tests of each form a unit and its instances hold. *)
type slice_counts = {
  indexes : int;
  subs : int;
  conversions : int;
  untested : int;
  late_calls : int;
}

type counts = {
  unit_bytes : int;
  instance_bytes : int;
  copy_bytes : int;
  output_bytes : int;
  output_limit : int;
  longest_instance_code : int;
  longest_name : int;
  slices : slice_counts;
  selection : Selection.size;
}

let count_slice_checks checks =
  let count counts ((check : Expressions.slice_check), form) =
    match (form, check.check) with
    | Expressions.Untested, _ ->
        { counts with untested = counts.untested + 1 }
    | Tested _, Index _ ->
        { counts with indexes = counts.indexes + 1;
          late_calls = counts.late_calls + Bool.to_int check.late_call }
    | Tested _, Sub _ ->
        { counts with subs = counts.subs + 1;
          late_calls = counts.late_calls + Bool.to_int check.late_call }
    | Tested _, Conversion _ ->
        { counts with conversions = counts.conversions + 1 }
  in
  List.fold_left count
    { indexes = 0; subs = 0; conversions = 0; untested = 0; late_calls = 0 }
    checks

(* The most steps, nodes and depth that building the tree of one match
   or test took, each over them all; the three need not be of one tree. *)
let largest_selection sizes =
  let most (largest : Selection.size) (size : Selection.size) =
    { Selection.steps = max largest.steps size.steps;
      nodes = max largest.nodes size.nodes;
      depth = max largest.depth size.depth }
  in
  List.fold_left most { steps = 0; nodes = 0; depth = 0 } sizes

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
  let slices = count_slice_checks (Declarations.slice_checks declarations) in
  let counts =
    {
      unit_bytes = Typec_cpp.Reader.length text;
      instance_bytes = Declarations.instance_bytes declarations;
      copy_bytes = Declarations.copy_bytes declarations;
      output_bytes;
      output_limit = Typec_sema.Output_limit.of_unit text;
      longest_instance_code = Declarations.longest_instance_code declarations;
      longest_name = scopes.longest_type_name;
      slices;
      selection =
        largest_selection (Declarations.selection_sizes declarations);
    }
  in
  Ok
    ({ Typec_emit.Emitter.edits; assertions = assertions target edits }, counts)

let counts_line counts =
  Printf.sprintf
    "unit_bytes=%d instance_bytes=%d copy_bytes=%d output_bytes=%d \
     output_limit=%d longest_instance_code=%d longest_name=%d \
     slice_indexes=%d slice_subs=%d slice_conversions=%d \
     slice_untested=%d slice_late_calls=%d selection_steps=%d \
     selection_nodes=%d selection_depth=%d"
    counts.unit_bytes counts.instance_bytes counts.copy_bytes
    counts.output_bytes counts.output_limit counts.longest_instance_code
    counts.longest_name counts.slices.indexes counts.slices.subs
    counts.slices.conversions counts.slices.untested
    counts.slices.late_calls counts.selection.steps counts.selection.nodes
    counts.selection.depth
