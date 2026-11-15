(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Whether the GNU keywords spelled without underscores, [asm] and
    [typeof], are keywords, which follows the dialect (design 2.4) as in
    GCC and Clang: [Gnu] reserves them, as [-std=gnu11] or [-fasm] does;
    [Iso] leaves them identifiers, as [-std=c11] or [-fno-asm] does. The
    spellings with underscores, such as [__asm__], are keywords in
    both. *)
type dialect = Iso | Gnu

(** A family of the Arm vector types (Arm C Language Extensions) whose
    typedef names a backend declares on AArch64 ({!Builtin_typedef}):
    those of Neon, such as [__Float32x4_t], and those of SVE, such as
    [__SVFloat32_t]. *)
type vector_family = Neon | Sve

(** The keywords that a text is read with: those of its dialect, the
    spelling of each optional floating type that the backend has, and
    [__int128] where the backend has that type, which its macro
    [__SIZEOF_INT128__] states. [int128] also decides the typedef names
    [__int128_t] and [__uint128_t], and [vector_families] the families
    of the Arm vector types that the backend names ({!Builtin_typedef}). *)
type t = {
  dialect : dialect;
  optional_floats : Optional_float.t list;
  int128 : bool;
  vector_families : vector_family list;
}
