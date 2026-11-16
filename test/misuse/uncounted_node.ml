(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_syntax private type Typec_syntax.Tree.expression *)

(* Nodes wrapped in the span of the node they wrap, which the parser's
   count of the depth of the tree would not see, so a loop could make a
   tree deeper than Parser.max_depth: Tree.spanned is private, so this
   must not compile. *)

let rec wrapped (inner : Tree.expression) times : Tree.expression =
  if times = 0 then inner
  else wrapped { span = inner.span; node = Parenthesized inner } (times - 1)
