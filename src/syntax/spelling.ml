(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type type_name = string
type constructor = string

let begins_with_underscore_and_uppercase spelling =
  String.length spelling >= 2
  && spelling.[0] = '_'
  && 'A' <= spelling.[1]
  && spelling.[1] <= 'Z'

let is_reserved_for_any_use spelling =
  String.starts_with ~prefix:"__" spelling
  || begins_with_underscore_and_uppercase spelling

let has_double_underscore spelling =
  let last = String.length spelling - 1 in
  let rec from index =
    if index >= last then false
    else if spelling.[index] = '_' && spelling.[index + 1] = '_' then true
    else from (index + 1)
  in
  from 0

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
