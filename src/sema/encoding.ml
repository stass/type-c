(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type reason =
  | Int128
  | Va_list
  | Unknown_type of Unknown.t
  | Array_not_under_pointer
  | Function_not_under_pointer
  | Opaque_length
  | Variable_length
  | Unnamed
  | Several_names of string list
  | Not_at_file_scope
  | Too_long

type no_row = { part : Ctype.t; reason : reason }

(* Raised at the first part without a row; caught in [encode]. *)
exception No_row of no_row

let refuse part reason = raise (No_row { part; reason })

(* Design 10.3 bounds no name, but an instance is one node of a type, so
   [Ctype.max_size] does not bound the encodings that it holds: a
   typedef of [pair(p, p)] for each [p] doubles the name. The limit keeps
   both the memory of typec and the identifiers that it hands the
   backend small; it is far above the names of real programs. *)
let max_length = 4096

(* An encoding is written into a buffer that refuses to grow past
   [max_length], so that no step builds a longer string. *)
type code = { buffer : Buffer.t; whole : Ctype.t }

let add code text =
  Buffer.add_string code.buffer text;
  if Buffer.length code.buffer > max_length then refuse code.whole Too_long

(* A name is self-delimiting after its length in bytes, which counts a
   character outside ASCII as the bytes of its UTF-8 form. *)
let add_length_prefixed code name =
  add code (string_of_int (String.length name));
  add code name

let length_prefixed name = string_of_int (String.length name) ^ name

let integer_code part : Integer.t -> string = function
  | Bool -> "b"
  | Char -> "c"
  | Signed_char -> "a"
  | Unsigned_char -> "h"
  | Short -> "s"
  | Unsigned_short -> "t"
  | Int -> "i"
  | Unsigned_int -> "j"
  | Long -> "l"
  | Unsigned_long -> "m"
  | Long_long -> "x"
  | Unsigned_long_long -> "y"
  | Int128 | Unsigned_int128 -> refuse part Int128

let floating_code : Arithmetic.floating -> string = function
  | Float -> "f"
  | Double -> "d"
  | Long_double -> "e"

let arithmetic_code part : Arithmetic.t -> string = function
  | Integer integer -> integer_code part integer
  | Real floating -> floating_code floating
  | Complex floating -> "C" ^ floating_code floating

(* Several qualifiers are written in the order A, r, V, K. *)
let add_qualifiers code (qualifiers : Qualifiers.t) =
  let letter present text = if present then add code text in
  letter qualifiers.atomic "A";
  letter qualifiers.restrict "r";
  letter qualifiers.volatile "V";
  letter qualifiers.const "K"

let instance_code (instance : Ctype.instance) =
  "I"
  ^ length_prefixed (instance.generic :> string)
  ^ String.concat "" instance.arguments
  ^ "E"

let instance_name (instance : Ctype.instance) =
  (instance.generic :> string) ^ "__" ^ String.concat "" instance.arguments

(* Design 3.5 rule 2: only a declaration at file scope gives a type the
   one name that it has in every translation unit. *)
let at_file_scope part declared_at_file_scope =
  if not declared_at_file_scope then refuse part Not_at_file_scope

(* An untagged type is named by its one typedef name. *)
let add_typedef_name code tags part =
  match Ctype.typedef_names tags part with
  | [ name ] -> add_length_prefixed code name
  | [] -> refuse part Unnamed
  | names -> refuse part (Several_names names)

(* The declaration of a type chooses its row, however a use spells it
   (design 10.3): the tag that a variant or an alias claims is no tag of
   its own specifier. A type parameter of a definition check has no row
   of 10.3: [_], which begins none, and its id stand for it, so that the
   instances of a check over its parameters are its own (design 3.5 rule
   4). *)
let add_record code tags part (tag : Ctype.record_tag) =
  at_file_scope part tag.record_at_file_scope;
  match tag.record_name with
  | Named name ->
      add code "T";
      add_length_prefixed code name
  | Variant_name name -> add_length_prefixed code (name :> string)
  | Alias_name name -> add_length_prefixed code name
  | Instance_name instance -> add code (instance_code instance)
  | Opaque_name _ -> add code ("_" ^ string_of_int tag.record_id ^ "_")
  | Anonymous -> add_typedef_name code tags part

let add_enum code tags part (tag : Ctype.enum_tag) =
  at_file_scope part tag.enum_at_file_scope;
  match tag.enum_name with
  | Some name ->
      add code "T";
      add_length_prefixed code name
  | None -> add_typedef_name code tags part

(* An instance of a distinct generic takes the row of an application. *)
let add_distinct code part (distinct : Ctype.distinct) =
  at_file_scope part distinct.distinct_at_file_scope;
  match distinct.distinct_instance with
  | Some instance -> add code (instance_code instance)
  | None -> add_length_prefixed code distinct.distinct_name

let add_length code part (length : Ctype.length) =
  match length with
  | Constant count -> add code (string_of_int count)
  | Unknown -> ()
  | Opaque -> refuse part Opaque_length
  | Variable -> refuse part Variable_length

(* [t] where an array or a function type has a row: what a pointer points
   to, or the element of such an array. The qualifiers of an array are
   those of its element, which encodes them (C11 6.7.3p9). *)
let rec add_pointee code tags (t : Ctype.t) =
  match t.shape with
  | Array { element; length } ->
      add code "Y";
      add_pointee code tags element;
      add_length code t length;
      add code "E"
  | Function { return; parameters } ->
      add code "F";
      add_object code tags return;
      add_parameters code tags parameters;
      add code "E"
  | Void | Arithmetic _ | Enum _ | Pointer _ | Record _ | Distinct _ | Va_list
  | Unknown_type _ ->
      add_object code tags t

(* The parameters are adjusted and unqualified ({!Ctype.parameters}), as C
   compares them (C11 6.7.6.3p15). *)
and add_parameters code tags (parameters : Ctype.parameters) =
  match parameters with
  | Prototype { types = []; variadic = false } -> add code "v"
  | Prototype { types; variadic } ->
      List.iter (add_object code tags) types;
      if variadic then add code "z"
  | Unspecified | Old_style _ -> add code "N"

and add_object code tags (t : Ctype.t) =
  add_qualifiers code t.qualifiers;
  add_unqualified code tags t

and add_unqualified code tags (t : Ctype.t) =
  match t.shape with
  | Void -> add code "v"
  | Arithmetic arithmetic -> add code (arithmetic_code t arithmetic)
  | Enum tag -> add_enum code tags t tag
  | Pointer referenced ->
      add code "P";
      add_pointee code tags referenced
  | Record tag -> add_record code tags t tag
  | Distinct distinct -> add_distinct code t distinct
  | Va_list -> refuse t Va_list
  | Array _ -> refuse t Array_not_under_pointer
  | Function _ -> refuse t Function_not_under_pointer
  | Unknown_type unknown -> refuse t (Unknown_type unknown)

let encode tags t =
  let code = { buffer = Buffer.create 16; whole = t } in
  match add_object code tags t with
  | () -> Ok (Buffer.contents code.buffer)
  | exception No_row no_row -> Error no_row

(* The arguments are encoded into one buffer that holds the code of the
   instance, which the name and every encoding that holds the instance
   hold whole: bounding it, but for its closing [E], bounds them all.
   The argument that takes the code past the limit is the part
   refused. *)
let instance (type written) tags (generic : Typec_syntax.Spelling.type_name)
    (arguments : (written * Ctype.t) list) =
  let exception Argument_refused of written * no_row in
  let buffer = Buffer.create 16 in
  let encode_argument (written, argument) =
    let code = { buffer; whole = argument } and start = Buffer.length buffer in
    match add_object code tags argument with
    | () -> Buffer.sub buffer start (Buffer.length buffer - start)
    | exception No_row no_row -> raise (Argument_refused (written, no_row))
  in
  Buffer.add_string buffer ("I" ^ length_prefixed (generic :> string));
  match List.map encode_argument arguments with
  | encodings ->
      let mentions_parameter =
        List.exists (fun (_, t) -> Ctype.mentions_opaque t) arguments
      in
      Ok { Ctype.generic; arguments = encodings; mentions_parameter }
  | exception Argument_refused (written, no_row) -> Error (written, no_row)
