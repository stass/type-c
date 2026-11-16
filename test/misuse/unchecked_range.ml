(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A range made without Reader.range, so nothing checks that it lies
   within the tokens: Reader.range is private, so this must not
   compile. *)

let before_the_tokens : Reader.range = { first = -1; count = 1 }
