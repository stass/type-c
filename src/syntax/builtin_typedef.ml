(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The typedef names that GCC and Clang declare before the first token of
    a translation unit, and the types they name: the one table that the
    parser reads for the names and the declaration reader for the types.
    Only those that the system headers and the corpus use are here.

    The parser reads every name of the table on every target; the
    declaration reader declares those whose type the target has, as GCC
    and Clang declare [__int128_t] only where [__int128] exists. On a
    target without it the parser still reads [__int128_t] as a typedef
    name, so a declaration that uses the reserved name for an ordinary
    identifier there is refused. The optional floating types follow the
    target instead, through the keyword set ({!Optional_float}). *)

(** What a builtin typedef name denotes. *)
type t =
  | Va_list
      (** The type of [__builtin_va_list], which [stdarg.h] names
          [va_list]: its representation is the target's, an array of one
          structure on x86-64 and [char *] on i386 and arm64 Darwin. *)
  | Int128  (** [__int128] *)
  | Unsigned_int128  (** [unsigned __int128] *)

(* Also the spelling of the type in diagnostics and in C for a backend. *)
let va_list_name = "__builtin_va_list"

(** Each name with what it denotes. *)
let table =
  [
    (va_list_name, Va_list);
    ("__int128_t", Int128);
    ("__uint128_t", Unsigned_int128);
  ]
