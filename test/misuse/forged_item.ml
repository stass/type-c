(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax private type Typec_syntax.Tree.external_declaration *)

(* An external declaration made of a declaration that the parser read
   elsewhere, such as in a block of a statement expression, whose anchor
   would stand inside that expression: only the parser makes an item of
   the unit, so this must not compile. *)

let item (declaration : Tree.declaration) : Tree.external_declaration Tree.item
    =
  { declaration = External_declaration declaration }
