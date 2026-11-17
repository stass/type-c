(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type t = Builtin | Function of string

let builtin = Builtin

let is_identifier_start c =
  match c with 'A' .. 'Z' | 'a' .. 'z' | '_' -> true | _ -> false

let is_identifier_char c =
  match c with '0' .. '9' -> true | c -> is_identifier_start c

let calling name =
  if name <> ""
     && is_identifier_start name.[0]
     && String.for_all is_identifier_char name
  then Some (Function name)
  else None

let builtin_call = "__builtin_trap()"

(* The one function that every trap calls under --trap-function, under a
   name reserved to typec, and its head. *)
let trap_function = "__tc_trap"

let trap_function_head =
  Printf.sprintf "static inline _Noreturn void %s(void)" trap_function

let call = function
  | Builtin -> builtin_call
  | Function _ -> trap_function ^ "()"

let prototype = function
  | Builtin -> []
  | Function _ -> [ trap_function_head ^ ";" ]

(* [name] is declared in the body, after the unit's own text: a
   declaration of file scope in front of that text would make the
   program's own declaration of [name] redundant, which GCC reports under
   -Wredundant-decls at the program's line. *)
let definition = function
  | Builtin -> []
  | Function name ->
      [ Printf.sprintf "%s { _Noreturn void %s(void); %s(); %s; }"
          trap_function_head name name builtin_call ]
