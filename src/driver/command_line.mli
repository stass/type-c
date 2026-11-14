(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** A [typec] command line read into inputs and options with
    {!Cc_option.classify}. Reading never fails: whatever the backend would
    refuse is kept for it to refuse. *)

type argument =
  | Input of { path : string; type_c : bool }
      (** An argument that is not an option, or ["-"]. [type_c] is
          whether it goes through the pipeline: its name ends in [.tc]
          and no [-x] other than [-x none] is in effect, so [-x c x.tc]
          makes [x.tc] a C input. *)
  | Option of { role : Cc_option.role; words : string list; value : string }
      (** An option and its separate values, as given, in [words]. [value]
          is its joined value, else its first separate value, else
          empty. *)
  | Truncated of string list
      (** The last option of the line, without all of its values. *)

val read : string list -> argument list

val words : argument list -> string list
(** [words arguments] spells [arguments] as they were given. *)
