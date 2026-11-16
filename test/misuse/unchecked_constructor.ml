(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax Typec_syntax.Spelling.constructor *)

(* An enumerator made from a constructor name that no spelling check
   passed, which would derive the [v___x] of an instance name (design 3.2
   rule 2): Spelling.constructor is private, so this must not compile. *)

let enumerator (variant : Spelling.c_name) =
  Tree.enumerator_name ~variant "__x"
