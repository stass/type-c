(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax Typec_syntax.Spelling.c_name *)

(* A derived name made from a name that is neither a checked type name
   nor an instance name, which would derive the reserved [_Static_tag]
   (design 3.1 rule 6): Spelling.c_name is private, so this must not
   compile. *)

let tag = Tree.enum_tag_name "_Static"
