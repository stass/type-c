(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

exception Malformed of string

let fail format =
  Printf.ksprintf (fun message -> raise (Malformed message)) format

type summary = { expressions : int; without_range : int }

(* The walk. A location is an object with an offset, written in full only
   for the first location in a buffer: Clang leaves out the buffer's name
   ("file") while it is that of the location written before, so the walk
   follows the nodes in the order of the dump to know it. *)

type reader = {
  input : string;
  input_size : int;
  emit : Record.t -> unit;
  mutable buffer : string;  (** the buffer of the last location *)
  mutable expressions : int;
  mutable without_range : int;
}

type location = Invalid | At of { offset : int; token_length : int }

let string_member key fields =
  match List.assoc_opt key fields with
  | Some (`String text) -> Some text
  | None -> None
  | Some _ -> fail "a %s that is not a string" key

let required_string key fields =
  match string_member key fields with
  | Some text -> text
  | None -> fail "a node without a %s" key

let count_member key fields =
  match List.assoc_opt key fields with
  | Some (`Int count) when count >= 0 -> count
  | _ -> fail "a location without a valid %s" key

(* An expansion of a macro has a spelling and an expansion location in
   place of an offset; the input is preprocessed, so it has none. *)
let is_location fields =
  List.exists
    (fun key -> List.mem_assoc key fields)
    [ "offset"; "spellingLoc"; "expansionLoc" ]

let in_macro_expansion fields =
  List.mem_assoc "spellingLoc" fields || List.mem_assoc "expansionLoc" fields

(* A location names its buffer only when that changes. *)
let follow_buffer reader fields =
  match string_member "file" fields with
  | Some name -> reader.buffer <- name
  | None -> ()

let locate reader fields =
  if fields = [] then Invalid
  else if in_macro_expansion fields then fail "a location in a macro expansion"
  else begin
    follow_buffer reader fields;
    if reader.buffer <> reader.input then
      fail "a location in %S, not in the input" reader.buffer;
    At
      {
        offset = count_member "offset" fields;
        token_length = count_member "tokLen" fields;
      }
  end

let location_member reader key fields =
  match List.assoc_opt key fields with
  | Some (`Assoc location) -> locate reader location
  | _ -> fail "a range without a %s" key

(* An expression's own fields, which its source range completes. *)
type expression = {
  kind : string;
  cast : string option;
  category : string;
  qual_type : string;
  desugared : string option;
}

(* Clang gives every expression, and nothing else, a value category. *)
let expression_of fields =
  match string_member "valueCategory" fields with
  | None -> None
  | Some category ->
      let qual_type, desugared =
        match List.assoc_opt "type" fields with
        | Some (`Assoc type_fields) ->
            ( required_string "qualType" type_fields,
              string_member "desugaredQualType" type_fields )
        | _ -> fail "an expression without a type"
      in
      if not (List.mem_assoc "range" fields) then
        fail "an expression without a range";
      Some
        {
          kind = required_string "kind" fields;
          cast = string_member "castKind" fields;
          category;
          qual_type;
          desugared;
        }

(* The range's end is the start of its last token. *)
let record reader expression range =
  let first = location_member reader "begin" range in
  let last = location_member reader "end" range in
  match (first, last) with
  | At first, At last ->
      let limit = last.offset + last.token_length in
      if first.offset > limit || limit > reader.input_size then
        fail "a range %d-%d outside the input" first.offset limit;
      reader.expressions <- reader.expressions + 1;
      reader.emit
        {
          Record.first = first.offset;
          limit;
          kind = expression.kind;
          cast = expression.cast;
          category = expression.category;
          qual_type = expression.qual_type;
          desugared = expression.desugared;
        }
  | Invalid, _ | _, Invalid -> reader.without_range <- reader.without_range + 1

(* Clang writes a node's range before the nodes inside it, so an
   expression is recorded before its operands. *)
let rec visit reader = function
  | `Assoc fields -> visit_object reader fields
  | `List items -> List.iter (visit reader) items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> ()

and visit_object reader fields =
  (* A location outside an expression's range is followed for the
     buffer it may name. *)
  if is_location fields then ignore (locate reader fields)
  else
    match expression_of fields with
    | None -> List.iter (fun (_, value) -> visit reader value) fields
    | Some expression ->
        List.iter (visit_expression_field reader expression) fields

and visit_expression_field reader expression = function
  | "range", `Assoc range -> record reader expression range
  | "range", _ -> fail "a range that is not an object"
  | _, value -> visit reader value

(* The translation unit is one object; its declarations, in its "inner"
   array, and its other fields are read and walked one at a time, so
   that only one declaration is held as a tree at once. *)
let read_translation_unit reader state lexbuf =
  let visit_value () state lexbuf =
    visit reader (Yojson.Safe.read_json state lexbuf)
  in
  let visit_field () key state lexbuf =
    if key = "inner" then Yojson.Safe.read_sequence visit_value () state lexbuf
    else visit_value () state lexbuf
  in
  Yojson.Safe.read_fields visit_field () state lexbuf

let read ~input ~input_size channel emit =
  let reader =
    { input; input_size; emit; buffer = ""; expressions = 0;
      without_range = 0 }
  in
  let lexbuf = Lexing.from_channel channel in
  match read_translation_unit reader (Yojson.init_lexer ()) lexbuf with
  | () ->
      Ok
        {
          expressions = reader.expressions;
          without_range = reader.without_range;
        }
  | exception Malformed message -> Error message
  | exception Yojson.Json_error message ->
      (* Yojson puts the position on a line of its own. *)
      Error (String.concat " " (String.split_on_char '\n' message))
  | exception Stack_overflow -> Error "the AST nests too deep to read"
