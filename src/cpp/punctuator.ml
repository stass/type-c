(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** A punctuator of C11 6.4.6, named for its primary spelling and not for
    an operator, since one spelling can be several: [Star] multiplies and
    dereferences. A digraph is the punctuator it stands for (6.4.6p3), so
    [<:] is [Left_bracket]; the token keeps the spelling. *)
type t =
  | Left_bracket
  | Right_bracket
  | Left_paren
  | Right_paren
  | Left_brace
  | Right_brace
  | Dot
  | Arrow
  | Plus_plus
  | Minus_minus
  | Ampersand
  | Star
  | Plus
  | Minus
  | Tilde
  | Exclaim
  | Slash
  | Percent
  | Less_less
  | Greater_greater
  | Less
  | Greater
  | Less_equal
  | Greater_equal
  | Equal_equal
  | Exclaim_equal
  | Caret
  | Pipe
  | Ampersand_ampersand
  | Pipe_pipe
  | Question
  | Colon
  | Semicolon
  | Ellipsis
  | Equal
  | Star_equal
  | Slash_equal
  | Percent_equal
  | Plus_equal
  | Minus_equal
  | Less_less_equal
  | Greater_greater_equal
  | Ampersand_equal
  | Caret_equal
  | Pipe_equal
  | Comma
  | Hash
  | Hash_hash

(** Every spelling of a punctuator, digraphs included, with the punctuator
    it is. This is the one mapping from spellings to punctuators: the
    reader matches the text against it. *)
let spellings =
  [
    ("[", Left_bracket);
    ("]", Right_bracket);
    ("(", Left_paren);
    (")", Right_paren);
    ("{", Left_brace);
    ("}", Right_brace);
    (".", Dot);
    ("->", Arrow);
    ("++", Plus_plus);
    ("--", Minus_minus);
    ("&", Ampersand);
    ("*", Star);
    ("+", Plus);
    ("-", Minus);
    ("~", Tilde);
    ("!", Exclaim);
    ("/", Slash);
    ("%", Percent);
    ("<<", Less_less);
    (">>", Greater_greater);
    ("<", Less);
    (">", Greater);
    ("<=", Less_equal);
    (">=", Greater_equal);
    ("==", Equal_equal);
    ("!=", Exclaim_equal);
    ("^", Caret);
    ("|", Pipe);
    ("&&", Ampersand_ampersand);
    ("||", Pipe_pipe);
    ("?", Question);
    (":", Colon);
    (";", Semicolon);
    ("...", Ellipsis);
    ("=", Equal);
    ("*=", Star_equal);
    ("/=", Slash_equal);
    ("%=", Percent_equal);
    ("+=", Plus_equal);
    ("-=", Minus_equal);
    ("<<=", Less_less_equal);
    (">>=", Greater_greater_equal);
    ("&=", Ampersand_equal);
    ("^=", Caret_equal);
    ("|=", Pipe_equal);
    (",", Comma);
    ("#", Hash);
    ("##", Hash_hash);
    ("<:", Left_bracket);
    (":>", Right_bracket);
    ("<%", Left_brace);
    ("%>", Right_brace);
    ("%:", Hash);
    ("%:%:", Hash_hash);
  ]
