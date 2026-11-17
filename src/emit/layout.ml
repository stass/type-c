(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

open Typec_cpp
open Typec_syntax

let definition_text (unit : Reader.t) (span : Tree.span) =
  let text = Buffer.create 256 in
  for index = span.first to span.last do
    Buffer.add_string text (Reader.spelling unit unit.tokens.(index));
    Buffer.add_char text ' '
  done;
  Buffer.contents text

(* The names of design 13.5: the tag names the digest, and the typedef
   the instance. *)
let typedef (instance : Spelling.c_name) ~definition =
  let digest = Digest.BLAKE128.to_hex (Digest.BLAKE128.string definition) in
  "typedef struct __tc_digest__" ^ digest ^ " *__tc_layout__"
  ^ (instance :> string) ^ ";"
