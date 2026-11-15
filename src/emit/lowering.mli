(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Lowering (design 13.5): the edits that turn the Type-C constructs of
    a translation unit into C11. The C inside a construct, such as the
    type name that an alias stands for, keeps its own tokens (design
    13.4), so an edit replaces only the tokens that Type-C adds, and the
    lines and pragmas between them are kept.

    A type declaration (design 3.1) becomes the declarations of design
    10.1 and 10.2 at its own point: an alias [type N = T;] the typedef
    that declares [N] as [T]; [type N;], and a definition that is a
    structure or union specifier with a body,
    [struct T; typedef struct T N;] before the specifier, whose tag [T]
    is [N] where it has none of its own. The leading [struct T;]
    declares the tag in the scope of the declaration (C11 6.7.2.3p7),
    where a [typedef] alone would name one of an enclosing block. *)

val edits :
  Typec_cpp.Reader.t ->
  Typec_syntax.Tree.type_declaration list ->
  Typec_sema.Expressions.construction list ->
  Typec_sema.Expressions.answered list ->
  Emitter.edit list
(** [edits text declarations constructions answered] lowers
    [declarations], the constructor expressions [constructions] and the
    constructs [answered], parsed from [text], to edits in the order that
    {!Emitter.emit} takes. An answered construct drops its tokens but
    those of the expression it selects, and the edits of the tokens it
    drops are discarded. *)
