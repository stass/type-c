(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* Property tests of the names of instances (design 10.3, 13.5). Over
   types drawn at random from those that have a row in the table of
   10.3: two types of one encoding are the same type to Ctype (3.5 rule
   3); no encoding is a proper prefix of another, so the arguments of an
   instance name split one way; and neither the names that an instance
   derives nor those that typec invents is an instance name or a name
   of another kind. The converse of the first, one encoding of the same
   type, holds since Ctype builds every type in one form and the
   encoding is a function of it; the pool draws no old-style parameter
   lists, which that form keeps and the table does not write. The
   generator is written here and seeded, so a failure repeats with the
   same OCaml, whose [Random] and order of evaluation fix the draws; the
   repository uses no property-testing library. *)

open Typec_cpp
open Typec_syntax
open Typec_sema
open Typec_test_support

let target = Canned_targets.(target (as_clang lp64_macros))

(* Change the seed to draw other types; every seed must pass. *)
let seed = 20262
let random = Random.State.make [| seed |]

(* Most types are shallow, so that the pool covers the short ones
   densely: two types that differ in one part, such as a trailing
   ellipsis, are both drawn, which the identity check needs. *)
let pool_size = 20000
let depths = [ 1; 1; 2; 2; 2; 3; 4 ]
let failures = ref 0

let fail name message =
  incr failures;
  Printf.eprintf "FAIL (seed %d): %s\n  %s\n" seed name message

let get = function
  | Ok x -> x
  | Error error -> failwith (Ctype.error_message error)

let below bound = Random.State.int random bound
let chance percent = below 100 < percent
let pick list = List.nth list (below (List.length list))

(* {1 Names} *)

(* The pieces of a name: letters that are also codes of the table, so
   that a name inside an encoding looks like the encoding around it,
   [_], digits, and the two- and three-byte UTF-8 forms of e-acute and
   the euro sign, so that a length counts bytes. *)
let letters = [ "a"; "n"; "x"; "v"; "E"; "I"; "K"; "P"; "T"; "Y"; "_" ]
let wide = [ "\xc3\xa9"; "\xe2\x82\xac" ]
let digits = [ "0"; "1"; "9" ]

(* The names drawn so far in each namespace, where every name differs
   from every other, as in one translation unit; constructors are in a
   namespace of their own here, which is stricter than one per
   variant. *)
type namespace = (string, unit) Hashtbl.t

let ordinary : namespace = Hashtbl.create 64
let tag_namespace : namespace = Hashtbl.create 64
let constructors : namespace = Hashtbl.create 64

(* Up to 12 pieces, so that some lengths have two digits. *)
let rec fresh namespace accept =
  let piece index =
    pick (if index = 0 then letters @ wide else letters @ wide @ digits)
  in
  let name = String.concat "" (List.init (1 + below 12) piece) in
  if Hashtbl.mem namespace name || not (accept name) then
    fresh namespace accept
  else begin
    Hashtbl.add namespace name ();
    name
  end

(* A name in C text: any identifier, [__] and a final [_] among them. *)
let c_name () = fresh ordinary (fun _ -> true)

(* Half of the tags spell an ordinary name, as [struct n] and the
   typedef [n] may in C, where only the row tells the two apart. *)
let tag_name () =
  let not_a_tag name () names =
    if Hashtbl.mem tag_namespace name then names else name :: names
  in
  (* Sorted, as the order of a fold is not the order of insertion. *)
  match List.sort compare (Hashtbl.fold not_a_tag ordinary []) with
  | _ :: _ as names when chance 50 ->
      let name = pick names in
      Hashtbl.add tag_namespace name ();
      name
  | _ -> fresh tag_namespace (fun _ -> true)

(* [fresh] draws only names that [check] accepts. *)
let checked_name namespace check =
  match check (fresh namespace (fun name -> Result.is_ok (check name))) with
  | Ok name -> name
  | Error _ -> failwith "checked_name: a fresh name refused"

let type_name () =
  checked_name ordinary (Spelling.type_name ~at_file_scope:true)

