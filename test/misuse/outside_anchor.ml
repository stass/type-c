(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax module Typec_syntax__Anchor, which is missing *)

(* An anchor at any token, made by the constructor that the parser
   uses: Anchor is private to the library, so this must not compile. *)

let anchor = Anchor.before 7
