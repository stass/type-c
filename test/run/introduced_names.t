SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

No local that lowering introduces hides another (design 13.5), so a
program whose constructs nest compiles under -Wshadow -Werror on each
backend at -O0 and -O2 and prints the same lines. The program nests a
match in an arm of a match, each holding a copy of its operand; a match
with nested patterns in an arm of another, with their pointer locals; a
test in a test, in the else of a test and in the statement of a while
test; a match in a statement expression of the scrutinee of another;
the temporaries of try expressions in nested blocks, under a
conditional operator and in a braced list that converts; a deferred
match that each return in an arm of another match repeats; a return in
a statement expression of a return, each holding its value across a
cleanup; and slice tests in nested loops.

  $ . ./backends.sh
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Wshadow -Werror"
  $ cat > nested.tc <<'EOF'
  > #include <stdio.h>
  > type res = | Good(int value) | Bad(int error);
  > type expr = | Num(int value) | Add(const expr *l, const expr *r);
  > static int notes;
  > static void note(int n) { notes += n; }
  > static res make(int v) { return v > 0 ? Good(v) : Bad(v); }
  > static result(int, int) parse(int v) {
  >   if (v < 0)
  >     return Err(-v);
  >   return Ok(v);
  > }
  > static int shown(result(int, int) r) {
  >   match (r) {
  >   case Ok(v):
  >     return v;
  >   case Err(e):
  >     return -100 - e;
  >   }
  > }
  > static int matches(int a, int b) {
  >   match (make(a)) {
  >   case Good(x):
  >     match (make(b)) {
  >     case Good(y):
  >       return x * 10 + y;
  >     case Bad(e):
  >       return x * 10 - e;
  >     }
  >   case Bad(e):
  >     return e;
  >   }
  > }
  > static int scrutinees(int a) {
  >   match (__extension__({
  >     int t = a;
  >     match (make(t)) {
  >     case Good(x):
  >       t = x * 2;
  >       break;
  >     default:
  >       break;
  >     }
  >     make(t);
  >   })) {
  >   case Good(y):
  >     return y;
  >   default:
  >     return 0;
  >   }
  > }
  > static int sums(const expr *a, const expr *b) {
  >   match (*a) {
  >   case Add(*Num(x), *Add(*Num(y), _)):
  >     match (*b) {
  >     case Add(*Num(z), *Add(*Num(w), _)):
  >       return x + y + z + w;
  >     default:
  >       return x + y;
  >     }
  >   default:
  >     return 0;
  >   }
  > }
  > static int tests(res r, const expr *e) {
  >   if (case Good(x) = r) {
  >     if (case Good(y) = make(x - 1))
  >       return y;
  >     if (case Add(*Num(p), *Add(*Num(q), _)) = *e) {
  >       if (case Add(*Num(s), *Add(*Num(t), _)) = *e)
  >         return p + q + s + t + x;
  >     }
  >     return -x;
  >   } else if (case Bad(y) = r)
  >     return y * 100;
  >   return 0;
  > }
  > static int loops(int n) {
  >   int count = 0;
  >   while (case Good(x) = make(n)) {
  >     int m = x;
  >     n--;
  >     while (case Good(y) = make(m)) {
  >       m -= 2;
  >       count += y;
  >     }
  >   }
  >   return count;
  > }
  > static result(int, int) tries(int v) {
  >   int a = try parse(v);
  >   {
  >     int b = a > 1 ? try parse(a - 2) : 0;
  >     {
  >       long c[2] = { try parse(b), try parse(a) };
  >       if (c[0] > 0) {
  >         int d = try parse((int)c[1] - 10);
  >         return Ok(d);
  >       }
  >       return Ok(a + b + (int)c[0] + (int)c[1]);
  >     }
  >   }
  > }
  > static int defers(res r) {
  >   defer note(1);
  >   {
  >     defer match (r) {
  >     case Good(x):
  >       note(x * 10);
  >       break;
  >     default:
  >       break;
  >     }
  >     {
  >       defer note(100);
  >       match (make(notes)) {
  >       case Good(y):
  >         return y;
  >       default:
  >         break;
  >       }
  >     }
  >     return -1;
  >   }
  > }
  > static int returns(int c) {
  >   defer note(1000);
  >   return __extension__({
  >     int v = c;
  >     if (v > 5)
  >       return v;
  >     v + 1;
  >   });
  > }
  > static int slices(slice(int) s) {
  >   int sum = 0;
  >   for (size_t i = 0; i < s.len; i++) {
  >     sum += s[i];
  >     for (size_t j = i; j < s.len; j++)
  >       sum += slice_sub(s, j, s.len)[0];
  >   }
  >   return sum;
  > }
  > int main(void) {
  >   expr n1 = Num(1), n2 = Num(2);
  >   expr a1 = Add(&n2, &n1), a2 = Add(&n1, &a1);
  >   int numbers[3] = { 1, 2, 3 };
  >   int first, second;
  >   printf("matches %d %d %d\n", matches(1, 2), matches(1, -3),
  >          matches(-4, 1));
  >   printf("scrutinees %d %d\n", scrutinees(3), scrutinees(-1));
  >   printf("sums %d %d %d\n", sums(&a2, &a2), sums(&a2, &a1),
  >          sums(&a1, &a2));
  >   printf("tests %d %d %d %d\n", tests(Good(3), &a2),
  >          tests(Good(1), &a2), tests(Good(1), &a1), tests(Bad(5), &a1));
  >   printf("loops %d\n", loops(3));
  >   printf("tries %d %d %d %d\n", shown(tries(5)), shown(tries(1)),
  >          shown(tries(-2)), shown(tries(2)));
  >   first = defers(Good(2));
  >   printf("defers %d %d\n", first, notes);
  >   second = defers(Good(2));
  >   printf("defers %d %d\n", second, notes);
  >   first = returns(7);
  >   second = returns(1);
  >   printf("returns %d %d %d\n", first, second, notes);
  >   printf("slices %d\n", slices(slice_from_array(numbers)));
  >   return 0;
  > }
  > EOF

Each backend compiles the program without a warning, and each build
prints the same lines.

  $ for cc in "$clang" "$gcc"; do
  >   for opt in -O0 -O2; do
  >     typec --cc="$cc" $opt $flags -o nested nested.tc || exit 1
  >     ./nested > "nested$opt.out"
  >   done
  >   cmp nested-O0.out nested-O2.out || echo "$cc differs"
  >   cat nested-O0.out
  > done
  matches 12 13 -4
  scrutinees 6 0
  sums 6 3 0
  tests 2 7 -1 500
  loops 7
  tries -105 2 -102 4
  defers -1 121
  defers 121 242
  returns 7 2 2242
  slices 20
  matches 12 13 -4
  scrutinees 6 0
  sums 6 3 0
  tests 2 7 -1 500
  loops 7
  tries -105 2 -102 4
  defers -1 121
  defers 121 242
  returns 7 2 2242
  slices 20