let constructor_name () = checked_name constructors Spelling.constructor

(* {1 Types} *)

let tags = Ctype.create_tags ()
let int_type = get (Ctype.integer target Int)

let arithmetic_types =
  let integers : Integer.t list =
    [ Bool; Char; Signed_char; Unsigned_char; Short; Unsigned_short; Int;
      Unsigned_int; Long; Unsigned_long; Long_long; Unsigned_long_long ]
  and floatings : Arithmetic.floating list = [ Float; Double; Long_double ]
  and arithmetic kind = get (Ctype.arithmetic target kind) in
  List.map (fun integer -> arithmetic (Integer integer)) integers
  @ List.map (fun floating -> arithmetic (Real floating)) floatings
  @ List.map (fun floating -> arithmetic (Complex floating)) floatings

(* A record is complete, so that an array of it has a row. *)
let defined tag =
  let member =
    { Ctype.member_name = Some "m"; member_type = int_type;
      bit_field_width = None }
  in
  get (Ctype.define_record target tags tag [ member ]);
  Ctype.record tag

let defined_enum tag =
  get (Ctype.define_enum tags tag (Answer Int));
  Ctype.enum tag

(* The declarator of a name is no part of its encoding. *)
let named_untagged t =
  let declared = Typec_syntax.Tree.Builtin "" in
  Ctype.name_untagged tags t [ { name = c_name (); declared } ];
  t

(* A type of a kind that a name, a tag or an id tells apart. *)
let named_type () =
  let at_file_scope = true in
  let tagged kind = Ctype.declare_record tags kind ~at_file_scope in
  match below 8 with
  | 0 -> defined (tagged Struct (Some (tag_name ())))
  | 1 -> defined (tagged Union (Some (tag_name ())))
  | 2 ->
      defined_enum (Ctype.declare_enum tags (Some (tag_name ())) ~at_file_scope)
  | 3 -> named_untagged (defined (tagged Struct None))
  | 4 ->
      named_untagged
        (defined_enum (Ctype.declare_enum tags None ~at_file_scope))
  | 5 -> Ctype.record (Ctype.declare_variant tags (type_name ()) ~at_file_scope)
  | 6 ->
      let name = (type_name () :> string) in
      defined (Ctype.declare_alias_record tags Union name ~at_file_scope)
  | _ ->
      let name = (type_name () :> string) in
      get (Ctype.declare_distinct tags name Public int_type ~at_file_scope)

(* The type parameters of a check are declared first, so that their ids
   run from one digit to two and one id begins another, as [1] begins
   [10]. *)
let named_types =
  let parameters = List.init 12 (fun _ -> Ctype.declare_opaque tags "T") in
  let others = List.init 40 (fun _ -> named_type ()) in
  List.map Ctype.record parameters @ others

(* What an application of a generic of each kind is (design 3.5 rule
   3). *)
type generic_kind = Alias of Ctype.record_kind | Variant | Distinct

type generic = {
  generic_name : Spelling.type_name;
  kind : generic_kind;
  arity : int;
}

let generics =
  List.map
    (fun (kind, arity) -> { generic_name = type_name (); kind; arity })
    [ (Alias Struct, 1); (Alias Union, 2); (Variant, 1); (Variant, 2);
      (Distinct, 1); (Alias Struct, 3) ]

(* The instances of the pool, as they are drawn. *)
let drawn_instances = ref []

let distinct_instance generic instance =
  let name = (generic.generic_name :> string) in
  Ctype.read_instance tags instance ~read:(fun () ->
      get
        (Ctype.declare_distinct ~instance tags name Public int_type
           ~at_file_scope:true))

let application generic instance =
  drawn_instances := (generic, instance) :: !drawn_instances;
  match generic.kind with
  | Alias kind ->
      Ctype.record (Ctype.declare_instance tags kind instance ~define:ignore)
  | Variant ->
      Ctype.record
        (Ctype.declare_variant_instance tags instance ~define:ignore)
  | Distinct -> distinct_instance generic instance

