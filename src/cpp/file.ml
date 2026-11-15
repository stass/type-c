(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The file that preprocessed text belongs to: the file the preprocessor
    was reading when it produced the text, as the enter and return flags
    of the line markers describe it.

    [name] is spelled as in the line marker that opened the file, between
    the quotes and with its escape sequences not decoded. [system_header]
    is whether that marker carried the system header flag (3). [main] is
    whether the file is the primary source file of the translation unit,
    the one at the bottom of the stack of files being read, which the
    first line marker or the first token opens; a file that a marker with
    the enter flag opens never is.

    The reader makes one value per name and flags, so owners compare with
    [==] as well as [=]. *)
type t = { name : string; system_header : bool; main : bool }

(** The suffix of a Type-C source file and of a Type-C interface (design
    2.1). *)
let source_suffix = ".tc"

let interface_suffix = ".tci"

(** Whether text that [file] holds is Type-C text, which the suffix of
    its name decides (design 2.1); all other text is C text. *)
let is_type_c_text file =
  Filename.check_suffix file.name source_suffix
  || Filename.check_suffix file.name interface_suffix

(* The module [M] of a name [M ^ suffix], without its directory, or [None]
   where the name lacks the suffix. *)
let module_name ~suffix name =
  let base = Filename.basename name in
  if Filename.check_suffix base suffix then
    Some (Filename.chop_suffix base suffix)
  else None

(* Whether [file] is the primary source file [M.tc] of the interface
   [declaring], [M.tci]. *)
let implements ~declaring file =
  match module_name ~suffix:interface_suffix declaring.name with
  | Some interface ->
      file.main && module_name ~suffix:source_suffix file.name = Some interface
  | None -> false

(** The owner rule (design 9.2 rule 2): whether the text of [file] owns
    the declarations in the text of [declaring], which is the text of
    [declaring] itself and, where [declaring] is an interface [M.tci],
    the text of the primary source file [M.tc].

    {e Pending the owner (default):} the names compare without their
    directories, as the backend names an interface by the path it found
    it through, [-I] included, and the main file as the command line
    does. Not a security boundary (9.2 rule 4): a line marker with the
    enter flag in the source can name any file. *)
let owns ~declaring file = file = declaring || implements ~declaring file
