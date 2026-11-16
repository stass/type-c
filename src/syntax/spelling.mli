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

val type_name : at_file_scope:bool -> string -> (type_name, string) result
(** The name of a type declaration (design 3.1 rules 6 and 7), declared
    at file scope or not; a name checked for a block scope is valid only
    there. [Error reason] completes the sentence that
    begins with the name and "cannot name a type declaration". *)

val constructor : string -> (constructor, string) result
(** The name of a constructor, as far as the names it derives need
    (design 3.2 rule 2). [Error reason] completes the sentence that
    begins with the name and "cannot name a constructor, as". *)

val is_reserved_for_any_use : string -> bool
(** Whether C reserves the identifier for any use (C11 7.1.3p1): it
    begins with two underscores or with one and an uppercase letter. *)
