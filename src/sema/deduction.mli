(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The deduction of the type arguments of a call of a generic function
    (design 7.2 rules 1 to 3), and the substitution of type arguments
    for the type parameters in a type. A type parameter is the opaque
    record that the reading of the generic declares for it (design 7.1
    rule 2). *)

(** The type parameters of one generic function, in order, and the type
    deduced for each so far. *)
type t

val start : Ctype.record_tag list -> t
(** The type parameters, none of them deduced. *)

val explicit : Ctype.record_tag list -> Ctype.t list -> t
(** The type parameters with the type arguments of an explicit instance,
    one for each. *)

val is_deduced_in : t -> Ctype.t -> bool
(** Whether every type parameter that the type mentions is deduced. *)

(** Why an argument's type does not match its parameter's type. *)
type failure =
  | Mismatch of { parameter_part : Ctype.t; argument_part : Ctype.t }
      (** the parts of the two types where they differ (rule 2) *)
  | Twice of { first : Ctype.t; second : Ctype.t }
      (** a type parameter that the parameter type holds twice meets two
          different types (rule 2) *)
  | Unknown_part of Unknown.t
      (** a part that decides the match is a type that typec does not
          compute *)
  | Not_built of Ctype.error
      (** a substituted type that C does not allow, such as one too
          large *)

val deduce :
  t -> parameter:Ctype.t -> argument:Ctype.t -> (t, failure) result
(** Matches the type of an argument, after lvalue, array and function
    conversion, structurally against the type of its parameter (rule 2),
    and deduces each type parameter that the parameter type holds as
    the part of the argument's type at its place. *)

val arguments : t -> (Ctype.t list, Ctype.record_tag) result
(** The type arguments, in order, or the first type parameter that is
    not deduced (rule 3). *)

val substitute :
  Ctype.tags ->
  apply:(Typec_syntax.Spelling.type_name -> Ctype.t list -> Ctype.t) ->
  complete:(Ctype.t -> unit) ->
  t ->
  Ctype.t ->
  (Ctype.t, failure) result
(** The type with each deduced type parameter replaced by its type
    argument, qualifiers kept. An instance of a generic type whose
    arguments mention a type parameter is [apply] of its generic to its
    substituted argument types, and the element of an array is
    [complete]d before the array is built. *)

val newly_deduced : before:t -> after:t -> Ctype.t list
(** The types that [after], a deduction from [before], deduces for type
    parameters that [before] leaves undeduced, in order. *)
