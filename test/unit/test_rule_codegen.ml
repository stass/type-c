(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Rule_codegen

let live constructor name =
  Live
    {
      constructor;
      name;
      clause = "design 1";
      meaning = constructor ^ " refuses.";
    }

let retired name = Retired { name; meaning = "The retired refusal." }

(* The middle row of this table is retired. *)
let with_retired =
  [ live "First" "first"; retired "second"; live "Third" "third-rule" ]

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

let accepts_name name = accepted [ live "Rule" name ]

let stale text = stale_citations with_retired ~file:"f.md" text

let cites_nothing_stale text = stale text = []

(* Whether [text] has one stale citation, whose message begins [opening]. *)
let one_stale text opening =
  match stale text with
  | [ message ] -> String.starts_with ~prefix:opening message
  | _ -> false

let failures () =
  let catalogue_of_all = catalogue with_retired in
  let source = ocaml with_retired in
  List.filter_map
    (fun (name, holds) -> if holds then None else Some name)
    [
      ("unique names with a retired row pass", accepted with_retired);
      ( "a new rule cannot take a retired name",
        not (accepted (with_retired @ [ live "Reuse" "second" ])) );
      ( "two live rules cannot share a name",
        not (accepted [ live "First" "same"; live "Second" "same" ]) );
      ( "a retired name cannot repeat a live one",
        not (accepted [ live "First" "first"; retired "first" ]) );
      ( "a name is lowercase words of letters and digits",
        accepts_name "match-arm-end" && accepts_name "c11-rule2" );
      ("a name is not empty", not (accepts_name ""));
      ("a name has no uppercase letter", not (accepts_name "Arm-end"));
      ("a name has no underscore", not (accepts_name "arm_end"));
      ("a name begins with a letter", not (accepts_name "2-arms"));
      ( "a name has no empty word",
        not
          (accepts_name "-arm" || accepts_name "arm-" || accepts_name "a--b")
      );
      ( "a retired name is checked as a live one",
        not (accepted [ retired "Moved text" ]) );
      ( "the generators refuse an unchecked table",
        refused ocaml [ live "First" "First" ]
        && refused catalogue [ live "First" "First" ] );
      ( "the catalogue lists the retired name",
        contains catalogue_of_all "## Retired names"
        && contains catalogue_of_all "| `second` | The retired refusal. |" );
      ( "the catalogue lists the live rules with their clauses",
        contains catalogue_of_all "| `third-rule` | design 1 |" );
      ( "the catalogue of live rules has no retired section",
        not (contains (catalogue [ live "First" "first" ]) "## Retired names")
      );
      ( "Rule has no name of a retired row",
        not (contains source "\"second\"") );
      ( "Rule keeps the live rules",
        contains source "| Third -> \"third-rule\"" );
      ( "prose may cite a live rule",
        cites_nothing_stale "A rule [first] and\n[third-rule]." );
      ( "a citation of a retired rule is stale, with its line",
        one_stale "One\n\ntwo [second]." "f.md:3: [second] names a retired rule"
      );
      ( "a citation of no rule is stale",
        one_stale "[thrid-rule]" "f.md:1: [thrid-rule] names no rule" );
      ( "an inline link is no citation",
        cites_nothing_stale "[a](b.md) ![c](d.png) [e\nf](g.md)" );
      ( "a reference link is checked as citations",
        List.length (stale "[e][ref] [g][]\n\n[ref]: https://x") = 5 );
      ( "a citation may begin a line before a colon",
        one_stale "Text\n[x]: more text" "f.md:2: [x]" );
      ( "code holds no citation",
        cites_nothing_stale
          "`a[i]` ``b`[j]`` `c\n[k]`\n\n```c\nd[l] = 0;\n```\n" );
      ("an escaped bracket is no citation", cites_nothing_stale "\\[x]");
      ( "backticks with a backtick after them open no fence",
        one_stale "```c` x\n[x]\n" "f.md:2: [x]" );
      ( "a fence closes only on as many backticks alone",
        one_stale "````\n```c\n[i]\n```\n````\n[x]" "f.md:6: [x]" );
      ( "lines are counted through code blocks",
        one_stale "```\n[x]\n```\n[x]" "f.md:4: [x]" );
      ( "a backtick without a closing run is text",
        one_stale "a ` b [x]" "f.md:1: [x]" );
      ( "a code span ends with its paragraph",
        one_stale "a ` b\n\n[x] `" "f.md:3: [x]" );
    ]

let () =
  match failures () with
  | [] -> ()
  | failed ->
      List.iter (fun name -> prerr_endline ("FAIL: " ^ name)) failed;
      exit 1
