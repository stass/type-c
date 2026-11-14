(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The expressions of a translation unit, read from the JSON that
    [clang -Xclang -ast-dump=json] prints for a preprocessed file.

    The JSON is untrusted: it is read one top-level declaration at a
    time, and refused when it nests deeper than {!max_depth}, a
    declaration or another field of the translation unit takes more
    than {!max_declaration_bytes}, or it holds a comment. Every location
    must be in the preprocessed file itself, outside any macro
    expansion, since the records key expressions by their offsets in
    it. *)

val max_depth : int
(** The deepest nesting of JSON arrays and objects accepted. *)

val max_declaration_bytes : int
(** The most bytes, not counting the blanks between tokens, that one
    top-level declaration may take. *)

type summary = {
  expressions : int;  (** the expressions recorded *)
  without_range : int;
      (** the expressions with no source range, such as the implicit
          initialisers of the members an initialiser list leaves out,
          which are not recorded *)
}

val read :
  input:string ->
  input_size:int ->
  in_channel ->
  (Record.t -> unit) ->
  (summary, string) result
(** [read ~input ~input_size channel emit] reads the JSON from [channel]
    to its end and calls [emit] on each expression of the preprocessed
    file named [input], as Clang names it, of [input_size] bytes. The
    records come in the order of Clang's dump, each node before the nodes
    inside it: of the nodes that share a source range, such as an
    implicit conversion and its operand, the outermost comes first. *)
