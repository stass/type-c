(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Texts that nest as deep as the caller asks, which the tests of the
   parser and of the stages after it share. *)

(* How many links a chain within Parser.max_depth has: the margin leaves
   room for the nodes around it. *)
let links_within_bound = Typec_syntax.Parser.max_depth - 16

let repeat count text = String.concat "" (List.init count (fun _ -> text))

(* [count] copies of [text i], for each [i] from 0. *)
let numbered count text = String.concat "" (List.init count text)

let in_body statements = "void f(int a) { " ^ statements ^ " }"

(* A text, the file it is read from, and whether the stages after the
   parser take it: a text they refuse is one that no C program holds at
   that depth, or whose type has more parts than typing reads. *)
type chain = { name : string; file : string; text : string; lowers : bool }

(* Chains that the parser reads in loops and that nest, [links] levels
   deep. Each is valid C where C has a form of it, so that it reaches
   every stage. *)
let nesting_chains links =
  let chain separator last =
    String.concat separator (List.init links (fun _ -> "a")) ^ last
  in
  let c ?(lowers = true) name text = { name; file = "in.i"; text; lowers } in
  let initialised value = in_body ("int x = " ^ value ^ ";") in
  let c_chains =
    [
      c "binary operators" (initialised (chain " + " ""));
      c "assignments" (initialised (chain " = " ""));
      c "conditionals" (initialised (chain " ? a : " ""));
      c "omitted middle operands" (initialised (chain " ?: " ""));
      c "comma operators" (initialised ("(" ^ chain ", " ")"));
      c "sizeof" (initialised (repeat links "sizeof " ^ "a"));
      c "unary operators" (initialised (repeat links "- " ^ "a"));
      c "real and imaginary parts"
        (initialised (repeat (links / 2) "__real__ __imag__ " ^ "a"));
      c "alignof" (initialised (repeat links "__alignof__ " ^ "a"));
      (* An increment gives no lvalue for the next one. *)
      c "increments" ~lowers:false (initialised (repeat links "++" ^ "a"));
      c "casts" (initialised (repeat links "(int)" ^ "a"));
      c "postfix operators"
        ("struct s { struct s *p; }; void f(struct s *a) { void *x = a"
        ^ repeat links "->p" ^ "; }");
      c "pointers" ~lowers:false ("int " ^ String.make links '*' ^ "p;");
      c "arrays" ~lowers:false ("int a" ^ repeat links "[1]" ^ ";");
      c "ifs" (in_body (repeat links "if (a) " ^ ";"));
      c "else-if chains" (in_body (repeat links "if (a) ; else " ^ ";"));
      c "dangling elses"
        (in_body (repeat links "if (a) " ^ ";" ^ repeat links " else ;"));
      c "labels" (in_body (numbered links (Printf.sprintf "l%d: ") ^ ";"));
      c "case labels"
        (in_body
           ("switch (a) " ^ numbered links (Printf.sprintf "case %d: ") ^ ";"));
      (* A switch holds one default label. *)
      c "default labels"
        (in_body (repeat (links / 2) "switch (a) default: " ^ ";"));
      c "switches" (in_body (repeat links "switch (a) " ^ ";"));
      c "whiles" (in_body (repeat links "while (a) " ^ ";"));
      c "fors" (in_body (repeat links "for (int i = 0;;) " ^ ";"));
      c "dos" (in_body (repeat links "do " ^ ";" ^ repeat links " while (a);"));
      c "case ranges"
        (in_body
           ("switch (a) "
           ^ numbered links (fun i ->
                 Printf.sprintf "case %d ... %d: " (2 * i) ((2 * i) + 1))
           ^ ";"));
      c "block pointers" ("int " ^ String.make links '^' ^ "p;");
      c "attributed pointers"
        ("int " ^ repeat links "* __attribute__((a)) const " ^ "p;");
      c "attributed labels"
        (in_body
           (numbered links (Printf.sprintf "l%d: __attribute__((a)) ") ^ ";"));
    ]
  in
  (* Each break of the chain is in tail position of the arm (design 4.3
     rule 5), which the parser checks against every one. *)
  let type_c_chains =
    [
      {
        name = "else-if chains of breaks in an arm";
        file = "in.tc";
        text =
          "type e = | A; void f(e v, int a) { match (v) { default: "
          ^ repeat links "if (a) break; else " ^ "break; } }";
        lowers = true;
      };
      (* The parser reads a try in the loop of a cast-expression, and
         typing places each. *)
      {
        name = "tries";
        file = "in.tc";
        text = in_body (repeat links "try " ^ "a;");
        lowers = false;
      };
      {
        name = "tries among unary operators";
        file = "in.tc";
        text = in_body (repeat (links / 2) "- try " ^ "a;");
        lowers = false;
      };
      (* A try in the second operand of each conditional of a chain,
         which the prelude evaluates under the truth of every first
         operand before it. *)
      {
        name = "tries in a chain of conditionals";
        file = "in.tc";
        text =
          "typedef result(int, int) r; r f(void); r g(int a) { int x = "
          ^ repeat links "a ? try f() : "
          ^ "0; return Ok(x); }";
        lowers = true;
      };
    ]
  in
  c_chains @ type_c_chains
