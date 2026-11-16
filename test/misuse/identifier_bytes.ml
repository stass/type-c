(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A stage that takes an identifier's name from the bytes that spell it,
   which may be universal character names: Reader.text is abstract, so
   this must not compile. *)

let name (result : Reader.t) (token : Token.t) =
  String.sub result.text token.start token.length
