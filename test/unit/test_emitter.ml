(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax
open Typec_emit

let failures = ref 0

let check name passed =
  if not passed then begin
    Printf.eprintf "FAIL: %s\n" name;
    incr failures
  end

let read text =
  match Reader.read ~name:"input.i" text with
  | Ok unit -> unit
  | Error error -> failwith (Reader.error_message error)

(* Tokens: int x = 1 ; | int y ; (in h.h) | int z ; *)
let source =
  "# 1 \"a.c\"\n\
   int x = 1;\n\
   # 1 \"h.h\" 1 3\n\
   int y;\n\
   # 2 \"a.c\" 2\n\
   int z;\n"

let unit = read source
let at line : Location.t = { file = "a.c"; line; flags = No_flags }

(* The text with [edits] and no assertions. *)
let emit unit edits = Emitter.emit unit { edits; assertions = [] }

let edit (unit : Reader.t) ~first ~count location text =
  Emitter.code (Reader.range unit.tokens ~first ~count) ~location text

(* x = 1 becomes x = 2 at line 1. *)
let replacement = edit unit ~first:1 ~count:3 (at 1) "x = 2"

(* int w; goes before int z, at line 2. *)
let insertion = edit unit ~first:8 ~count:0 (at 2) "int w;"

let () =
  check "no edits: the text itself" (emit unit [] = source);
  check "a replacement and an insertion"
    (emit unit [ replacement; insertion ]
    = "# 1 \"a.c\"\n\
       int \n\
       # 1 \"a.c\"\n\
       x = 2\n\
       # 1 \"a.c\"\n\
       ;\n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.c\" 2\n\
       \n\
       # 2 \"a.c\"\n\
       int w;\n\
       # 2 \"a.c\"\n\
       int z;\n")

(* An edit between identifiers that universal character names spell
   leaves their bytes as written, though their names are in UTF-8. *)
let () =
  let written = read "# 1 \"input.i\"\ncaf\\u00e9 = x\\U0001F600;\n" in
  let edit = edit written ~first:1 ~count:1 (at 1) "+=" in
  check "an edit keeps universal character names as written"
    (emit written [ edit ]
    = "# 1 \"input.i\"\n\
       caf\\u00e9 \n\
       # 1 \"a.c\"\n\
       +=\n\
       # 1 \"input.i\"\n\
      \ x\\U0001F600;\n")

(* y becomes w in the system header h.h, which stays one for the
   backend's warnings. *)
let () =
  let in_header = unit.tokens.(6).location in
  let edit = edit unit ~first:6 ~count:1 in_header "w" in
  let owner (token : Token.t) = (token.owner.name, token.owner.system_header) in
  let owners text = Array.to_list (Array.map owner (read text).tokens) in
  check "read back, an edit in a system header keeps the owners"
    (owners (emit unit [ edit ]) = owners source);
  check "an edit in a system header"
    (emit unit [ edit ]
    = "# 1 \"a.c\"\n\
       int x = 1;\n\
       # 1 \"h.h\" 1 3\n\
       int \n\
       # 1 \"h.h\" 3\n\
       w\n\
       # 1 \"h.h\" 3\n\
       ;\n\
       # 2 \"a.c\" 2\n\
       int z;\n")

(* y becomes w after the marker that #pragma GCC system_header gives:
   the markers repeat its flag, though the owner p.h is no system header,
   and read back keep the owners. *)
let () =
  let source =
    "# 1 \"a.c\"\n\
     # 1 \"p.h\" 1\n\
     # 2 \"p.h\" 3\n\
     int y;\n\
     # 2 \"a.c\" 2\n\
     int z;\n"
  in
  let unit = read source in
  let edit = edit unit ~first:1 ~count:1 unit.tokens.(1).location "w" in
  let owner (token : Token.t) = token.owner in
  let owners text = Array.to_list (Array.map owner (read text).tokens) in
  check "read back, an edit after the pragma keeps the owners"
    (owners (emit unit [ edit ]) = owners source);
  check "an edit after the marker of the pragma"
    (emit unit [ edit ]
    = "# 1 \"a.c\"\n\
       # 1 \"p.h\" 1\n\
       # 2 \"p.h\" 3\n\
       int \n\
       # 2 \"p.h\" 3\n\
       w\n\
       # 2 \"p.h\" 3\n\
       ;\n\
       # 2 \"a.c\" 2\n\
       int z;\n")

(* In the expansion of a macro that a system header defines, which GCC
   marks with flags 3 and 4, lowered text takes the flags of the
   construct it lowers, and the marker after it restores those of the
   token where the replaced range ends. *)
let () =
  let unit =
    read
      "# 1 \"a.c\"\n\
       int\n\
       # 1 \"a.c\" 3 4\n\
       m\n\
       # 1 \"a.c\"\n\
       ;\n"
  in
  let inside = edit unit ~first:1 ~count:1 unit.tokens.(1).location "n" in
  let before = edit unit ~first:0 ~count:1 unit.tokens.(0).location "long" in
  check "edits in and before a system macro region"
    (emit unit [ before; inside ]
    = "# 1 \"a.c\"\n\
       \n\
       # 1 \"a.c\"\n\
       long\n\
       # 1 \"a.c\"\n\
       \n\
       # 1 \"a.c\" 3 4\n\
       \n\
       # 1 \"a.c\" 3 4\n\
       n\n\
       # 1 \"a.c\" 3 4\n\
       \n\
       # 1 \"a.c\"\n\
       ;\n")

(* What the backend sees of a token: its bytes, where it is and the file
   it belongs to. *)
let seen (unit : Reader.t) (token : Token.t) =
  (Reader.spelling unit token, token.location, token.owner)

let seen_all unit = Array.to_list (Array.map (seen unit) unit.Reader.tokens)

let rec drop count list =
  if count = 0 then list else drop (count - 1) (List.tl list)

let rec take count list =
  if count = 0 then [] else List.hd list :: take (count - 1) (List.tl list)

(* Read back, the tokens outside the replaced range keep their place and
   owner, and those of the edit are at its location. *)
let () =
  let emitted = read (emit unit [ replacement ]) in
  let before = take 1 (seen_all unit) and after = drop 4 (seen_all unit) in
  let emitted_tokens = seen_all emitted in
  let edit_tokens = take 3 (drop 1 emitted_tokens) in
  check "untouched tokens keep their place"
    (take 1 emitted_tokens = before && drop 4 emitted_tokens = after);
  check "edit tokens are at its location"
    (List.for_all
       (fun (_, location, (owner : File.t)) ->
         location = at 1 && owner.name = "a.c")
       edit_tokens)

(* Each check raises its own message, so a test that names it shows
   which check refused the edits. *)
let raises make message =
  match make () with
  | _ -> false
  | exception Invalid_argument raised -> raised = message

let out_of_order edits =
  raises
    (fun () -> emit unit edits)
    "Reader.rewrite: replacements out of order"

let spans_files edits =
  raises (fun () -> emit unit edits) "Emitter.emit: an edit spans files"

let outside ~first ~count =
  raises
    (fun () -> Reader.range unit.tokens ~first ~count)
    "Reader.range: outside the tokens"

let () =
  check "overlapping edits"
    (out_of_order [ replacement; edit unit ~first:3 ~count:1 (at 1) "2" ]);
  check "edits in any order"
    (emit unit [ insertion; replacement ]
    = emit unit [ replacement; insertion ]);
  check "replacement past the last token" (outside ~first:9 ~count:3);
  check "insertion after the last token" (outside ~first:11 ~count:0);
  check "range before the first token" (outside ~first:(-1) ~count:1);
  check "negative count" (outside ~first:8 ~count:(-1));
  check "an edit that spans files"
    (spans_files [ edit unit ~first:1 ~count:6 (at 1) "x = 2" ]);
  check "adjacent edits"
    (emit unit [ replacement; edit unit ~first:4 ~count:1 (at 1) "," ]
    = "# 1 \"a.c\"\n\
       int \n\
       # 1 \"a.c\"\n\
       x = 2\n\
       # 1 \"a.c\"\n\
       \n\
       # 1 \"a.c\"\n\
       ,\n\
       # 1 \"a.c\"\n\
       \n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.c\" 2\n\
       int z;\n");
  check "insertions in front of one token keep their order"
    (emit unit
       [ edit unit ~first:8 ~count:0 (at 2) "int v;"; insertion ]
    = "# 1 \"a.c\"\n\
       int x = 1;\n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.c\" 2\n\
       \n\
       # 2 \"a.c\"\n\
       int v;\n\
       # 2 \"a.c\"\n\
       \n\
       # 2 \"a.c\"\n\
       int w;\n\
       # 2 \"a.c\"\n\
       int z;\n");
  check "assertions follow the text under a marker of their own"
    (Emitter.emit unit
       { edits = [ replacement ]; assertions = [ "int a;"; "int b;" ] }
    = "# 1 \"a.c\"\n\
       int \n\
       # 1 \"a.c\"\n\
       x = 2\n\
       # 1 \"a.c\"\n\
       ;\n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.c\" 2\n\
       int z;\n\
       \n\
       # 1 \"<typec>\" 3\n\
       int a;\n\
       int b;\n");
  ()

let declarations = Typec_test_support.External_declarations.of_unit

(* The pieces of the [count] tokens of [unit] from [first], none of them
   a pragma line. *)
let pieces unit ~first ~count =
  List.init count (fun offset ->
      Option.get (Emitter.token unit (first + offset)))

(* A bracketed text stands in the packing bracket of design 10.3, whose
   pragmas take the line of the edit, and the unit ends with the packing
   probe after the assertions; one without assertions gets the probe all
   the same. *)
let probe =
  "#pragma pack(push)\n\
   #pragma pack(1)\n\
   #pragma pack(push)\n\
   #pragma pack()\n\
   struct __tc_pack_probe_1 { char c; int i; };\n\
   #pragma pack(pop)\n\
   #pragma pack(2)\n\
   #pragma pack(push)\n\
   #pragma pack()\n\
   struct __tc_pack_probe_2 { char c; int i; };\n\
   #pragma pack(pop)\n\
   #pragma pack(pop)\n\
   _Static_assert(_Alignof(struct __tc_pack_probe_1) \
   == _Alignof(struct __tc_pack_probe_2), \"typec assumes \
   '#pragma pack()' restores the packing of the command line \
   (-fapple-pragma-pack or -fxl-pragma-pack?)\");\n"

let () =
  let anchor = Tree.anchor (List.nth (declarations unit) 2) in
  let bracketed =
    Emitter.bracketed unit ~at:anchor ~location:(at 2)
      [ Emitter.generated (at 2) "struct s { int n; };" ]
  in
  let text =
    "# 1 \"a.c\"\n\
     int x = 1;\n\
     # 1 \"h.h\" 1 3\n\
     int y;\n\
     # 2 \"a.c\" 2\n\
     \n\
     # 2 \"a.c\"\n\
     #pragma pack(push)\n\
     #pragma pack()\n\
     # 2 \"a.c\"\n\
     struct s { int n; };\n\
     # 2 \"a.c\"\n\
     #pragma pack(pop)\n\
     # 2 \"a.c\"\n\
     int z;\n\
     \n\
     # 1 \"<typec>\" 3\n"
  in
  check "a bracketed text, then the assertions and the probe"
    (Emitter.emit unit { edits = [ bracketed ]; assertions = [ "int a;" ] }
    = text ^ "int a;\n" ^ probe);
  check "the probe without assertions"
    (Emitter.emit unit { edits = [ bracketed ]; assertions = [] }
    = text ^ probe)

(* Tokens: struct box { int value ; } ; (g.h, lines 1 to 3) |
   typedef int word ; (s.h, a system header) | int z ; (a.c, line 2) *)
let moving =
  read
    "# 1 \"a.c\"\n\
     # 1 \"g.h\" 1\n\
     struct box {\n\
    \  int value;\n\
     };\n\
     # 1 \"s.h\" 1 3\n\
     typedef int word;\n\
     # 4 \"g.h\" 2\n\
     # 2 \"a.c\" 2\n\
     int z;\n"

let own index = moving.tokens.(index).location

(* The typedef of s.h and the structure of g.h, renamed as an instance
   would be, move in front of int z: each token keeps its own file, line
   and flags, the name written for box takes the line of box, and the
   bracket takes the line of the edit. *)
let moved =
  Emitter.bracketed moving
    ~at:(Tree.anchor (List.nth (declarations moving) 2))
    ~location:(own 12)
    (pieces moving ~first:8 ~count:4
    @ pieces moving ~first:0 ~count:1
    @ [ Emitter.generated (own 1) "box__i" ]
    @ pieces moving ~first:2 ~count:6)

let moved_text = Emitter.emit moving { edits = [ moved ]; assertions = [] }

let () =
  check "moved text keeps the lines of its tokens"
    (moved_text
    = "# 1 \"a.c\"\n\
       # 1 \"g.h\" 1\n\
       struct box {\n\
      \  int value;\n\
       };\n\
       # 1 \"s.h\" 1 3\n\
       typedef int word;\n\
       # 4 \"g.h\" 2\n\
       # 2 \"a.c\" 2\n\
       \n\
       # 2 \"a.c\"\n\
       #pragma pack(push)\n\
       #pragma pack()\n\
       # 1 \"s.h\" 3\n\
       typedef int word ;\n\
       # 1 \"g.h\"\n\
       struct box__i {\n\
       # 2 \"g.h\"\n\
       int value ;\n\
       # 3 \"g.h\"\n\
       } ;\n\
       # 2 \"a.c\"\n\
       #pragma pack(pop)\n\
       # 2 \"a.c\"\n\
       int z;\n\
       \n\
       # 1 \"<typec>\" 3\n"
      ^ probe)

(* Read back, every moved token is where its own token was, the pragmas
   of the bracket open at the edit's line and close on it, and the tokens
   after it are where they were. The emitted tokens are the 12 of the
   text before the edit, the two opening pragmas, the 12 moved, the
   closing pragma and int z ;. *)
let () =
  let location (token : Token.t) = token.location in
  let read_back =
    Array.to_list (Array.map location (read moved_text).tokens)
  in
  check "read back, moved tokens are at their own locations"
    (take 12 (drop 14 read_back)
    = List.map own [ 8; 9; 10; 11; 0; 1; 2; 3; 4; 5; 6; 7 ]);
  check "read back, the bracket and the text after it are at the edit"
    (take 2 (drop 12 read_back) = [ own 12; { (own 12) with line = 3 } ]
    && take 4 (drop 26 read_back) = List.map own [ 12; 12; 13; 14 ])

(* A piece holds no pragma line: the token of one is none, and typec's
   own text that would write one is refused. The reader refuses a #
   outside a directive. Tokens: two pragma lines | int a ; *)
let () =
  let unit =
    read
      "# 1 \"a.c\"\n\
       #pragma pack(1)\n\
       #pragma typec checked\n\
       int a;\n"
  in
  let piece index = Option.is_some (Emitter.token unit index) in
  check "no piece of a pragma line" (not (piece 0));
  check "no piece of a pragma typec line" (not (piece 1));
  check "a piece of any other token" (piece 2 && piece 3 && piece 4);
  let refused text =
    raises
      (fun () -> Emitter.generated (at 1) text)
      (Printf.sprintf
         "Emitter.generated: %S holds a byte that typec's text never does"
         text)
  in
  check "generated text holds no #pragma" (refused "#pragma pack(1)");
  check "generated text holds no %: pragma" (refused "%:pragma pack(1)");
  check "generated text holds no ??= pragma" (refused "??=pragma pack(1)");
  check "generated text holds no _Pragma" (refused "_Pragma(\"pack(1)\")");
  check "generated text is one line" (refused "int a;\nint b;");
  check "generated text ends no line in Clang" (refused "int a;\r");
  check "generated text splices no line" (refused "int a; \\");
  check "generated text opens no comment" (refused "int a; /*");
  check "generated text may hold a name with _Pragma"
    (not (refused "typedef int my_Pragma;"));
  check "code holds no pragma"
    (raises
       (fun () -> edit unit ~first:2 ~count:0 (at 1) "#pragma pack(push)")
       "Emitter.code: \"#pragma pack(push)\" holds a byte that typec's \
        text never does")

(* A token of the universe text (design 3.6) is a piece at its own place
   in the universe, under flag 3 as typec's own text (design 13.4), and
   emission writes the unit's own text alone. The other cases read C
   units, which have no universe text.
   Tokens: the universe text, line 2 from its 16th | int a ; *)
let () =
  let own_text = "# 1 \"a.tc\"\nint a;\n" in
  let unit = read own_text in
  let at line : Location.t = { file = "a.tc"; line; flags = No_flags } in
  let a = Array.length unit.tokens - 2 in
  let universe_at line : Location.t =
    { file = "<universe>"; line; flags = System }
  in
  (* A piece is the text and its location, as typec's own text is. *)
  let is_piece index location text =
    Emitter.token unit index = Some (Emitter.generated location text)
  in
  check "a universe token is at its line"
    (is_piece 1 (universe_at 1) "option"
    && is_piece 15 (universe_at 2) "type");
  check "a token of the unit follows the universe" (is_piece a (at 1) "a");
  check "no edits: the unit's own text" (emit unit [] = own_text);
  check "an edit of the unit's own text"
    (emit unit [ edit unit ~first:a ~count:1 (at 1) "b" ]
    = "# 1 \"a.tc\"\nint \n# 1 \"a.tc\"\nb\n# 1 \"a.tc\"\n;\n")

(* A token of moved text is a pragma line where it is a #pragma line
   that is a sequence of preprocessing tokens, a piece where it is a
   movable token, and none else. Tokens: four pragma lines | int a ; *)
let () =
  let unit =
    read
      "# 1 \"a.c\"\n\
       #pragma GCC diagnostic push\n\
       #pragma typec checked\n\
       #pragma mark - Don't\n\
       #pragma weak f \\\n\
       int a;\n"
  in
  let moved index =
    match Emitter.moved_token unit index with
    | Some (Pragma_line _) -> `Line
    | Some (Piece _) -> `Piece
    | None -> `None
  in
  check "a pragma line of a #pragma line" (moved 0 = `Line);
  check "no moved token of a pragma typec line" (moved 1 = `None);
  check "no moved token of a line with an open quote" (moved 2 = `None);
  check "no moved token of a line that would splice the next"
    (moved 3 = `None);
  check "a piece of any other token"
    (List.for_all (fun index -> moved index = `Piece) [ 4; 5; 6 ])

(* Tokens: int a ; (line 1) | a pragma line (line 2) | int b ; (line 3) |
   int z ; (line 4) *)
let pragmatic =
  read
    "# 1 \"a.c\"\n\
     int a;\n\
     #pragma GCC diagnostic push\n\
     int b;\n\
     int z;\n"

let moved index = Option.get (Emitter.moved_token pragmatic index)

(* The tokens of int a ; #pragma int b ; and a name of typec's at the
   pragma's line, moved in place of int z ;. *)
let moved_with_pragma =
  Emitter.moved
    (Reader.range pragmatic.tokens ~first:7 ~count:3)
    [ moved 0; moved 1; moved 2; moved 3;
      Emitter.Piece (Emitter.generated (at 2) "int c;");
      moved 4; moved 5; moved 6 ]

let moved_pragma_text = emit pragmatic [ moved_with_pragma ]

(* Moved text is written as in a bracket, without the bracket's pragmas
   and so without the probe; the pragma line stands on a line of its own
   under a marker for its line, and joins no piece at that line. *)
let () =
  check "moved text with a pragma line"
    (moved_pragma_text
    = "# 1 \"a.c\"\n\
       int a;\n\
       #pragma GCC diagnostic push\n\
       int b;\n\
       \n\
       # 1 \"a.c\"\n\
       int a ;\n\
       # 2 \"a.c\"\n\
       #pragma GCC diagnostic push\n\
       # 2 \"a.c\"\n\
       int c;\n\
       # 3 \"a.c\"\n\
       int b ;\n\
       # 4 \"a.c\"\n\
       \n")

(* Read back, every moved token, the pragma line among them, is at its
   own location, and nothing follows the edit. The emitted tokens are
   the 7 before the edit and the 10 moved. *)
let () =
  let read_back = (read moved_pragma_text).tokens in
  let location (token : Token.t) = token.location in
  check "read back, a moved pragma line is a pragma line"
    (match read_back.(10).kind with
     | Pragma (Identifiers [ "GCC"; "diagnostic"; "push" ]) -> true
     | _ -> false);
  check "read back, moved tokens and a pragma line at their own places"
    (drop 7 (Array.to_list (Array.map location read_back))
    = List.map at [ 1; 1; 1; 2; 2; 2; 2; 3; 3; 3 ]);
  check "read back, nothing follows the moved text"
    (Array.length read_back = 17)

let () = if !failures > 0 then exit 1
