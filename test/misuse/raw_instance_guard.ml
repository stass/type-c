(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit Typec_syntax.Spelling.c_name *)

(* A guard of raw text, which would write a line of its own, such as a
   '#pragma pack', into a packing bracket in a header: the guard is made
   from a checked instance name, so this must not compile. *)

let text pieces =
  Emitter.Guarded { instance = "g\n#pragma pack(1)"; pieces }
