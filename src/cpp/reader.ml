(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* [bytes] is the universe text, where the unit is a Type-C unit, then
   the unit's own text, which starts at [own_start]. [definition_lines]
   are the (start, stop) bytes of each definition line without its
   newline, in order: emission copies none of them (design 13.3). *)
type text = {
  bytes : string;
  own_start : int;
  definition_lines : (int * int) list;
}

type t = { text : text; tokens : Token.t array; macros : Macros.t }
type range = { first : int; count : int }
type replacement = { range : range; text : string }
type error = { location : Location.t; message : string }
type include_line = {
  next_token : int;
  directive : string;
  header_name : string;
  location : Location.t;
}

type guard_line =
  | If_not_defined of { name : string; location : Location.t }
  | End_if of Location.t

type own_part =
  | Include_line of include_line
  | Guard_line of guard_line
  | Own_token of Token.t

type interface = {
  unit : t;
  own_text : own_part list;
  holds_text : bool;
}

(* The largest line number a line marker or #line may give (C11 6.10.4);
   it also keeps the number far from overflow while it is read. *)
let max_line_number = 2147483647

(* How a line marker moves on the stack of files being read. *)
type motion = Stay | Enter | Return

module Owners = Map.Make (struct
  type t = string * bool * File.origin

  let compare = Stdlib.compare
end)

