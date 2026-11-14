(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

module Names = Map.Make (String)

(* The declarations of one scope. *)
type ('ordinary, 'tag) frame = {
  ordinary : 'ordinary Names.t;
  tags : 'tag Names.t;
}

(* The innermost scope first; never empty, as file scope is last. *)
type ('ordinary, 'tag) t = ('ordinary, 'tag) frame list

let empty_frame = { ordinary = Names.empty; tags = Names.empty }
let file = [ empty_frame ]
let enter scopes = empty_frame :: scopes

let leave = function
  | _ :: (_ :: _ as outer) -> outer
  | [ _ ] | [] -> invalid_arg "Scope.leave: file scope"

let reenter outer ~inner =
  match inner with
  | innermost :: _ -> innermost :: outer
  | [] -> invalid_arg "Scope.reenter"

let is_file_scope = function [ _ ] -> true | _ -> false

let innermost = function
  | frame :: _ -> frame
  | [] -> invalid_arg "Scope.innermost"

let replace_innermost scopes frame =
  match scopes with
  | _ :: outer -> frame :: outer
  | [] -> invalid_arg "Scope.replace_innermost"

let find_in_frames select scopes name =
  List.find_map (fun frame -> Names.find_opt name (select frame)) scopes

let find scopes name = find_in_frames (fun frame -> frame.ordinary) scopes name

let find_in_innermost scopes name =
  Names.find_opt name (innermost scopes).ordinary

let declare scopes name binding =
  let frame = innermost scopes in
  replace_innermost scopes
    { frame with ordinary = Names.add name binding frame.ordinary }

let find_tag scopes name = find_in_frames (fun frame -> frame.tags) scopes name
let find_tag_in_innermost scopes name =
  Names.find_opt name (innermost scopes).tags

let declare_tag scopes name binding =
  let frame = innermost scopes in
  replace_innermost scopes
    { frame with tags = Names.add name binding frame.tags }

let innermost_ordinary scopes = Names.bindings (innermost scopes).ordinary
