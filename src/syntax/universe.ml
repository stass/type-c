(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The names that the universe scope declares (design 2.3). It encloses
    file scope, so a declaration of the same identifier in any scope
    hides the universe name from that point, under C's scope rules, and
    [int result = f();] keeps its meaning. Each is an ordinary
    identifier to the grammar.

    The generics of the universe scope are the declarations of
    {!Typec_cpp.File.universe_text} (design 3.6), which the parser
    declares in the universe scope where the reader holds that text.
    Each other name gets its meaning in work [package] of the plan,
    after design [section]; until then a use of one is an error, as is
    a use of a generic in text read without the universe text. *)

type t = { name : string; section : string; package : string }

(* The universe text declares one generic a line, as [type name(...)],
   so the names come from the text and no list repeats them. *)
let generic_names =
  String.split_on_char '\n' Typec_cpp.File.universe_text
  |> List.filter (fun line -> line <> "")
  |> List.map (fun line -> Scanf.sscanf line "type %[a-z_](" Fun.id)

let generic name = { name; section = "3.6"; package = "2.3" }

let names =
  List.map generic generic_names
  @ [
      { name = "slice"; section = "8"; package = "3.4" };
      { name = "str"; section = "8"; package = "3.4" };
      { name = "slice_from_array"; section = "8"; package = "3.4" };
      { name = "slice_sub"; section = "8"; package = "3.4" };
      { name = "slice_unchecked"; section = "8"; package = "3.4" };
    ]

let find name = List.find_opt (fun universe -> universe.name = name) names
