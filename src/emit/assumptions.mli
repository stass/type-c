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

val assertion : holds:string -> assumes:string -> option:string -> string
(** [assertion ~holds ~assumes ~option] is a static assertion of the
    constant expression [holds], whose message says that typec assumes
    [assumes] and asks whether [option] breaks it. [assumes] and
    [option] are typec's own text, without a quote or a backslash, as
    they go into a string literal unescaped. *)

val assertions : Typec_sema.Target.t -> string list
(** [assertions target]: one declaration per line, valid at file scope in
    C11 and C17 under [-Wall -Wextra -pedantic-errors], each true for the
    types of [target]:
    - a plain [int] bit-field is signed (C11 6.7.2p5 leaves it to the
      implementation), as typec types it as [int];
    - an unsuffixed floating constant has type [double] (C11 6.4.4.2p4),
      which GCC's [-fsingle-precision-constant] breaks;
    - the enumeration assertion, {!enumeration} [target ~suffix:""], with
      the declaration of its enumeration. *)

val enumeration : Typec_sema.Target.t -> suffix:string -> string list
(** [enumeration target ~suffix] is the enumeration assertion (design
    13.4) after the declaration of its enumeration, one per line, valid
    where {!assertions} are, also under GCC's [-Wc++-compat]: a static
    assertion that an enumeration of the value 0 has the compatible type
    that
    {!Typec_sema.Arithmetic.enum_compatible_type} gives it under the
    representation of [target], which [-fshort-enums] or
    [-fno-short-enums] changes; the message names the representation and
    the option that gives the other. One enumeration stands for every
    one, as the options that change the rule change it for the whole
    unit. Its tag and its enumerator, each [__tc_enum_probe] followed by
    [suffix], are declared at file scope under a name reserved to typec;
    a unit's
    suffix is empty, and a header's names the header (design 13.5), as a
    client may include several.
    {e Provisional}: that a target whose rule differs also differs at the
    value 0; [test/run/types.t] run on more targets would settle it. *)
