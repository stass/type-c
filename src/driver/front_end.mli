(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The stages of [typec] between reading the preprocessed text and
    emitting it (design 13.1): parsing, then the declarations, which type
    each function body where its definition stands, then lowering. This
    is the one place where [typec] chains them. *)

(** What a unit counts against the translation limits of design 3.5
    rule 7, which [--stats] reports for measurement (design P30). *)
type counts = {
  unit_bytes : int;  (** of the preprocessed text *)
  instance_bytes : int;
      (** charged to the instance budget by the readings for instances *)
  copy_bytes : int;
      (** charged to the output limit by the front end's copies of
          deferred statements, which [output_bytes] counts again *)
  output_bytes : int;
      (** charged to the output limit by lowering, the unit's own text
          included *)
  output_limit : int;  (** the output limit of the unit *)
  longest_instance_code : int;
      (** the most bytes of the code of one instance, its generic's name
          and the encodings of its arguments, which the bound on
          encodings holds ({!Typec_sema.Encoding.code_length}) *)
  longest_name : int;
      (** the bytes of the longest name of a type declaration or a
          generic function, those of the universe text included *)
}

val lower :
  Typec_syntax.Keyword_set.dialect ->
  Typec_sema.Target.t ->
  Typec_cpp.Reader.t ->
  (Typec_emit.Emitter.lowered * counts, Typec_cpp.Reader.error) result
(** [lower dialect target text] parses [text] with the keywords that the
    backend of [target] reads in [dialect], reads its declarations and
    types its expressions for [target], and gives the edits that lower
    its Type-C constructs with the assertions of the types of [target]
    that they assume ({!Typec_emit.Assumptions}), and the unit's counts,
    or the first error of either stage. A text without Type-C constructs
    has no edits and no assertions. It has no effects. *)

val counts_line : counts -> string
(** The counts as one line of [name=value] fields, in the order of
    {!counts}, without a line break. *)
