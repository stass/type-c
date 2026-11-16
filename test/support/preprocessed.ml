(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** [text ~name source] is [source], preprocessed text that may hold
    line markers of its own, after the line marker that opens the main
    file [name], which the reader requires before the first token.
    [name] is written as it is, so it must need no escape in a marker. *)
let text ~name source = Printf.sprintf "# 1 \"%s\"\n%s" name source
