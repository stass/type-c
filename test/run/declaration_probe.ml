(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Writes a preprocessed C file followed by static assertions of what
   typec reads in its declarations, for the target model read from a macro
   dump: the type of each identifier at file scope, the value of each
   enumerator and the integer type of each enumeration that a typedef
   names. A backend that compiles the result agrees with typec on every
   one. Types that are not C when spelled, such as anonymous structures,
   are left out. *)

open Typec_cpp
open Typec_syntax
open Typec_sema

let read_file path = In_channel.with_open_bin path In_channel.input_all

let or_exit message = function
  | Ok value -> value
  | Error error ->
      prerr_endline (message error);
      exit 1

let spelled t =
  let name = Type_name.of_ctype t in
  if String.contains name '<' then None else Some name

let pointer_to t = Result.to_option (Ctype.pointer_to t)

(* _Generic selects by compatibility after lvalue conversion, so an
   assertion on a pointer to the type also checks its qualifiers. *)
let assert_selects expression t =
  Option.iter
    (fun name ->
      Printf.printf
        "_Static_assert(_Generic(%s, %s: 1, default: 0), \"%s: %s\");\n"
        expression name expression name)
    (Option.bind t spelled)

(* A C constant that every integer type converts to the value. *)
let c_constant value =
  if Exact_integer.is_negative value then
    let less_one =
      Exact_integer.sub (Exact_integer.neg value) Exact_integer.one
    in
    "(-" ^ Exact_integer.to_string less_one ^ "LL - 1)"
  else Exact_integer.to_string value ^ "ULL"

let print_value name (constant : Integer_constant.t) =
  match constant.value with
  | Known value ->
      Printf.printf "_Static_assert(%s == %s, \"%s\");\n" name
        (c_constant value) name
  | Opaque -> ()

let print_enum_integer (result : Declarations.t) name (t : Ctype.t) =
  match t.shape with
  | Enum tag ->
      Option.iter
        (function
          | Ctype.Answer integer ->
              Printf.printf
                "_Static_assert(_Generic((%s)0, %s: 1, default: 0), \
                 \"%s is %s\");\n"
                name (Integer.name integer) name (Integer.name integer)
          | Depends_on _ -> ())
        (Ctype.enum_integer result.tags tag)
  | Void | Arithmetic _ | Pointer _ | Record _ | Va_list | Array _ | Function _
  | Unknown_type _ ->
      ()

let print_identifier result (name, (entity : Declarations.entity)) =
  match entity.declared with
  | Object { object_type = t; _ } | Function { function_type = t; _ } ->
      assert_selects ("&" ^ name) (pointer_to t)
  | Typedef t ->
      assert_selects ("(" ^ name ^ " *)0") (pointer_to t);
      print_enum_integer result name t
  | Enumerator { enumerator_type; value } ->
      assert_selects name (Some enumerator_type);
      print_value name value

let () =
  match Sys.argv with
  | [| _; dump; source |] ->
      let target =
        or_exit Target.error_message
          (Target.of_predefined_macros (read_file dump))
      in
      let text =
        or_exit Reader.error_message
          (Reader.read ~name:source (read_file source))
      in
      let unit = or_exit Parser.error_message (Parser.parse text) in
      let result =
        or_exit Reader.error_message (Declarations.read target text unit)
      in
      print_string text.text;
      List.iter (print_identifier result)
        (Scope.innermost_ordinary result.file_scope)
  | _ ->
      prerr_endline "usage: declaration_probe MACRO-DUMP PREPROCESSED-C";
      exit 2
