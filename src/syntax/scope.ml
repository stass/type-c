(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Names = Map.Make (String)

(* Declarations by name: those of one scope, or the innermost of each
   name among all the scopes visible at a point. *)
type ('ordinary, 'tag) frame = {
  ordinary : 'ordinary Names.t;
  tags : 'tag Names.t;
}

(* An open scope: what it declares, what is visible in it, which is
   what it declares over what is visible around it, and its depth.
   Keeping [visible] and [depth] makes a lookup and the depth cost the
   same at any depth, so that a long chain of nested statements, which
   the parser reads in a loop, takes linear time. *)
type ('ordinary, 'tag) level = {
  declared : ('ordinary, 'tag) frame;
  visible : ('ordinary, 'tag) frame;
  depth : int;
}

(* The innermost scope first; never empty, as file scope is last. *)
type ('ordinary, 'tag) t = ('ordinary, 'tag) level list

let empty_frame = { ordinary = Names.empty; tags = Names.empty }
let file = [ { declared = empty_frame; visible = empty_frame; depth = 1 } ]

let innermost = function
  | level :: _ -> level
  | [] -> invalid_arg "Scope.innermost"

(* Only what the universe makes visible stays: its levels are not
   scopes of the unit, so file scope is still the outermost one. *)
let file_within universe =
  [
    {
      declared = empty_frame;
      visible = (innermost universe).visible;
      depth = 1;
    };
  ]

let enter scopes =
  let around = innermost scopes in
  { declared = empty_frame; visible = around.visible; depth = around.depth + 1 }
  :: scopes

let is_file = function
  | [ _ ] -> true
  | _ -> false

let depth scopes = (innermost scopes).depth

(* [inner]'s declarations, hiding those of [outer] of the same name. *)
let hiding outer inner =
  Names.union (fun _ declaration _hidden -> Some declaration) inner outer

let reenter outer ~inner =
  let declared = (innermost inner).declared in
  let around = innermost outer in
  let visible =
    {
      ordinary = hiding around.visible.ordinary declared.ordinary;
      tags = hiding around.visible.tags declared.tags;
    }
  in
  { declared; visible; depth = around.depth + 1 } :: outer

let replace_innermost scopes level =
  match scopes with
  | _ :: outer -> level :: outer
  | [] -> invalid_arg "Scope.replace_innermost"

let find scopes name = Names.find_opt name (innermost scopes).visible.ordinary

let find_in_innermost scopes name =
  Names.find_opt name (innermost scopes).declared.ordinary

let declared_in_innermost scopes =
  Names.bindings (innermost scopes).declared.ordinary

let add_ordinary name binding frame =
  { frame with ordinary = Names.add name binding frame.ordinary }

let declare scopes name binding =
  let level = innermost scopes in
  replace_innermost scopes
    {
      level with
      declared = add_ordinary name binding level.declared;
      visible = add_ordinary name binding level.visible;
    }

let find_tag scopes name = Names.find_opt name (innermost scopes).visible.tags

let find_tag_in_innermost scopes name =
  Names.find_opt name (innermost scopes).declared.tags

let tags_declared_in_innermost scopes =
  Names.bindings (innermost scopes).declared.tags

let add_tag name binding frame =
  { frame with tags = Names.add name binding frame.tags }

let declare_tag scopes name binding =
  let level = innermost scopes in
  replace_innermost scopes
    {
      level with
      declared = add_tag name binding level.declared;
      visible = add_tag name binding level.visible;
    }
