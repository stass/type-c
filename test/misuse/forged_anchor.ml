(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax the private type Typec_syntax.Tree.anchor *)

(* An anchor at any token, which could stand inside an expression that
   the pragma lines of a packing bracket break: only the parser makes an
   anchor, in front of an external declaration or after the forward
   declaration of a type declaration, so this must not compile. *)

let anchor : Tree.anchor = { before = 7 }
