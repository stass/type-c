(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* The selection tree of design 4.7 rule 6: label sets written as data,
   the bound of rule 10, and a property test against a matcher that
   tries the labels in source order. *)

open Typec_syntax
open Typec_sema
open Typec_test_support

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

(* The index of [constructor] in [variant], which holds it. *)
let index_in variant constructor =
  match List.find_index (fun held -> held == constructor) variant with
  | Some index -> index
  | None -> failwith "a constructor of another variant"

let pattern variant constructor fields =
  { Selection.variant = Array.of_list variant;
    index = index_in variant constructor;
    fields }

let select scrutinee labels ~default =
  match Selection.select (Array.of_list scrutinee) labels ~default with
  | Ok tree -> tree
  | Error (Too_many_steps | Too_deep) ->
      failwith "a small tree refused as too large"

(* The missing values named, where a constructor of the scrutinee stands
   for the value that holds it with every field unread. *)
let missing_values tree =
  match Selection.missing tree with
  | Nothing_missing -> []
  | Values { named; _ } -> named
  | Scrutinee_constructors { named = constructors; _ } ->
      List.map
        (fun (constructor : Ctype.constructor) ->
          Selection.Holds
            { constructor;
              through_pointer = false;
              read = []
            })
        constructors

let spelling = Selection.spelling ~most:max_int

let missing tree = List.map spelling (missing_values tree)

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
     | Scrutinee_constructors { named = [ first; second ]; more = 0 } ->
         first == a && second == c
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
   both missing at the second. The values of every leaf of nothing
   follow in the tree's order. *)
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
  check "P(X, Y) and P(X, Z) share the first missing leaf"
    (missing tree
    = [ "P(X, Y)"; "P(X, Z)"; "P(Y, X)"; "P(Y, Y)"; "P(Z, _)" ])

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

(* The bounds (rule 10) *)

(* A variant of [labels] + [extra] constructors of no field and one
   label for each of the first [labels]. *)
let flat_match ~labels ~extra =
  let scrutinee =
    Array.init (labels + extra) (fun i ->
        constructor (Printf.sprintf "K%d" i) 0)
  in
  Selection.select scrutinee
    (List.init labels (fun index ->
         { Selection.variant = scrutinee; index; fields = [] }))
    ~default:false

(* type x = | K0 | ...; type w = | W(x, x) | E0 | ... of [extra] E: the
   [asking] labels W(Ki, _), one for each constructor of x, then the
   [trailing] labels W(_, K0). The node at the first field of W sorts
   every label, and each of its branches looks at its own label and at
   every trailing label, which asks for the second field first. *)
let wide_node ~asking ~trailing ~extra =
  let ks =
    Array.init asking (fun i -> constructor (Printf.sprintf "K%d" i) 0)
  in
  let w = constructor "W" 2 in
  let ws =
    Array.append [| w |]
      (Array.init extra (fun i -> constructor (Printf.sprintf "E%d" i) 0))
  in
  let names_at field index =
    { Selection.variant = ws;
      index = 0;
      fields =
        List.init 2 (fun at ->
            if at = field then
              Selection.Constructor { variant = ks; index; fields = [] }
            else Any) }
  in
  Selection.select ws
    (List.init asking (names_at 0) @ List.init trailing (fun _ -> names_at 1 0))
    ~default:false

(* The steps of [wide_node]. The root sorts every label and every
   constructor, and its branch of W looks twice at each label, past the
   root's tag to its next test; the branch of the E constructors keeps
   no label. The node at the first field sorts every label and the
   asking constructors; the branch of each looks twice at its own label
   and once at each trailing label. *)
let wide_steps ~asking ~trailing ~extra =
  let labels = asking + trailing in
  let root = labels + 1 + extra + (2 * labels) in
  let first_field = labels + asking + (asking * (2 + trailing)) in
  root + first_field

(* type bit = | X | Y; type chain = | A(chain *next) | W(bit, ..., bit) of
   2n + 1 bits. *)
let x = constructor "X" 0
let y = constructor "Y" 0
let bit = [ x; y ]
let bits_x = Selection.Constructor (pattern bit x [])

