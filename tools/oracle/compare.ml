(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The comparison of the typing oracle (docs/development.md, "Typing oracle"):
   checks the type and the value category typec gives each expression of a
   preprocessed file against the oracle's records of Clang's.

     compare [--show N] CC INPUT RECORDS ALLOW-LIST [OPTION...]

   CC and the options give the target model and the dialect, as for
   typec. It prints the counts, the reasons of the records it could not
   compare, and the first N (by default shown_by_default) of each of:
   the disagreements outside ALLOW-LIST, the comparisons with a type
   typec does not compute, the expressions that only Clang or only typec
   types, and the unresolved records. Exit status: 0 when every
   disagreement is allowed, 1 when one is not or typec refuses INPUT or
   fails on it, 2
   when there is nothing to compare: a wrong command line, options CC
   gives no model for, or a file that cannot be read. *)

open Typec_sema

exception Usage
exception Unreadable of string
exception Refused of string

let shown_by_default = 20

type counts = {
  mutable agree : int;
  mutable disagree : int;
  mutable allowed : int;  (** disagreements that the allow-list accepts *)
  mutable unknown : int;  (** a type that typec does not compute *)
  mutable unresolved : int;  (** a Clang type typec cannot read *)
  mutable clang_only : int;
  mutable typec_only : int;
}

(* What the run prints after the counts, the first [show] of each. *)
type report = {
  show : int;
  counts : counts;
  reasons : (string, int) Hashtbl.t;  (** unresolved records by why *)
  mutable disagreements : string list;
  mutable unknown_lines : string list;
  mutable clang_only_lines : string list;
  mutable typec_only_lines : string list;
  mutable unresolved_lines : string list;
}

let empty_report show =
  {
    show;
    counts =
      {
        agree = 0;
        disagree = 0;
        allowed = 0;
        unknown = 0;
        unresolved = 0;
        clang_only = 0;
        typec_only = 0;
      };
    reasons = Hashtbl.create 16;
    disagreements = [];
    unknown_lines = [];
    clang_only_lines = [];
    typec_only_lines = [];
    unresolved_lines = [];
  }

let read_file path =
  try In_channel.with_open_bin path In_channel.input_all
  with Sys_error message -> raise (Unreadable message)

(* The record that Clang gives each range: the last of the records that
   share it, which come in the order of the dump, so that it is the
   expression as written, inside its implicit conversions. *)
let read_records path =
  let records = Hashtbl.create 65536 in
  let add number line =
    match Record.of_line line with
    | Ok record -> Hashtbl.replace records (record.first, record.limit) record
    | Error message ->
        let where = Printf.sprintf "%s:%d" path (number + 1) in
        raise (Unreadable (where ^ ": " ^ message))
  in
  let contents = read_file path in
  (* Each record ends in a newline, which starts no record. *)
  let body =
    if String.ends_with ~suffix:"\n" contents then
      String.sub contents 0 (String.length contents - 1)
    else contents
  in
  if body <> "" then List.iteri add (String.split_on_char '\n' body);
  records

let read_allow_list path =
  match Allow_list.read (read_file path) with
  | Ok list -> list
  | Error message -> raise (Unreadable (path ^ ": " ^ message))

let expressions_by_range unit ~below =
  let expressions = Hashtbl.create 65536 in
  let add (expression : Typec_unit.expression) =
    Hashtbl.replace expressions (expression.first, expression.limit) expression
  in
  List.iter add (Typec_unit.expressions unit ~below);
  expressions

let sorted_keys table =
  List.sort compare (List.of_seq (Hashtbl.to_seq_keys table))

let note report lines line =
  if List.length lines < report.show then lines @ [ line ] else lines

(* What comes from INPUT or RECORDS is printed escaped, as a record
   holds it, so that it reaches the terminal as text. *)
let place unit first limit =
  let location = Typec_unit.location unit first in
  Printf.sprintf "%s:%d: [%d,%d)"
    (Record.escaped location.file)
    location.line first limit

let clang_lvalue (record : Record.t) = record.category = "lvalue"
let clang_category record = if clang_lvalue record then "lvalue" else "rvalue"

let disagreement unit (record : Record.t) (typed : Expressions.typed) =
  Printf.sprintf "%s %s: Clang %s '%s', typec %s '%s'"
    (place unit record.first record.limit)
    (Record.escaped record.kind)
    (clang_category record)
    (Record.escaped record.qual_type)
    (Typec_unit.category typed)
    (Type_name.of_ctype typed.expression_type)

let disagree report allow_list line =
  match Allow_list.reason allow_list line with
  | Some _ -> report.counts.allowed <- report.counts.allowed + 1
  | None ->
      report.counts.disagree <- report.counts.disagree + 1;
      report.disagreements <- note report report.disagreements line

let unresolved report unit (record : Record.t) why =
  let counts = report.counts in
  counts.unresolved <- counts.unresolved + 1;
  let seen = Option.value (Hashtbl.find_opt report.reasons why) ~default:0 in
  Hashtbl.replace report.reasons why (seen + 1);
  report.unresolved_lines <-
    note report report.unresolved_lines
      (Printf.sprintf "%s %s: '%s': %s"
         (place unit record.first record.limit)
         (Record.escaped record.kind)
         (Record.escaped record.qual_type)
         why)

