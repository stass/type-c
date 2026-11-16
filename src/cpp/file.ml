(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The file that preprocessed text belongs to: the file the preprocessor
    was reading when it produced the text, as the enter and return flags
    of the line markers describe it.

    [name] is spelled as in the line marker that opened the file, between
    the quotes and with its escape sequences not decoded. [system_header]
    is whether that marker carried the system header flag (3).

    The reader makes one value per name, flags and origin, and the
    universe has the one value {!universe}, so owners compare with [==]
    as well as [=]. *)

(** How the file came to be read. *)
type origin =
  | Main
      (** the primary source file of the translation unit, the one at the
          bottom of the stack of files being read, which the first line
          marker with a file name opens *)
  | Entered  (** a file that a line marker with the enter flag opens *)
  | Universe
      (** the text of the universe generics, {!universe_text}, which no
          line marker opens *)

type t = { name : string; system_header : bool; origin : origin }

(** The Type-C text of the generic types of the universe scope, the two
    lines of design 3.6, which the reader puts in front of a unit's own
    text ({!Reader.read_with_universe}). It ends with a newline, so the
    unit's text starts a line. It declares one generic a line, as
    [type name(...)], which is how [Typec_syntax.Universe] reads the
    names. *)
let universe_text =
  "type option(T)    = | None | Some(T value);\n\
   type result(T, E) = | Err(E error) | Ok(T value);\n"

(** The one owner of {!universe_text}. A line marker that names
    [<universe>] opens a file of another origin, so source text cannot
    pass for the universe. *)
let universe = { name = "<universe>"; system_header = false; origin = Universe }

(** Whether [file] is {!universe}, which owns the universe text alone. *)
let is_universe file = file == universe

(** The suffix of a Type-C source file and of a Type-C interface (design
    2.1). *)
let source_suffix = ".tc"

let interface_suffix = ".tci"

(** Whether text that [file] holds is Type-C text: the universe text is,
    and the suffix of the name decides for any other file (design 2.1);
    all other text is C text. *)
let is_type_c_text file =
  match file.origin with
  | Universe -> true
  | Main | Entered ->
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
      file.origin = Main
      && module_name ~suffix:source_suffix file.name = Some interface
  | None -> false

(** The owner rule (design 9.2 rule 2): whether the text of [file] owns
    the declarations in the text of [declaring], which is the text of
    [declaring] itself and, where [declaring] is an interface [M.tci],
    the text of the primary source file [M.tc].

    The names compare without their directories, as the backend names
    an interface by the path it found it through, [-I] included, and the
    main file as the command line does. Not a security boundary (9.2
    rule 4): a line marker with the enter flag in the source can name
    any file. *)
let owns ~declaring file = file = declaring || implements ~declaring file
