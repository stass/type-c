(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Sources of a few lines whose instances grow exponentially with them,
   which the instance budget of design 3.5 rule 7 must refuse, and their
   smaller partners, which compile. The tests of the front end and of
   lowering share them: each count refuses some of them. *)

let lines texts = String.concat "\n" texts ^ "\n"

(* [depth] aliases, each of which applies the one before it twice and so
   doubles the depth of a pointer. *)
let alias_lines depth =
  "type a0(T) = T *;"
  :: List.init depth (fun n ->
         Printf.sprintf "type a%d(T) = a%d(a%d(T));" (n + 1) n n)

let aliases depth =
  lines (alias_lines depth @ [ Printf.sprintf "a%d(int) x;" depth ])

(* The aliases up to [depth], applied to each of [count] structures. *)
let aliases_over_structures depth count =
  let use k =
    Printf.sprintf "struct s%d { int i; }; a%d(struct s%d) x%d;" k depth k k
  in
  lines (alias_lines depth @ List.init count use)

(* A structure whose tag has [length] bytes. *)
let long_tag length = "s" ^ String.make (length - 1) 'x'

(* A tree of structures [depth] deep over the leaf [g0], each of which
   holds two instances of the one below it. *)
let tree_lines depth leaf =
  leaf
  :: List.init depth (fun n ->
         Printf.sprintf
           "type g%d(T) = struct { g%d(T *) a; g%d(const T *) b; };" (n + 1)
           n n)

(* The tree over a leaf of 20 members, applied to a structure whose tag
   has [tag_length] bytes. *)
let tree ~tag_length depth =
  let tag = long_tag tag_length in
  let members = String.concat " " (List.init 20 (Printf.sprintf "T f%d;")) in
  lines
    ((Printf.sprintf "struct %s { int i; };" tag
     :: tree_lines depth (Printf.sprintf "type g0(T) = struct { %s };" members))
    @ [ Printf.sprintf "g%d(struct %s) x;" depth tag ])

(* The tree over a variant of 200 constructors, which uses its type
   parameter once: the names of its constructors carry the tag of
   [tag_length] bytes. *)
let variant_tree ~tag_length depth =
  let tag = long_tag tag_length in
  let constructors =
    String.concat " " (List.init 200 (Printf.sprintf "| C%d"))
  in
  lines
    ([ Printf.sprintf "struct %s { int i; };" tag;
       Printf.sprintf "type v(T) = %s | D(T *p);" constructors ]
    @ tree_lines depth "type g0(T) = struct { v(T) a; };"
    @ [ Printf.sprintf "g%d(struct %s) x;" depth tag ])

(* The aliases up to [depth] after a presumed file name of [length]
   bytes, which the line marker in front of each text of an instance
   holds. *)
let aliases_in_long_file ~length depth =
  Printf.sprintf "#line 1 \"%s\"\n" (String.make length 'n') ^ aliases depth

(* A function of [count] defers, each followed by a return that runs
   the copies of all the defers before it: the front end counts each
   copy against the output limit of design 3.5 rule 7. *)
let defers_by_exits count =
  let step n = Printf.sprintf "  defer g(%d); if (c == %d) return;" n n in
  lines
    ([ "void g(int);"; "void f(int c) {" ]
    @ List.init count step
    @ [ "}" ])

(* [functions] functions of [count] defers by exits each, whose copies
   add up to the unit's. *)
let functions_of_defers_by_exits ~functions count =
  let step n = Printf.sprintf "  defer g(%d); if (c == %d) return;" n n in
  let definition k =
    (Printf.sprintf "void f%d(int c) {" k :: List.init count step) @ [ "}" ]
  in
  lines ("void g(int);" :: List.concat (List.init functions definition))

(* The same in a loop, each defer followed by [jump] instead: a break, a
   continue, or a goto to the label after the loop. *)
let defers_by_jumps ~jump count =
  let step n = Printf.sprintf "    defer g(%d); if (c == %d) %s;" n n jump in
  lines
    ([ "void g(int);"; "void f(int c) {"; "  for (;;) {" ]
    @ List.init count step
    @ [ "  }"; "out:"; "  return;"; "}" ])

(* [count] functions of three defers and twelve returns each, whose
   copies together pass the instance budget: an ordinary program, which
   the count of copies must let through. *)
let defers_in_functions count =
  let return_step n = Printf.sprintf "  if (c == %d) return;" n in
  let defer_step n = Printf.sprintf "  defer g(%d);" n in
  let definition k =
    (Printf.sprintf "void f%d(int c) {" k :: List.init 3 defer_step)
    @ List.init 11 return_step
    @ [ "  return;"; "}" ]
  in
  lines ("void g(int);" :: List.concat (List.init count definition))

(* A function of one defer and [count] returns in its scope, each in a
   statement that a pragma line stands before, which design 6 refuses:
   every statement holds a place of the defer. *)
let pragmas_before_exits count =
  let step _ = "#pragma GCC unroll 2\n  while (c) return;" in
  lines
    ([ "void f(int c) {"; "  defer ;" ] @ List.init count step @ [ "}" ])

(* [count] type declarations, each of them edits with two line markers,
   after a presumed file name of [length] bytes, whose text the output
   limit of design 3.5 rule 7 bounds. *)
let edits_in_long_file ~length count =
  Printf.sprintf "#line 1 \"%s\"\n" (String.make length 'n')
  ^ lines (List.init count (Printf.sprintf "type t%d = int;"))

(* A variant whose name has [length] bytes, with [count] constructors,
   the name of each of which holds the variant's: the parser's bound on
   the name keeps their text linear in the source. *)
let long_variant ~length count =
  let constructors =
    String.concat " " (List.init count (Printf.sprintf "| C%d"))
  in
  lines
    [ Printf.sprintf "type %s = %s;" ("v" ^ String.make (length - 1) 'x')
        constructors ]

(* A defer of a call with a string literal of [length] bytes, which
   makes a [str], and [count] returns, each of which runs a copy of
   it. *)
let string_defer_by_exits ~length count =
  let step n = Printf.sprintf "  if (c == %d) return;" n in
  lines
    ([ "void use(str s);"; "void f(int c) {";
       Printf.sprintf "  defer use(\"%s\");" (String.make length 'a') ]
    @ List.init count step
    @ [ "}" ])

(* [depth] operands of [slice_from_array] nested in one another, each
   of which lowering writes twice, the second time under [sizeof]. *)
let nested_array_operands depth =
  let rec operand depth =
    if depth = 0 then "a"
    else
      Printf.sprintf "*({ (void)slice_from_array(%s); &a; })"
        (operand (depth - 1))
  in
  lines
    [ "int a[3];";
      Printf.sprintf "long f(void) { return (long)slice_from_array(%s).len; }"
        (operand depth) ]

(* A match whose label is a chain of [depth] patterns of [C], each of
   which follows its pointer field to the next and binds its other
   field, over a variant whose pointer field has a name of [length]
   bytes. *)
let deep_pattern ~length depth =
  let field = "f" ^ String.make (length - 1) 'x' in
  let rec label depth =
    if depth = 0 then "N"
    else Printf.sprintf "C(*%s, n%d)" (label (depth - 1)) depth
  in
  lines
    [ Printf.sprintf "type e = | N | C(const e *%s, int n);" field;
      Printf.sprintf
        "int g(e v) { match (v) { case %s: return 1; default: return 0; } }"
        (label depth) ]
