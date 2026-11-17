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
    where a [typedef] alone would name one of an enclosing block.

    A generic's definition is removed at its own place, and each
    application becomes the name of its instance. The texts of the
    instances (design 10.3) are written from the tokens of the
    definitions, as moved text in packing brackets, at the anchors that
    their placements name. *)

val edits :
  Typec_cpp.Reader.t ->
  Typec_sema.Declarations.t ->
  (Emitter.edit list * int, Typec_cpp.Reader.error) result
(** [edits text declarations] lowers the unit [text] that [declarations]
    read: its type declarations, constructor expressions, match
    statements, single-pattern tests and answered constructs, and the
    instances that it uses. An answered [__builtin_types_compatible_p]
    becomes its answer. An answered generic selection keeps its tokens,
    but the type names of its associations become types that steer the
    backend to typec's answer, and its controlling expression is wrapped
    to have the selected one; the edits of the tokens dropped are
    discarded.

    Every piece and edit is made for one {!Emitter.output}, so the
    lowered text is held to the output limit of design 3.5 rule 7 as it
    is made, and the edits come with the bytes charged to it; the error
    is at the first that would pass it. The texts of the instances are
    made first, in the order of their placements. *)
