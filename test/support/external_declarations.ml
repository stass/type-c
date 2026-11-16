(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** [of_unit unit] is the external declarations of [unit], parsed with
    the keywords of ISO C and no optional type, as a test that anchors
    an edit at them needs; [Failure] where [unit] does not parse. *)
let of_unit unit =
  let keywords : Typec_syntax.Keyword_set.t =
    { dialect = Iso; optional_floats = []; int128 = false;
      vector_families = [] }
  in
  match Typec_syntax.Parser.parse ~keywords unit with
  | Ok declarations -> declarations
  | Error error -> failwith (Typec_syntax.Parser.error_message error)
