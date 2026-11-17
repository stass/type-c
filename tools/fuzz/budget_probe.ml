(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Prints a unit that nearly fills the instance budget of design 3.5
   rule 7 and is lowered, which takes some 23 million words of heap, far
   past the linear bounds of the reader and the parser, so that seeds.t
   can show which target bounds the work of the declaration reader. It
   starts with the line marker the reader needs, as a seed does. *)

(* Eight aliases deep, 49 structures is the most the budget accepts:
   a 50th takes the instances past it, and the unit is refused before
   lowering runs. *)
let alias_depth = 8
let structures = 49

let () =
  print_string "# 1 \"probe.tc\"\n";
  print_string
    (Typec_test_support.Budget_probes.aliases_over_structures alias_depth
       structures)
