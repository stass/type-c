(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The presumed location of preprocessed text: the file name and line
    that diagnostics show, as line markers and [#line] set them. The name
    is spelled as in the line marker (see {!File}), and it may differ from
    the name of the file the text belongs to. *)
type t = { file : string; line : int }
