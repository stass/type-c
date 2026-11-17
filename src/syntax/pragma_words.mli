(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one table of the layout pragmas (design 13.5): those that set the
    layout of a structure and take their own words and numbers as
    arguments, which Clang reads after macro replacement when it
    compiles C and as written in the preprocessed text that [typec]
    compiles. *)

(** An identifier among the arguments of a layout pragma that is none of
    its words. *)
type stray = {
  pragma : string;  (** the first identifier of the line *)
  word : string;  (** the first identifier after it that is no word *)
  words : string list;  (** the words of the pragma, in the table's order *)
}

(** The stray identifier of a pragma line whose identifiers are [names],
    in order: [None] when the line is of no layout pragma or its
    arguments hold only the pragma's words. *)
val stray_word : string list -> stray option