(* [t] if [built] is no type: the parts that C forbids, such as a
   restrict-qualified integer, are dropped. *)
let or_else t built = match built with Ok built -> built | Error _ -> t

let qualifiers () =
  { Qualifiers.const = chance 30; volatile = chance 15;
    restrict = chance 15; atomic = chance 10 }

let array_length () : Ctype.length =
  if chance 20 then Unknown else Constant (pick [ 0; 1; 3; 9; 10; 12; 100 ])

(* A type with a row of its own, which is no array or function; [depth]
   bounds the nesting. *)
let rec object_type depth =
  if depth <= 0 then leaf ()
  else
    match below 6 with
    | 0 -> leaf ()
    | 1 | 2 -> or_else Ctype.void (Ctype.pointer_to (pointee (depth - 1)))
    | 3 ->
        let t = object_type (depth - 1) in
        or_else t (Ctype.qualify (qualifiers ()) t)
    | 4 -> instance_type (depth - 1)
    | _ -> pick arithmetic_types

and leaf () =
  match below 3 with
  | 0 -> pick named_types
  | 1 -> Ctype.void
  | _ -> pick arithmetic_types

(* What a pointer points to, where an array or a function has a row. *)
and pointee depth =
  match below 5 with
  | 0 -> array_type depth
  | 1 -> function_type depth
  | _ -> object_type depth

and array_type depth =
  let element =
    if depth > 0 && chance 20 then array_type (depth - 1)
    else object_type depth
  in
  or_else element (Ctype.array_of tags element (array_length ()))

(* A parameter may be an array or a function, which C adjusts to a
   pointer, and its qualifiers are dropped. Old-style parameters are
   left to [check_no_prototype]. *)
and function_type depth =
  let return = object_type depth in
  let parameter _ = if chance 20 then pointee depth else object_type depth in
  let parameters : Ctype.parameters =
    if chance 15 then Unspecified
    else
      Prototype
        { types = List.init (below 4) parameter; variadic = chance 20 }
  in
  or_else return (Ctype.function_returning return parameters)

and instance_type depth =
  let generic = pick generics in
  let argument _ = ((), object_type depth) in
  let arguments = List.init generic.arity argument in
  match Encoding.instance tags generic.generic_name arguments with
  | Ok instance -> application generic instance
  | Error _ -> leaf ()

(* The pool and the encoding of each of its types, all of which have a
   row by construction. *)
let pool =
  let coded t =
    match Encoding.encode tags t with
    | Ok code -> Some (t, code)
    | Error { reason = Too_long; _ } ->
        fail "a drawn type" "is longer than Encoding.max_length";
        None
    | Error _ ->
        fail "a drawn type" "has no row, though every part of it has one";
        None
  in
  List.filter_map coded
    (List.init pool_size (fun _ -> object_type (pick depths)))

(* {1 Encodings} *)

let location = { Location.file = "in.c"; line = 1; flags = No_flags }

let same a b =
  match Ctype.same_type target tags location a b with
  | Answer same -> same
  | Depends_on _ -> failwith "a drawn type depends on an unknown type"

(* Design 3.5 rule 3: types of equal encodings are the same type. Each
   type is compared with the first type of its encoding. The result is
   each encoding once, in the order drawn. *)
let unique_codes =
  let first_of_code = Hashtbl.create 1024 in
  let check codes (t, code) =
    match Hashtbl.find_opt first_of_code code with
    | Some first ->
        if not (same first t) then fail "one encoding of two types" code;
        codes
    | None ->
        Hashtbl.add first_of_code code t;
        code :: codes
  in
  List.rev (List.fold_left check [] pool)

(* Every encoding is self-delimiting. In sorted order the codes that
   begin with a code follow it directly, so a code that is a proper
   prefix of another is one of the next code. *)
let check_prefix_free () =
  let rec check = function
    | shorter :: (longer :: _ as rest) ->
        if String.starts_with ~prefix:shorter longer then
          fail "a proper prefix" (shorter ^ " begins " ^ longer);
        check rest
    | [ _ ] | [] -> ()
  in
  check (List.sort compare unique_codes)

