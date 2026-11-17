(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit Unbound constructor Trap.Function *)

(* A trap function whose name is not checked as a C identifier, which
   would put other text into the C unquoted (design 10.5): Trap.t is
   abstract and only Trap.calling makes one, so this must not
   compile. *)

let injected : Trap.t = Trap.Function "stop(); exit"
