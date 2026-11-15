(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* rule_table ocaml | rule_table catalogue: the module Rule of typec_syntax,
   or the Markdown catalogue of the diagnostics that it makes, both from
   the one table below. Generating the variant from the table is what
   lets the catalogue and the golden tests enumerate every rule: OCaml
   cannot list the constructors of a hand-written variant. *)

type rule = {
  name : string;  (** the constructor of [Rule.t] *)
  code : int;
      (** the number of the stable code, written in the table so that
          adding or removing a rule renumbers no other; a new rule takes
          a number above every number the table has ever held *)
  clause : string option;
      (** the clause of the design that states the rule, which the
          diagnostic cites; [None] for a refusal whose text cites its own *)
  meaning : string;  (** what the rule refuses, in odoc markup *)
}

let rules =
  [
    { name = "Generated_name"; code = 1; clause = Some "design 2.3";
      meaning =
        "An identifier that begins with [__tc_]." };
    { name = "Own_name"; code = 2; clause = Some "design 3.1 rule 2";
      meaning =
        "A definition that uses the name it defines, other than a \
         structure or union specifier." };
    { name = "One_definition"; code = 3; clause = Some "design 3.1 rule 5";
      meaning =
        "A name declared twice in one scope where either is a type \
         declaration." };
    { name = "Claimed_name"; code = 4; clause = Some "design 10.1 rule 6";
      meaning =
        "A tag or enumerator that a type declaration claims for the C \
         it lowers to (also design 10.2), declared otherwise in its \
         scope, named in Type-C text or reserved for any use in C; and \
         a type declaration of any form whose name C reserves so." };
    { name = "Duplicate_constructor"; code = 5;
      clause = Some "design 3.2 rule 2";
      meaning =
        "Two constructors of one variant with one name." };
    { name = "Field_type"; code = 6; clause = Some "design 3.2 rule 4";
      meaning =
        "A field of a constructor whose type is not a value type; also \
         design 3.2 rule 5." };
    { name = "Variant_operation"; code = 7; clause = Some "design 3.2 rule 6";
      meaning =
        "An operation on a variant in Type-C text other than those that \
         design 3.2 rule 6 allows." };
    { name = "Zero_value"; code = 8; clause = Some "design 3.2 rule 7";
      meaning =
        "A braced initialiser of a variant other than [{0}] and [{}] in \
         Type-C text." };
    { name = "Constructor_expression"; code = 9; clause = Some "design 3.3";
      meaning =
        "A constructor expression that names no constructor, or whose \
         arguments do not match its fields." };
    { name = "Distinct_representation"; code = 10;
      clause = Some "design 3.4";
      meaning =
        "A distinct type over a type that is no unqualified arithmetic \
         or pointer type." };
    { name = "Distinct_operation"; code = 11; clause = Some "design 3.4";
      meaning =
        "An operation on a value of a distinct type in Type-C text that \
         the table of design 3.4 does not allow." };
    { name = "Distinct_conversion"; code = 12; clause = Some "design 3.4";
      meaning =
        "An implicit conversion to or from a distinct type in Type-C \
         text." };
    { name = "Private_creation"; code = 13; clause = Some "design 9.2 rule 1";
      meaning =
        "A constructor expression of a private variant, or a cast to a \
         private distinct type, in Type-C text that does not own the \
         type." };
    { name = "Match_scrutinee"; code = 14; clause = Some "design 4.1 rule 1";
      meaning =
        "A match whose scrutinee is no complete variant, or one outside \
         the scope of the declaration of the variant; also design 4.2 \
         rule 4. The same for a single-pattern test and its operand \
         (design 4.6 rule 2)." };
    { name = "Arm_form"; code = 15; clause = Some "design 4.1 rule 2";
      meaning =
        "A match body that is not a sequence of arms, each of labels \
         and at least one block item." };
    { name = "Pattern"; code = 16; clause = Some "design 4.1 rule 3";
      meaning =
        "A pattern that names no constructor of the scrutinee's type, \
         or whose sub-patterns do not match its fields; also the pattern \
         of a single-pattern test (design 4.6 rule 2)." };
    { name = "Shared_arm"; code = 17; clause = Some "design 4.1 rule 6";
      meaning =
        "An arm of several labels one of which binds." };
    { name = "Exhaustiveness"; code = 18; clause = Some "design 4.2 rule 1";
      meaning =
        "A constructor that a match covers twice or not at all." };
    { name = "Default_arm"; code = 19; clause = Some "design 4.2 rule 2";
      meaning =
        "A second [default] in a match, or one that covers no \
         constructor." };
    { name = "Enclosing_switch_label"; code = 20;
      clause = Some "design 4.3 rule 3";
      meaning =
        "A [case] or [default] label inside a match that is not one of \
         its own, or inside the statement of a single-pattern test \
         (design 4.6 rule 6)." };
    { name = "Arm_end"; code = 21; clause = Some "design 4.3 rule 1";
      meaning =
        "A match arm whose end can be reached; also design 4.4."
    };
    { name = "Arm_entry"; code = 22; clause = Some "design 4.3 rule 3";
      meaning =
        "A jump into a match arm or the statement of a single-pattern \
         test (design 4.6 rule 6) from outside it, or the address of a \
         label inside one." };
    { name = "Not_implemented"; code = 23; clause = None;
      meaning =
        "A construct that a later work package of the plan implements; \
         the text names the section of the design and the package." };
    { name = "Variant_scope"; code = 24; clause = Some "design 3.3";
      meaning =
        "A constructor expression outside the scope of the declaration \
         of its variant." };
    { name = "Reserved_constructor"; code = 25;
      clause = Some "design 3.2 rule 2";
      meaning =
        "A constructor named for a word of Type-C text (design 2.3) or \
         a universe name, or a constructor or field whose name C \
         reserves for any use." };
    { name = "Disputed_jump"; code = 26; clause = Some "design 4.4";
      meaning =
        "A [break] or [continue] in Type-C text in a statement \
         expression in the condition of a loop or the step of a [for], \
         outside every loop, [switch] and match within it, which GCC and \
         Clang take to leave different statements." };
    { name = "Break_outside"; code = 27;
      clause = Some "C11 6.8.6.3p1, design 4.3 rule 2";
      meaning =
        "A [break] outside every loop, [switch] and match; also C11 \
         6.8.6.3p1." };
    { name = "Early_break"; code = 28; clause = Some "design 4.3 rule 5";
      meaning =
        "A [break] in Type-C text that leaves a match other than in \
         tail position of its arm." };
  ]

