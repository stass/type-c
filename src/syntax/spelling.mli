(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The spelling of the names that typec derives C names from: the name
    of a type declaration and the name of a constructor. A derived name
    begins as the type name does and joins a constructor name to it with
    one [_] (design 10.1), so these spellings keep every derived name from
    being reserved in C or holding the [__] of an instance name (design
    3.1 rules 6 and 7, 3.2 rule 2). The checks below are the only way to
    make a value of either type, so a derived name is made only of
    checked names. *)

type type_name = private string
type constructor = private string

type c_name = private string
(** The name that a variant or an instance lowers to, which begins every
    name that a variant derives (design 10.1 rule 6): the type name of a
    declaration, or the name of an instance of a generic (10.3). Only
    {!declared} and {!instance} make one. *)

val max_type_name_length : int
(** The most bytes in a type name, which every name derived from it
    holds; one more is a translation limit of typec (design 3.5 rule 7). *)

(** Why a spelling names no type declaration: [Misspelt reason], where
    [reason] completes the sentence that begins with the name and
    "cannot name a type declaration", or [Too_long length], a name of
    [length] bytes, over {!max_type_name_length}. *)
type refusal = Misspelt of string | Too_long of int

val type_name : at_file_scope:bool -> string -> (type_name, refusal) result
(** The name of a type declaration (design 3.1 rules 6 and 7), declared
    at file scope or not; a name checked for a block scope is valid only
    there. *)

val constructor : string -> (constructor, string) result
(** The name of a constructor, as far as the names it derives need
    (design 3.2 rule 2). [Error reason] completes the sentence that
    begins with the name and "cannot name a constructor, as". *)

val declared : type_name -> c_name
(** The name that the variant of a type declaration lowers to. *)

val instance : type_name -> string list -> c_name
(** The name of the instance of the generic [type_name] whose arguments
    have these encodings (design 10.3): the generic, [__] and each
    encoding. The [__], which no type name holds, keeps the names that
    an instance derives apart from those of every declared variant. The
    encodings are trusted to be those of [Encoding.encode], which no
    type here checks. *)

val instance_space : string -> string option
(** [Some generic] where the identifier begins with [generic] and [__],
    as the name of every instance of a generic of that name does and as
    every name that the instance derives does (design 10.3): the part
    before the identifier's first [__], where that part is not empty.
    Whether a generic of that name is declared is the caller's to ask. *)

val is_reserved_for_any_use : string -> bool
(** Whether C reserves the identifier for any use (C11 7.1.3p1): it
    begins with two underscores or with one and an uppercase letter. *)
