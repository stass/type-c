(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Parsing the tokens of preprocessed text into a {!Tree.translation_unit}
    (design 13.3): recursive descent over the complete token array, with
    the scope of typedef names fed back into the grammar through scope
    rules ({!scopes}) that the parser drives.

    The grammar is C11's declarations, expressions and statements (C11
    6.5, 6.7, 6.8, 6.9) and the GNU profile's (design 13.3). The body of
    a function that a system header defines is matched brace for brace
    and kept as a span, and so are the arguments of an attribute. A
    construct outside them, such as a GNU block literal ([^{ ... }]), is
    an error that names the token where it starts.

    Pragma tokens ([#pragma] lines, including those that [_Pragma] writes
    in the middle of an expression, and [#pragma typec] lines) are not
    part of the grammar: the parser passes over them, and the node around
    them holds them in its span, so emission keeps them in place.

    Parsing takes time linear in the number of tokens, up to a logarithmic
    factor for typedef names, and its recursion is bounded by
    {!max_nesting}. *)

open Typec_cpp

(** Why the tokens are not a C11 translation unit: the presumed location
    of the token where parsing stopped, and a message that names what the
    grammar expected there and the token it found. *)
type error = Reader.error = { location : Location.t; message : string }

val max_nesting : int
(** The most brackets ([(], [[], [{]) and conditional operators that the
    parser accepts open at once; one more is an error. *)

(** A declaration that the parser hands to the scope rules where the
    name it declares, if it has one, enters scope (C11 6.2.1p7). *)
type scoped_declaration =
  | Declarator of { specifiers : Tree.specifiers; declarator : Tree.declarator }
      (** at the end of a declarator, before its initialiser, or before
          the body of a function definition *)
  | Enumerator of Tree.enumerator  (** at the end of the enumerator *)
  | Parameter of Tree.parameter
      (** at the end of a parameter declaration, named or not *)
  | Parameter_name of Tree.identifier  (** in an identifier list *)

val scoped_name : scoped_declaration -> string option
(** The identifier that a declaration puts in scope, if it has one. *)

(** The scope rules (C11 6.2.1) as the parser drives them: the parser
    alone decides where a scope begins and ends and when a declaration
    enters one; the rules decide what a declaration binds and which
    names are typedef names, which the grammar needs. A ['scope] is the
    stack of scopes open at a point. It is persistent: the parser saves
    the value on entering a scope and goes back to it on leaving. The
    functions have no effects: the parser may call them to look ahead
    and drop the result, as where an old-style definition's declaration
    list may begin. *)
type 'scope scopes = {
  file : 'scope;  (** file scope before the first token *)
  enter : 'scope -> 'scope;  (** a block or prototype scope inside *)
  reenter : 'scope -> inner:'scope -> 'scope;
      (** [reenter outer ~inner] is the innermost scope of [inner] inside
          [outer]: the body of a function definition is its parameter
          list's scope (6.2.1p4), not one nested in it, inside the scope
          where the function is declared. *)
  declare : 'scope -> scoped_declaration -> 'scope;
  is_typedef_name : 'scope -> string -> bool;
}

val parse_with :
  'scope scopes -> Reader.t -> (Tree.translation_unit, error) result

val parse : Reader.t -> (Tree.translation_unit, error) result
(** [parse_with] the syntactic scope rules: a name is a typedef name if
    the specifiers of its declaration hold [typedef], or if GCC and Clang
    declare it before the first token ({!Builtin_typedef.table}). *)

val error_message : error -> string
(** ["file:line: message"], as {!Reader.error_message}. *)
