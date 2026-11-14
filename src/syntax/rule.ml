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
  | Claimed_tag
      (** A tag that a type declaration claims, declared otherwise in its
          scope or named in Type-C text (design 10.1 rule 6, 10.2). *)
  | Not_implemented of { section : string; package : string }
      (** A construct of design [section] that work [package] implements. *)

let clause = function
  | Generated_name -> "design 2.3"
  | Own_name -> "design 3.1 rule 2"
  | One_definition -> "design 3.1 rule 5"
  | Claimed_tag -> "design 10.2"
  | Not_implemented { section; package } ->
      Printf.sprintf "design %s; work package %s" section package

(** [message rule text] is the diagnostic [text] about [rule], which it
    follows with the clause that states the rule. *)
let message rule text = Printf.sprintf "%s (%s)" text (clause rule)
