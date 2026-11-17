(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The selection tree of design 4.7 rule 6: label sets written as data,
   the bound of rule 10, and a property test against a matcher that
   tries the labels in source order. *)

open Typec_syntax
open Typec_sema

let failures = ref 0

let check what condition =
  if not condition then begin
    incr failures;
    Printf.eprintf "FAIL: %s\n" what
  end

let spelled name =
  match Spelling.constructor name with
  | Ok spelled -> spelled
  | Error reason -> failwith (name ^ reason)

(* Selection reads only the number of a constructor's fields. *)
let field =
  { Ctype.member_name = None; member_type = Ctype.void; bit_field_width = None }

let constructor name arity =
  { Ctype.constructor_name = spelled name;
    fields = List.init arity (fun _ -> field);
    void_fields = [] }

let pattern variant constructor fields =
  { Selection.variant; constructor; fields }

let select scrutinee labels ~default =
  match Selection.select scrutinee labels ~default with
  | Ok tree -> tree
  | Error Too_large -> failwith "a small tree refused as too large"

(* The missing values, where a constructor of the scrutinee stands for
   the value that holds it with every field unread. *)
let missing_values tree =
  match Selection.missing tree with
  | Nothing_missing -> []
  | Values values -> values
  | Scrutinee_constructors constructors ->
      List.map
        (fun (constructor : Ctype.constructor) ->
          Selection.Holds
            { constructor;
              through_pointer = false;
              fields = List.map (fun _ -> Selection.Unread) constructor.fields
            })
        constructors

let missing tree = List.map Selection.spelling (missing_values tree)

let rec size (tree : Selection.tree) =
  match tree with
  | Leaf _ -> 1
  | Node { branches; _ } -> 1 + branches_size branches

and branches_size branches =
  List.fold_left
    (fun total (branch : Selection.branch) -> total + size branch.subtree)
    0 branches

(* The root reads the scrutinee. *)
let tree_size (tree : Selection.t) = 1 + branches_size tree.scrutinee

(* Data *)

(* type eval_error = | DivByZero | Overflow;
   result(int, eval_error) = | Ok(int value) | Err(eval_error error); *)
let div_by_zero = constructor "DivByZero" 0
let overflow = constructor "Overflow" 0
let eval_error = [ div_by_zero; overflow ]
let ok = constructor "Ok" 1
let err = constructor "Err" 1
let result = [ ok; err ]
let ok_any = pattern result ok [ Any ]
let err_any = pattern result err [ Any ]

let err_of inner =
  pattern result err [ Constructor (pattern eval_error inner []) ]

let nested_results () =
  let tree = select result [ ok_any; err_of div_by_zero ] ~default:false in
  check "Err(Overflow) is missing" (missing tree = [ "Err(Overflow)" ]);
  check "every label is selected" (Selection.never_selected tree = []);
  let tree =
    select result [ ok_any; err_of div_by_zero; err_of overflow ]
      ~default:false
  in
  check "the three labels miss nothing" (missing tree = []);
  let tree =
    select result [ ok_any; err_any; err_of div_by_zero ] ~default:false
  in
  check "Err(DivByZero) after Err(_) is never selected"
    (Selection.never_selected tree = [ 2 ]);
  let tree = select result [ ok_any; err_of overflow ] ~default:true in
  check "a default takes Err(DivByZero)"
    (missing tree = [] && not (Selection.default_never_selected tree))

(* type e = | A | B(int, int) | C(int); *)
let a = constructor "A" 0
let b = constructor "B" 2
let c = constructor "C" 1
let e = [ a; b; c ]
let case_a = pattern e a []
let case_b = pattern e b [ Any; Any ]
let case_c = pattern e c [ Any ]

let flat () =
  let tree = select e [ case_b ] ~default:false in
  check "A and C share the missing leaf"
    (match Selection.missing tree with
     | Scrutinee_constructors [ first; second ] -> first == a && second == c
     | _ -> false);
  check "a flat match is one node"
    (List.for_all
       (fun (branch : Selection.branch) ->
         match branch.subtree with Leaf _ -> true | Node _ -> false)
       tree.scrutinee);
  let tree = select e [ case_a; case_b; case_c ] ~default:true in
  check "a default after every constructor takes nothing"
    (Selection.default_never_selected tree);
  let tree = select e [ case_a; case_a ] ~default:true in
  check "a constructor named twice is never selected the second time"
    (Selection.never_selected tree = [ 1 ]);
  let tree = select e [] ~default:true in
  check "a lone default takes every constructor"
    (match tree.scrutinee with
     | [ { constructors; subtree = Leaf Default } ] ->
         List.length constructors = 3
     | _ -> false)

(* type expr = | Num(int value) | Add(const expr *l, const expr *r); *)
let num = constructor "Num" 1
let add = constructor "Add" 2
let expr = [ num; add ]
let num_any = Selection.Pointer (pattern expr num [ Any ])

let pointers () =
  let tree =
    select expr
      [ pattern expr add [ num_any; num_any ];
        pattern expr add [ Any; Any ];
        pattern expr num [ Any ] ]
      ~default:false
  in
  check "the expr match misses nothing" (missing tree = []);
  check "the expr match selects every label"
    (Selection.never_selected tree = []);
  let tree =
    select expr
      [ pattern expr num [ Any ];
        pattern expr add [ Pointer (pattern expr add [ Any; Any ]); Any ] ]
      ~default:false
  in
  check "Add(*Num(_), _) is missing" (missing tree = [ "Add(*Num(_), _)" ])

(* A label given up on a tag read does not split the branches below
   it: in P(X, X), P(Y, Z), where the first field holds X, Y and Z are
   both missing at the second. *)
let given_up_names () =
  let x = constructor "X" 0 and y = constructor "Y" 0 in
  let z = constructor "Z" 0 in
  let xyz = [ x; y; z ] in
  let p = constructor "P" 2 in
  let ps = [ p ] in
  let label first second =
    pattern ps p
      [ Constructor (pattern xyz first []);
        Constructor (pattern xyz second []) ]
  in
  let tree = select ps [ label x x; label y z ] ~default:false in
  check "P(X, Y) and P(X, Z) share the missing leaf"
    (missing tree = [ "P(X, Y)"; "P(X, Z)" ])

(* type side = | Left | Right; type pair = | Pair(side s, tree *t);
   In case Pair(Left, _): before case Pair(_, *Leaf(n)):, the second
   field of a value whose first field holds Left is never followed. *)
let read_order () =
  let left = constructor "Left" 0 and right = constructor "Right" 0 in
  let side = [ left; right ] in
  let leaf = constructor "Leaf" 1 and fork = constructor "Fork" 2 in
  let tree_variant = [ leaf; fork ] in
  let pair = constructor "Pair" 2 in
  let pairs = [ pair ] in
  let tree =
    select pairs
      [ pattern pairs pair [ Constructor (pattern side left []); Any ];
        pattern pairs pair
          [ Any; Pointer (pattern tree_variant leaf [ Any ]) ] ]
      ~default:true
  in
  let first_field =
    [ { Selection.holder = spelled "Pair"; field = 0;
        through_pointer = false } ]
  in
  check "Left selects the first label without following the pointer"
    (match tree.scrutinee with
     | [ { subtree = Node { position; branches }; _ } ] ->
         position = first_field
         && List.exists
              (fun (branch : Selection.branch) ->
                branch.constructors = [ left ]
                && branch.subtree = Leaf (Label 0))
              branches
     | _ -> false)

(* The bound (rule 10) *)

(* type bit = | X | Y; type word = | W(bit, ..., bit) of [fields] bits,
   with [extra] constructors of no field beside it that no label
   names. *)
let x = constructor "X" 0
let y = constructor "Y" 0
let bit = [ x; y ]

let word ~fields ~extra =
  let w = constructor "W" fields in
  (w, w :: List.init extra (fun i -> constructor (Printf.sprintf "V%d" i) 0))

let bits_x = Selection.Constructor (pattern bit x [])

(* One label of [fields] X: a node and a leaf of nothing per field, the
   root and the label's leaf. *)
let linear ~fields ~extra =
  let w, scrutinee = word ~fields ~extra in
  Selection.select scrutinee
    [ pattern scrutinee w (List.init fields (fun _ -> bits_x)) ]
    ~default:false

(* Label i names X at fields i and n + i. Each label's tree holds the
   tree of the labels after it twice: once where field i holds Y, once
   where field n + i does. *)
let doubling n =
  let w, scrutinee = word ~fields:(2 * n) ~extra:0 in
  let label i =
    pattern scrutinee w
      (List.init (2 * n) (fun field ->
           if field = i || field = n + i then bits_x else Selection.Any))
  in
  Selection.select scrutinee (List.init n label) ~default:false

let bound () =
  let at_bound = (Selection.max_size - 2) / 2 in
  (match linear ~fields:at_bound ~extra:0 with
   | Ok tree ->
       check "the linear tree holds exactly the bound"
         (tree_size tree = Selection.max_size)
   | Error Too_large -> check "a tree at the bound is accepted" false);
  check "a tree one over the bound is refused"
    (linear ~fields:at_bound ~extra:1 = Error Too_large);
  check "a doubling tree of 4 labels is accepted"
    (Result.is_ok (doubling 4));
  check "a doubling tree of 20 labels is refused"
    (doubling 20 = Error Too_large)

(* Property test *)

(* A field of a generated shape: of no variant, of the variant of that
   index, or a pointer to it. A field names only variants of a higher
   index, so every value is finite. *)
type kind = Plain | Variant of int | Points of int

type shape = (Ctype.constructor * kind list) array array

(* A value of variant [ty]: the index of its constructor and a value for
   each field of variant type. *)
type value = { ty : int; tag : int; fields : value option list }

let seed = 37
let random = Random.State.make [| seed |]
let below bound = Random.State.int random bound
let trials = 3000
let most_values = 2000

let generate_shape () : shape =
  let types = 1 + below 3 in
  Array.init types (fun ty ->
      Array.init (1 + below 3) (fun tag ->
          let kind () =
            if ty = types - 1 || below 3 = 0 then Plain
            else
              let target = ty + 1 + below (types - ty - 1) in
              if below 2 = 0 then Variant target else Points target
          in
          let kinds = List.init (below 3) (fun _ -> kind ()) in
          (constructor (Printf.sprintf "T%dC%d" ty tag) (List.length kinds),
           kinds)))

let variant (shape : shape) ty = Array.to_list (Array.map fst shape.(ty))

let rec count_values (shape : shape) ty =
  Array.fold_left
    (fun total (_, kinds) ->
      total
      + List.fold_left
          (fun product kind ->
            match kind with
            | Plain -> product
            | Variant target | Points target ->
                product * count_values shape target)
          1 kinds)
    0 shape.(ty)

let rec values (shape : shape) ty =
  List.concat
    (List.mapi
       (fun tag (_, kinds) ->
         List.map
           (fun fields -> { ty; tag; fields })
           (field_values shape kinds))
       (Array.to_list shape.(ty)))

and field_values shape = function
  | [] -> [ [] ]
  | kind :: rest ->
      let firsts =
        match kind with
        | Plain -> [ None ]
        | Variant target | Points target ->
            List.map Option.some (values shape target)
      in
      List.concat_map
        (fun first ->
          List.map (fun rest -> first :: rest) (field_values shape rest))
        firsts

let rec generate_pattern (shape : shape) ty =
  let tag = below (Array.length shape.(ty)) in
  let constructor, kinds = shape.(ty).(tag) in
  let sub_pattern = function
    | Plain -> Selection.Any
    | (Variant _ | Points _) when below 2 = 0 -> Any
    | Variant target -> Constructor (generate_pattern shape target)
    | Points target -> Pointer (generate_pattern shape target)
  in
  pattern (variant shape ty) constructor (List.map sub_pattern kinds)

let constructor_name (shape : shape) value =
  (fst shape.(value.ty).(value.tag)).constructor_name

(* The matcher of rule 6 written directly: the labels in source order,
   the tags of each in the order it writes them, each tag read at most
   once. Every match checks the tag of the scrutinee (4.5), so it reads
   that tag first even where no label asks for it. The result is what it
   selects and the positions it read, as constructor names and field
   indices, in order. *)
let reference shape labels ~default root =
  let read = ref [] in
  let tag_at key value =
    if not (List.mem key !read) then read := key :: !read;
    constructor_name shape value
  in
  let rec matches key (pattern : Selection.constructor_pattern) value =
    tag_at key value = pattern.constructor.constructor_name
    && fields_match key pattern 0 pattern.fields value.fields
  and fields_match key pattern field sub_patterns fields =
    match (sub_patterns, fields) with
    | [], _ -> true
    | Selection.Any :: sub_rest, _ :: rest ->
        fields_match key pattern (field + 1) sub_rest rest
    | (Constructor inner | Pointer inner) :: sub_rest, Some value :: rest ->
        let below = key @ [ (pattern.constructor.constructor_name, field) ] in
        matches below inner value
        && fields_match key pattern (field + 1) sub_rest rest
    | _ -> failwith "a pattern that does not fit its shape"
  in
  let rec first index = function
    | [] -> if default then Selection.Default else Nothing
    | label :: rest ->
        if matches [] label root then Label index else first (index + 1) rest
  in
  ignore (tag_at [] root);
  let selected = first 0 labels in
  (selected, List.rev !read)

let key (position : Selection.position) =
  List.map (fun (step : Selection.step) -> (step.holder, step.field)) position

let rec value_at value (position : Selection.position) =
  match (position, value) with
  | [], _ -> value
  | step :: rest, { fields; _ } -> (
      match List.nth fields step.field with
      | Some inner -> value_at inner rest
      | None -> failwith "a read of a field of no variant")

(* The leaf of [tree] that [root] reaches and the positions read on the
   way. *)
let evaluate shape (tree : Selection.t) root =
  let rec down read position branches =
    let name = constructor_name shape (value_at root position) in
    let read = key position :: read in
    match
      List.find_opt
        (fun (branch : Selection.branch) ->
          List.exists
            (fun (held : Ctype.constructor) -> held.constructor_name = name)
            branch.constructors)
        branches
    with
    | None -> failwith "a constructor with no branch"
    | Some { subtree = Leaf leaf; _ } -> (leaf, List.rev read)
    | Some { subtree = Node { position; branches }; _ } ->
        down read position branches
  in
  down [] [] tree.scrutinee

let rec value_matches shape (pattern : Selection.value) value =
  match (pattern, value) with
  | Unread, _ -> true
  | Holds { constructor; fields; _ }, _ ->
      constructor.constructor_name = constructor_name shape value
      && List.for_all2
           (fun sub field ->
             match field with
             | None -> sub = Selection.Unread
             | Some inner -> value_matches shape sub inner)
           fields value.fields

let one_trial shape =
  let labels = List.init (below 6) (fun _ -> generate_pattern shape 0) in
  let default = below 2 = 0 in
  let tree = select (variant shape 0) labels ~default in
  let all = values shape 0 in
  let leaves =
    List.map
      (fun root ->
        let expected = reference shape labels ~default root in
        let got = evaluate shape tree root in
        check "the tree selects what the in-order matcher does"
          (fst expected = fst got);
        check "the tree reads the tags that the in-order matcher does"
          (snd expected = snd got);
        fst got)
      all
  in
  let unselected =
    List.filter
      (fun index -> not (List.mem (Selection.Label index) leaves))
      (List.init (List.length labels) Fun.id)
  in
  check "the labels never selected are those no value selects"
    (Selection.never_selected tree = unselected);
  check "the default is never selected where no value takes it"
    (Selection.default_never_selected tree
    = (default && not (List.mem Selection.Default leaves)));
  let missing = missing_values tree in
  check "something is missing where some value is taken by nothing"
    ((missing <> []) = List.mem Selection.Nothing leaves);
  List.iter
    (fun pattern ->
      let matched = List.filter (value_matches shape pattern) all in
      check "a missing value stands for some value" (matched <> []);
      check "a missing value stands for values that nothing takes"
        (List.for_all
           (fun value -> fst (reference shape labels ~default value) = Nothing)
           matched))
    missing

let property () =
  let trial = ref 0 in
  while !trial < trials do
    let shape = generate_shape () in
    if count_values shape 0 <= most_values then begin
      incr trial;
      one_trial shape
    end
  done

let () =
  nested_results ();
  flat ();
  pointers ();
  read_order ();
  given_up_names ();
  bound ();
  property ();
  if !failures > 0 then exit 1
