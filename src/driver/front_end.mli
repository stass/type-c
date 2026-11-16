(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The stages of [typec] between reading the preprocessed text and
    emitting it (design 13.1): parsing, then the declarations, which type
    each function body where its definition stands, then lowering. This
    is the one place where [typec] chains them. *)

val lower :
  Typec_syntax.Keyword_set.dialect ->
  Typec_sema.Target.t ->
  Typec_cpp.Reader.t ->
  (Typec_emit.Emitter.lowered, Typec_cpp.Reader.error) result
(** [lower dialect target text] parses [text] with the keywords that the
    backend of [target] reads in [dialect], reads its declarations and
    types its expressions for [target], and gives the edits that lower
    its Type-C constructs with the assertions of the types of [target]
    that they assume ({!Typec_emit.Assumptions}), or the first error of
    either stage. A text without Type-C constructs has no edits and no
    assertions. It has no effects. *)
