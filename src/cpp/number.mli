(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Telling integer from floating constants. Private to the library. *)

val classify : string -> Token.kind option
(** [classify spelling] is [Some Integer] when the preprocessing number
    [spelling] is an integer constant (C11 6.4.4.1), [Some Floating] when
    it is a floating constant (C11 6.4.4.2), [Some Version] when it is
    neither but a version of Clang's availability attribute, and [None]
    otherwise. The GNU profile adds binary integers with [0b] and one
    imaginary suffix [i] or [j], in either case, among the other
    suffixes. *)
