(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The keywords of C11 6.4.1, which are keywords in every file. The words
   that Type-C adds are not here: [try] and [defer] are keywords only in
   Type-C text and [type], [match] and the others only in some positions
   (design 2.3), so the parser recognises them where they may appear. *)

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

(* The one mapping from spellings to keywords. *)
let spellings =
  [
    ("auto", Auto);
    ("break", Break);
    ("case", Case);
    ("char", Char);
    ("const", Const);
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
    ("int", Int);
    ("long", Long);
    ("register", Register);
    ("restrict", Restrict);
    ("return", Return);
    ("short", Short);
    ("signed", Signed);
    ("sizeof", Sizeof);
    ("static", Static);
    ("struct", Struct);
    ("switch", Switch);
    ("typedef", Typedef);
    ("union", Union);
    ("unsigned", Unsigned);
    ("void", Void);
    ("volatile", Volatile);
    ("while", While);
    ("_Alignas", Alignas);
    ("_Alignof", Alignof);
    ("_Atomic", Atomic);
    ("_Bool", Bool);
    ("_Complex", Complex);
    ("_Generic", Generic);
    ("_Imaginary", Imaginary);
    ("_Noreturn", Noreturn);
    ("_Static_assert", Static_assert);
    ("_Thread_local", Thread_local);
  ]

let table = Hashtbl.of_seq (List.to_seq spellings)

(* The keyword that an identifier token spells, if any. *)
let of_spelling spelling = Hashtbl.find_opt table spelling
