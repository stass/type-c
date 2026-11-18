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
    it does for every Type-C unit. The operators of section 8 are read
    by the parser where a name is not hidden, applied to their operands
    ({!Tree.slice_operation}). *)

(** The operators of section 8 that make a slice. *)
type slice_operator = From_array | Sub | Unchecked

(** What typec makes of a universe name. *)
type meaning =
  | Declared  (** declared by the universe text *)
  | Slice_operator of slice_operator

type t = { name : string; meaning : meaning }

(* The universe text declares one type a line, as [type name ...],
   so the names come from the text and no list repeats them. *)
let declaration_lines =
  String.split_on_char '\n' Typec_cpp.File.universe_text
  |> List.filter (String.starts_with ~prefix:"type ")

let declared_names =
  List.map
    (fun line -> Scanf.sscanf line "type %[a-z_]" Fun.id)
    declaration_lines

let declared name = { name; meaning = Declared }

let slice_operator (name, operator) =
  { name; meaning = Slice_operator operator }

let names =
  List.map declared declared_names
  @ List.map slice_operator
      [ ("slice_from_array", From_array); ("slice_sub", Sub);
        ("slice_unchecked", Unchecked) ]

let find name = List.find_opt (fun universe -> universe.name = name) names
