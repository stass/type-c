(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

(* A magnitude is a list of limbs of [limb_bits] bits, least significant
   first, with no zero limb at the most significant end, so that zero is
   [] and every number has one representation. Thirty bits keep the
   product of two limbs plus two carries within OCaml's 63-bit int. *)
let limb_bits = 30
let limb_base = 1 lsl limb_bits
let limb_mask = limb_base - 1

(* Zero is never negative. *)
type t = { negative : bool; magnitude : int list }

let without_high_zeros limbs =
  let rec strip = function 0 :: rest -> strip rest | rest -> rest in
  List.rev (strip (List.rev limbs))

let make negative limbs =
  let magnitude = without_high_zeros limbs in
  { negative = negative && magnitude <> []; magnitude }

let zero = make false []
let one = make false [ 1 ]
let is_negative x = x.negative

(* Magnitudes *)

let compare_magnitudes a b =
  match Int.compare (List.length a) (List.length b) with
  | 0 -> List.compare Int.compare (List.rev a) (List.rev b)
  | order -> order

let rec add_magnitudes a b carry =
  match (a, b) with
  | [], [] -> if carry = 0 then [] else [ carry ]
  | limb :: rest, [] | [], limb :: rest ->
      let sum = limb + carry in
      (sum land limb_mask) :: add_magnitudes rest [] (sum lsr limb_bits)
  | x :: a, y :: b ->
      let sum = x + y + carry in
      (sum land limb_mask) :: add_magnitudes a b (sum lsr limb_bits)

(* [a - b] for [a >= b]. *)
let rec subtract_magnitudes a b borrow =
  match (a, b) with
  | [], [] -> []
  | [], _ :: _ -> invalid_arg "Exact_integer.subtract_magnitudes"
  | x :: a, b ->
      let y, b = match b with [] -> (0, []) | y :: b -> (y, b) in
      let difference = x - y - borrow in
      if difference < 0 then
        (difference + limb_base) :: subtract_magnitudes a b 1
      else difference :: subtract_magnitudes a b 0

let rec multiply_by_limb a limb carry =
  match a with
  | [] -> if carry = 0 then [] else [ carry ]
  | x :: a ->
      let product = (x * limb) + carry in
      (product land limb_mask)
      :: multiply_by_limb a limb (product lsr limb_bits)

let rec multiply_magnitudes a = function
  | [] -> []
  | limb :: b ->
      add_magnitudes (multiply_by_limb a limb 0)
        (0 :: multiply_magnitudes a b)
        0

let bits_of_limb limb =
  let rec count limb bits =
    if limb = 0 then bits else count (limb lsr 1) (bits + 1)
  in
  count limb 0

let magnitude_bit_length magnitude =
  match List.rev magnitude with
  | [] -> 0
  | top :: rest -> (List.length rest * limb_bits) + bits_of_limb top

let magnitude_bit magnitude index =
  (List.nth magnitude (index / limb_bits) lsr (index mod limb_bits)) land 1

(* Long division one bit at a time, from the most significant bit of [a]:
   at most 256 steps for the operands of a constant expression. *)
let divide_magnitudes a b =
  let quotient = ref [] and remainder = ref [] in
  for index = magnitude_bit_length a - 1 downto 0 do
    let doubled = add_magnitudes !remainder !remainder 0 in
    let next_bit = [ magnitude_bit a index ] in
    remainder := without_high_zeros (add_magnitudes doubled next_bit 0);
    let fits = compare_magnitudes !remainder b >= 0 in
    if fits then
      remainder := without_high_zeros (subtract_magnitudes !remainder b 0);
    quotient :=
      without_high_zeros
        (add_magnitudes
           (add_magnitudes !quotient !quotient 0)
           [ (if fits then 1 else 0) ]
           0)
  done;
  (!quotient, !remainder)

(* Signed operations *)

let neg x = make (not x.negative) x.magnitude

let add x y =
  if x.negative = y.negative then
    make x.negative (add_magnitudes x.magnitude y.magnitude 0)
  else if compare_magnitudes x.magnitude y.magnitude >= 0 then
    make x.negative (subtract_magnitudes x.magnitude y.magnitude 0)
  else make y.negative (subtract_magnitudes y.magnitude x.magnitude 0)

let sub x y = add x (neg y)

let mul x y =
  make (x.negative <> y.negative) (multiply_magnitudes x.magnitude y.magnitude)

let compare x y =
  match (x.negative, y.negative) with
  | false, true -> 1
  | true, false -> -1
  | false, false -> compare_magnitudes x.magnitude y.magnitude
  | true, true -> compare_magnitudes y.magnitude x.magnitude

let equal x y = compare x y = 0

let div x y =
  if y.magnitude = [] then raise Division_by_zero;
  let quotient, _ = divide_magnitudes x.magnitude y.magnitude in
  make (x.negative <> y.negative) quotient

let rem x y =
  if y.magnitude = [] then raise Division_by_zero;
  let _, remainder = divide_magnitudes x.magnitude y.magnitude in
  make x.negative remainder

let power_of_two n =
  make false
    (List.init (n / limb_bits) (fun _ -> 0) @ [ 1 lsl (n mod limb_bits) ])

let floor_shift_right x n =
  let divisor = power_of_two n in
  let quotient = div x divisor in
  if x.negative && not (equal (mul quotient divisor) x) then sub quotient one
  else quotient

let modulo_power_of_two x n =
  let modulus = power_of_two n in
  let remainder = rem x modulus in
  if remainder.negative then add remainder modulus else remainder

let rec zip_limbs operation a b =
  match (a, b) with
  | [], [] -> []
  | x :: a, [] -> operation x 0 :: zip_limbs operation a []
  | [], y :: b -> operation 0 y :: zip_limbs operation [] b
  | x :: a, y :: b -> operation x y :: zip_limbs operation a b

let bitwise operation x y =
  if x.negative || y.negative then invalid_arg "Exact_integer.bitwise";
  make false (zip_limbs operation x.magnitude y.magnitude)

let logand = bitwise ( land )
let logor = bitwise ( lor )
let logxor = bitwise ( lxor )
let bit_length x = magnitude_bit_length x.magnitude

(* Conversions *)

let rec limbs_of_natural n =
  if n = 0 then [] else (n land limb_mask) :: limbs_of_natural (n lsr limb_bits)

(* [-(n + 1)] is the magnitude of a negative [n] less one, which never
   overflows, even for [min_int]. *)
let of_int n =
  if n >= 0 then make false (limbs_of_natural n)
  else neg (add (make false (limbs_of_natural (-(n + 1)))) one)

let int_bits = Sys.int_size - 1

let to_int x =
  let value () =
    List.fold_right
      (fun limb value -> (value lsl limb_bits) lor limb)
      x.magnitude 0
  in
  if bit_length x <= int_bits then
    Some (if x.negative then -value () else value ())
  else if equal x (of_int min_int) then Some min_int
  else None

let digit_value c =
  match c with
  | '0' .. '9' -> Char.code c - Char.code '0'
  | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
  | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
  | _ -> invalid_arg "Exact_integer.of_digits"

let of_digits ~base digits =
  let magnitude =
    String.fold_left
      (fun magnitude c ->
        let digit = digit_value c in
        if digit >= base then invalid_arg "Exact_integer.of_digits";
        add_magnitudes (multiply_by_limb magnitude base 0) [ digit ] 0)
      [] digits
  in
  make false magnitude

(* The quotient and remainder of a magnitude divided by a small [divisor],
   from the most significant limb down. *)
let divide_by_small magnitude divisor =
  let step limb (quotient, remainder) =
    let dividend = (remainder lsl limb_bits) lor limb in
    ((dividend / divisor) :: quotient, dividend mod divisor)
  in
  let quotient, remainder = List.fold_right step magnitude ([], 0) in
  (without_high_zeros quotient, remainder)

let to_string x =
  let rec digits magnitude written =
    if magnitude = [] then written
    else
      let quotient, digit = divide_by_small magnitude 10 in
      digits quotient (string_of_int digit :: written)
  in
  match digits x.magnitude [] with
  | [] -> "0"
  | written -> (if x.negative then "-" else "") ^ String.concat "" written
