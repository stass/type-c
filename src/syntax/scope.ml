(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Names = Map.Make (String)

(* Declarations by name: those of one scope, or the innermost of each
   name among all the scopes visible at a point. *)
type ('ordinary, 'tag) frame = {
  ordinary : 'ordinary Names.t;
  tags : 'tag Names.t;
}

(* An open scope: what it declares, and what is visible in it, which is
   what it declares over what is visible around it. Keeping [visible]
   makes a lookup cost the same at any depth, so that a long chain of
   nested statements, which the parser reads in a loop, takes linear
   time. *)
type ('ordinary, 'tag) level = {
  declared : ('ordinary, 'tag) frame;
  visible : ('ordinary, 'tag) frame;
}

(* The innermost scope first; never empty, as file scope is last. *)
type ('ordinary, 'tag) t = ('ordinary, 'tag) level list

let empty_frame = { ordinary = Names.empty; tags = Names.empty }
let file = [ { declared = empty_frame; visible = empty_frame } ]

let innermost = function
  | level :: _ -> level
  | [] -> invalid_arg "Scope.innermost"

let enter scopes =
  { declared = empty_frame; visible = (innermost scopes).visible } :: scopes

let is_file = function
  | [ _ ] -> true
  | _ -> false

(* [inner]'s declarations, hiding those of [outer] of the same name. *)
let hiding outer inner =
  Names.union (fun _ declaration _hidden -> Some declaration) inner outer

let reenter outer ~inner =
  let declared = (innermost inner).declared in
  let around = (innermost outer).visible in
  let visible =
    {
      ordinary = hiding around.ordinary declared.ordinary;
      tags = hiding around.tags declared.tags;
    }
  in
  { declared; visible } :: outer

let replace_innermost scopes level =
  match scopes with
  | _ :: outer -> level :: outer
  | [] -> invalid_arg "Scope.replace_innermost"

let find scopes name = Names.find_opt name (innermost scopes).visible.ordinary

let find_in_innermost scopes name =
  Names.find_opt name (innermost scopes).declared.ordinary

let add_ordinary name binding frame =
  { frame with ordinary = Names.add name binding frame.ordinary }

let declare scopes name binding =
  let { declared; visible } = innermost scopes in
  replace_innermost scopes
    {
      declared = add_ordinary name binding declared;
      visible = add_ordinary name binding visible;
    }

let find_tag scopes name = Names.find_opt name (innermost scopes).visible.tags

let find_tag_in_innermost scopes name =
  Names.find_opt name (innermost scopes).declared.tags

let add_tag name binding frame =
  { frame with tags = Names.add name binding frame.tags }

let declare_tag scopes name binding =
  let { declared; visible } = innermost scopes in
  replace_innermost scopes
    {
      declared = add_tag name binding declared;
      visible = add_tag name binding visible;
    }
