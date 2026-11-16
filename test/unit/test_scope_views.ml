(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The views of the scopes that the parser records (design 13.5): what
   a name denotes in front of each external declaration, and at the
   arguments of each attribute. *)

open Typec_cpp
open Typec_syntax
open Typec_test_support

let keywords : Keyword_set.t =
  {
    dialect = Gnu;
    optional_floats = Optional_float.all;
    int128 = true;
    vector_families = [];
  }

(* A text, the names that a case looks up in it, and what the views
   show, or the error. *)
type case = {
  name : string;
  text : string;
  names : string list;
  expected : string;
}

let case name text names expected = { name; text; names; expected }

let kind_name : Parser.kind -> string = function
  | Not_a_type -> "object"
  | Typedef_name -> "typedef"
  | Declared_type { parameters; _ } -> Printf.sprintf "type/%d" parameters
  | Type_parameter -> "parameter"
  | Derived_enumerator -> "enumerator"

(* Where a declaration is, by the line of its token, which a case keeps
   to one declaration a line. *)
let place (reader : Reader.t) = function
  | Tree.In_tree (Ordinary_at token) ->
      string_of_int reader.tokens.(token).location.line
  | Builtin _ -> "builtin"

(* "name=kind@line" for an ordinary identifier that [view] holds,
   "struct name@line" for a tag, and "name=-" for neither. *)
let show_name reader view name =
  match (Parser.View.find view name, Parser.View.find_tag view name) with
  | Some { declaration; kind }, _ ->
      Printf.sprintf "%s=%s@%s" name (kind_name kind) (place reader declaration)
  | None, Some (Tag_at token) ->
      Printf.sprintf "tag %s@%d" name reader.tokens.(token).location.line
  | None, None -> name ^ "=-"

let show_view reader names view =
  String.concat " " (List.map (show_name reader view) names)

let parsed ~file text =
  match Reader.read ~name:file (Preprocessed.text ~name:file text) with
  | Error error -> Error ("read error: " ^ Reader.error_message error)
  | Ok reader -> (
      match Parser.parse_with_scopes ~keywords reader with
      | Error error -> Error ("error: " ^ Parser.error_message error)
      | Ok (unit, scopes) -> Ok (reader, unit, scopes))

let outcome see ?(file = "in.i") case =
  match parsed ~file case.text with
  | Error message -> message
  | Ok (reader, unit, scopes) -> see reader unit scopes case.names

(* The view in front of each external declaration, separated by " | ",
   or a mismatch where the declarations are not those of the tree. *)
let declaration_views reader unit (scopes : Parser.scopes) names =
  if List.map fst scopes.declarations <> unit then
    "the declarations with views are not those of the tree"
  else
    List.map (fun (_, view) -> show_view reader names view) scopes.declarations
    |> String.concat " | "

let field_attributes (declarator : Tree.member_declarator) =
  match declarator.node with Field { attributes; _ } -> attributes | _ -> []

let member_attributes (member : Tree.member_declaration) =
  match member.node with
  | Members { declarators; _ } -> List.concat_map field_attributes declarators
  | Member_static_assert _ -> []

let specifier_attributes (specifier : Tree.declaration_specifier Tree.spanned)
    =
  match specifier.node with Attributes attributes -> attributes | _ -> []

(* The attributes of a declaration: among its specifiers and with its
   declarators. *)
let declaration_attributes specifiers (declarators : Tree.init_declarator list)
    =
  List.concat_map specifier_attributes specifiers
  @ List.concat_map
      (fun (declarator : Tree.init_declarator) -> declarator.node.attributes)
      declarators

(* The attributes of the members of a structure that a type declaration
   defines, and those of a declaration, in source order within each. *)
let attributes_of = function
  | Tree.Type_declaration { declaration; _ } -> (
      match declaration.node.definition with
      | Record_alias { node = { members = Some members; _ }; _ } ->
          List.concat_map member_attributes members.node
      | _ -> [])
  | External_declaration { node = Declaration { specifiers; declarators }; _ }
    ->
      declaration_attributes specifiers declarators
  | _ -> []

(* Each identifier among the tokens of an attribute's arguments, as its
   view shows it, or "none" for an attribute without arguments. *)
let attribute_names reader scopes (attribute : Tree.attribute) =
  match
    (attribute.node.arguments, Parser.attribute_view scopes attribute)
  with
  | Some { first; last }, Some view ->
      List.init (last - first + 1) (fun offset -> first + offset)
      |> List.filter_map (fun index ->
             match reader.Reader.tokens.(index).kind with
             | Token.Identifier name -> Some (show_name reader view name)
             | _ -> None)
      |> String.concat " "
  | None, None -> "none"
  | Some _, None -> "no view"
  | None, Some _ -> "a view without arguments"

