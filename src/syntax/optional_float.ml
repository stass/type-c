(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The floating types beyond C11 that GCC and Clang name by a keyword
    on some targets only: the interchange and extended types of ISO/IEC
    TS 18661-3 and GNU [__float128]. Only those that the system headers
    use are here.

    Each spelling is a keyword exactly where the backend has the type,
    which its predefined macros state, and for [__float128] a probe
    compile of the target query (see {!Typec_sema.Target}). Where
    it is not, the C library declares the spelling itself: glibc reads
    [typedef __float128 _Float128;] under Clang, which has no keyword
    [_Float128]. A backend may reserve a spelling it cannot use, as
    Apple clang reserves [__float128]; no macro says so, and typec reads
    the spelling as an identifier there, which a program may not declare
    (C11 7.1.3). GCC declares [__float128] as a builtin typedef name, not
    a keyword, so a block-scope declaration of it as an identifier and
    [_Complex __float128] differ from typec as well. *)
type t =
  | Float16
  | Float32
  | Float64
  | Float128
  | Float32x
  | Float64x
  | Gnu_float128  (** [__float128] *)

(** Every type, in the order of {!t}. *)
let all =
  [ Float16; Float32; Float64; Float128; Float32x; Float64x; Gnu_float128 ]

let spelling = function
  | Float16 -> "_Float16"
  | Float32 -> "_Float32"
  | Float64 -> "_Float64"
  | Float128 -> "_Float128"
  | Float32x -> "_Float32x"
  | Float64x -> "_Float64x"
  | Gnu_float128 -> "__float128"
