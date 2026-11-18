(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit Declarations.header_text is not compatible with type *)

(* Declarations read for a header lowered as a unit, which would write
   the definition of each instance without its guard: the product is a
   type parameter of the declarations, so this must not compile. *)

let lower target text scopes =
  match
    Typec_sema.Declarations.read target
      ~product:Typec_sema.Declarations.Header_text text scopes
  with
  | Ok declarations -> Lowering.edits text ~trap:Trap.builtin declarations
  | Error error -> Error error