let instance_name generic arguments =
  Encoding.instance_name
    { generic; arguments; argument_types = []; mentions_parameter = false }

(* Design 10.3: the arguments of an instance name split one way, so one
   name is one list of one or two encodings. This follows from
   [check_prefix_free] and shows it on names; 70 codes, the first
   drawn, keep the table small. *)
let check_names_split () =
  let codes = List.filteri (fun index _ -> index < 70) unique_codes in
  let generic = (List.hd generics).generic_name in
  let pairs_with first = List.map (fun second -> [ first; second ]) codes in
  let lists =
    List.map (fun code -> [ code ]) codes @ List.concat_map pairs_with codes
  in
  let arguments_of_name = Hashtbl.create 8192 in
  let check arguments =
    let name = instance_name generic arguments in
    match Hashtbl.find_opt arguments_of_name name with
    | Some other when other <> arguments ->
        fail "one instance name of two lists" name
    | Some _ | None -> Hashtbl.replace arguments_of_name name arguments
  in
  List.iter check lists

(* No prototype is one row, [N], whatever an old-style definition
   declares (design 10.3). The pool draws no old-style parameters, which
   [Ctype.same_type] compares and the row does not write. *)
let check_no_prototype () =
  let pointer parameters =
    get (Ctype.pointer_to (get (Ctype.function_returning int_type parameters)))
  in
  let code parameters = Encoding.encode tags (pointer parameters) in
  let lists = [ Ctype.Unspecified; Old_style []; Old_style [ int_type ] ] in
  if List.exists (fun parameters -> code parameters <> Ok "PFiNE") lists
  then fail "a function without a prototype" "is not PFiNE"

(* {1 Names of other kinds} *)

let index_of_double_underscore name =
  let rec from index =
    if index + 1 >= String.length name then None
    else if name.[index] = '_' && name.[index + 1] = '_' then Some index
    else from (index + 1)
  in
  from 0

let holds_double_underscore name = index_of_double_underscore name <> None

(* The first [__] of an instance name ends its generic (design 10.3),
   since Spelling refuses every type name that holds one or ends in
   [_]. *)
let check_generic_ends_at_first_underscores () =
  let check (generic, (instance : Ctype.instance)) =
    let name = Encoding.instance_name instance in
    let generic_end = String.length (generic.generic_name :> string) in
    if index_of_double_underscore name <> Some generic_end then
      fail "the generic of an instance name" name
  in
  List.iter check !drawn_instances;
  let refused spelling =
    if Result.is_ok (Spelling.type_name ~at_file_scope:true spelling) then
      fail "a type name that would hide the end of a generic" spelling
  in
  List.iter refused [ "a__b"; "vector_"; "__tc_x" ]

let begins_with_underscore_and_digit code =
  String.length code >= 2 && code.[0] = '_' && code.[1] >= '0'
  && code.[1] <= '9'

(* [I_tag] and [I_C] (design 10.1, 10.3) follow the last encoding of [I]
   with [_] and a word that begins with no digit or [_]: [tag], or a
   constructor, which is an identifier that Spelling keeps from a first
   [_]. No encoding begins so, as no row begins with [_] but the type
   parameter of a check, [_] and a digit; by [check_prefix_free], then,
   neither name is an instance name, and each is one instance and one
   word. *)
let check_derived_names () =
  let check_code code =
    if String.starts_with ~prefix:"_" code
       && not (begins_with_underscore_and_digit code)
    then fail "an encoding that begins as a derived name" code
  in
  List.iter check_code unique_codes;
  if Result.is_ok (Spelling.constructor "_x") then
    fail "a constructor" "may begin with _"

(* A name that a declared variant derives holds no [__], which every
   instance name holds. *)
let check_declared_names () =
  let check _ =
    let name = (type_name () :> string)
    and word = (constructor_name () :> string) in
    let derived = [ name; name ^ "_tag"; name ^ "_" ^ word ] in
    if List.exists holds_double_underscore derived then
      fail "a declared name like an instance name" name
  in
  List.iter check (List.init 200 Fun.id)

