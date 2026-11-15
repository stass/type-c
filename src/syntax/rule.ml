(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The rules of the design that typec enforces on Type-C constructs, and
    the constructs that it refuses because a later work package of the
    plan implements them. Every diagnostic about either is made by
    {!message}, the one place where work package 1.8 gives each rule its
    stable code. *)

type t =
  | Generated_name
      (** An identifier that begins with [__tc_] (design 2.3). *)
  | Own_name
      (** A definition that uses the name it defines, other than a
          structure or union specifier (design 3.1 rule 2). *)
  | One_definition
      (** A name declared twice in one scope where either is a type
          declaration (design 3.1 rule 5). *)
  | Claimed_name
      (** A tag or enumerator that a type declaration claims for the C
          it lowers to, declared otherwise in its scope or named in
          Type-C text (design 10.1 rule 6, 10.2). *)
  | Duplicate_constructor
      (** Two constructors of one variant with one name (design 3.2
          rule 2). *)
  | Field_type
      (** A field of a constructor whose type is not a value type (design
          3.2 rules 4 and 5). *)
  | Variant_operation
      (** An operation on a variant in Type-C text other than those that
          design 3.2 rule 6 allows. *)
  | Zero_value
      (** A braced initialiser of a variant other than [{0}] in Type-C
          text (design 3.2 rule 7). *)
  | Constructor_expression
      (** A constructor expression that names no constructor, or whose
          arguments do not match its fields (design 3.3). *)
  | Distinct_representation
      (** A distinct type over a type that is no unqualified arithmetic or
          pointer type (design 3.4). *)
  | Distinct_operation
      (** An operation on a value of a distinct type in Type-C text that
          the table of design 3.4 does not allow. *)
  | Distinct_conversion
      (** An implicit conversion to or from a distinct type in Type-C text
          (design 3.4). *)
  | Match_scrutinee
      (** A match whose scrutinee is no complete variant (design 4.1
          rule 1, 4.2 rule 4). *)
  | Arm_form
      (** A match body that is not a sequence of arms, each of labels and
          at least one block item (design 4.1 rule 2). *)
  | Pattern
      (** A pattern that names no constructor of the scrutinee's type, or
          whose sub-patterns do not match its fields (design 4.1 rule 3). *)
  | Shared_arm
      (** An arm of several labels one of which binds (design 4.1
          rule 6). *)
  | Exhaustiveness
      (** A constructor that a match covers twice or not at all (design
          4.2 rule 1). *)
  | Default_arm
      (** A second [default] in a match, or one that covers no constructor
          (design 4.2 rule 2). *)
  | Enclosing_switch_label
      (** A [case] or [default] label inside a match that is not one of
          its own (design 4.3 rule 3). *)
  | Not_implemented of { section : string; package : string }
      (** A construct of design [section] that work [package] implements. *)

let clause = function
  | Generated_name -> "design 2.3"
  | Own_name -> "design 3.1 rule 2"
  | One_definition -> "design 3.1 rule 5"
  | Claimed_name -> "design 10.1 rule 6"
  | Duplicate_constructor -> "design 3.2 rule 2"
  | Field_type -> "design 3.2 rule 4"
  | Variant_operation -> "design 3.2 rule 6"
  | Zero_value -> "design 3.2 rule 7"
  | Constructor_expression -> "design 3.3"
  | Distinct_representation | Distinct_operation | Distinct_conversion ->
      "design 3.4"
  | Match_scrutinee -> "design 4.1 rule 1"
  | Arm_form -> "design 4.1 rule 2"
  | Pattern -> "design 4.1 rule 3"
  | Shared_arm -> "design 4.1 rule 6"
  | Exhaustiveness -> "design 4.2 rule 1"
  | Default_arm -> "design 4.2 rule 2"
  | Enclosing_switch_label -> "design 4.3 rule 3"
  | Not_implemented { section; package } ->
      Printf.sprintf "design %s; work package %s" section package

(** [message rule text] is the diagnostic [text] about [rule], which it
    follows with the clause that states the rule. *)
let message rule text = Printf.sprintf "%s (%s)" text (clause rule)