let compare_types report allow_list unit record (typed : Expressions.typed)
    line = function
  | Spellings.Unresolved why -> unresolved report unit record why
  | Resolved clang_type -> (
      let counts = report.counts in
      let tags = Declarations.tags unit.Typec_unit.declarations in
      let location = Typec_unit.location unit record.Record.first in
      match
        Ctype.same_type unit.target tags location typed.expression_type
          clang_type
      with
      | Answer true -> counts.agree <- counts.agree + 1
      | Answer false -> disagree report allow_list line
      | Depends_on _ ->
          counts.unknown <- counts.unknown + 1;
          report.unknown_lines <- note report report.unknown_lines line)

(* The one comparison: the value categories, then the types by
   Ctype.same_type, of Clang's spelling read by typec. A record whose
   type is not C's is compared in neither. *)
let check report allow_list unit resolve (record : Record.t)
    (typed : Expressions.typed) =
  let line = disagreement unit record typed in
  match Normalisation.retyped record with
  | Some why -> unresolved report unit record why
  | None when clang_lvalue record <> (typed.category = Lvalue) ->
      disagree report allow_list line
  | None ->
      compare_types report allow_list unit record typed line
        (resolve record.qual_type)

let typec_only report unit (expression : Typec_unit.expression) =
  report.counts.typec_only <- report.counts.typec_only + 1;
  report.typec_only_lines <-
    note report report.typec_only_lines
      (Printf.sprintf "%s typec %s '%s'"
         (place unit expression.first expression.limit)
         (Typec_unit.category expression.typed)
         (Type_name.of_ctype expression.typed.expression_type))

let clang_only report unit (record : Record.t) =
  report.counts.clang_only <- report.counts.clang_only + 1;
  report.clang_only_lines <-
    note report report.clang_only_lines
      (Printf.sprintf "%s %s: Clang %s '%s'"
         (place unit record.first record.limit)
         (Record.escaped record.kind)
         (clang_category record)
         (Record.escaped record.qual_type))

let compare_all report allow_list unit resolve records expressions =
  let join key =
    match (Hashtbl.find_opt records key, Hashtbl.find_opt expressions key) with
    | Some record, Some (expression : Typec_unit.expression) ->
        check report allow_list unit resolve record expression.typed
    | Some record, None -> clang_only report unit record
    | None, Some expression -> typec_only report unit expression
    | None, None -> ()
  in
  let keys = Hashtbl.create (Hashtbl.length records) in
  Hashtbl.iter (fun key _ -> Hashtbl.replace keys key ()) records;
  Hashtbl.iter (fun key _ -> Hashtbl.replace keys key ()) expressions;
  List.iter join (sorted_keys keys)

(* The spellings that the comparison reads: those of the records that
   typec has an expression for. *)
let joined_spellings records expressions =
  let add key (record : Record.t) spellings =
    if Hashtbl.mem expressions key then record.qual_type :: spellings
    else spellings
  in
  Hashtbl.fold add records []

let print_report input report =
  let c = report.counts in
  Printf.printf
    "%s: %d agree, %d disagree, %d allowed, %d unknown, %d unresolved, %d \
     Clang-only, %d typec-only\n"
    input c.agree c.disagree c.allowed c.unknown c.unresolved c.clang_only
    c.typec_only;
  List.iter
    (fun why ->
      Printf.printf "unresolved %d: %s\n" (Hashtbl.find report.reasons why) why)
    (sorted_keys report.reasons);
  let section title lines =
    if lines <> [] then begin
      Printf.printf "%s:\n" title;
      List.iter (Printf.printf "  %s\n") lines
    end
  in
  section "disagreements" report.disagreements;
  section "unknown" report.unknown_lines;
  section "Clang only" report.clang_only_lines;
  section "typec only" report.typec_only_lines;
  section "unresolved" report.unresolved_lines

let model ~cc options =
  try Typec_unit.model ~cc options
  with Failure message -> raise (Unreadable message)

(* typec's types are those of INPUT as it is; the spellings are read in
   a unit of their own, which appends to it. *)
let run ~show ~cc ~input ~records ~allow_list ~options =
  let allow_list = read_allow_list allow_list in
  let records = read_records records in
  let text = read_file input in
  let dialect, target = model ~cc options in
  match Typec_unit.read dialect target ~name:input text with
  | Error error -> raise (Refused (Typec_cpp.Reader.error_message error))
  | Ok unit ->
      let below = String.length text in
      let expressions = expressions_by_range unit ~below in
      let resolve =
        Spellings.resolve dialect target ~name:input text
          (joined_spellings records expressions)
      in
      let report = empty_report show in
      compare_all report allow_list unit resolve records expressions;
      print_report input report;
      report.counts.disagree = 0

let show_count text =
  match int_of_string_opt text with
  | Some count when count >= 0 -> count
  | _ -> raise Usage

let main arguments =
  let show, arguments =
    match arguments with
    | "--show" :: count :: rest -> (show_count count, rest)
    | _ -> (shown_by_default, arguments)
  in
  match arguments with
  | cc :: input :: records :: allow_list :: options ->
      run ~show ~cc ~input ~records ~allow_list ~options
  | _ -> raise Usage

let usage = "usage: compare [--show N] CC INPUT RECORDS ALLOW-LIST [OPTION...]"

let fail status message =
  Printf.eprintf "compare: %s\n" message;
  exit status

let () =
  match main (List.tl (Array.to_list Sys.argv)) with
  | true -> exit 0
  | false -> exit 1
  | exception Usage -> fail 2 usage
  | exception Refused message -> fail 1 message
  | exception Unreadable message -> fail 2 message
  | exception Failure message -> fail 1 message
  | exception Unix.Unix_error (error, call, argument) ->
      let reason = Unix.error_message error in
      fail 2 (Printf.sprintf "%s %s: %s" call argument reason)