(* Design 13.5: an invented name that is one of many of its kind holds
   [__] after [__tc_], and one that is not holds none, so names of
   different kinds differ. The names that are not are read from what
   typec emits for a unit with the constructs that invent them and a
   bracketed edit, which ends the unit with the packing probe. *)
let invented_source =
  "type list = | Nil | Cons(long head, list *tail);\n\
   list make(void);\n\
   long f(const list *l) {\n\
  \  long total = 0;\n\
  \  match (*l) {\n\
  \  case Nil: break;\n\
  \  case Cons(head, _): total = head; break;\n\
  \  }\n\
  \  match (make()) {\n\
  \  case Nil: break;\n\
  \  case Cons(head, _): total += head; break;\n\
  \  }\n\
  \  if (case Cons(head, _) = *l) total += head;\n\
  \  return total;\n\
   }\n"

let with_bracket reader (lowered : Typec_emit.Emitter.lowered) =
  let at =
    match Typec_test_support.External_declarations.of_unit reader with
    | first :: _ -> Typec_syntax.Tree.anchor first
    | [] -> failwith "with_bracket: no external declaration"
  in
  let location = reader.Reader.tokens.(0).location in
  let bracketed output =
    Typec_emit.Emitter.bracketed output ~at ~location
      [ Typec_emit.Emitter.generated output location "struct s { int i; };" ]
  in
  let bracketed, _ =
    Result.get_ok (Typec_emit.Emitter.limited reader bracketed)
  in
  { lowered with edits = bracketed :: lowered.edits }

let emitted source =
  let file = "in.tc" in
  let preprocessed = Preprocessed.text ~name:file source in
  let lower reader =
    Typec_driver.Front_end.lower Gnu target reader
    |> Result.map fst
    |> Result.map (with_bracket reader)
    |> Result.map (Typec_emit.Emitter.emit reader)
  in
  match Result.bind (Reader.read ~name:file preprocessed) lower with
  | Ok text -> text
  | Error error -> failwith (Reader.error_message error)

let is_identifier_byte = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

(* The runs of identifier bytes of [text], in strings and comments too,
   which can only add names to check. *)
let identifiers text =
  let words = ref [] and start = ref None in
  let close index =
    Option.iter
      (fun first -> words := String.sub text first (index - first) :: !words)
      !start;
    start := None
  in
  String.iteri
    (fun index byte ->
      if not (is_identifier_byte byte) then close index
      else if !start = None then start := Some index)
    text;
  close (String.length text);
  !words

let prefix = "__tc_"

(* The names that the sample invents: those of the match and the test,
   of the assertions and of the probe. Fewer means that the sample no
   longer reaches a construct, and the check would pass unread. *)
let invented_in_sample = 7

let check_invented_names () =
  let invented =
    List.filter
      (String.starts_with ~prefix)
      (identifiers (emitted invented_source))
    |> List.sort_uniq compare
  in
  if List.length invented < invented_in_sample then
    fail "the invented names" (String.concat " " invented);
  let after_prefix name =
    String.sub name (String.length prefix)
      (String.length name - String.length prefix)
  in
  let check name =
    if holds_double_underscore (after_prefix name) then
      fail "an invented name with the shape of a kind" name
  in
  List.iter check invented;
  (* The name of a universe function is a kind word: no [__], no final
     [_]. The universe types are held to it too, which costs nothing. *)
  let check_universe ({ name; _ } : Universe.t) =
    if holds_double_underscore name || String.ends_with ~suffix:"_" name then
      fail "a universe name that is no kind word" name
  in
  List.iter check_universe Universe.names

let () =
  check_prefix_free ();
  check_names_split ();
  check_no_prototype ();
  check_generic_ends_at_first_underscores ();
  check_derived_names ();
  check_declared_names ();
  check_invented_names ();
  if !failures > 0 then exit 1
