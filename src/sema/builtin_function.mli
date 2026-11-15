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
  | Uint16  (** [uint16_t] *)
  | Uint32
      (** [uint32_t], which is [unsigned long] on some 32-bit targets. *)
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

(** The type of an operand of a builtin that moves a value into or out
    of the object that its first argument points to, by the unqualified
    type of that object. *)
type moved = Object_type | Pointer_to_object

(** The type of the result of such a builtin. *)
type moved_result =
  | Moved_object  (** The object's type. *)
  | Fixed of c_type  (** A type of its own. *)

(** How a builtin whose arguments take more than one type is typed: its
    call has the type that the rule gives from the arguments, and the
    name alone has an unknown function type. *)
type rule =
  | Type_generic of c_type
      (** Arguments of any type, a result of the type, as the
          classification and overflow builtins have. *)
  | Pointee_of_first
      (** The unqualified type that the first argument points to, as the
          [__sync], [__atomic] and [__c11_atomic] builtins that compute
          on that object (arithmetic, bitwise, max and min) give; they
          read it, so it is of no distinct type in Type-C text
          (design 3.4). *)
  | Complex_of_first
      (** The complex type of the real floating type of the first
          argument, as [__builtin_complex] gives. *)
  | Moves_object of { operands : moved list; result : moved_result }
      (** A builtin that only moves a value into or out of the object
          that the first argument points to, so the object may be of a
          distinct type (design 3.4): the arguments after the first have
          the types of [operands], those past them have none. Those that
          do arithmetic on the object are [Pointee_of_first]. *)

type signature =
  | Prototype of prototype
  | Rule of rule
  | Unknown
      (** A type that typec does not state (P21), such as one with a
          vector or an optional floating type: a call has an unknown type. *)

(** What an undeclared identifier names for a target. *)
type lookup =
  | Builtin of signature
  | Of_other_compiler  (** A builtin of the other compiler only. *)
  | Of_other_architectures
      (** A builtin that the backend has on other architectures only. *)
  | Not_builtin

val find : Target.t -> string -> lookup

val noreturn : string -> bool
(** Whether the builtin of the name does not return, as GCC and Clang
    declare it. *)

val c_type : Target.t -> c_type -> (Ctype.t, Ctype.error) result
val function_type : Target.t -> prototype -> (Ctype.t, Ctype.error) result

(** {1 The table} *)

(** The architectures that a compiler has a builtin on. *)
type architectures = Every | Only of Target.architecture list

(** What a compiler has of a builtin. *)
type offer = { signature : signature; architectures : architectures }

(** A builtin with what each compiler that has it offers, which is the
    same but for [__builtin_setjmp], [__builtin_longjmp] and
    [__builtin_bswap16]. *)
type entry = { name : string; gcc : offer option; clang : offer option }

val table : entry list
(** One entry for each name. *)

val lookup : Target.t -> entry -> lookup
(** What the entry is for the target, never [Not_builtin]: the one test
    of availability, which {!find} applies. *)

val offer : Target.t -> entry -> offer option
(** What the backend of the target has of the entry, on any
    architecture. *)
