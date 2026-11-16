(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax private type Typec_syntax.Rule.diagnostic *)

(* A refusal under a rule of Type-C without the rule's code (design
   13.6): Rule.diagnostic is private, so only Rule.message makes one,
   and this must not compile. *)

let refusal = Rule.Type_c "a match arm whose end can be reached"
