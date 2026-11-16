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
let at line : Location.t = { file = "a.tc"; line }

(* x = 1 becomes x = 2 at line 1. *)
let replacement =
  { Emitter.first = 1; count = 3; location = at 1; text = "x = 2" }

(* int w; goes before int z, at line 2. *)
let insertion =
  { Emitter.first = 8; count = 0; location = at 2; text = "int w;" }

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
  let written = "caf\\u00e9 = x\\U0001F600;\n" in
  let edit =
    { Emitter.first = 1; count = 1; location = at 1; text = "+=" }
  in
  check "an edit keeps universal character names as written"
    (Emitter.emit (read written) [ edit ]
    = "caf\\u00e9 \n\
       # 1 \"a.tc\"\n\
       +=\n\
       # 1 \"input.i\"\n\
      \ x\\U0001F600;\n")

(* y becomes w in the system header h.h, which stays one for the
   backend's warnings. *)
let () =
  let in_header : Location.t = { file = "h.h"; line = 1 } in
  let edit =
    { Emitter.first = 6; count = 1; location = in_header; text = "w" }
  in
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

let raises_invalid edits =
  match Emitter.emit unit edits with
  | _ -> false
  | exception Invalid_argument _ -> true

let () =
  check "overlapping edits"
    (raises_invalid [ replacement; { replacement with first = 3 } ]);
  check "edits out of order" (raises_invalid [ insertion; replacement ]);
  check "replacement past the last token"
    (raises_invalid [ { replacement with first = 9; count = 3 } ]);
  check "insertion after the last token"
    (raises_invalid [ { insertion with first = 11 } ]);
  check "an edit that spans files"
    (raises_invalid [ { replacement with count = 6 } ]);
  check "negative count" (raises_invalid [ { insertion with count = -1 } ]);
  check "adjacent edits"
    (not
       (raises_invalid
          [ replacement; { replacement with first = 4; count = 1 } ]));
  if !failures > 0 then exit 1
