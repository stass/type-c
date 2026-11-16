(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The flags 3 and 4 of the last line marker that names a file. The
    backend exempts the text after flag 3 from warnings as the text of a
    system header; flag 4, which GCC writes only with flag 3, also wraps
    it in an implicit [extern "C"] in C++. Clang writes flag 3 after
    [#pragma GCC system_header] too, and GCC around the tokens of a macro
    that a system header defines, so the flags need not match the file
    the text belongs to. A marker without a file name, and [#line], keep
    what the marker before said. *)
type flags = No_flags | System | Extern_c_system

(** The flags as a line marker writes them after the file name, with the
    blank in front. *)
let flag_spelling = function
  | No_flags -> ""
  | System -> " 3"
  | Extern_c_system -> " 3 4"

(** The presumed location of preprocessed text: the file name and line
    that diagnostics show, as line markers and [#line] set them, and the
    flags in effect there. The name is spelled as in the line marker (see
    {!File}), and it may differ from the name of the file the text
    belongs to. *)
type t = { file : string; line : int; flags : flags }
