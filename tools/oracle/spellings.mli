(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Clang's spellings of types, read as type names by typec in the file
    scope of the translation unit they come from.

    Each spelling, after {!Normalisation.apply}, becomes the operand of
    [typeof] in a typedef of its own, in a function appended to the text:
    its typedef names and tags are those visible at the end of the unit,
    which are those of the expression unless it is in a block that
    declares one of their names again. A spelling that typec refuses
    there, or whose tag no file-scope declaration declares, names a type
    only the scope of its expression has, and is unresolved. *)

open Typec_sema

type resolution = Resolved of Ctype.t | Unresolved of string  (** why *)

val resolve :
  Typec_syntax.Keyword_set.dialect ->
  Target.t ->
  name:string ->
  string ->
  string list ->
  string ->
  resolution
(** [resolve dialect target ~name text spellings] reads [text], named
    [name], which typec reads alone, with the typedefs appended, and
    gives the resolution of each of [spellings]. It raises [Failure]
    when typec refuses the appended function other than on the line of
    a spelling. *)
