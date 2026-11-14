(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The keywords that a text is read with, which follow its dialect
    (design 2.4) as in GCC and Clang: [Gnu] reserves the GNU keywords
    spelled without underscores, [asm] and [typeof], as [-std=gnu11] or
    [-fasm] does; [Iso] leaves them identifiers, as [-std=c11] or
    [-fno-asm] does. The spellings with underscores, such as [__asm__],
    are keywords in both. *)
type t = Iso | Gnu
