(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
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
  "# 1 \"a.tc\"\n\
   int x = 1;\n\
   # 1 \"h.h\" 1 3\n\
   int y;\n\
   # 2 \"a.tc\" 2\n\
   int z;\n"

let unit = read source
let at line : Location.t = { file = "a.tc"; line; flags = No_flags }

let edit (unit : Reader.t) ~first ~count location text : Emitter.edit =
  { range = Reader.range unit.tokens ~first ~count; location; text }

(* x = 1 becomes x = 2 at line 1. *)
let replacement = edit unit ~first:1 ~count:3 (at 1) "x = 2"

(* int w; goes before int z, at line 2. *)
let insertion = edit unit ~first:8 ~count:0 (at 2) "int w;"

let () =
  check "no edits: the text itself" (Emitter.emit unit [] = source);
  check "a replacement and an insertion"
    (Emitter.emit unit [ replacement; insertion ]
    = "# 1 \"a.tc\"\n\
       int \n\
       # 1 \"a.tc\"\n\
       x = 2\n\
       # 1 \"a.tc\"\n\
       ;\n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.tc\" 2\n\
       \n\
       # 2 \"a.tc\"\n\
       int w;\n\
       # 2 \"a.tc\"\n\
       int z;\n")

(* An edit between identifiers that universal character names spell
   leaves their bytes as written, though their names are in UTF-8. *)
let () =
  let written = read "# 1 \"input.i\"\ncaf\\u00e9 = x\\U0001F600;\n" in
  let edit = edit written ~first:1 ~count:1 (at 1) "+=" in
  check "an edit keeps universal character names as written"
    (Emitter.emit written [ edit ]
    = "# 1 \"input.i\"\n\
       caf\\u00e9 \n\
       # 1 \"a.tc\"\n\
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
    (owners (Emitter.emit unit [ edit ]) = owners source);
  check "an edit in a system header"
    (Emitter.emit unit [ edit ]
    = "# 1 \"a.tc\"\n\
       int x = 1;\n\
       # 1 \"h.h\" 1 3\n\
       int \n\
       # 1 \"h.h\" 3\n\
       w\n\
       # 1 \"h.h\" 3\n\
       ;\n\
       # 2 \"a.tc\" 2\n\
       int z;\n")

(* y becomes w after the marker that #pragma GCC system_header gives:
   the markers repeat its flag, though the owner p.h is no system header,
   and read back keep the owners. *)
let () =
  let source =
    "# 1 \"a.tc\"\n\
     # 1 \"p.h\" 1\n\
     # 2 \"p.h\" 3\n\
     int y;\n\
     # 2 \"a.tc\" 2\n\
     int z;\n"
  in
  let unit = read source in
  let edit = edit unit ~first:1 ~count:1 unit.tokens.(1).location "w" in
  let owner (token : Token.t) = token.owner in
  let owners text = Array.to_list (Array.map owner (read text).tokens) in
  check "read back, an edit after the pragma keeps the owners"
    (owners (Emitter.emit unit [ edit ]) = owners source);
  check "an edit after the marker of the pragma"
    (Emitter.emit unit [ edit ]
    = "# 1 \"a.tc\"\n\
       # 1 \"p.h\" 1\n\
       # 2 \"p.h\" 3\n\
       int \n\
       # 2 \"p.h\" 3\n\
       w\n\
       # 2 \"p.h\" 3\n\
       ;\n\
       # 2 \"a.tc\" 2\n\
       int z;\n")

(* In the expansion of a macro that a system header defines, which GCC
   marks with flags 3 and 4, lowered text takes the flags of the
   construct it lowers, and the marker after it restores those of the
   token where the replaced range ends. *)
let () =
  let unit =
    read
      "# 1 \"a.tc\"\n\
       int\n\
       # 1 \"a.tc\" 3 4\n\
       m\n\
       # 1 \"a.tc\"\n\
       ;\n"
  in
  let inside = edit unit ~first:1 ~count:1 unit.tokens.(1).location "n" in
  let before = edit unit ~first:0 ~count:1 unit.tokens.(0).location "long" in
  check "edits in and before a system macro region"
    (Emitter.emit unit [ before; inside ]
    = "# 1 \"a.tc\"\n\
       \n\
       # 1 \"a.tc\"\n\
       long\n\
       # 1 \"a.tc\"\n\
       \n\
       # 1 \"a.tc\" 3 4\n\
       \n\
       # 1 \"a.tc\" 3 4\n\
       n\n\
       # 1 \"a.tc\" 3 4\n\
       \n\
       # 1 \"a.tc\"\n\
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
  let emitted = read (Emitter.emit unit [ replacement ]) in
  let before = take 1 (seen_all unit) and after = drop 4 (seen_all unit) in
  let emitted_tokens = seen_all emitted in
  let edit_tokens = take 3 (drop 1 emitted_tokens) in
  check "untouched tokens keep their place"
    (take 1 emitted_tokens = before && drop 4 emitted_tokens = after);
  check "edit tokens are at its location"
    (List.for_all
       (fun (_, location, (owner : File.t)) ->
         location = at 1 && owner.name = "a.tc")
       edit_tokens)

(* Each check raises its own message, so a test that names it shows
   which check refused the edits. *)
let raises make message =
  match make () with
  | _ -> false
  | exception Invalid_argument raised -> raised = message

let out_of_order edits =
  raises
    (fun () -> Emitter.emit unit edits)
    "Reader.rewrite: replacements out of order"

let spans_files edits =
  raises (fun () -> Emitter.emit unit edits) "Emitter.emit: an edit spans files"

let outside ~first ~count =
  raises
    (fun () -> Reader.range unit.tokens ~first ~count)
    "Reader.range: outside the tokens"

let () =
  check "overlapping edits"
    (out_of_order [ replacement; edit unit ~first:3 ~count:1 (at 1) "2" ]);
  check "edits out of order" (out_of_order [ insertion; replacement ]);
  check "replacement past the last token" (outside ~first:9 ~count:3);
  check "insertion after the last token" (outside ~first:11 ~count:0);
  check "range before the first token" (outside ~first:(-1) ~count:1);
  check "negative count" (outside ~first:8 ~count:(-1));
  check "an edit that spans files"
    (spans_files [ edit unit ~first:1 ~count:6 (at 1) "x = 2" ]);
  check "adjacent edits"
    (Emitter.emit unit [ replacement; edit unit ~first:4 ~count:1 (at 1) "," ]
    = "# 1 \"a.tc\"\n\
       int \n\
       # 1 \"a.tc\"\n\
       x = 2\n\
       # 1 \"a.tc\"\n\
       \n\
       # 1 \"a.tc\"\n\
       ,\n\
       # 1 \"a.tc\"\n\
       \n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.tc\" 2\n\
       int z;\n");
  check "insertions in front of one token keep their order"
    (Emitter.emit unit
       [ edit unit ~first:8 ~count:0 (at 2) "int v;"; insertion ]
    = "# 1 \"a.tc\"\n\
       int x = 1;\n\
       # 1 \"h.h\" 1 3\n\
       int y;\n\
       # 2 \"a.tc\" 2\n\
       \n\
       # 2 \"a.tc\"\n\
       int v;\n\
       # 2 \"a.tc\"\n\
       \n\
       # 2 \"a.tc\"\n\
       int w;\n\
       # 2 \"a.tc\"\n\
       int z;\n");
  if !failures > 0 then exit 1
