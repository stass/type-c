(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit Declarations.unit_text is not compatible with type *)

(* Declarations read for a unit lowered as a header, which would write
   the definition of each instance without its guard and with no named
   instance defined at the end: the product is a type parameter of the
   declarations, so this must not compile. *)

let lower target text scopes =
  match
    Typec_sema.Declarations.read target
      ~product:Typec_sema.Declarations.Unit_text text scopes
  with
  | Ok declarations ->
      Lowering.header_text text ~target ~trap:Trap.builtin
        ~header_module:"m" declarations
  | Error error -> Error error
