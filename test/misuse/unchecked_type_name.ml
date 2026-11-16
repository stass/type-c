(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax Typec_syntax.Spelling.type_name *)

(* A derived name made from a type name that no spelling check passed,
   which would derive the reserved [_Static_tag] (design 3.1 rule 6):
   Spelling.type_name is private, so this must not compile. *)

let tag = Tree.enum_tag_name "_Static"
