(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one list of the pragmas that a deferred statement may hold
    (design 6 rule 9, 13.5): those that apply to the statement that
    follows them or to the compound statement they stand in, and set no
    state for the rest of the text. The scope of a defer statement may
    hold the first kind alone.
    Lowering copies the statement to each exit of its scope, so a pragma
    in it that sets state, as [#pragma pack(push, 1)] does, would be in
    force once per copy, and one in the scope would be in force at some
    copies and not at the defer statement. Each entry is measured on
    Apple Clang 21 and GCC 16: the pragma reaches the loop or block it
    precedes and no loop or statement after it. A backend that does not
    know an entry ignores it, which sets no state either.

    An entry is the leading identifiers of the line, matched without the
    other tokens: a line whose first tokens are not these identifiers
    alone holds a pragma that neither backend knows. *)

(* The pragmas that annotate the loop that follows them, and nothing
   else: the scope of a defer statement may hold these alone. *)
let loop_pragmas =
  [
    (* GCC and Clang: unrolls the loop that follows. *)
    [ "GCC"; "unroll" ];
    (* GCC: drops dependences in the loop that follows. *)
    [ "GCC"; "ivdep" ];
    (* GCC: does not vectorize the loop that follows. *)
    [ "GCC"; "novector" ];
    (* Clang: hints for the loop that follows. *)
    [ "clang"; "loop" ];
    (* Clang: unrolls the loop that follows. *)
    [ "unroll" ];
    (* Clang: does not unroll the loop that follows. *)
    [ "nounroll" ];
  ]

(* The pragmas that are in force to the end of the compound statement
   they stand in. Each copy of a deferred statement is written as a
   block, so one in it reaches its copy alone; one in the scope would
   reach the copies at the exits after it in its block. *)
let block_pragmas =
  [
    (* C11 7.12.2. *)
    [ "STDC"; "FP_CONTRACT" ];
    (* C11 7.6.1. *)
    [ "STDC"; "FENV_ACCESS" ];
    (* C11 7.3.4. *)
    [ "STDC"; "CX_LIMITED_RANGE" ];
  ]

let rec begins_with prefix names =
  match (prefix, names) with
  | [], _ -> true
  | word :: prefix, name :: names -> word = name && begins_with prefix names
  | _ :: _, [] -> false

let is_among pragmas names =
  List.exists (fun prefix -> begins_with prefix names) pragmas

let is_loop_pragma names = is_among loop_pragmas names

let is_statement_scoped names =
  is_loop_pragma names || is_among block_pragmas names
