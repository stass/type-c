(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type tree = { archive : string; dir : string }
type program = { name : string; units : string list }
type suite = Own | Substitute of string
type place = Here | Not_here of string
type test = { script : string; suite : suite; place : place }

type t = {
  trees : tree list;
  cflags : string list;
  libs : string list;
  prepare : string option;
  library : string list;
  programs : program list;
  tests : test list;
}

let units recipe =
  let seen = Hashtbl.create 64 in
  let first_time unit =
    let fresh = not (Hashtbl.mem seen unit) in
    Hashtbl.replace seen unit ();
    fresh
  in
  let program_units = List.concat_map (fun p -> p.units) recipe.programs in
  List.filter first_time (recipe.library @ program_units)

(* The message of the first line a recipe gets wrong. *)
exception Invalid of string

let invalid fmt = Printf.ksprintf (fun message -> raise (Invalid message)) fmt

(* A path stays inside the build tree, because the runner writes next to
   every unit and removes the tree before each build. *)
let relative_path path =
  let components = String.split_on_char '/' path in
  if path = "" || path.[0] = '/' || List.mem ".." components then
    invalid "%S is not a relative path inside the tree" path;
  path

let plain_name name =
  if name = "" || name.[0] = '.' || String.contains name '/' then
    invalid "%S is not a plain file name" name;
  name

let unit_path path =
  if not (Filename.check_suffix path ".c") then
    invalid "the unit %S does not end in .c" path;
  relative_path path

(* The runner builds at -O2 without debug information (plan 0.11, gate
   2), so a recipe cannot choose either. *)
let compiler_option word =
  let starts prefix = String.starts_with ~prefix word in
  if starts "-O" || starts "-g" then
    invalid "%S: the runner chooses optimisation and debug options" word;
  word

let words line =
  String.map (fun c -> if c = '\t' then ' ' else c) line
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")

(* The keyword, and the host it is limited to, if any. *)
let split_keyword keyword =
  match String.index_opt keyword '@' with
  | None -> (keyword, None)
  | Some at ->
      let after = String.length keyword - at - 1 in
      (String.sub keyword 0 at, Some (String.sub keyword (at + 1) after))

let only_once what previous value =
  if previous <> None then invalid "a second %s line" what;
  Some value

(* A HOST is SYSTEM or SYSTEM/MACHINE, matched against uname -s and -m. *)
let names_host ~system ~machine host =
  match String.split_on_char '/' host with
  | [ s ] when s <> "" -> s = system
  | [ s; m ] when s <> "" && m <> "" -> s = system && m = machine
  | _ -> invalid "%S is not a host, SYSTEM or SYSTEM/MACHINE" host

let place_of ~system ~machine = function
  | None -> Here
  | Some host when names_host ~system ~machine host -> Here
  | Some host -> Not_here host

let test_line place = function
  | [ "own"; script ] -> { script = plain_name script; suite = Own; place }
  | "substitute" :: script :: (_ :: _ as description) ->
      let suite = Substitute (String.concat " " description) in
      { script = plain_name script; suite; place }
  | (("own" | "substitute") as kind) :: _ ->
      invalid "wrong number of words after test %s" kind
  | _ ->
      invalid
        "a test line is \"test own SCRIPT\" or \"test substitute SCRIPT \
         DESCRIPTION...\""

(* Lists accumulate in reverse and are put in order by [finish]. *)
let add_line ~system ~machine recipe line =
  match words line with
  | [] -> recipe
  | first :: _ when first.[0] = '#' -> recipe
  | keyword :: rest -> (
      let keyword, only_on = split_keyword keyword in
      let place = place_of ~system ~machine only_on in
      match (keyword, rest) with
      | "cflags", options ->
          (* Checked on every host, so a recipe is valid on all or none. *)
          let options = List.map compiler_option options in
          if place <> Here then recipe
          else { recipe with cflags = List.rev_append options recipe.cflags }
      | "libs", _ when place <> Here -> recipe
      | "libs", options ->
          { recipe with libs = List.rev_append options recipe.libs }
      | "test", suite_words ->
          let test = test_line place suite_words in
          { recipe with tests = test :: recipe.tests }
      | _, _ when only_on <> None ->
          invalid "only cflags, libs and test can be limited to a host"
      | "tree", [ archive ] ->
          let tree = { archive = plain_name archive; dir = "." } in
          { recipe with trees = tree :: recipe.trees }
      | "tree", [ archive; dir ] ->
          let dir = relative_path dir in
          let tree = { archive = plain_name archive; dir } in
          { recipe with trees = tree :: recipe.trees }
      | "prepare", [ script ] ->
          let script = plain_name script in
          { recipe with prepare = only_once "prepare" recipe.prepare script }
      | "library", units ->
          let units = List.map unit_path units in
          { recipe with library = List.rev_append units recipe.library }
      | "program", name :: (_ :: _ as units) ->
          if List.exists (fun p -> p.name = name) recipe.programs then
            invalid "a second program %S; list its units on one line" name;
          let program =
            { name = relative_path name; units = List.map unit_path units }
          in
          { recipe with programs = program :: recipe.programs }
      | ("tree" | "prepare" | "program"), _ ->
          invalid "wrong number of words after %s" keyword
      | _, _ -> invalid "unknown keyword %S" keyword)

let empty =
  {
    trees = [];
    cflags = [];
    libs = [];
    prepare = None;
    library = [];
    programs = [];
    tests = [];
  }

let finish recipe =
  if recipe.trees = [] then invalid "no tree line";
  if recipe.programs = [] then invalid "no program line";
  if recipe.tests = [] then invalid "no test line";
  {
    recipe with
    trees = List.rev recipe.trees;
    cflags = List.rev recipe.cflags;
    libs = List.rev recipe.libs;
    library = List.rev recipe.library;
    programs = List.rev recipe.programs;
    tests = List.rev recipe.tests;
  }

let read_lines path =
  In_channel.with_open_text path In_channel.input_all
  |> String.split_on_char '\n'

let read ~system ~machine path =
  match read_lines path with
  | exception Sys_error message -> Error message
  | lines -> (
      let line_number = ref 0 in
      let add recipe line =
        incr line_number;
        add_line ~system ~machine recipe line
      in
      match List.fold_left add empty lines with
      | exception Invalid message ->
          Error (Printf.sprintf "%s:%d: %s" path !line_number message)
      | recipe -> (
          match finish recipe with
          | recipe -> Ok recipe
          | exception Invalid message ->
              Error (Printf.sprintf "%s: %s" path message)))
