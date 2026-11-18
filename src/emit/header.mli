(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The C header of an interface ([typec --emit-c-header M.tci], design
    9.3): a pure function from the output of the interface's [-E -dI]
    step, read and lowered, to the text of [M.h]. The driver runs the
    step and writes the file. *)

(** The last component of the path of an interface, which the header's
    redirect names: a [.tci] name of ASCII letters, digits, [.], [_], [-]
    and [+] alone, which a quoted header name holds as it is. *)
type name

val name_of_path : string -> name option
(** [name_of_path path] is the name of the interface at [path], or None
    where its last component does not end in [.tci] or holds another
    byte. *)

val module_name : name -> string
(** The module of the interface (design 13.5): the last component of its
    path without [.tci], each ASCII letter or digit standing for itself
    and every other byte written as [_] and two hexadecimal digits in
    lower case. *)

val first_line : string
(** The comment that begins every header, by which [typec] knows a file
    that it may write over. *)

val check_interface :
  source:string ->
  Typec_cpp.Reader.interface ->
  Typec_syntax.Tree.translation_unit ->
  (unit, Typec_cpp.Reader.error) result
(** [check_interface ~source read unit] refuses what the header of the
    interface [source] cannot carry and that only the step's own output
    shows: a text of the interface that holds no token and no directive
    line, and an include line inside an external declaration of [unit],
    the declarations that [read] parses to. *)

val write :
  Emitter.output ->
  source:string ->
  name ->
  Typec_cpp.Reader.interface ->
  (string, Typec_cpp.Reader.error) result
(** [write output ~source name lowered] is the header of the interface
    [name] at the path [source], whose lowered text
    {!Typec_cpp.Reader.read_interface} has read in [lowered]: the
    redirect to the interface under [__TYPEC__], the guard, the macro
    probe, and the tokens of the interface's own text in runs between its
    include lines, each run in a macro bracket. Or the error at the first
    include line, pragma line or identifier that the header cannot carry:
    an [#include_next], a trigraph sequence in an include or pragma line,
    and an identifier with a character outside the basic character set
    but [$]. Every line is charged to the output limit of [output] as it
    is written ({!Emitter.lines}): a line of a run at the location of its
    text, an include line at its own, a line of a macro bracket at that
    of its run's first line, and the others at the first line of
    [source]; a charge that passes the
    limit raises past this function to {!Emitter.limited}. *)
