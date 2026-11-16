(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* misuse: Typec_emit Emitter.pragma_line but an expression was expected *)

(* A pragma line of the source in a packing bracket, which could be a
   '#pragma pack' that the probe of design 10.3 does not see: only moved
   text holds a pragma line, so this must not compile. *)

let bracketed unit ~at ~location index =
  match Emitter.moved_token unit index with
  | Some (Pragma_line line) -> Emitter.bracketed unit ~at ~location [ line ]
  | Some (Piece _) | None -> failwith "no pragma line"
