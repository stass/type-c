(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax module Typec_syntax__Spanned, which is missing *)

(* A node made outside the parser, with a counter of its own that knows
   none of the nodes of the parser's tree, so its height escapes the
   bound on the depth: Spanned is private to the library, so this must
   not compile. *)

let outside =
  Spanned.make (Spanned.counter ~max_depth:1) { first = 0; last = 0 } ()
