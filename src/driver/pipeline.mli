(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The backend commands that compile the [.tc] inputs of a command line
    (design 13.2).

    Each [.tc] input is a translation: the backend preprocesses it with
    [-E -x c], [-D__TYPEC__=1] and the options that matter to
    preprocessing; [typec] reads and emits the result; the backend
    compiles the emitted C with [-x cpp-output] to what the command line
    asks for, an object ([-c]), assembly ([-S]) or nothing
    ([-fsyntax-only]), named as cc names it. When the command line links
    and has no other input, the final command compiles the emitted C and
    links in one step: it is the command line with each [.tc] input
    replaced by its emitted C, a file named as a C source like it, so
    that the backend leaves the side outputs of a one-step build of C
    sources, named as there. When it links with other inputs, each
    translation makes an object in the temporary directory and the final
    command is the command line with each [.tc] input replaced by its
    object. Without linking, the final command is the command line
    without its [.tc] inputs, when other inputs remain. Every other input
    and option reaches the backend as given, so a [.c] input is compiled
    as cc compiles it.

    The commands that read the text of a translation get [-std=gnu17]
    unless the command line selects C11 or C17 (design 2.4). A
    dependency file ([-MD], [-MMD]) comes from the [-E] step, named as cc
    names it: after [-MF], else after [-o] with [.d] for its suffix, else
    after the input; its target is the [-MT] or [-MQ] values, else the
    [-o] value, else the input's object. With [-M] or [-MM] the command
    line compiles nothing: the [-E] step of each [.tc] input prints its
    rule in place of the preprocessed text, to the [-o] file or stdout,
    and then a final command does the same for the other inputs, as cc
    does for C sources. *)

(** Where the emitted C goes. *)
type destination = File of string | Standard_output

(** A backend command: the argument vector, whose first element is the
    backend, for the compiler that {!Target_query.query} finds the
    backend to be. It depends on the compiler because only Clang gets the
    option that quiets its warning about the options of the command line
    that a step does not use, and a command that compiles emitted C turns
    Clang's trigraphs off, which typec's reader does not read (design
    13.2). *)
type command = Typec_sema.Target.compiler -> string list

(** The commands for one [.tc] input. *)
type translation = {
  source : string;  (** the input, as given *)
  directory : string;
      (** the directory, in the temporary one, of the files of the
          translation, which the caller makes *)
  preprocess : command;
      (** writes the preprocessed text on stdout, which goes to
          [preprocessed] *)
  preprocessed : string;
  dialect : Typec_syntax.Keyword_set.dialect;
      (** the dialect of the keywords that the backend reads the text
          with: that of [-std=], unless [-fasm] or [-fno-asm] says
          otherwise *)
  emitted : destination;
  compile : command option;
      (** [None] with [--emit-c] and when the final command compiles the
          emitted C *)
}

type t = {
  target_options : string list;
      (** the options of the compile step for Clang, without its inputs
          and outputs, for {!Target_query.query}: the target model is that
          of the compilation, and the query runs before the backend's
          family is known *)
  translations : translation list;
  finals : command list;
      (** the backend commands after the translations, in order: with
          [-M] or [-MM] the rule of each [.tc] input; then the one that
          links, or compiles the other inputs *)
}

(** Why a command line with a [.tc] input has no pipeline. *)
type error =
  | Refused_option of { option : string; reason : string }
  | Unaccepted_standard of string  (** the value of [-std=] *)
  | Missing_value of string  (** the option that lacks it *)
  | Output_for_several_inputs
      (** [-o] with [-c], [-S], [-M] or [-MM] and more than one input *)
  | Emit_c_inputs  (** [--emit-c] without exactly one input, a [.tc] *)
  | Emit_c_rules  (** [--emit-c] with [-M] or [-MM] *)
  | Several_architectures of string list
      (** the distinct [-arch] names, in order, when there are several *)
  | Header_inputs
      (** [--emit-c-header] without exactly one input, a [.tci] *)
  | Header_stops  (** [--emit-c-header] with [-c], [-S] or [-fsyntax-only] *)
  | Header_dependencies  (** [--emit-c-header] with a dependency option *)
  | Header_name of string
      (** the path of an interface whose last component the header's
          redirect cannot name ({!Typec_emit.Header.name_of_path}) *)

val has_type_c_input : Command_line.argument list -> bool

val plan :
  program:string ->
  emit_c:bool ->
  temp_dir:string ->
  Command_line.argument list ->
  (t, error) result
(** [plan ~program ~emit_c ~temp_dir arguments] gives the commands for
    the backend [program] and the backend arguments of a command line,
    whose intermediate files are in [temp_dir]. With [emit_c] the
    command line has one input, a [.tc] file; its C goes to the [-o]
    file, else to stdout, and nothing is compiled. *)

(** The command of [--emit-c-header] (design 9.3): the target options
    and the [-E] step of the one [.tci] input, as for a [.tc] input but
    with [-dI] and, after the user's options, [-Wno-unused-macros]; the
    header's destination, [emitted], beside the interface with the suffix
    [.h], the [-o] file, or stdout under [-o -]; and the interface's name
    for the header's redirect. [compile] is [None]. *)
type header = {
  header_target_options : string list;
  interface : translation;
  name : Typec_emit.Header.name;
}

val plan_header :
  program:string ->
  temp_dir:string ->
  Command_line.argument list ->
  (header, error) result
(** [plan_header ~program ~temp_dir arguments] is the command of
    [--emit-c-header] for the backend arguments of a command line. It
    refuses every option that {!plan} refuses, by the same table. *)

val error_message : error -> string
