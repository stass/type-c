(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* builtin_probe MACRO-DUMP calls | others | unavailable | withheld: for
   the target model of the dump, the builtins of the table by what the
   backend has. [calls] writes C that calls each one with a prototype,
   with arguments of its parameter types, in a function for each, and
   once more with an extra argument where it is variadic; [others] lists
   the names of those that a rule types or whose type is unknown;
   [unavailable] lists the names that only the other compiler has;
   [withheld] writes the calls of those with a prototype that the backend
   has on other architectures only. *)

open Typec_sema

let read_file path = In_channel.with_open_bin path In_channel.input_all

let or_exit = function
  | Ok value -> value
  | Error message ->
      prerr_endline ("builtin_probe: " ^ message);
      exit 1

let spelled target t =
  match Builtin_function.c_type target t with
  | Ok ctype -> Type_name.of_ctype ctype
  | Error error -> or_exit (Error (Ctype.error_message error))

(* A pointer or va_list argument is a parameter of the probe, so that its
   type is exact; any other is the constant 1 of its type, as the builtins
   that need a constant, such as __builtin_longjmp, take it. *)
let argument target index (t : Builtin_function.c_type) =
  match t with
  | Pointer _ | Va_list -> Printf.sprintf "a%d" index
  | Void | Integer _ | Size | Uint16 | Uint32 | Uint64 | Real _ | Complex _
  | Const _ | Volatile _ ->
      Printf.sprintf "(%s)1" (spelled target t)

let parameter target index t =
  Printf.sprintf "__typeof__(%s) a%d" (spelled target t) index

let probe target index name (prototype : Builtin_function.prototype) =
  let parameters =
    match prototype.parameters with
    | [] -> "void"
    | types -> String.concat ", " (List.mapi (parameter target) types)
  in
  let arguments = List.mapi (argument target) prototype.parameters in
  let calls =
    if prototype.variadic then [ arguments; arguments @ [ "1" ] ]
    else [ arguments ]
  in
  let statement arguments =
    Printf.sprintf " %s(%s);" name (String.concat ", " arguments)
  in
  Printf.printf "void probe_%d(%s) {%s }\n" index parameters
    (String.concat "" (List.map statement calls))

(* Each entry with the signature that the backend gives it. *)
let available target =
  List.filter_map
    (fun (entry : Builtin_function.entry) ->
      match Builtin_function.lookup target entry with
      | Builtin signature -> Some (entry.name, signature)
      | Of_other_compiler | Of_other_architectures | Not_builtin -> None)
    Builtin_function.table

(* Each entry that the backend has on other architectures only, with the
   signature that it has there. *)
let withheld_entries target =
  List.filter_map
    (fun (entry : Builtin_function.entry) ->
      match Builtin_function.(lookup target entry, offer target entry) with
      | Of_other_architectures, Some offer -> Some (entry.name, offer.signature)
      | _ -> None)
    Builtin_function.table

let write_calls target entries =
  List.iteri
    (fun index (name, (signature : Builtin_function.signature)) ->
      match signature with
      | Prototype prototype -> probe target index name prototype
      | Rule _ | Unknown -> ())
    entries

let calls target = write_calls target (available target)
let withheld target = write_calls target (withheld_entries target)

let others target =
  List.iter
    (fun (name, (signature : Builtin_function.signature)) ->
      match signature with
      | Rule _ | Unknown -> print_endline name
      | Prototype _ -> ())
    (available target)

let unavailable target =
  List.iter
    (fun (entry : Builtin_function.entry) ->
      if Builtin_function.lookup target entry = Of_other_compiler then
        print_endline entry.name)
    Builtin_function.table

let () =
  match Sys.argv with
  | [| _; dump; mode |] -> (
      let target =
        or_exit
          (Result.map_error Target.error_message
             (Target.of_predefined_macros ~enum_representation:Int_sized
                (read_file dump)))
      in
      match mode with
      | "calls" -> calls target
      | "others" -> others target
      | "unavailable" -> unavailable target
      | "withheld" -> withheld target
      | _ -> or_exit (Error ("no mode " ^ mode)))
  | _ ->
      prerr_endline
        "usage: builtin_probe MACRO-DUMP calls|others|unavailable|withheld";
      exit 2
