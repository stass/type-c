(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(** The builtin functions of GCC and Clang, which a program calls without
    declaring them: the one table of their names, types and availability,
    which expression typing reads for an undeclared identifier (design
    13.3). Those that the corpus calls and the macros of the system
    headers of the all-headers test expand to are here, with the rest of
    their families, such as the [__atomic] and [__sync] builtins; any
    other undeclared name is an error.
    [__builtin_va_arg], [__builtin_offsetof] and
    [__builtin_types_compatible_p] take a type name and
    [__builtin_choose_expr] is a selection, as [_Generic] is, so they are
    keywords with tree nodes of their own, as in GCC and Clang, rather
    than entries. *)

(** A type in a signature, as the backends' documentation states it. *)
type c_type =
  | Void
  | Integer of Integer.t
  | Size  (** [size_t] *)
  | Uint64
      (** [uint64_t], which is [unsigned long] or [unsigned long long] by
          target. *)
  | Real of Arithmetic.floating
  | Complex of Arithmetic.floating
  | Va_list
  | Pointer of c_type  (** To the type. *)
  | Const of c_type
  | Volatile of c_type

type prototype = { return : c_type; parameters : c_type list; variadic : bool }

(** How a builtin whose arguments take more than one type is typed: its
    call has the type that the rule gives from the arguments, and the
    name alone has an unknown function type. *)
type rule =
  | Type_generic of c_type
      (** Arguments of any type, a result of the type, as the
          classification and overflow builtins have. *)
  | Pointee_of_first
      (** The unqualified type that the first argument points to, as the
          [__sync] and [__atomic] builtins give. *)
  | Complex_of_first
      (** The complex type of the real floating type of the first
          argument, as [__builtin_complex] gives. *)

type signature =
  | Prototype of prototype
  | Rule of rule
  | Unknown
      (** A type that typec does not state (P21), such as one with a
          vector or an optional floating type: a call has an unknown type. *)

(** What an undeclared identifier names for a target. *)
type lookup =
  | Builtin of signature
  | Unavailable  (** A builtin of the other compiler only. *)
  | Not_builtin

val find : Target.t -> string -> lookup

val c_type : Target.t -> c_type -> (Ctype.t, Ctype.error) result
val function_type : Target.t -> prototype -> (Ctype.t, Ctype.error) result

(** {1 The table} *)

(** A builtin with its signature in each compiler that has it, which
    are equal but for [__builtin_setjmp] and [__builtin_longjmp]. *)
type entry = {
  name : string;
  gcc : signature option;
  clang : signature option;
}

val table : entry list
(** One entry for each name. *)

val signature_for : Target.t -> entry -> signature option
(** The signature that the backend of the target gives the entry, if it
    has it: the one test of availability, which {!find} applies. *)
