(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Rule_codegen

let live name code =
  Live { name; code; clause = Some "design 1"; meaning = name ^ " refuses." }

let retired name code =
  Retired { name; code; meaning = "The retired refusal." }

(* The middle row of this table is retired. *)
let with_retired = [ live "First" 1; retired "Second" 2; live "Third" 3 ]

let accepted rows =
  match check rows with () -> true | exception Invalid_table _ -> false

let refused generate rows =
  match generate rows with _ -> false | exception Invalid_table _ -> true

let contains text part =
  let n = String.length part in
  let rec from i =
    i + n <= String.length text
    && (String.sub text i n = part || from (i + 1))
  in
  from 0

(* Rows with the codes 1 to 9999, the most that four digits hold. *)
let four_digit_rows = List.init 9999 (fun i -> live "Row" (i + 1))

let failures () =
  let catalogue_of_all = catalogue with_retired in
  let source = ocaml with_retired in
  List.filter_map
    (fun (name, holds) -> if holds then None else Some name)
    [
      ("codes in sequence with a retired row pass", accepted with_retired);
      ( "a new rule cannot take a retired code",
        not (accepted [ live "First" 1; retired "Second" 2; live "Reuse" 2 ])
      );
      ( "a new rule cannot skip a code",
        not (accepted [ live "First" 1; retired "Second" 2; live "Skip" 4 ])
      );
      ( "a deleted row leaves a hole",
        not (accepted [ live "First" 1; live "Third" 3 ]) );
      ( "a retired code cannot repeat a live one",
        not (accepted [ live "First" 1; retired "Again" 1 ]) );
      ( "a retired code cannot fall below an earlier one",
        not (accepted [ retired "A" 1; retired "B" 3; retired "C" 2 ]) );
      ("four digits hold 9999 rules", accepted four_digit_rows);
      ( "a live code has four digits at most",
        not (accepted (four_digit_rows @ [ live "Last" 10000 ])) );
      ( "a retired code has four digits at most",
        not (accepted (four_digit_rows @ [ retired "Last" 10000 ])) );
      ( "the generators refuse an unchecked table",
        refused ocaml [ live "First" 2 ] && refused catalogue [ live "First" 2 ]
      );
      ( "the catalogue lists the retired code",
        contains catalogue_of_all "## Retired codes"
        && contains catalogue_of_all
             "| TC0002 | `Second` | The retired refusal. |" );
      ( "the catalogue lists the live rules",
        contains catalogue_of_all "| TC0003 | `Third` |" );
      ( "the catalogue of live rules has no retired section",
        not (contains (catalogue [ live "First" 1 ]) "## Retired codes") );
      ( "Rule has no constructor for a retired row",
        not (contains source "TC0002" || contains source "Second") );
      ("Rule keeps the live rules", contains source "| Third -> \"TC0003\"");
    ]

let () =
  match failures () with
  | [] -> ()
  | failed ->
      List.iter (fun name -> prerr_endline ("FAIL: " ^ name)) failed;
      exit 1
