(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type kind = Unknown_object | Unknown_function | Object_or_function
type cause = Not_typed | Typed_differently

type t = {
  construct : string;
  location : Typec_cpp.Location.t;
  kind : kind;
  cause : cause;
}

type 'a answer = Answer of 'a | Depends_on of t
