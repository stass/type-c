(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The keywords of C11 6.4.1 and of the GNU profile (design 13.3). The
   words that Type-C adds are not here: [try] and [defer] are keywords
   only in Type-C text and [type], [match] and the others only in some
   positions (design 2.3), so the parser recognises them where they may
   appear. *)

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
  | Label
  | Typeof
  | Optional_float of Optional_float.t
  | Int128
  | Nonnull
  | Nullable
  | Nullable_result
  | Null_unspecified
  | Builtin_va_arg
  | Builtin_offsetof
  | Builtin_types_compatible_p
  | Real
  | Imag

(* Where a spelling is a keyword. GCC and Clang reserve the GNU keywords
   spelled without underscores only in the GNU dialects, since in ISO C
   they are the user's identifiers; a spelling with underscores is
   reserved to the implementation (C11 7.1.3), so it is a keyword in
   every dialect, and [__int128] where the backend has the type. *)
type reserved_in = Every_dialect | Gnu_dialect | With_int128

(* The one mapping from spellings to keywords but for the optional
   floating types, which Optional_float spells and the keyword set
   selects. The GNU spellings of C11 keywords map to the C11 keyword: GCC
   and Clang give them the same meaning in every dialect. *)
let spellings =
  [
    ("auto", Auto, Every_dialect);
    ("break", Break, Every_dialect);
    ("case", Case, Every_dialect);
    ("char", Char, Every_dialect);
    ("const", Const, Every_dialect);
    ("__const", Const, Every_dialect);
    ("__const__", Const, Every_dialect);
    ("continue", Continue, Every_dialect);
    ("default", Default, Every_dialect);
    ("do", Do, Every_dialect);
    ("double", Double, Every_dialect);
    ("else", Else, Every_dialect);
    ("enum", Enum, Every_dialect);
    ("extern", Extern, Every_dialect);
    ("float", Float, Every_dialect);
    ("for", For, Every_dialect);
    ("goto", Goto, Every_dialect);
    ("if", If, Every_dialect);
    ("inline", Inline, Every_dialect);
    ("__inline", Inline, Every_dialect);
    ("__inline__", Inline, Every_dialect);
    ("int", Int, Every_dialect);
    ("long", Long, Every_dialect);
    ("register", Register, Every_dialect);
    ("restrict", Restrict, Every_dialect);
    ("__restrict", Restrict, Every_dialect);
    ("__restrict__", Restrict, Every_dialect);
    ("return", Return, Every_dialect);
    ("short", Short, Every_dialect);
    ("signed", Signed, Every_dialect);
    ("__signed", Signed, Every_dialect);
    ("__signed__", Signed, Every_dialect);
    ("sizeof", Sizeof, Every_dialect);
    ("static", Static, Every_dialect);
    ("struct", Struct, Every_dialect);
    ("switch", Switch, Every_dialect);
    ("typedef", Typedef, Every_dialect);
    ("union", Union, Every_dialect);
    ("unsigned", Unsigned, Every_dialect);
    ("void", Void, Every_dialect);
    ("volatile", Volatile, Every_dialect);
    ("__volatile", Volatile, Every_dialect);
    ("__volatile__", Volatile, Every_dialect);
    ("while", While, Every_dialect);
    ("_Alignas", Alignas, Every_dialect);
    ("_Alignof", Alignof, Every_dialect);
    ("__alignof", Alignof, Every_dialect);
    ("__alignof__", Alignof, Every_dialect);
    ("_Atomic", Atomic, Every_dialect);
    ("_Bool", Bool, Every_dialect);
    ("_Complex", Complex, Every_dialect);
    ("__complex", Complex, Every_dialect);
    ("__complex__", Complex, Every_dialect);
    ("_Generic", Generic, Every_dialect);
    ("_Imaginary", Imaginary, Every_dialect);
    ("_Noreturn", Noreturn, Every_dialect);
    ("_Static_assert", Static_assert, Every_dialect);
    ("_Thread_local", Thread_local, Every_dialect);
    ("__thread", Thread_local, Every_dialect);
    ("asm", Asm, Gnu_dialect);
    ("__asm", Asm, Every_dialect);
    ("__asm__", Asm, Every_dialect);
    ("__attribute", Attribute, Every_dialect);
    ("__attribute__", Attribute, Every_dialect);
    ("__extension__", Extension, Every_dialect);
    ("__int128", Int128, With_int128);
    ("__label__", Label, Every_dialect);
    ("typeof", Typeof, Gnu_dialect);
    ("__typeof", Typeof, Every_dialect);
    ("__typeof__", Typeof, Every_dialect);
    ("_Nonnull", Nonnull, Every_dialect);
    ("_Nullable", Nullable, Every_dialect);
    ("_Nullable_result", Nullable_result, Every_dialect);
    ("_Null_unspecified", Null_unspecified, Every_dialect);
    ("__builtin_va_arg", Builtin_va_arg, Every_dialect);
    ("__builtin_offsetof", Builtin_offsetof, Every_dialect);
    ("__builtin_types_compatible_p", Builtin_types_compatible_p, Every_dialect);
    ("__real", Real, Every_dialect);
    ("__real__", Real, Every_dialect);
    ("__imag", Imag, Every_dialect);
    ("__imag__", Imag, Every_dialect);
  ]

let table =
  Hashtbl.of_seq
    (List.to_seq
       (List.map
          (fun (spelling, keyword, reserved_in) ->
            (spelling, (keyword, reserved_in)))
          spellings))

let is_reserved (keywords : Keyword_set.t) reserved_in =
  match (reserved_in, keywords.dialect) with
  | Every_dialect, _ | Gnu_dialect, Gnu -> true
  | Gnu_dialect, Iso -> false
  | With_int128, _ -> keywords.int128

let optional_float_of_spelling (keywords : Keyword_set.t) spelling =
  List.find_opt
    (fun optional -> Optional_float.spelling optional = spelling)
    keywords.optional_floats

(* The keyword that an identifier token spells in [keywords], if any. *)
let of_spelling (keywords : Keyword_set.t) spelling =
  let reserved = is_reserved keywords in
  match Hashtbl.find_opt table spelling with
  | Some (keyword, reserved_in) when reserved reserved_in -> Some keyword
  | Some _ -> None
  | None ->
      Option.map
        (fun optional -> Optional_float optional)
        (optional_float_of_spelling keywords spelling)
