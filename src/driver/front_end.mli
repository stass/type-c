(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The stages of [typec] between reading the preprocessed text and
    emitting it (design 13.1): parsing, then the declarations, which type
    each function body where its definition stands. This is the one place
    where [typec] chains them. *)

val check :
  Typec_syntax.Keyword_set.dialect ->
  Typec_sema.Target.t ->
  Typec_cpp.Reader.t ->
  (unit, Typec_cpp.Reader.error) result
(** [check dialect target text] parses [text] with the keywords that the
    backend of [target] reads in [dialect], reads its declarations and
    types its expressions for [target], and gives the first error of
    either stage. It has no effects. *)
