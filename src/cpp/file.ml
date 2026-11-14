(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The file that preprocessed text belongs to: the file the preprocessor
    was reading when it produced the text, as the enter and return flags
    of the line markers describe it.

    [name] is spelled as in the line marker that opened the file, between
    the quotes and with its escape sequences not decoded. [system_header]
    is whether that marker carried the system header flag (3).

    The reader makes one value per name and flag, so owners compare with
    [==] as well as [=]. *)
type t = { name : string; system_header : bool }