(* Stable codes are "TC" and four digits: fixed width for tools that read
   them, and a prefix that no backend's diagnostic uses. *)
let largest_code = 9999

let code_text rule = Printf.sprintf "TC%04d" rule.code

exception Invalid_table of string

(* Codes rise down the table, which makes them unique and keeps the table
   in the order of its catalogue; a retired code leaves a gap. The
   compiler refuses a name used twice when it builds the generated
   variant. *)
let check_table () =
  let check previous rule =
    if rule.code <= previous then
      raise (Invalid_table (rule.name ^ "'s code does not rise"));
    if rule.code > largest_code then
      raise (Invalid_table (rule.name ^ "'s code has over four digits"));
    rule.code
  in
  ignore (List.fold_left check 0 rules)

(* Generated text keeps doc comments within 80 columns. *)
let wrap ~indent ~width text =
  let line = Buffer.create width and lines = ref [] in
  let flush () =
    lines := Buffer.contents line :: !lines;
    Buffer.clear line
  in
  let add word =
    if Buffer.length line > 0
       && indent + Buffer.length line + 1 + String.length word > width
    then flush ();
    if Buffer.length line > 0 then Buffer.add_char line ' ';
    Buffer.add_string line word
  in
  List.iter add (String.split_on_char ' ' text);
  flush ();
  String.concat ("\n" ^ String.make indent ' ') (List.rev !lines)

let module_header =
  {|(* Generated by src/syntax/rule_table/rule_table.ml; do not edit. *)

(** The rules of the design that typec enforces on Type-C constructs, and
    the constructs that it refuses because a later work package of the
    plan implements them. Every diagnostic about either is made by
    {!message}, which ends it with the rule's stable code. *)

type t =
|}

let module_message =
  {|
(** [message rule text] is the diagnostic [text] about [rule], which it
    follows with the clause that states the rule and the rule's code in
    brackets, as GCC and Clang end a warning with its option. *)
let message rule text =
  match clause rule with
  | Some clause -> Printf.sprintf "%s (%s) [%s]" text clause (code rule)
  | None -> Printf.sprintf "%s [%s]" text (code rule)
|}

(* A doc comment opens with this and closes with " *)" by column 80. *)
let doc_opening = "      (** "

let print_constructor rule =
  let indent = String.length doc_opening in
  Printf.printf "  | %s\n%s%s *)\n" rule.name doc_opening
    (wrap ~indent ~width:(80 - String.length " *)") rule.meaning)

let print_code rule = Printf.printf "  | %s -> %S\n" rule.name (code_text rule)

let print_clause rule =
  match rule.clause with
  | Some clause -> Printf.printf "  | %s -> Some %S\n" rule.name clause
  | None -> Printf.printf "  | %s -> None\n" rule.name

let print_ocaml () =
  print_string module_header;
  List.iter print_constructor rules;
  print_string "\n(** [code rule] is the stable code of [rule]. *)\n";
  print_string "let code = function\n";
  List.iter print_code rules;
  print_string "\n(** [clause rule] is the clause that states [rule]. *)\n";
  print_string "let clause = function\n";
  List.iter print_clause rules;
  print_string "\n(** Every rule, in the order of their codes. *)\n";
  print_string "let all = [\n";
  List.iter (fun rule -> Printf.printf "  %s;\n" rule.name) rules;
  print_string "]\n";
  print_string module_message

let catalogue_header =
  {|# Diagnostics of typec

Generated by `src/syntax/rule_table/rule_table.ml`; do not edit.

A diagnostic about a Type-C construct ends with the clause of the design
that states its rule and the rule's stable code (design 13.6):

```
file:line: text (clause) [code]
```

| Code | Rule | Clause | What it refuses |
| --- | --- | --- | --- |
|}

(* odoc's [code] is Markdown's `code`. *)
let markdown text =
  String.map (fun c -> if c = '[' || c = ']' then '`' else c) text

let print_entry rule =
  Printf.printf "| %s | `%s` | %s | %s |\n" (code_text rule) rule.name
    (Option.value rule.clause ~default:"named in the text")
    (markdown rule.meaning)

let print_catalogue () =
  print_string catalogue_header;
  List.iter print_entry rules

let () =
  let generate =
    match Sys.argv with
    | [| _; "ocaml" |] -> print_ocaml
    | [| _; "catalogue" |] -> print_catalogue
    | _ ->
        prerr_endline "usage: rule_table ocaml | rule_table catalogue";
        exit 2
  in
  match check_table () with
  | () -> generate ()
  | exception Invalid_table reason ->
      prerr_endline ("rule_table: " ^ reason);
      exit 1
