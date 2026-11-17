(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The one list of the pragmas that a deferred statement may hold (design
    6 rule 9, 13.5): those that apply to the statement that follows them
    or to the compound statement they stand in, and set no state for the
    rest of the text. Lowering copies the statement to each exit of its
    scope, so a pragma that sets state, as [#pragma pack(push, 1)] does,
    would be in force once per copy. Each entry is measured on Apple
    Clang 21 and GCC 16: the pragma reaches the loop or block it precedes
    and no loop or statement after it. A backend that does not know an
    entry ignores it, which sets no state either.

    An entry is the leading identifiers of the line, matched without the
    other tokens: a line whose first tokens are not these identifiers
    alone holds a pragma that neither backend knows. *)
let statement_pragmas =
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
    (* C11 7.12.2: in force to the end of the compound statement it begins,
       and each copy of a deferred statement is written as a block. *)
    [ "STDC"; "FP_CONTRACT" ];
    (* C11 7.6.1, as FP_CONTRACT. *)
    [ "STDC"; "FENV_ACCESS" ];
    (* C11 7.3.4, as FP_CONTRACT. *)
    [ "STDC"; "CX_LIMITED_RANGE" ];
  ]

let rec begins_with prefix names =
  match (prefix, names) with
  | [], _ -> true
  | word :: prefix, name :: names -> word = name && begins_with prefix names
  | _ :: _, [] -> false

(** Whether a pragma line whose identifiers are [names], in order, is one
    that a deferred statement may hold. *)
let is_statement_scoped names =
  List.exists (fun prefix -> begins_with prefix names) statement_pragmas
