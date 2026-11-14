(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type rule =
  | Rewrite of { clang : string; type_name : string }
      (** each occurrence of [clang] in a spelling becomes [type_name] *)
  | No_type_name of { marker : string }
      (** a spelling that holds [marker] names a type no type name can *)
  | Retyped of { kind : string; category : string }
      (** Clang gives a node of [kind] in [category] a type that is not
          the one C gives the expression *)

(* Clang's spellings that typec reads as Clang means them, such as the
   typedef names, [typeof] and [_Atomic(int)], need no rule: they are
   read where the comparison reads every spelling. *)
let rules =
  [
    ( No_type_name { marker = "(unnamed " },
      "an anonymous structure, union or enumeration, which Clang names by \
       the location of its keyword" );
    ( No_type_name { marker = "(anonymous " },
      "an anonymous member (C11 6.7.2.1p13), which Clang names by the \
       location of its keyword" );
    ( No_type_name { marker = "<builtin fn type>" },
      "a builtin function, which has no C type in Clang" );
    ( Rewrite { clang = " __attribute__((noreturn))"; type_name = "" },
      "Clang keeps noreturn in a function type; it is no part of a type in \
       C11 (6.7.4) or in typec" );
    ( Rewrite
        { clang = "struct __va_list_tag *"; type_name = "__builtin_va_list" },
      "a va_list parameter, which Clang adjusts to a pointer on x86-64 and \
       typec does not (design P20)" );
    ( Retyped { kind = "StringLiteral"; category = "prvalue" },
      "a string literal that initialises an array, which Clang gives the \
       array's type" );
  ]

let variable_length = "__typec_oracle_length"

(* Whether [pattern] occurs in [text] at [index]. *)
let occurs_at ~pattern text index =
  index + String.length pattern <= String.length text
  && String.sub text index (String.length pattern) = pattern

let contains ~marker text =
  let rec scan index =
    index < String.length text
    && (occurs_at ~pattern:marker text index || scan (index + 1))
  in
  scan 0

(* [text] with each occurrence of [pattern], which is not empty, replaced
   by [replacement], scanning left to right. *)
let replace_all ~pattern ~replacement text =
  let buffer = Buffer.create (String.length text) in
  let rec scan index =
    if index >= String.length text then ()
    else if occurs_at ~pattern text index then begin
      Buffer.add_string buffer replacement;
      scan (index + String.length pattern)
    end
    else begin
      Buffer.add_char buffer text.[index];
      scan (index + 1)
    end
  in
  scan 0;
  Buffer.contents buffer

(* The index of the [']'] that closes the ['['] at [index], or the end
   of [text]. *)
let closing_bracket text index =
  let rec scan index depth =
    if index >= String.length text then index
    else
      match text.[index] with
      | '[' -> scan (index + 1) (depth + 1)
      | ']' when depth = 1 -> index
      | ']' -> scan (index + 1) (depth - 1)
      | _ -> scan (index + 1) depth
  in
  scan index 0

let is_constant_length length =
  String.for_all (fun c -> '0' <= c && c <= '9') length

(* Clang spells the length of a constant array as its value and that of
   a variable length array as written, which names objects of the scope
   it is in: each length that is not a number, [*] among them, becomes
   [variable_length]. *)
let variable_lengths spelling =
  let buffer = Buffer.create (String.length spelling) in
  let rec copy index =
    if index < String.length spelling then
      if spelling.[index] <> '[' then begin
        Buffer.add_char buffer spelling.[index];
        copy (index + 1)
      end
      else
        let close = closing_bracket spelling index in
        let length = String.sub spelling (index + 1) (close - index - 1) in
        let length =
          if is_constant_length length then length else variable_length
        in
        Buffer.add_string buffer ("[" ^ length);
        copy close
  in
  copy 0;
  Buffer.contents buffer

let apply_rule spelling (rule, why) =
  match (spelling, rule) with
  | Error _, _ | _, Retyped _ -> spelling
  | Ok text, No_type_name { marker } ->
      if contains ~marker text then Error why else spelling
  | Ok text, Rewrite { clang; type_name } ->
      Ok (replace_all ~pattern:clang ~replacement:type_name text)

(* Whether as many brackets of [spelling] close as open, with none
   closing before one is open; a bracket closed by one of the other kind
   is a parse error on the spelling's own line. *)
let brackets_balance spelling =
  let step (depth, balanced) c =
    match c with
    | '(' | '[' -> (depth + 1, balanced)
    | ')' | ']' -> (depth - 1, balanced && depth > 0)
    | _ -> (depth, balanced)
  in
  let depth, balanced = String.fold_left step (0, true) spelling in
  balanced && depth = 0

(* The comparison reads a spelling on a line of its own as the operand of
   [__typeof__], so one that could end the operand, its declaration or
   its line is no type name it can read: a statement expression in
   [typeof], which Clang spells over several lines, is one. *)
let is_one_type_name spelling =
  String.for_all
    (fun c ->
      (not (Record.needs_escape c)) && c <> ';' && c <> '{' && c <> '}')
    spelling
  && brackets_balance spelling

let apply spelling =
  if not (is_one_type_name spelling) then
    Error
      "a spelling with a control byte such as a line break, a backslash, \
       a brace, a semicolon or unbalanced brackets, which is not one type \
       name on one line"
  else
    List.fold_left apply_rule (Ok spelling) rules
    |> Result.map variable_lengths

let retyped (record : Record.t) =
  let applies = function
    | Retyped { kind; category }, why
      when kind = record.kind && category = record.category ->
        Some why
    | _ -> None
  in
  List.find_map applies rules
