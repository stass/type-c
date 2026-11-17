(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The names that the universe scope declares (design 2.3). It encloses
    file scope, so a declaration of the same identifier in any scope
    hides the universe name from that point, under C's scope rules, and
    [int result = f();] keeps its meaning. Each is an ordinary
    identifier to the grammar.

    The generics of the universe scope are the declarations of
    {!Typec_cpp.File.universe_text} (design 3.6), which the parser
    declares in the universe scope where the reader holds that text, as
    it does for every Type-C unit. Each other name gets its meaning in a
    later work package of the plan; until then a use of one is an
    error. *)

(** What typec makes of a universe name. *)
type meaning =
  | Generic  (** declared by the universe text *)
  | Not_implemented of { package : string }
      (** to get its meaning in work [package] of the plan *)

type t = { name : string; meaning : meaning }

(* The universe text declares one generic a line, as [type name(...)],
   so the names come from the text and no list repeats them. *)
let generic_names =
  String.split_on_char '\n' Typec_cpp.File.universe_text
  |> List.filter (fun line -> line <> "")
  |> List.map (fun line -> Scanf.sscanf line "type %[a-z_](" Fun.id)

let generic name = { name; meaning = Generic }

let slice_name name =
  { name; meaning = Not_implemented { package = "3.4" } }

let names =
  List.map generic generic_names
  @ List.map slice_name
      [ "slice"; "str"; "slice_from_array"; "slice_sub"; "slice_unchecked" ]

let find name = List.find_opt (fun universe -> universe.name = name) names
