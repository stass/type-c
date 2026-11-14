(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** {e Provisional (design 13.3).} A type that typec does not compute, and
    the answer to a question about types that may depend on one, apart
    from {!Ctype} so that the table of what GCC types otherwise
    ({!Backend_difference}), which {!Ctype} asks, can give them. *)

(** What typec knows of a type it does not compute: whether it is a
    function type, which the declarator that gives it decides where there
    is one. *)
type kind =
  | Unknown_object  (** An object type, such as a block pointer. *)
  | Unknown_function
      (** A function type, such as a function that an attribute changes. *)
  | Object_or_function  (** As [typeof] of an expression may give. *)

(** Why typec does not compute a type. *)
type cause =
  | Not_typed  (** typec does not type the construct. *)
  | Typed_differently
      (** The backend, GCC, types the construct otherwise than Clang, whose
          rules typec follows; see {!Backend_difference}. *)

(** A type that typec does not compute: the construct that gives it, as a
    message names it ("a block pointer"), the location of the token that
    starts it, for the error at a point that needs the type, and why. *)
type t = {
  construct : string;
  location : Typec_cpp.Location.t;
  kind : kind;
  cause : cause;
}

(** The answer to a question about a type, or the unknown type it depends
    on. *)
type 'a answer = Answer of 'a | Depends_on of t