(* Label i < n names X at fields i and n + i of a W [depth] pointers
   below the scrutinee. Each such label's tree holds the tree of the
   labels after it twice: once where field i holds Y, once where field
   n + i does. The [trailing] labels after them name X at field 2n
   only, which no label before them reads, so every node of that tree
   keeps them possible. *)
let doubling ?(depth = 0) n ~trailing =
  let fields = (2 * n) + 1 in
  let a = constructor "A" 1 and w = constructor "W" fields in
  let chain = [ a; w ] in
  let rec label depth names_x =
    if depth > 0 then
      pattern chain a [ Selection.Pointer (label (depth - 1) names_x) ]
    else
      pattern chain w
        (List.init fields (fun field ->
             if names_x field then bits_x else Selection.Any))
  in
  let doubling_label i =
    label depth (fun field -> field = i || field = n + i)
  in
  let trailing_label _ = label depth (fun field -> field = 2 * n) in
  Selection.select (Array.of_list chain)
    (List.init n doubling_label @ List.init trailing trailing_label)
    ~default:false

let bound () =
  (match flat_match ~labels:3 ~extra:1 with
   | Ok tree ->
       check "a flat match has a leaf per label and one for the others"
         (tree_size tree = 3 + 2)
   | Error _ -> check "a small flat match is accepted" false);
  let asking = 2000 and trailing = 2000 in
  let extra = Selection.max_steps - wide_steps ~asking ~trailing ~extra:0 in
  check "a match of exactly the bound's steps is accepted"
    (Result.is_ok (wide_node ~asking ~trailing ~extra));
  check "a match one step over the bound is refused"
    (wide_node ~asking ~trailing ~extra:(extra + 1) = Error Too_many_steps);
  check "a doubling tree of 4 labels is accepted"
    (Result.is_ok (doubling 4 ~trailing:0));
  check "a doubling tree of 20 labels is refused"
    (doubling 20 ~trailing:0 = Error Too_many_steps)

(* The labels that a tree keeps possible cost steps at each of its
   nodes, though the tree stays small: the bound refuses them in time
   that does not grow with their number. *)
let probe_labels = 13
let probe_trailing = 1000

let kept_possible () =
  check "the doubling tree of the probe alone is accepted"
    (Result.is_ok (doubling probe_labels ~trailing:1));
  let all_refused = ref true in
  let refuse trailing =
    if doubling probe_labels ~trailing <> Error Selection.Too_many_steps then
      all_refused := false
  in
  let times = Timing.outgrows ~degree:0 ~small:probe_trailing refuse in
  check "a doubling tree that keeps many labels possible is refused"
    !all_refused;
  match times with
  | None -> ()
  | Some times ->
      check ("the refusal does not grow with the labels kept possible: "
             ^ times) false

(* A step compares positions at a cost that does not grow with their
   depth: the probe's labels, as many fields in all at each depth, are
   refused in time that does not grow with the depth. *)
let probe_depth = 16

let deep_positions () =
  let all_refused = ref true in
  let refuse depth =
    let trailing = probe_trailing * probe_depth / depth in
    if doubling ~depth probe_labels ~trailing <> Error Selection.Too_many_steps
    then all_refused := false
  in
  let times = Timing.outgrows ~degree:0 ~small:probe_depth refuse in
  check "a deep doubling tree that keeps many labels possible is refused"
    !all_refused;
  match times with
  | None -> ()
  | Some times ->
      check ("the refusal does not grow with the depth of the labels: "
             ^ times) false

