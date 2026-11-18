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
  Typec_sema.Declarations.t ->
  Typec_cpp.Reader.t ->
  Typec_sema.Declarations.generic_definition ->
  string option
(** [definition_text declarations unit generic] is the text that the
    layout typedef of an instance of [generic] digests: the definition
    of [generic] in [unit], then that of each generic that it applies,
    transitively, each once, in the order in which their applications
    first stand, so that the text names the whole layout that the
    definition depends on. A definition is each of its tokens as
    {!Typec_cpp.Reader.spelling} spells it, followed by one space, so
    that neither the white space between the tokens nor the spelling of
    an identifier by universal character names changes it, and then a
    line break. [None] where [generic] or a generic that it applies,
    transitively, is declared and not defined (design 3.1 rule 4). *)

val typedef : Typec_syntax.Spelling.c_name -> definition:string -> string
(** [typedef instance ~definition] is the layout typedef of [instance]
    whose generic's definition is the text [definition]:
    [typedef struct __tc_digest__D *__tc_layout__I;], where [D] is the
    BLAKE2b-128 digest of [definition] in 32 lower-case hexadecimal
    digits. *)
