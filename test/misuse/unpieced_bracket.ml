(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit expected of type Typec_emit.Emitter.piece list *)

(* Raw text in a packing bracket, which could hold a '#pragma pack' that
   the probe of design 10.3 does not see: a bracket holds pieces, each a
   token that is no pragma line or typec's text that holds none, so this
   must not compile. *)

let text = Emitter.Bracketed "#pragma pack(1)\nstruct s { int n; };"
