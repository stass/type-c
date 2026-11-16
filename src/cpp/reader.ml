(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type text = string
type t = { text : text; tokens : Token.t array }
type replacement = { first : int; count : int; text : string }
type error = { location : Location.t; message : string }

(* The largest line number a line marker or #line may give (C11 6.10.4);
   it also keeps the number far from overflow while it is read. *)
let max_line_number = 2147483647

(* How a line marker moves on the stack of files being read. *)
type motion = Stay | Enter | Return

module Owners = Map.Make (struct
  type t = string * bool * bool

  let compare = Stdlib.compare
end)

(* The position in the text and what the line markers before it said. *)
type state = {
  text : string;
  input_name : string;
  mutable pos : int;
  mutable presumed : Location.t;  (** of the current line *)
  mutable include_stack : File.t list;
      (** innermost first, and empty until the main file is known. Its
          depth needs no limit: each level costs a line of input, and
          nothing recurses over it. *)
  mutable owners : File.t Owners.t;  (** each owner made so far *)
  mutable tokens : Token.t list;  (** in reverse *)
}

(* Raised at the first part of the text that is not cc -E output. *)
exception Failed of error

let fail state message =
  raise (Failed { location = state.presumed; message })

(* The cursor. *)

let peek state offset =
  let index = state.pos + offset in
  if index < String.length state.text then Some state.text.[index] else None

let advance state count = state.pos <- state.pos + count

let looking_at state prefix =
  let length = String.length prefix in
  let rec same_from index =
    index = length
    || state.text.[state.pos + index] = prefix.[index]
       && same_from (index + 1)
  in
  state.pos + length <= String.length state.text && same_from 0

let next_is state accepted =
  Option.fold ~none:false ~some:accepted (peek state 0)

let skip_while state accepted =
  while next_is state accepted do
    advance state 1
  done

(* Characters. *)

let is_digit = Char_class.is_digit
let is_hex_digit = Char_class.is_hex_digit

(* The value of a digit that [is_hex_digit] accepts. *)
let hex_digit_value c =
  match c with
  | '0' .. '9' -> Char.code c - Char.code '0'
  | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
  | _ -> Char.code c - Char.code 'A' + 10

(* White space other than the newline, which ends a directive. *)
let is_blank = function
  | ' ' | '\t' | '\r' | '\011' | '\012' -> true
  | _ -> false

(* '$' is the GNU profile's. *)
let is_ascii_identifier_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$' -> true
  | _ -> false

let is_printable c = ' ' <= c && c <= '~'

let describe_byte c =
  if is_printable c then Printf.sprintf "character '%c'" c
  else Printf.sprintf "byte 0x%02X" (Char.code c)

(* Lines, owners and tokens. *)

let start_next_line state =
  state.presumed <- { state.presumed with line = state.presumed.line + 1 }

(* The one value for an owner. *)
let owner state ~main name system_header =
  let key = (name, system_header, main) in
  match Owners.find_opt key state.owners with
  | Some file -> file
  | None ->
      let file = { File.name; system_header; main } in
      state.owners <- Owners.add key file state.owners;
      file

(* Text before the first line marker that names a file belongs to a main
   file named for the input. *)
let current_owner state =
  match state.include_stack with
  | file :: _ -> file
  | [] ->
      let main = owner state ~main:true state.input_name false in
      state.include_stack <- [ main ];
      main

let add_token state kind start =
  let token =
    {
      Token.kind;
      start;
      length = state.pos - start;
      owner = current_owner state;
      location = state.presumed;
    }
  in
  state.tokens <- token :: state.tokens

(* Tokens. *)

(* A character of an identifier or a preprocessing number: a letter,
   digit, '_' or '$' written as itself, or an extended character, which
   a universal character name or UTF-8 spells. GCC writes extended
   characters as universal character names, and Clang in UTF-8. *)
type identifier_char = Basic of char | Extended of Uchar.t

(* How the next character is written, if it can be part of an
   identifier. *)
type identifier_char_form = As_itself | Universal_character_name | Utf_8

let next_identifier_char_form state =
  match (peek state 0, peek state 1) with
  | Some c, _ when is_ascii_identifier_char c -> Some As_itself
  | Some '\\', Some ('u' | 'U') -> Some Universal_character_name
  | Some c, _ when c >= '\128' -> Some Utf_8
  | _ -> None

let describe_code_point c = Printf.sprintf "U+%04X" (Uchar.to_int c)

(* C11 6.4.3p2: a universal character name names no character below
   U+00A0 other than '$', '@' and '`', which C does not require in the
   basic character set. *)
let may_be_universal_character_name code =
  match code with
  | 0x24 | 0x40 | 0x60 -> true
  | _ -> code >= 0xA0

(* A value of [beyond_unicode] or more names no character, so the value
   of a universal character name stops growing there, which keeps it
   far from overflow. *)
let beyond_unicode = 0x110000

(* \u and four hexadecimal digits, or \U and eight, which must name a
   Unicode scalar value: C11 6.4.3p2 refuses a surrogate, and ISO/IEC
   10646 has no character beyond U+10FFFF. *)
let scan_universal_character_name state =
  let start = state.pos in
  let digits = if peek state 1 = Some 'u' then 4 else 8 in
  advance state 2;
  let code = ref 0 in
  for _ = 1 to digits do
    match peek state 0 with
    | Some c when is_hex_digit c ->
        code := min beyond_unicode ((!code * 16) + hex_digit_value c);
        advance state 1
    | _ -> fail state "incomplete universal character name"
  done;
  let written = String.sub state.text start (state.pos - start) in
  if not (Uchar.is_valid !code) then
    fail state
      (Printf.sprintf "universal character name %s names no character"
         written);
  if not (may_be_universal_character_name !code) then
    fail state
      (Printf.sprintf
         "character %s cannot be written as a universal character name"
         (describe_code_point (Uchar.of_int !code)));
  Uchar.of_int !code

let scan_utf_8_character state =
  let decoded = String.get_utf_8_uchar state.text state.pos in
  if not (Uchar.utf_decode_is_valid decoded) then fail state "invalid UTF-8";
  advance state (Uchar.utf_decode_length decoded);
  Uchar.utf_decode_uchar decoded

(* Consumes a character that can be part of an identifier, if one is
   next, and returns it. *)
let scan_identifier_char state =
  match next_identifier_char_form state with
  | Some As_itself ->
      let c = state.text.[state.pos] in
      advance state 1;
      Some (Basic c)
  | Some Universal_character_name ->
      Some (Extended (scan_universal_character_name state))
  | Some Utf_8 -> Some (Extended (scan_utf_8_character state))
  | None -> None

let starts_identifier state = Option.is_some (next_identifier_char_form state)

(* C11 6.4.2.1p3 and Annex D: the extended characters an identifier may
   hold, and those it may not begin with. *)
let check_extended_char state c ~initial =
  if not (Annex_d.allowed c) then
    fail state
      (Printf.sprintf "character %s cannot be part of an identifier"
         (describe_code_point c));
  if initial && not (Annex_d.allowed_initially c) then
    fail state
      (Printf.sprintf "character %s cannot begin an identifier"
         (describe_code_point c))

(* The name of an identifier is in UTF-8 however its characters are
   written, so that each name has one spelling in every later stage;
   the text keeps the bytes, which emission copies unchanged. *)
let scan_identifier state =
  let start = state.pos in
  let name = Buffer.create 16 in
  let continues = ref true in
  while !continues do
    let initial = state.pos = start in
    match scan_identifier_char state with
    | Some (Basic c) -> Buffer.add_char name c
    | Some (Extended c) ->
        check_extended_char state c ~initial;
        Buffer.add_utf_8_uchar name c
    | None -> continues := false
  done;
  Token.Identifier (Buffer.contents name)

(* A preprocessing number (C11 6.4.8): a digit, or '.' and a digit, then
   digits, identifier characters, '.' and signs after e, E, p and P. *)
let scan_number state =
  advance state (if peek state 0 = Some '.' then 2 else 1);
  let continues = ref true in
  while !continues do
    match (peek state 0, peek state 1) with
    | Some ('e' | 'E' | 'p' | 'P'), Some ('+' | '-') -> advance state 2
    | Some '.', _ -> advance state 1
    | _ -> continues := Option.is_some (scan_identifier_char state)
  done;
  Token.Number

let starts_number state =
  match (peek state 0, peek state 1) with
  | Some c, _ when is_digit c -> true
  | Some '.', Some c when is_digit c -> true
  | _ -> false

(* From the opening quote to the closing one. An escape sequence is
   skipped whole so that an escaped quote does not end the literal; what
   it means is checked later, where its value is needed. *)
let scan_quoted state quote =
  let opening = state.pos in
  advance state 1;
  let closed = ref false in
  while not !closed do
    match (peek state 0, peek state 1) with
    | (None | Some '\n'), _ -> fail state "unterminated literal"
    | Some '\\', Some next when next <> '\n' -> advance state 2
    | Some c, _ when c = quote ->
        advance state 1;
        closed := true
    | Some _, _ -> advance state 1
  done;
  let empty_length = 2 (* the two quotes *) in
  if quote = '\'' && state.pos - opening = empty_length then
    fail state "empty character constant"

(* The spellings that open a literal, each with the kind it opens. A
   prefix is an identifier unless a quote follows it. *)
let literal_openers =
  [
    ("u8\"", Token.String Utf8);
    ("u\"", Token.String Char16);
    ("U\"", Token.String Char32);
    ("L\"", Token.String Wide);
    ("\"", Token.String Plain);
    ("u'", Token.Character Char16);
    ("U'", Token.Character Char32);
    ("L'", Token.Character Wide);
    ("'", Token.Character Plain);
  ]

(* The spellings of the punctuators, longest first, so that the first one
   that matches is the longest. *)
let punctuators =
  List.stable_sort
    (fun (a, _) (b, _) -> compare (String.length b) (String.length a))
    Punctuator.spellings

let scan_punctuator state =
  let matches (spelling, _) = looking_at state spelling in
  match List.find_opt matches punctuators with
  | Some (spelling, punctuator) ->
      advance state (String.length spelling);
      Token.Punctuator punctuator
  | None -> fail state ("unexpected " ^ describe_byte state.text.[state.pos])

(* Consumes one token and returns its kind. *)
let scan_token state =
  let opens_here (opener, _) = looking_at state opener in
  match List.find_opt opens_here literal_openers with
  | Some (opener, kind) ->
      let quote_offset = String.length opener - 1 in
      advance state quote_offset;
      scan_quoted state opener.[quote_offset];
      kind
  | None ->
      if starts_number state then scan_number state
      else if starts_identifier state then scan_identifier state
      else if looking_at state "/*" || looking_at state "//" then
        fail state "comment in preprocessed text"
      else scan_punctuator state

(* Directives. *)

(* A directive line holds nothing after its last part but blanks. *)
let end_directive state =
  skip_while state is_blank;
  match peek state 0 with
  | None | Some '\n' -> ()
  | Some _ -> fail state "unexpected text at the end of a directive"

(* The line after the directive is [next_line] of [file]; the newline
   that ends the directive counts as one line. *)
let set_presumed state file next_line =
  state.presumed <- { Location.file; line = next_line - 1 }

let read_word state =
  let start = state.pos in
  skip_while state is_ascii_identifier_char;
  String.sub state.text start (state.pos - start)

let read_line_number state =
  if not (next_is state is_digit) then
    fail state "missing line number";
  let number = ref 0 in
  while next_is state is_digit do
    let digit = Char.code state.text.[state.pos] - Char.code '0' in
    number := (!number * 10) + digit;
    if !number > max_line_number then fail state "line number out of range";
    advance state 1
  done;
  !number

(* The name as spelled between the quotes. *)
let read_file_name state =
  let start = state.pos + 1 in
  scan_quoted state '"';
  String.sub state.text start (state.pos - 1 - start)

let read_optional_file_name state =
  skip_while state is_blank;
  if peek state 0 = Some '"' then Some (read_file_name state) else None

(* GCC accepts the flags in this order only: 1 (enter) or 2 (return), then
   3 (system header), then 4 (C++ extern "C"), which needs 3. *)
let read_flags state =
  let flags = ref [] in
  skip_while state is_blank;
  while next_is state is_digit do
    let start = state.pos in
    skip_while state is_digit;
    flags := String.sub state.text start (state.pos - start) :: !flags;
    skip_while state is_blank
  done;
  let motion, system_flags =
    match List.rev !flags with
    | "1" :: rest -> (Enter, rest)
    | "2" :: rest -> (Return, rest)
    | rest -> (Stay, rest)
  in
  match system_flags with
  | [] -> (motion, false)
  | [ "3" ] | [ "3"; "4" ] -> (motion, true)
  | _ -> fail state "invalid line marker flags"

(* The stack of files being read after a line marker with a file name.
   Only a marker that opens a file says whether it is a system header:
   GCC also puts the system flag on markers without the enter flag around
   the tokens of a macro that a system header defines, and those tokens
   belong to the file of the expansion. *)
let stack_after_marker state motion name system_header =
  match (motion, state.include_stack) with
  | Enter, stack -> owner state ~main:false name system_header :: stack
  | Stay, [] -> [ owner state ~main:true name system_header ]
  | Stay, stack -> stack
  | Return, _ :: (_ :: _ as includer) -> includer
  | Return, _ -> fail state "line marker returns from the main file"

(* # N "file" flags, and # N. *)
let read_line_marker state =
  let next_line = read_line_number state in
  match read_optional_file_name state with
  | Some name ->
      let motion, system_header = read_flags state in
      end_directive state;
      state.include_stack <-
        stack_after_marker state motion name system_header;
      set_presumed state name next_line
  | None ->
      end_directive state;
      set_presumed state state.presumed.file next_line

(* #line N "file", and #line N. *)
let read_line_directive state =
  skip_while state is_blank;
  let next_line = read_line_number state in
  let name = read_optional_file_name state in
  end_directive state;
  set_presumed state (Option.value name ~default:state.presumed.file) next_line

(* The whole line is the token, so that it can be passed through. *)
let read_pragma state hash =
  skip_while state is_blank;
  let kind =
    if read_word state = "typec" then Token.Typec_pragma else Token.Pragma
  in
  skip_while state (fun c -> c <> '\n');
  add_token state kind hash

let read_directive state =
  let hash = state.pos in
  advance state 1;
  skip_while state is_blank;
  if next_is state is_digit then
    read_line_marker state
  else
    match read_word state with
    | "line" -> read_line_directive state
    | "pragma" -> read_pragma state hash
    | name -> fail state (Printf.sprintf "unsupported directive #%s" name)

(* The text. *)

(* GCC reads a directive in preprocessed text only where '#' is the first
   byte of a line; both compilers write a '#' that a macro produced
   after a blank, so that it stays a punctuator. *)
let starts_line state = state.pos = 0 || state.text.[state.pos - 1] = '\n'

let read_next state =
  match state.text.[state.pos] with
  | '\n' ->
      advance state 1;
      start_next_line state
  | c when is_blank c -> advance state 1
  | '#' when starts_line state -> read_directive state
  | _ ->
      let start = state.pos in
      let kind = scan_token state in
      add_token state kind start

let read ~name text =
  let state =
    {
      text;
      input_name = name;
      pos = 0;
      presumed = { Location.file = name; line = 1 };
      include_stack = [];
      owners = Owners.empty;
      tokens = [];
    }
  in
  match
    while state.pos < String.length text do
      read_next state
    done
  with
  | () ->
      let tokens = Array.of_list (List.rev state.tokens) in
      Ok { text; tokens }
  | exception Failed error -> Error error

let spelling (result : t) (token : Token.t) =
  match token.kind with
  | Identifier name -> name
  | Number | Character _ | String _ | Punctuator _ | Pragma | Typec_pragma ->
      String.sub result.text token.start token.length

(* The bytes of the text that a replacement replaces, as (start, stop). *)
let replaced_bytes (tokens : Token.t array) replacement =
  let start = tokens.(replacement.first).start in
  if replacement.count = 0 then (start, start)
  else
    let last = tokens.(replacement.first + replacement.count - 1) in
    (start, last.start + last.length)

let rewrite (result : t) replacements =
  let buffer = Buffer.create (String.length result.text) in
  (* [copied] is the end of the text copied so far. A replacement that
     starts before it overlaps or is out of order; one that ends before
     it starts has a negative count. *)
  let apply copied replacement =
    let start, stop = replaced_bytes result.tokens replacement in
    if start < copied || stop < start then
      invalid_arg "Reader.rewrite: replacements out of order";
    Buffer.add_substring buffer result.text copied (start - copied);
    Buffer.add_string buffer replacement.text;
    stop
  in
  let copied = List.fold_left apply 0 replacements in
  Buffer.add_substring buffer result.text copied
    (String.length result.text - copied);
  Buffer.contents buffer

let escaped_byte c = Printf.sprintf "\\x%02X" (Char.code c)

(* How a message shows a character: printable ASCII as itself, an
   extended character as a universal character name and any other as
   [\xNN], as C writes them. *)
let shown_character c =
  let code = Uchar.to_int c in
  if code > 0xFFFF then Printf.sprintf "\\U%08X" code
  else if code >= 0x80 then Printf.sprintf "\\u%04X" code
  else if is_printable (Char.chr code) then String.make 1 (Char.chr code)
  else escaped_byte (Char.chr code)

(* [\xNN] for each of the [length] bytes of [text] from [start]. *)
let escaped_bytes text start length =
  String.concat ""
    (List.init length (fun offset -> escaped_byte text.[start + offset]))

(* Every character that is not printable ASCII is escaped, so that the
   names and spellings of the text cannot send control sequences to a
   terminal: Annex D lets an identifier hold invisible and bidirectional
   characters, and no table here tells which characters print. *)
let escape text =
  let buffer = Buffer.create (String.length text) in
  let index = ref 0 in
  while !index < String.length text do
    let decoded = String.get_utf_8_uchar text !index in
    let length = Uchar.utf_decode_length decoded in
    if Uchar.utf_decode_is_valid decoded then
      Buffer.add_string buffer
        (shown_character (Uchar.utf_decode_uchar decoded))
    else Buffer.add_string buffer (escaped_bytes text !index length);
    index := !index + length
  done;
  Buffer.contents buffer

let error_message error =
  escape
    (Printf.sprintf "%s:%d: %s" error.location.file error.location.line
       error.message)
