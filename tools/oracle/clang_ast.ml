(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* An AST node nests two levels deeper than its parent, in its "inner"
   array, so this admits expressions some 5000 deep, far beyond what
   Clang parses by default, and keeps the recursion of the JSON reader
   and of the walk below in a few megabytes of stack. *)
let max_depth = 10_000

(* A declaration is held as a tree while it is walked. Clang's take a
   few times their bytes, and the largest function of lua, luaV_execute,
   takes a quarter of this; the densest JSON, of empty arrays, takes
   some 25 times its bytes, under a gigabyte. *)
let max_declaration_bytes = 32 * 1024 * 1024

exception Malformed of string

let fail format =
  Printf.ksprintf (fun message -> raise (Malformed message)) format

type summary = { expressions : int; without_range : int }

(* Bounded input. The scanner sees every byte the JSON reader is given,
   ahead of it, and tracks only what the bounds need: the nesting depth
   outside strings and the bytes since the reader started its current
   value. The JSON reader is given at most one buffer of bytes it has
   not read, so a value can exceed its bound by that much. *)

type scanner = {
  channel : in_channel;
  mutable depth : int;
  mutable in_string : bool;
  mutable escaped : bool;  (** the previous byte began an escape *)
  mutable value_bytes : int;
  mutable complete : bool;  (** the top-level value has been closed *)
}

let start_value scanner = scanner.value_bytes <- 0

let scan_string_byte scanner c =
  if scanner.escaped then scanner.escaped <- false
  else if c = '\\' then scanner.escaped <- true
  else if c = '"' then scanner.in_string <- false

let open_value scanner =
  scanner.depth <- scanner.depth + 1;
  if scanner.depth > max_depth then
    fail "the AST nests deeper than %d levels" max_depth

let close_value scanner =
  scanner.depth <- scanner.depth - 1;
  if scanner.depth = 0 then scanner.complete <- true

(* Yojson also reads comments, which Clang never writes and which would
   hide quotes and brackets from the scanner; its other extensions hold
   neither. *)
let scan_structural_byte scanner c =
  if scanner.complete then fail "data after the AST";
  match c with
  | '"' -> scanner.in_string <- true
  | '{' | '[' -> open_value scanner
  | '}' | ']' -> close_value scanner
  | '/' -> fail "a comment in the AST"
  | _ -> ()

let count_value_byte scanner =
  scanner.value_bytes <- scanner.value_bytes + 1;
  if scanner.value_bytes > max_declaration_bytes then
    fail "a value of the AST takes more than %d bytes" max_declaration_bytes

(* Blanks between tokens are not counted: the reader keeps nothing of
   them. *)
let scan_byte scanner c =
  let blank = (not scanner.in_string) && String.contains " \t\r\n" c in
  if not blank then begin
    if scanner.in_string then scan_string_byte scanner c
    else scan_structural_byte scanner c;
    count_value_byte scanner
  end

let refill scanner buffer length =
  let count = input scanner.channel buffer 0 length in
  for i = 0 to count - 1 do
    scan_byte scanner (Bytes.get buffer i)
  done;
  count

(* Reads what the JSON reader left, so that every byte is checked and
   Clang can write all its output and exit. *)
let drain scanner =
  let buffer = Bytes.create 65536 in
  while refill scanner buffer (Bytes.length buffer) > 0 do
    ()
  done

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
   array, and its other fields are read and walked one at a time, each
   within the bound of a declaration. *)
let read_translation_unit scanner reader state lexbuf =
  let visit_value () state lexbuf =
    start_value scanner;
    visit reader (Yojson.Safe.read_json state lexbuf)
  in
  let visit_field () key state lexbuf =
    if key = "inner" then Yojson.Safe.read_sequence visit_value () state lexbuf
    else visit_value () state lexbuf
  in
  Yojson.Safe.read_fields visit_field () state lexbuf

let read ~input ~input_size channel emit =
  let scanner =
    {
      channel;
      depth = 0;
      in_string = false;
      escaped = false;
      value_bytes = 0;
      complete = false;
    }
  in
  let reader =
    { input; input_size; emit; buffer = ""; expressions = 0;
      without_range = 0 }
  in
  let lexbuf = Lexing.from_function (refill scanner) in
  match
    read_translation_unit scanner reader (Yojson.init_lexer ()) lexbuf;
    drain scanner
  with
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
