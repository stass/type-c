(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The layout typedef of an instance in the header of an interface
    (design 9.3, 13.5): a typedef named for the instance of a pointer to
    a structure that no text defines, whose tag holds the digest of the
    text of the definition of the instance's generic. Two headers that
    write one definition write one typedef, which C lets them repeat;
    two that write different ones write typedefs of different types,
    which a C client that includes both refuses. *)

val definition_text :
  Typec_cpp.Reader.t -> Typec_syntax.Tree.span -> string
(** [definition_text unit span] is the text that a layout typedef
    digests: each token of [span] in [unit] as
    {!Typec_cpp.Reader.spelling} spells it, followed by one space, so
    that neither the white space between the tokens nor the spelling of
    an identifier by universal character names changes it. *)

val typedef : Typec_syntax.Spelling.c_name -> definition:string -> string
(** [typedef instance ~definition] is the layout typedef of [instance]
    whose generic's definition is the text [definition]:
    [typedef struct __tc_digest__D *__tc_layout__I;], where [D] is the
    BLAKE2b-128 digest of [definition] in 32 lower-case hexadecimal
    digits. *)
