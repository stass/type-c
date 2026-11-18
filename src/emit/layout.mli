(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The layout typedef of an instance in the header of an interface
    (design 9.3, 13.5): a typedef named for the instance of a pointer to
    a structure that no text defines, whose tag holds the digest of the
    definition of the instance's generic and of the generics that it
    applies. Two headers that write one definition write one typedef,
    which C lets them repeat; two that write different ones write
    typedefs of different types, which a C client that includes both
    refuses. *)

val typedefs :
  Typec_sema.Declarations.header_text Typec_sema.Declarations.t ->
  Typec_cpp.Reader.t ->
  (Typec_syntax.Tree.span * string) list
(** [typedefs declarations unit] is the layout typedef of each instance
    that {!Typec_sema.Declarations.applications} gives, in its order,
    with the instance's latest application.

    The digest is that of the instance's generic's component in the
    graph whose edges are the applications that the unit's reading
    resolved in each generic's definition: generics that apply each
    other, directly or through others, are one component. It digests
    the definitions of the component's members in [unit], in the order
    of their text, then the digest of each other component that a member
    applies, each once and followed by a line break, in the order of the
    digests. A definition is each of its tokens as
    {!Typec_cpp.Reader.spelling} spells it, followed by one space, so
    that neither the white space between the tokens nor the spelling of
    an identifier by universal character names changes it, and then a
    line break. Each definition is spelt and each digest computed once.

    An instance has no typedef where its generic or a generic that it
    applies, transitively, is declared and not defined (design 3.1
    rule 4). *)

(** {!digest} and {!typedef} are the pieces of what {!typedefs} writes,
    which the tests pin. *)

val digest : string -> string
(** [digest text] is the BLAKE2b-128 digest of [text] in 32 lower-case
    hexadecimal digits. *)

val typedef : Typec_syntax.Spelling.c_name -> digest:string -> string
(** [typedef instance ~digest] is the layout typedef of [instance] whose
    generic's component has the digest [digest]:
    [typedef struct __tc_digest__D *__tc_layout__I;]. *)
