(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type type_name = string
type constructor = string
type c_name = string

let begins_with_underscore_and_uppercase spelling =
  String.length spelling >= 2
  && spelling.[0] = '_'
  && 'A' <= spelling.[1]
  && spelling.[1] <= 'Z'

let is_reserved_for_any_use spelling =
  String.starts_with ~prefix:"__" spelling
  || begins_with_underscore_and_uppercase spelling

(* The [__] that joins a generic to the encodings of an instance's
   arguments (design 10.3), which no type name or constructor holds, so
   that the first one in a name ends the name of its generic. *)
let instance_separator = "__"

(* The index of the first separator in the spelling, if it holds one. *)
let first_separator spelling =
  let width = String.length instance_separator in
  let last = String.length spelling - width in
  let rec from index =
    if index > last then None
    else if String.sub spelling index width = instance_separator then
      Some index
    else from (index + 1)
  in
  from 0

let has_double_underscore spelling = Option.is_some (first_separator spelling)

(* A derived name joins the type name with one [_] to a suffix that holds
   no [__] and does not begin with [_], as [constructor] checks of a
   constructor, so this spelling keeps every derived name from being
   reserved or holding [__], whatever the form of the declaration. *)
let type_name ~at_file_scope spelling =
  if has_double_underscore spelling then Error ", as it contains `__`"
  else if String.ends_with ~suffix:"_" spelling then
    Error ", as it ends with `_`"
  else if begins_with_underscore_and_uppercase spelling then
    Error ", as it begins with `_` and an uppercase letter"
  else if at_file_scope && String.starts_with ~prefix:"_" spelling then
    Error " at file scope, as it begins with `_`"
  else Ok spelling

let constructor spelling =
  if String.starts_with ~prefix:"_" spelling then Error "it begins with `_`"
  else if has_double_underscore spelling then Error "it contains `__`"
  else Ok spelling

let declared type_name = type_name

let instance generic arguments =
  generic ^ instance_separator ^ String.concat "" arguments

(* No type name holds [__], so the first one ends the generic's name. *)
let instance_space spelling =
  match first_separator spelling with
  | Some index when index > 0 -> Some (String.sub spelling 0 index)
  | Some _ | None -> None
