(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The types that typec assumes of the backend where no predefined macro
    of the target model states them, each as a C11 static assertion that
    the backend fails where its options or its target give another type
    (design 13.4). Each message names the option of GCC or Clang known to
    give the other type, as a question, since another route may.

    They check a tool that typec does not control: the backend reads its
    options from config files, wrappers, [-Xclang] and the like, where the
    driver cannot see them, and a target may default to other types. A
    failure is fixed by building without the option that changes the
    type, or by a target model that reads the type it changes. *)

val assertions : Typec_sema.Target.t -> string list
(** [assertions target]: one declaration per line, valid at file scope in
    C11 and C17 under [-Wall -Wextra -pedantic-errors], each true for the
    types of [target]:
    - a plain [int] bit-field is signed (C11 6.7.2p5 leaves it to the
      implementation), as typec types it as [int];
    - an unsuffixed floating constant has type [double] (C11 6.4.4.2p4),
      which GCC's [-fsingle-precision-constant] breaks;
    - an enumeration of the value 0 has the compatible type that
      {!Typec_sema.Arithmetic.enum_compatible_type} gives it, which
      [-fshort-enums] narrows. One enumeration stands for every one, as
      the options that change the rule change it for the whole unit.
      {e Provisional}: that a target whose rule differs also differs at
      the value 0; [test/run/types.t] run on more targets would settle
      it. Its enumerator, [__tc_enum_probe], is declared at file scope
      under a name reserved to typec. *)
