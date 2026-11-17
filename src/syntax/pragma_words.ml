(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The layout pragmas (design 13.5). Clang 21 to 23 and Apple Clang 21
    replace a macro among their arguments when they compile C, and keep
    it as written in their [-E] output, which [typec] compiles:
    [#pragma pack(push, M)] with [M] defined as 1 packs to 1 in a [.c]
    unit and reads [M] as a label of [push] in a [.tc] unit. GCC 14 and
    16 replace no macro there in either mode. Any other identifier among
    the arguments is refused, since [typec] sees no macros and cannot
    tell one from a label. A pragma that sets layout but whose arguments
    both backends read as written in both modes, as GCC's
    [scalar_storage_order], has no entry.

    An entry is the first identifier of the line and the words its
    arguments may hold: the union of the words that Clang and GCC
    define, as a backend that does not know a word ignores the line in
    both modes alike. *)

type stray = { pragma : string; word : string; words : string list }

type entry = { pragma : string; words : string list }

(* The alignment rules of [#pragma options align=] and [#pragma align=]:
   Clang's, which include GCC's on Darwin. *)
let alignments =
  [ "native"; "natural"; "packed"; "power"; "mac68k"; "reset" ]

let table =
  [
    (* Clang and GCC: push and pop; Clang: show. *)
    { pragma = "pack"; words = [ "push"; "pop"; "show" ] };
    (* Clang, and GCC on Darwin. *)
    { pragma = "options"; words = "align" :: alignments };
    (* Clang. *)
    { pragma = "align"; words = alignments };
    (* Clang: on and off; GCC on Darwin: reset as well. *)
    { pragma = "ms_struct"; words = [ "on"; "off"; "reset" ] };
  ]

let first_stray ({ pragma; words } : entry) arguments =
  List.find_opt (fun word -> not (List.mem word words)) arguments
  |> Option.map (fun word -> { pragma; word; words })

let stray_word = function
  | [] -> None
  | first :: arguments -> (
      match List.find_opt (fun (entry : entry) -> entry.pragma = first) table
      with
      | Some entry -> first_stray entry arguments
      | None -> None)
