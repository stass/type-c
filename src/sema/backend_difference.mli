(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The constructs that GCC types otherwise than Clang, and the one
    decision on them (design 13.3).

    typec types C by Clang's rules. With GCC as the backend, a construct
    of this table where GCC's type differs has an unknown type (P21):
    typec neither guesses GCC's type nor refuses what GCC accepts, and
    reports an error only where a declaration needs the type. Each entry
    names the construct, what GCC does, and a probe that shows it, with
    [struct { unsigned b : 3; unsigned long long l : 40; } s] where it
    takes one; GCC 14, 15 and 16 and Clang 20, 21 (Apple) and 22 give the
    answers stated. *)

type t =
  | Narrow_bit_field of { integer : Integer.t Ctype.answer; width : int }
      (** The value of a bit-field of [width] bits declared with [integer],
          or with an enumerated type compatible with it, which may be
          unknown. GCC gives one narrower than its type a type of that
          width, a standard integer type where one has the width and
          otherwise a type that no program names, and keeps it through
          assignment, [++], [--], the comma operator, a statement
          expression and [__real__] and [__imag__]:
          [_Generic(s.b++, unsigned: 1, default: 0)] is 1 in Clang and 0
          in GCC, [sizeof (s.b++)] is 4 and 1, and [_Generic(s.b, ...)]
          with [unsigned b : 8] selects [unsigned] in Clang and
          [unsigned char] in GCC. *)
  | Bit_field_promotion of { integer : Integer.t; width : int }
      (** The integer promotion of such a bit-field (6.3.1.1p2). GCC
          promotes one narrower than [int] to [int], as Clang does, and
          leaves one of a type ranked above [int] and at least as wide as
          [int] unpromoted: [s.l + 1] has a 40-bit type that wraps at
          2^40, where Clang gives it [unsigned long long], and with
          [-m32] [long w : 32] promotes to [long], where Clang gives
          [int]. *)
  | Bit_field_real_part
      (** [__real__] of a bit-field. Clang takes the bit-field's value,
          and GCC's real part is the bit-field itself, an lvalue that
          [sizeof] and [&] refuse: GCC accepts [__real__ s.b = 1] and
          Clang refuses it, also where the bit-field has its type's full
          width. *)
  | Anonymous_member of { member_type : Ctype.t; anonymous : Ctype.qualifiers }
      (** A member of type [member_type], qualified as the structure that
          it is a member of, found through anonymous members that are
          qualified with [anonymous]. GCC gives the member their
          [const] and [volatile] and Clang does not: with
          [struct { const struct { int z; }; } t], [&t.z] is a
          [const int *] in GCC and an [int *] in Clang, which lets
          [t.z = 1] assign. *)
  | Atomic_comparison of Ctype.t * Ctype.t
      (** The comparison of two types by [__builtin_types_compatible_p],
          where one has a top-level [_Atomic] and the other has not. GCC
          drops [_Atomic] with the other top-level qualifiers and Clang
          keeps it: [__builtin_types_compatible_p(_Atomic int, int)] is 1
          in GCC and 0 in Clang. *)
  | Old_style_function of {
      clang : Ctype.parameters;
      composite : Ctype.parameters;
    }
      (** A use of a function whose composite type has the parameters
          [composite], to which Clang gives [clang]. Clang gives a
          definition with a non-empty identifier list the prototype of the
          promoted types of its parameters. A later declaration without a
          prototype inherits it, but the uses that reach the definition
          itself see no prototype (C11 6.9.1p7, DR 316). GCC gives the
          definition no prototype of its own and keeps one before it:
          after
          [int f(int); int f(a) int a; {...}],
          [__builtin_types_compatible_p(typeof(f), int (long))] is 1 in
          Clang and 0 in GCC, and after
          [int g(a) long a; {...} int g();],
          [__builtin_types_compatible_p(typeof(g), int (int))] is 0 in
          Clang and 1 in GCC. GCC 16 and Clang 21 (Apple), 22 and 23 give
          these answers. *)

val answer :
  Target.t -> t -> Typec_cpp.Location.t -> 'a -> 'a Ctype.answer
(** [answer target construct location clang] is [Answer clang], Clang's
    answer for [construct], unless the backend is GCC and GCC's differs;
    then it depends on an unknown object type at [location], the start of
    the construct, which names it. *)
