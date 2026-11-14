(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The backend commands that compile the [.tc] inputs of a command line
    (design 13.2).

    Each [.tc] input is a translation: the backend preprocesses it with
    [-E -x c], [-D__TYPEC__=1] and the options that matter to
    preprocessing; [typec] reads and emits the result; the backend
    compiles the emitted C with [-x cpp-output] to what the command line
    asks for, an object ([-c]), assembly ([-S]) or nothing
    ([-fsyntax-only]), named as cc names it. When the command line links,
    each translation makes an object in the temporary directory and the
    final command is the command line with each [.tc] input replaced by
    its object. Without linking, the final command is the command line
    without its [.tc] inputs, when other inputs remain. Every other input
    and option reaches the backend as given, so a [.c] input is compiled
    as cc compiles it.

    Both steps of a translation get [-std=gnu11] unless the command line
    selects C11 or C17 (design 2.4). A dependency file ([-MD], [-MMD])
    comes from the [-E] step, named as cc names it: after [-MF], else
    after [-o] with [.d] for its suffix, else after the input; its target
    is the [-MT] or [-MQ] values, else the [-o] value, else the input's
    object. *)

(** Where the emitted C goes. *)
type destination = File of string | Standard_output

(** The commands for one [.tc] input. Each command is an argument vector
    whose first element is the backend. *)
type translation = {
  source : string;  (** the input, as given *)
  preprocess : string list;
      (** writes the preprocessed text on stdout, which goes to
          [preprocessed] *)
  preprocessed : string;
  emitted : destination;
  compile : string list option;  (** [None] with [--emit-c] *)
}

type t = { translations : translation list; final : string list option }

(** Why a command line with a [.tc] input has no pipeline. *)
type error =
  | Refused_option of { option : string; reason : string }
  | Unaccepted_standard of string  (** the value of [-std=] *)
  | Missing_value of string  (** the option that lacks it *)
  | Output_for_several_inputs
      (** [-o] with [-c] or [-S] and more than one input *)
  | Emit_c_inputs  (** [--emit-c] without exactly one input, a [.tc] *)

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

val error_message : error -> string