(* The identifiers of the arguments of each attribute that
   [attributes_of] finds, separated by " | ". A case names no names. *)
let attribute_views reader unit (scopes : Parser.scopes) _names =
  List.concat_map attributes_of unit
  |> List.map (attribute_names reader scopes.attribute_views)
  |> String.concat " | "

let declaration_cases =
  [
    case "a name is in view after its declaration, not before"
      "int a;\nint b;\nint c;" [ "a"; "b" ]
      "a=- b=- | a=object@1 b=- | a=object@1 b=object@2";
    case "the last declaration of a name"
      "int a;\nextern int a;\nint b;" [ "a" ]
      "a=- | a=object@1 | a=object@2";
    case "what a function's parameters and body declare is out of view"
      "void f(int p) { int q; }\nint g;" [ "f"; "p"; "q" ]
      "f=- p=- q=- | f=object@1 p=- q=-";
    case "tags" "struct s;\nenum e { E };\nint x;" [ "s"; "e"; "E" ]
      "s=- e=- E=- | tag s@1 e=- E=- | tag s@1 tag e@2 E=object@2";
    case "every kind of external declaration has a view"
      "#pragma weak w\n__extension__ int a;\nasm(\"\");\n;\n\
       int f(void) { return 0; }\n_Static_assert(1, \"\");\nint b;"
      [ "a"; "f" ]
      "a=- f=- | a=object@2 f=- | a=object@2 f=- | a=object@2 f=- \
       | a=object@2 f=object@5 | a=object@2 f=object@5";
    case "__extension__ before each kind that takes it"
      "__extension__ int f(void) { return 0; }\n__extension__ asm(\"\");\n\
       __extension__ ;\nint b;"
      [ "f" ] "f=- | f=object@1 | f=object@1 | f=object@1";
  ]

let type_c_declaration_cases =
  [
    case "the kinds of ordinary identifiers"
      "typedef int t;\ntype v = | V;\nenum { e };\nint x;"
      [ "t"; "v"; "v_V"; "e"; "__builtin_va_list" ]
      "t=- v=- v_V=- e=- __builtin_va_list=typedef@builtin \
       | t=typedef@1 v=- v_V=- e=- __builtin_va_list=typedef@builtin \
       | t=typedef@1 v=type/0@2 v_V=enumerator@2 e=- \
       __builtin_va_list=typedef@builtin \
       | t=typedef@1 v=type/0@2 v_V=enumerator@2 e=object@3 \
       __builtin_va_list=typedef@builtin";
    case "the tags that a variant claims" "type v = | A;\nint x;"
      [ "v_tag" ] "v_tag=- | tag v_tag@1";
    case "a generic type, and not its type parameters"
      "type box(T) = struct { T v; };\nint x;" [ "box"; "T" ]
      "box=- T=- | box=type/1@1 T=-";
  ]

let attribute_cases =
  [
    case "the identifiers of an attribute in a generic, where it stands"
      "typedef char T;\nenum { N = 4 };\n\
       type box(T) = struct {\n\
       T v __attribute__((aligned(sizeof(T))));\n\
       int w __attribute__((vector_size(N * sizeof(int))));\n\
       int u __attribute__((packed));\n};"
      [] "sizeof=- T=parameter@3 | N=object@2 sizeof=- int=- | none";
    case "a later declaration leaves the view of an attribute"
      "type box(T) = struct {\nT v __attribute__((aligned(sizeof(n))));\n};\n\
       int n;"
      [] "sizeof=- n=-";
    case "a C23 attribute and an attribute after a declarator"
      "int n;\n[[gnu::aligned(sizeof(n))]] int y;\n\
       int z __attribute__((aligned(sizeof(y))));"
      [] "sizeof=- n=object@1 | sizeof=- y=object@2";
  ]

let () =
  let failed_with see ?file cases =
    List.filter_map
      (fun case ->
        let actual = outcome see ?file case in
        if actual = case.expected then None else Some (case, actual))
      cases
  in
  let failed =
    failed_with declaration_views declaration_cases
    @ failed_with declaration_views ~file:"in.tc" type_c_declaration_cases
    @ failed_with attribute_views ~file:"in.tc" attribute_cases
  in
  List.iter
    (fun (case, actual) ->
      Printf.eprintf "FAIL: %s\n  expected: %s\n  actual:   %s\n" case.name
        case.expected actual)
    failed;
  if failed <> [] then exit 1