(* One label W(X, ..., X) of [fields] fields makes a path of a node per
   field below the root's. *)
let x_path fields =
  let w = constructor "W" fields in
  Selection.select [| w |]
    [ pattern [ w ] w (List.init fields (fun _ -> bits_x)) ]
    ~default:true

let depth () =
  check "a tree as deep as the bound is accepted"
    (Result.is_ok (x_path (Selection.max_depth - 1)));
  check "a tree one node deeper than the bound is refused"
    (x_path Selection.max_depth = Error Too_deep)

(* W(K0, _, ..., _), of [size] fields over [size] constructors, misses
   a value for each other constructor. *)
let wide_miss size =
  let ks = List.init size (fun i -> constructor (Printf.sprintf "K%d" i) 0) in
  let w = constructor "W" size in
  let first = Selection.Constructor (pattern ks (List.hd ks) []) in
  let label =
    pattern [ w ] w (first :: List.init (size - 1) (fun _ -> Selection.Any))
  in
  select [ w ] [ label ] ~default:false

(* The spelling of W(Ki, _, ..., _) of [size] fields. *)
let wide_value size i =
  let unread = String.concat "" (List.init (size - 1) (fun _ -> ", _")) in
  Printf.sprintf "W(K%d%s)" i unread

let small_miss = 2000

(* The values missing are named in time linear in the size of the tree,
   the first of them only. *)
let missing_in_linear_time () =
  let name size = ignore (missing (wide_miss size)) in
  (match Timing.outgrows ~degree:1 ~small:small_miss name with
   | None -> ()
   | Some times ->
       check ("what a match misses is named in linear time: " ^ times) false);
  check "the first values missing are named and the others counted"
    (let first = List.init Selection.max_named (fun i -> i + 1) in
     match Selection.missing (wide_miss small_miss) with
     | Values { named; more } ->
         List.map spelling named
         = List.map (wide_value small_miss) first
         && more = small_miss - 1 - Selection.max_named
     | Nothing_missing | Scrutinee_constructors _ -> false);
  check "a few values missing are each named"
    (match Selection.missing (wide_miss 4) with
     | Values { named; more = 0 } ->
         List.map spelling named
         = [ wide_value 4 1; wide_value 4 2; wide_value 4 3 ]
     | Nothing_missing | Scrutinee_constructors _ | Values _ -> false)

(* type u = | A | Big0(F fields) | Big1 | ... | Big7; type s = S(u, ...)
   of [chain_fields] fields: label k names A at field k. Each field
   holds Big0 to Big7 where no label names a constructor, so the one
   leaf of nothing is [chain_fields] nodes deep and holds eight values,
   each with Big0 at every field above its own. *)
let chain_fields = 20

let shared_chain big_fields =
  let a = constructor "A" 0 and big0 = constructor "Big0" big_fields in
  let u =
    a :: big0
    :: List.init 7 (fun i -> constructor (Printf.sprintf "Big%d" (i + 1)) 0)
  in
  let s = constructor "S" chain_fields in
  let names_a k =
    pattern [ s ] s
      (List.init chain_fields (fun field ->
           if field = k then Selection.Constructor (pattern u a [])
           else Any))
  in
  select [ s ] (List.init chain_fields names_a) ~default:false

let declared name =
  match Spelling.type_name ~at_file_scope:true name with
  | Ok name -> Ctype.Declared name
  | Error _ -> failwith (name ^ " is no type name")

(* The error names values whose constructors have many fields in time
   that does not grow with the fields, however deep the leaf. *)
let small_big = 20_000

let missing_of_many_fields () =
  let trees = Hashtbl.create 2 in
  let tree big_fields =
    match Hashtbl.find_opt trees big_fields with
    | Some tree -> tree
    | None ->
        let tree = shared_chain big_fields in
        Hashtbl.add trees big_fields tree;
        tree
  in
  let word big_fields =
    let missing = Selection.missing (tree big_fields) in
    ignore (Expressions.missing_text (declared "s") missing)
  in
  ignore (tree small_big);
  ignore (tree (4 * small_big));
  (match Timing.outgrows ~degree:0 ~small:small_big word with
   | None -> ()
   | Some times ->
       check ("values of many fields are named in bounded time: " ^ times)
         false);
  check "the eight values of the deep leaf are named, cut short"
    (match Selection.missing (tree small_big) with
     | Values { named; more = 0 } ->
         List.length named = 8
         && List.for_all
              (fun value ->
                String.length (Selection.spelling ~most:64 value) = 65)
              named
     | Nothing_missing | Scrutinee_constructors _ | Values _ -> false)

(* The values missing at several leaves, in the tree's order: in
   P(X, X), P(Y, Y), P(Z, Z) over three constructors of no field, each
   leaf of nothing holds the other two constructors of the second
   field. *)
let missing_in_tree_order () =
  let x = constructor "X" 0 and y = constructor "Y" 0 in
  let z = constructor "Z" 0 in
  let xyz = [ x; y; z ] in
  let p = constructor "P" 2 in
  let label held =
    pattern [ p ] p
      [ Constructor (pattern xyz held []); Constructor (pattern xyz held []) ]
  in
  let tree = select [ p ] [ label x; label y; label z ] ~default:false in
  check "the missing values of every leaf are named in the tree's order"
    (missing tree
    = [ "P(X, Y)"; "P(X, Z)"; "P(Y, X)"; "P(Y, Z)"; "P(Z, X)"; "P(Z, Y)" ])

(* The error of 4.2 rule 1, worded from what is missing. *)
let wording () =
  let text missing = Expressions.missing_text (declared "e") missing in
  let value constructor =
    Selection.Holds { constructor; through_pointer = false; read = [] }
  in
  check "nothing missing has no error"
    (text Nothing_missing = None);
  check "one constructor missing"
    (text (Scrutinee_constructors { named = [ a ]; more = 0 })
    = Some "the match does not cover the constructor 'A' of the variant 'e'");
  check "constructors missing beyond those named"
    (text (Scrutinee_constructors { named = [ a; c ]; more = 3 })
    = Some
        "the match does not cover the constructors 'A', 'C' and 3 more of \
         the variant 'e'");
  check "two values missing"
    (text (Values { named = [ value a; value c ]; more = 0 })
    = Some "the match does not cover the values 'A' and 'C(_)'");
  check "one value named and one more"
    (text (Values { named = [ value a ]; more = 1 })
    = Some "the match does not cover the values 'A' and 1 more")

(* A match without nested patterns of [labels] labels over as many
   constructors takes steps linear in their number. *)
let large_flat = 20_000

let flat_in_linear_time () =
  check "a flat match of 20000 labels is accepted"
    (Result.is_ok (flat_match ~labels:large_flat ~extra:0));
  let build labels = ignore (flat_match ~labels ~extra:0) in
  match Timing.outgrows ~degree:1 ~small:(large_flat / 4) build with
  | None -> ()
  | Some times ->
      check ("a flat match is built in linear time: " ^ times) false

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
  let named (pattern : Selection.constructor_pattern) =
    pattern.variant.(pattern.index).constructor_name
  in
  let rec matches key (pattern : Selection.constructor_pattern) value =
    tag_at key value = named pattern
    && fields_match key pattern 0 pattern.fields value.fields
  and fields_match key pattern field sub_patterns fields =
    match (sub_patterns, fields) with
    | [], _ -> true
    | Selection.Any :: sub_rest, _ :: rest ->
        fields_match key pattern (field + 1) sub_rest rest
    | (Constructor inner | Pointer inner) :: sub_rest, Some value :: rest ->
        let below = key @ [ (named pattern, field) ] in
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

(* The constructor and field of each step of [position], from the
   scrutinee down, as [reference] names a position. *)
let key (position : Selection.position) =
  List.rev_map (fun (step : Selection.step) -> (step.holder, step.field))
    position

let value_at root (position : Selection.position) =
  let down value (step : Selection.step) =
    match List.nth value.fields step.field with
    | Some inner -> inner
    | None -> failwith "a read of a field of no variant"
  in
  List.fold_left down root (List.rev position)

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
  | Holds { constructor; read; _ }, _ ->
      let field_matches (index, sub) =
        match List.nth value.fields index with
        | None -> false
        | Some inner -> value_matches shape sub inner
      in
      constructor.constructor_name = constructor_name shape value
      && List.map fst read = List.sort_uniq compare (List.map fst read)
      && List.for_all field_matches read

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
  kept_possible ();
  deep_positions ();
  depth ();
  missing_in_linear_time ();
  missing_of_many_fields ();
  missing_in_tree_order ();
  wording ();
  flat_in_linear_time ();
  property ();
  if !failures > 0 then exit 1
