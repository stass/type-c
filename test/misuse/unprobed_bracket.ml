(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit Unbound value Emitter.bracket *)

(* A packing bracket written as code, so the unit that holds it would end
   without the probe of design 10.3: only emission of an Emitter.Bracketed
   text writes a bracket, so this must not compile. *)

let code = Emitter.Code (Emitter.bracket "struct s { int n; };")
