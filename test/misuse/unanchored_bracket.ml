(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit the private type Typec_emit.Emitter.edit *)

(* A packing bracket at any range, which could stand inside an
   expression that its pragma lines break: only Emitter.bracketed makes a
   bracketed edit, at an anchor that the parser makes, so this must not
   compile. *)

let edit range ~location : Emitter.edit =
  { range; location; text = Bracketed [] }
