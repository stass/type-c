(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The keywords of C11 6.4.1 and of the GNU profile (design 13.3), which
   are keywords in every file. The words that Type-C adds are not here:
   [try] and [defer] are keywords only in Type-C text and [type], [match]
   and the others only in some positions (design 2.3), so the parser
   recognises them where they may appear. *)

type t =
  | Auto
  | Break
  | Case
  | Char
  | Const
  | Continue
  | Default
  | Do
  | Double
  | Else
  | Enum
  | Extern
  | Float
  | For
  | Goto
  | If
  | Inline
  | Int
  | Long
  | Register
  | Restrict
  | Return
  | Short
  | Signed
  | Sizeof
  | Static
  | Struct
  | Switch
  | Typedef
  | Union
  | Unsigned
  | Void
  | Volatile
  | While
  | Alignas
  | Alignof
  | Atomic
  | Bool
  | Complex
  | Generic
  | Imaginary
  | Noreturn
  | Static_assert
  | Thread_local
  | Asm
  | Attribute
  | Extension
  | Typeof
  | Float16
  | Nonnull
  | Nullable
  | Nullable_result
  | Null_unspecified
  | Builtin_va_arg
  | Builtin_offsetof

(* The one mapping from spellings to keywords. The GNU spellings of C11
   keywords map to the C11 keyword: GCC and Clang give them the same
   meaning in every dialect. [asm] and [typeof] are keywords as in gnu11,
   the dialect that [typec] selects by default (design 2.4). *)
let spellings =
  [
    ("auto", Auto);
    ("break", Break);
    ("case", Case);
    ("char", Char);
    ("const", Const);
    ("__const", Const);
    ("__const__", Const);
    ("continue", Continue);
    ("default", Default);
    ("do", Do);
    ("double", Double);
    ("else", Else);
    ("enum", Enum);
    ("extern", Extern);
    ("float", Float);
    ("for", For);
    ("goto", Goto);
    ("if", If);
    ("inline", Inline);
    ("__inline", Inline);
    ("__inline__", Inline);
    ("int", Int);
    ("long", Long);
    ("register", Register);
    ("restrict", Restrict);
    ("__restrict", Restrict);
    ("__restrict__", Restrict);
    ("return", Return);
    ("short", Short);
    ("signed", Signed);
    ("__signed", Signed);
    ("__signed__", Signed);
    ("sizeof", Sizeof);
    ("static", Static);
    ("struct", Struct);
    ("switch", Switch);
    ("typedef", Typedef);
    ("union", Union);
    ("unsigned", Unsigned);
    ("void", Void);
    ("volatile", Volatile);
    ("__volatile", Volatile);
    ("__volatile__", Volatile);
    ("while", While);
    ("_Alignas", Alignas);
    ("_Alignof", Alignof);
    ("__alignof", Alignof);
    ("__alignof__", Alignof);
    ("_Atomic", Atomic);
    ("_Bool", Bool);
    ("_Complex", Complex);
    ("__complex", Complex);
    ("__complex__", Complex);
    ("_Generic", Generic);
    ("_Imaginary", Imaginary);
    ("_Noreturn", Noreturn);
    ("_Static_assert", Static_assert);
    ("_Thread_local", Thread_local);
    ("__thread", Thread_local);
    ("asm", Asm);
    ("__asm", Asm);
    ("__asm__", Asm);
    ("__attribute", Attribute);
    ("__attribute__", Attribute);
    ("__extension__", Extension);
    ("typeof", Typeof);
    ("__typeof", Typeof);
    ("__typeof__", Typeof);
    ("_Float16", Float16);
    ("_Nonnull", Nonnull);
    ("_Nullable", Nullable);
    ("_Nullable_result", Nullable_result);
    ("_Null_unspecified", Null_unspecified);
    ("__builtin_va_arg", Builtin_va_arg);
    ("__builtin_offsetof", Builtin_offsetof);
  ]

let table = Hashtbl.of_seq (List.to_seq spellings)

(* The keyword that an identifier token spells, if any. *)
let of_spelling spelling = Hashtbl.find_opt table spelling
