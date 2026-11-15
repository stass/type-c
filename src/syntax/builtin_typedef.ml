(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The typedef names that GCC and Clang declare before the first token of
    a translation unit, and the types they name: the one table that the
    parser reads for the names and the declaration reader for the types.
    Only those that the system headers and the corpus use are here.

    A name is declared where its type exists, as GCC and Clang declare
    [__int128_t] only where [__int128] does: the keyword set says so to
    the parser ({!declared}), and the declaration reader reads the
    references that the parser makes. Elsewhere the name is an ordinary
    identifier. *)

(** What a builtin typedef name denotes. *)
type t =
  | Va_list
      (** The type of [__builtin_va_list], which [stdarg.h] names
          [va_list]: its representation is the target's, an array of one
          structure on x86-64 and [char *] on i386 and arm64 Darwin. *)
  | Int128  (** [__int128] *)
  | Unsigned_int128  (** [unsigned __int128] *)
  | Arm_vector of Keyword_set.vector_family
      (** An Arm vector type of the family, which typec does not compute
          (design 13.3): a Neon vector of 8 or 16 bytes, or an SVE type,
          which has no size. *)

(* Also the spelling of the type in diagnostics and in C for a backend. *)
let va_list_name = "__builtin_va_list"

(** Whether a text read with [keywords] has the names of type [t]
    declared. *)
let declared (keywords : Keyword_set.t) = function
  | Va_list -> true
  | Int128 | Unsigned_int128 -> keywords.int128
  | Arm_vector family -> List.mem family keywords.vector_families

(** Each name with what it denotes. *)
let table =
  [
    (va_list_name, Va_list);
    ("__int128_t", Int128);
    ("__uint128_t", Unsigned_int128);
    ("__Float32x4_t", Arm_vector Neon);
    ("__Float64x2_t", Arm_vector Neon);
    ("__SVFloat32_t", Arm_vector Sve);
    ("__SVFloat64_t", Arm_vector Sve);
    ("__SVBool_t", Arm_vector Sve);
  ]
