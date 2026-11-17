(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The options of a [typec] command line: those of GCC and Clang that the
    pipeline must know, and the options of [typec] itself.

    One table answers, for each option, how many of the next arguments
    are its values, so that a value is never taken for an input, and what
    the option is to the pipeline. An option spelled with one ['-'] that
    is not in the table takes no separate value and is passed to every
    step, which is right for the options that select the target, the
    code or the warnings. A long option, spelled with ["--"], that is not
    in the table is [Refused]: GCC reads abbreviations of long options
    and [--NAME] as [-fNAME], so its meaning cannot be known. Every
    option that starts with [-d] (dumps), [-print-] or [--print-]
    (queries) is [Refused] too, except those of other meaning that the
    table names, such as [-dumpbase]. *)

(** The output a compilation stops at. *)
type stop =
  | Object  (** [-c] *)
  | Assembly  (** [-S] *)
  | Syntax_check  (** [-fsyntax-only] *)

(** What a dependency option does. *)
type dependency =
  | Print_rule
      (** [-M], [-MM]: print the rule of the [-E] step instead of
          compiling *)
  | Write_dependencies  (** [-MD], [-MMD]: write a dependency file *)
  | Dependency_file  (** [-MF FILE]: name it *)
  | Dependency_target  (** [-MT TARGET], [-MQ TARGET]: name its target *)
  | Dependency_detail  (** [-MP], [-MG], [-MV]: shape its contents *)

(** The options of [typec] itself, which never reach the backend. *)
type typec_option =
  | Cc  (** [--cc=PATH] *)
  | Print_target  (** [--print-target] *)
  | Emit_c  (** [--emit-c] *)
  | Stats  (** [--stats] *)

(** What an option is to the pipeline of a [.tc] input. *)
type role =
  | Preprocess
      (** Matters to preprocessing only, such as [-I] or [-D]: the
          [-E] step. *)
  | Dependency of dependency  (** The [-E] step, which writes the file. *)
  | Link  (** Matters to linking only, such as [-l]: the final command. *)
  | Common  (** Every step: the target, code generation, warnings. *)
  | Architecture
      (** [-arch NAME]: every step. A command line with a [.tc] input
          names one architecture, given once or more: cc builds a
          universal binary for several, but its [-E] step preprocesses
          for one only. *)
  | Dialect  (** [-std=]: every step, once checked (design 2.4). *)
  | Keywords of Typec_syntax.Keyword_set.dialect
      (** [-fasm], [-fno-asm]: every step. They select the keywords
          given, whatever [-std=] says, as in GCC and Clang. *)
  | Output  (** [-o]: names the result. *)
  | Language  (** [-x]: how cc treats the inputs after it. *)
  | Stop of stop
  | Refused of string
      (** Breaks the pipeline, for the reason given; allowed only on a
          command line without a [.tc] input. *)
  | Typec of typec_option

(** How an argument that starts with ['-'] or ['@'] reads: its role, how
    many of the next arguments are its values, and its own value, which
    is the part after its spelling for a joined form ([-Idir], [-std=c11],
    [--cc=PATH]) and empty otherwise. *)
type t = { role : role; separate_values : int; joined_value : string }

val classify : string -> t
(** [classify argument] finds [argument] in the table: an exact spelling
    first, then the longest spelling that is a prefix of it and takes a
    joined value. An argument that matches neither is [Refused] when it
    starts with ["--"] and [Common] with no value otherwise. An argument
    that starts with ['@'] is a response file, which is [Refused]:
    [typec] does not read the options inside it. *)