(* The position in the text and what the line markers before it said. *)
type state = {
  text : string;
  mutable pos : int;
  mutable presumed : Location.t;  (** of the current line *)
  mutable include_stack : File.t list;
      (** innermost first, and empty until the main file is known. Its
          depth needs no limit: each level costs a line of input, and
          nothing recurses over it. *)
  mutable owners : File.t Owners.t;  (** each owner made so far *)
  mutable tokens : Token.t list;  (** in reverse *)
  mutable token_count : int;  (** the length of [tokens] *)
  mutable macro_lines : Macros.line list;  (** in reverse *)
  mutable definition_lines : (int * int) list;  (** in reverse *)
  interface : bool;
      (** the text is the output of the -E -dI step of an interface whose
          header is written (design 9.3) *)
  mutable main_text_begun : bool;
      (** a line marker has placed the main file at line 1 or later *)
  mutable own_text : own_part list;  (** in reverse *)
  mutable holds_text : bool;
      (** a token or a directive line other than a line marker stood in
          the text of the interface *)
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

(* The newline that ends the line, or the end of the text: a search of
   the bytes, since skipping the rest of the definition lines takes most
   of the time of reading -dD output. *)
let line_end state =
  Option.value
    (String.index_from_opt state.text state.pos '\n')
    ~default:(String.length state.text)

let skip_to_line_end state = state.pos <- line_end state

let start_next_line state =
  state.presumed <- { state.presumed with line = state.presumed.line + 1 }

(* The one value for an owner. *)
let owner state ~origin name system_header =
  let key = (name, system_header, origin) in
  match Owners.find_opt key state.owners with
  | Some file -> file
  | None ->
      let file = { File.name; system_header; origin } in
      state.owners <- Owners.add key file state.owners;
      file

(* A token before the first line marker that names a file has no owner:
   without line markers, which -P and Clang's -fuse-line-directives
   remove, no token can be placed in its file or in a system header. *)
let current_owner state =
  match state.include_stack with
  | file :: _ -> file
  | [] ->
      fail state
        "token before the first line marker, as when an option such as \
         -P removes the line markers"

(* The main file, where it is the current file at the bottom of the
   include stack. *)
let main_at_bottom stack =
  match stack with
  | [ main ] when File.is_main main -> Some main
  | _ -> None

(* The text of the interface is what the output holds while its main file
   is at the bottom of the include stack, from the first line marker that
   places the main file at line 1 or later: GCC names the main file at
   line 0 and then, at line 0 too and without entering a file, the files
   of its predefined macros (design 9.3). From there the stack alone
   decides, for tokens and directives alike: a marker that names another
   file, as a #line of the interface or one that lowering writes in front
   of an instance does, leaves the text where it is. *)
let in_interface_text state =
  state.interface && state.main_text_begun
  && Option.is_some (main_at_bottom state.include_stack)

(* A line marker or #line that names [name] at [next_line] begins the
   text of the interface where it places the main file at line 1 or
   later. *)
let note_main_text_begun state name next_line =
  match main_at_bottom state.include_stack with
  | Some main when name = main.name && next_line >= 1 ->
      state.main_text_begun <- true
  | Some _ | None -> ()

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
  if in_interface_text state then begin
    state.holds_text <- true;
    state.own_text <- Own_token token :: state.own_text
  end;
  state.tokens <- token :: state.tokens;
  state.token_count <- state.token_count + 1

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
let scan_name state =
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
  Buffer.contents name

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

(* The spellings that open a raw string literal, which GCC and Clang
   read in their GNU modes. One may hold newlines, and the lines inside
   it would read as directives, so it is refused wherever it stands. In
   C no identifier stands directly before a string literal, so no valid
   text spells one. *)
let raw_string_openers = [ "R\""; "LR\""; "uR\""; "UR\""; "u8R\"" ]

let raw_string_message =
  "raw string literal, a GNU extension that C does not have"

(* Consumes one token and returns its kind. *)
let scan_token state =
  if List.exists (looking_at state) raw_string_openers then
    fail state raw_string_message;
  let opens_here (opener, _) = looking_at state opener in
  match List.find_opt opens_here literal_openers with
  | Some (opener, kind) ->
      let quote_offset = String.length opener - 1 in
      advance state quote_offset;
      scan_quoted state opener.[quote_offset];
      kind
  | None ->
      if starts_number state then scan_number state
      else if starts_identifier state then Token.Identifier (scan_name state)
      else if looking_at state "/*" || looking_at state "//" then
        fail state
          "comment in preprocessed text, as when an option such as -C \
           keeps the comments"
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
let set_presumed state file next_line flags =
  state.presumed <- { Location.file; line = next_line - 1; flags }

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
  | [] -> (motion, Location.No_flags)
  | [ "3" ] -> (motion, Location.System)
  | [ "3"; "4" ] -> (motion, Location.Extern_c_system)
  | _ -> fail state "invalid line marker flags"

(* The stack of files being read after a line marker with a file name.
   Only a marker that opens a file says whether it is a system header:
   GCC also puts the system flag on markers without the enter flag around
   the tokens of a macro that a system header defines, and those tokens
   belong to the file of the expansion. *)
let stack_after_marker state motion name (flags : Location.flags) =
  let system_header =
    match flags with
    | No_flags -> false
    | System | Extern_c_system -> true
  in
  match (motion, state.include_stack) with
  | Enter, [] -> fail state "line marker enters a file before the main file"
  | Enter, stack -> owner state ~origin:Entered name system_header :: stack
  | Stay, [] -> [ owner state ~origin:Main name system_header ]
  | Stay, stack -> stack
  | Return, _ :: (_ :: _ as includer) -> includer
  | Return, _ -> fail state "line marker returns from the main file"

(* # N "file" flags, and # N. *)
let read_line_marker state =
  let next_line = read_line_number state in
  match read_optional_file_name state with
  | Some name ->
      let motion, flags = read_flags state in
      end_directive state;
      state.include_stack <- stack_after_marker state motion name flags;
      note_main_text_begun state name next_line;
      set_presumed state name next_line flags
  | None ->
      end_directive state;
      note_main_text_begun state state.presumed.file next_line;
      set_presumed state state.presumed.file next_line state.presumed.flags

(* #line N "file", and #line N. *)
let read_line_directive state =
  skip_while state is_blank;
  let next_line = read_line_number state in
  let name =
    Option.value (read_optional_file_name state) ~default:state.presumed.file
  in
  end_directive state;
  note_main_text_begun state name next_line;
  set_presumed state name next_line state.presumed.flags

(* The names of the identifiers among the tokens of the rest of the
   line, in order. Raises [Failed] at the first part that is no token;
   no token holds a newline, so the cursor stays on the line. *)
let rec line_identifiers state names =
  skip_while state is_blank;
  match peek state 0 with
  | None | Some '\n' -> List.rev names
  | Some _ -> (
      match scan_token state with
      | Token.Identifier name -> line_identifiers state (name :: names)
      | Number | Character _ | String _ | Punctuator _ | Pragma _
      | Typec_pragma ->
          line_identifiers state names)

(* A pragma line that is no sequence of tokens is no error of the text:
   C text passes the line on whole, and the parser refuses it where a
   rule reads its identifiers (design 13.5). *)
(* Every raw string opener ends in R". A backend may lex on past the
   part where the reader stopped and find a raw string there, so a line
   that holds R" from that part on is refused, whatever stands before
   it. *)
let holds_raw_string_tail state =
  let stop = line_end state in
  let rec from index =
    index + 1 < stop
    && ((state.text.[index] = 'R' && state.text.[index + 1] = '"')
       || from (index + 1))
  in
  from state.pos

let pragma_text state =
  match line_identifiers state [] with
  | names -> Token.Identifiers names
  | exception Failed { message; _ } ->
      if holds_raw_string_tail state then fail state raw_string_message;
      Token.Not_tokens message

(* A [#pragma typec] line is one whose first token is the identifier
   [typec], read as any other identifier, so that a longer name such as
   [typec\u00e9] is none. A first part that is no token makes no such
   line. *)
let begins_typec_pragma state =
  match peek state 0 with
  | None | Some '\n' -> false
  | Some _ -> (
      match scan_token state with
      | Token.Identifier "typec" -> true
      | _ -> false
      | exception Failed _ -> false)

(* The whole line is the token, so that it can be passed through. *)
let read_pragma state hash =
  skip_while state is_blank;
  let text_start = state.pos in
  let kind =
    if begins_typec_pragma state then Token.Typec_pragma
    else begin
      state.pos <- text_start;
      Token.Pragma (pragma_text state)
    end
  in
  skip_to_line_end state;
  add_token state kind hash

(* Definition lines, which -dD writes (design 13.3). *)

let read_macro_name state =
  if not (next_is state is_blank) then fail state "missing macro name";
  skip_while state is_blank;
  (* A digit continues an identifier but begins none. *)
  if next_is state is_digit || not (starts_identifier state) then
    fail state "missing macro name";
  scan_name state

(* What follows the name of a macro: its parameters, a blank before its
   replacement list, or the end of the line. *)
let end_macro_name state =
  match peek state 0 with
  | None | Some ('(' | '\n') -> ()
  | Some c when is_blank c -> ()
  | Some _ -> fail state "unexpected text after the macro name"

(* The change takes effect at the next token. The line, which ends at
   the cursor, is kept out of emission. *)
let record_change state ~line_start name change =
  let line = { Macros.name; position = state.token_count; change } in
  state.macro_lines <- line :: state.macro_lines;
  state.definition_lines <- (line_start, state.pos) :: state.definition_lines

(* No consumer reads the parameters or the replacement list, and -dD
   writes far more of them than there are tokens, so the rest of the line
   is skipped without lexing it unless it holds a quote. A raw string
   literal, which GCC and Clang read in their GNU modes, may run past its
   line, and -dD writes its newlines as they are, so the lines inside it
   would read as directives; lexing refuses it (scan_token). *)
let skip_replacement_list state =
  let stop = line_end state in
  let rec holds_quote index =
    index < stop && (state.text.[index] = '"' || holds_quote (index + 1))
  in
  (* Lexed for its refusals alone: no consumer reads the tokens. *)
  let lex_rest_of_line () = ignore (line_identifiers state []) in
  if holds_quote state.pos then lex_rest_of_line () else state.pos <- stop

let read_definition state ~line_start =
  let name = read_macro_name state in
  end_macro_name state;
  let definition =
    { Macros.owner = current_owner state; location = state.presumed }
  in
  skip_replacement_list state;
  record_change state ~line_start name (Defined definition)

let read_undefinition state ~line_start =
  let name = read_macro_name state in
  end_directive state;
  record_change state ~line_start name Undefined

(* The delimiter that ends a header name that starts at the cursor: it
   ends at the first one on its line (C11 6.4.7). *)
let header_name_closing state =
  match peek state 0 with
  | Some '"' -> Some '"'
  | Some '<' -> Some '>'
  | Some _ | None -> None

(* The index of the last byte of the header name at the cursor. *)
let header_name_end state =
  match header_name_closing state with
  | None -> None
  | Some closing -> (
      match String.index_from_opt state.text (state.pos + 1) closing with
      | Some stop when stop < line_end state -> Some stop
      | Some _ | None -> None)

(* Clang ends the lines of -dI with this comment, and GCC does not. *)
let clang_include_comment = " /* clang -E -dI */"

(* An include line of -dI is read exactly (design 9.3): the directive
   right after the '#' of the first column, one space, the header name
   and the end of the line or Clang's comment. *)
let read_include_line state ~hash directive =
  let malformed () =
    fail state
      (Printf.sprintf "malformed #%s line in the output of -dI" directive)
  in
  if state.pos <> hash + 1 + String.length directive then malformed ();
  if peek state 0 <> Some ' ' then malformed ();
  advance state 1;
  let start = state.pos in
  let stop =
    match header_name_end state with
    | Some stop -> stop
    | None -> malformed ()
  in
  state.pos <- stop + 1;
  let name = String.sub state.text start (state.pos - start) in
  if looking_at state clang_include_comment then
    advance state (String.length clang_include_comment);
  if state.pos <> line_end state then malformed ();
  let line =
    {
      next_token = state.token_count;
      directive;
      header_name = name;
      location = state.presumed;
    }
  in
  state.own_text <- Include_line line :: state.own_text

(* The lines of the guard of an instance's definition in the lowered
   text of an interface are read exactly, as lowering writes them: the
   directive right after the '#' of the first column, then one space and
   a name for [#ifndef], then the end of the line. *)
let read_guard_line state ~hash directive read_rest =
  let malformed () =
    fail state (Printf.sprintf "malformed #%s line" directive)
  in
  if state.pos <> hash + 1 + String.length directive then malformed ();
  let line = read_rest ~malformed state.presumed in
  if state.pos <> line_end state then malformed ();
  state.own_text <- Guard_line line :: state.own_text

let read_if_not_defined_line state ~hash =
  read_guard_line state ~hash "ifndef" (fun ~malformed location ->
      if peek state 0 <> Some ' ' then malformed ();
      advance state 1;
      if not (starts_identifier state) then malformed ();
      If_not_defined { name = scan_name state; location })

let read_end_if_line state ~hash =
  read_guard_line state ~hash "endif" (fun ~malformed:_ location ->
      End_if location)

(* In the text of an interface whose header is written, an include line
   is read and every other directive that no unit reads is refused,
   since the header carries none; deeper text reaches no header, and its
   lines are passed over (design 9.3). An [#ifndef] or [#endif] line is
   read as a line of the guard of an instance, which the lowered text
   holds and the header refuses in the step's output. *)
let read_other_directive state ~hash name =
  if not state.interface then
    fail state (Printf.sprintf "unsupported directive #%s" name)
  else if not (in_interface_text state) then skip_to_line_end state
  else
    match name with
    | "include" | "include_next" | "import" ->
        read_include_line state ~hash name
    | "ifndef" -> read_if_not_defined_line state ~hash
    | "endif" -> read_end_if_line state ~hash
    | _ ->
        fail state
          (Printf.sprintf
             "#%s in an interface whose header is written: the header \
              carries no directive of the interface but its include lines \
              and pragmas"
             name)

let read_directive state =
  let hash = state.pos in
  advance state 1;
  skip_while state is_blank;
  if next_is state is_digit then
    read_line_marker state
  else begin
    if in_interface_text state then state.holds_text <- true;
    match read_word state with
    | "line" -> read_line_directive state
    | "pragma" -> read_pragma state hash
    | "define" -> read_definition state ~line_start:hash
    | "undef" -> read_undefinition state ~line_start:hash
    | name -> read_other_directive state ~hash name
  end

(* The text. *)

(* The reader reads a directive only where '#' is the first byte of a
   line, as GCC does. *)
let starts_line state = state.pos = 0 || state.text.[state.pos - 1] = '\n'

(* Preprocessed C holds no '#' or '##' outside a directive, and Clang
   reads a line as a directive wherever '#' or '%:' is its first token,
   blanks before it or not; refusing every such punctuator keeps the
   backend from applying a pragma or a line marker that typec has not
   read, whatever the backend takes for the start of a line. *)
let refuse_stray_hash state start =
  let spelling = String.sub state.text start (state.pos - start) in
  fail state
    (Printf.sprintf
       "stray '%s' outside a directive, as when a macro expands to it"
       spelling)

let read_token state =
  let start = state.pos in
  match scan_token state with
  | Token.Punctuator (Hash | Hash_hash) -> refuse_stray_hash state start
  | kind -> add_token state kind start

let read_next state =
  match state.text.[state.pos] with
  | '\n' ->
      advance state 1;
      start_next_line state
  | c when is_blank c -> advance state 1
  | '#' when starts_line state -> read_directive state
  | _ -> read_token state

let first_line name = { Location.file = name; line = 1; flags = No_flags }

(* The universe text is typec's own, so the flag 3 of its lines exempts
   the instances that lowering writes from it from the warnings that
   judge the user's code, as it exempts typec's assertions (design
   13.4). *)
let universe_first_line =
  { Location.file = File.universe.name; line = 1; flags = System }

(* Reads the text from the cursor up to [stop], which ends a line, from
   the line [first] and with [include_stack] in place. *)
let read_part state ~stop ~first ~include_stack =
  state.presumed <- first;
  state.include_stack <- include_stack;
  while state.pos < stop do
    read_next state
  done

let initial_state ~interface ~name text =
  {
    interface;
    main_text_begun = false;
    own_text = [];
    holds_text = false;
    text;
    pos = 0;
    presumed = first_line name;
    include_stack = [];
    owners = Owners.empty;
    tokens = [];
    token_count = 0;
    macro_lines = [];
    definition_lines = [];
  }

(* Whether the main file is Type-C text (design 2.1), which makes the
   unit a Type-C unit. Only the lines up to the marker that opens the
   main file are read, as no token comes before it. Text that has no
   such marker, or fails before it, is a C unit here, and its full read
   then reports the same failure, at the same place. *)
let is_type_c_unit ~name text =
  let state = initial_state ~interface:false ~name text in
  match
    while state.pos < String.length text && state.include_stack = [] do
      read_next state
    done
  with
  | () -> (
      match state.include_stack with
      | main :: _ -> File.is_type_c_text main
      | [] -> false)
  | exception Failed _ -> false

(* The universe text needs no line marker: its owner is on the stack from
   its first byte. The unit's own text then starts afresh, as if it were
   read alone. *)
let read_after ~interface ~universe ~name text =
  let bytes = universe ^ text in
  let own_start = String.length universe in
  let state = initial_state ~interface ~name bytes in
  match
    read_part state ~stop:own_start ~first:universe_first_line
      ~include_stack:[ File.universe ];
    read_part state ~stop:(String.length bytes) ~first:(first_line name)
      ~include_stack:[]
  with
  | () ->
      let tokens = Array.of_list (List.rev state.tokens) in
      let definition_lines = List.rev state.definition_lines in
      let macros = Macros.of_lines (List.rev state.macro_lines) in
      let unit =
        { text = { bytes; own_start; definition_lines }; tokens; macros }
      in
      Ok
        {
          unit;
          own_text = List.rev state.own_text;
          holds_text = state.holds_text;
        }
  | exception Failed error -> Error error

(* A C unit has no universe text, so its first part is empty and reads
   nothing. *)
let read_any ~interface ~name text =
  let universe =
    if is_type_c_unit ~name text then File.universe_text else ""
  in
  read_after ~interface ~universe ~name text

let read ~name text =
  Result.map
    (fun (read : interface) -> read.unit)
    (read_any ~interface:false ~name text)

let read_interface ~name text = read_any ~interface:true ~name text

let spelling (result : t) (token : Token.t) =
  match token.kind with
  | Identifier name -> name
  | Number | Character _ | String _ | Punctuator _ | Pragma _ | Typec_pragma
    ->
      String.sub result.text.bytes token.start token.length

(* A pragma token is a line of its own, which a macro's [_Pragma] may
   leave inside an expression; the text that a message quotes is the
   tokens around it. *)
let is_pragma (token : Token.t) =
  match token.kind with
  | Pragma _ | Typec_pragma -> true
  | Identifier _ | Number | Character _ | String _ | Punctuator _ -> false

let excerpt (result : t) ~first ~last =
  let words = Buffer.create 32 in
  let written = ref None in
  for index = first to last do
    let token = result.tokens.(index) in
    if not (is_pragma token) then begin
      (match !written with
      | Some (before : Token.t) when before.start + before.length < token.start
        ->
          Buffer.add_char words ' '
      | Some _ | None -> ());
      Buffer.add_string words (spelling result token);
      written := Some token
    end
  done;
  Buffer.contents words

let range (tokens : Token.t array) ~first ~count =
  let token_count = Array.length tokens in
  if first < 0 || first >= token_count || count < 0
     || count > token_count - first
  then invalid_arg "Reader.range: outside the tokens";
  { first; count }

let end_place (tokens : Token.t array) =
  { first = Array.length tokens; count = 0 }

let is_at_end (tokens : Token.t array) range =
  range.first = Array.length tokens

let end_token range =
  if range.count = 0 then range.first else range.first + range.count - 1

(* The bytes of the text that a range replaces, as (start, stop); an
   insertion at the end goes after every byte of the text. *)
let replaced_bytes (result : t) range =
  let tokens = result.tokens in
  if is_at_end tokens range then
    let length = String.length result.text.bytes in
    (length, length)
  else
    let start = tokens.(range.first).start in
    if range.count = 0 then (start, start)
    else
      let last = tokens.(end_token range) in
      (start, last.start + last.length)

(* The universe text holds no definition line (File.universe_text), so
   each line counted is in the unit's own text. *)
let length (result : t) =
  let line_bytes sum (start, stop) = sum + (stop - start) in
  let definitions = List.fold_left line_bytes 0 result.text.definition_lines in
  String.length result.text.bytes - result.text.own_start - definitions

(* Copies the bytes from [from] to [upto] but the definition lines among
   them, and gives the lines not yet passed. [lines] are in order, and
   one that starts before [from] lay in a range that a replacement
   dropped. A line lies between two tokens, so it ends by [upto]. *)
let rec copy_without_definitions buffer bytes lines ~from ~upto =
  match lines with
  | (start, _) :: rest when start < from ->
      copy_without_definitions buffer bytes rest ~from ~upto
  | (start, stop) :: rest when start < upto ->
      Buffer.add_substring buffer bytes from (start - from);
      copy_without_definitions buffer bytes rest ~from:stop ~upto
  | _ ->
      Buffer.add_substring buffer bytes from (upto - from);
      lines

let rewrite (result : t) replacements =
  let { bytes; own_start; definition_lines } = result.text in
  let buffer = Buffer.create (length result) in
  let copy lines ~from ~upto =
    copy_without_definitions buffer bytes lines ~from ~upto
  in
  (* [next] is the token after the range of the replacement before; a
     range that starts before it overlaps that range or is out of order.
     [copied] is the end of the text copied so far, which starts with the
     unit's own text, and [lines] the definition lines after it. *)
  let apply (next, copied, lines) { range; text } =
    if range.first < next then
      invalid_arg "Reader.rewrite: replacements out of order";
    let start, stop = replaced_bytes result range in
    if start < own_start then
      invalid_arg "Reader.rewrite: a replacement in the universe";
    let lines = copy lines ~from:copied ~upto:start in
    Buffer.add_string buffer text;
    (range.first + range.count, stop, lines)
  in
  let _, copied, lines =
    List.fold_left apply (0, own_start, definition_lines) replacements
  in
  ignore (copy lines ~from:copied ~upto:(String.length bytes));
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

let error_message (error : error) =
  escape
    (Printf.sprintf "%s:%d: error: %s" error.location.file
       error.location.line error.message)
