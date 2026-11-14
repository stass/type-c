(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** Whether the GNU keywords spelled without underscores, [asm] and
    [typeof], are keywords, which follows the dialect (design 2.4) as in
    GCC and Clang: [Gnu] reserves them, as [-std=gnu11] or [-fasm] does;
    [Iso] leaves them identifiers, as [-std=c11] or [-fno-asm] does. The
    spellings with underscores, such as [__asm__], are keywords in
    both. *)
type dialect = Iso | Gnu

(** The keywords that a text is read with: those of its dialect, and the
    spelling of each optional floating type that the backend has. *)
type t = { dialect : dialect; optional_floats : Optional_float.t list }
