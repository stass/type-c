(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The stages of [typec] between reading the preprocessed text and
    emitting it (design 13.1): parsing, then the declarations, which type
    each function body where its definition stands, then lowering. This
    is the one place where [typec] chains them. *)

(** The slice tests that lowering writes (design section 8 rule 9, P28),
    each source site once, however many copies of a deferred statement
    hold it; an instance of a generic function counts its own. *)
type slice_counts = {
  indexes : int;
      (** the indexes of a slice that C evaluates, which lowering
          writes with a test *)
  subs : int;  (** the same for [slice_sub] *)
  conversions : int;
      (** the same for a conversion of a slice to one of const elements *)
  untested : int;
      (** the indexes, [slice_sub]s and conversions that C does not
          evaluate, which have no test and stand wherever an expression
          does *)
  late_calls : int;
      (** the tested indexes and [slice_sub]s with a call or a statement
          expression in an operand after the first, which a call that
          returns twice may resume (section 8 rule 10); a bound, since
          the operands are read as written, so that one C does not
          evaluate counts and a bound of a variable length array does
          not *)
}

(** The preludes of the holders of a [try] that a unit and the instances
    it uses hold (design 5.1 rule 3, P33). *)
type try_counts = {
  holders : int;  (** the holders that hold a [try] *)
  tries : int;  (** the [try] expressions of all of them *)
  first_operands : int;
      (** the hoisted operands that are no [try]'s own: the first operands
          of [&&], [||] and a conditional operator, and the left operands
          of a comma *)
  conditioned : int;
      (** the hoisted operands that stand under a condition, whose
          prelude is written under an [if] *)
  multiple : int;
      (** the holders with more than one hoisted operand, whose prelude
          is more than the declaration of one value *)
}

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
  slices : slice_counts;
      (** the slice tests of the unit and of each instance it uses *)
  selection : Typec_sema.Selection.size;
      (** the most steps, nodes and depth that building the selection
          tree of one match or test of the unit or of an instance took
          (design 4.7 rule 10, P32), each the most over all of them, so
          that the three need not be of one tree; zeros where there is
          none *)
  preludes : try_counts;
      (** the holders of a [try] of the unit and of each instance it
          uses, which the measurements of P33 to P35 read *)
}

val lower :
  Typec_syntax.Keyword_set.dialect ->
  Typec_sema.Target.t ->
  trap:Typec_emit.Trap.t ->
  Typec_cpp.Reader.t ->
  (Typec_emit.Emitter.lowered * counts, Typec_cpp.Reader.error) result
(** [lower dialect target ~trap text] parses [text] with the keywords
    that the backend of [target] reads in [dialect], and reads its
    declarations and types its expressions for [target]. It gives the
    edits that lower its Type-C constructs, whose traps call as [trap]
    does, with [trap] and with the assertions of the types of [target]
    that the edits assume ({!Typec_emit.Assumptions}); and the unit's
    counts. Or it gives the first error of either stage. A text without
    Type-C constructs has no edits and no assertions. It has no
    effects. *)

val counts_line : counts -> string
(** The counts as one line of [name=value] fields, in the order of
    {!counts}, without a line break. *)
