SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The lowered forms of slices (design 8, 13.5) run on each backend at
-O0 and -O2 under the strictest warnings, with and without
AddressSanitizer and UndefinedBehaviorSanitizer: an index read and
written, `slice_sub`, `slice_from_array` of a static array, a local one
and a compound literal, `slice_unchecked`, the conversion to const
elements at an initialiser, an assignment, an argument, each branch of
`?:`, the right operand of a comma and the value of a `try`, string
literals as `str`, and an index and a `slice_sub` that C does not
evaluate. A counter shows that
the test of an index, a `slice_sub` and a conversion evaluates each
operand once. Each index and `slice_sub` out of range traps (design
10.5): the process ends by SIGILL or SIGTRAP, whichever the target's
trap instruction raises.

  $ . ./backends.sh
  $ flags="-std=c11 -pedantic-errors -Wall -Wextra -Wshadow -Wconversion"
  $ flags="$flags -Wsign-conversion -Werror"
  $ sanitize="-fsanitize=address,undefined -fno-sanitize-recover=all"
  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > #include <string.h>
  > static int calls;
  > static int numbers[5] = { 10, 20, 30, 40, 50 };
  > static slice(int) all = slice_from_array(numbers);
  > static str greeting = "hello";
  > static slice(int) counted(slice(int) s) {
  >   calls++;
  >   return s;
  > }
  > static size_t at(size_t i) {
  >   calls++;
  >   return i;
  > }
  > static int sum(slice(const int) s) {
  >   int total = 0;
  >   for (size_t i = 0; i < s.len; i++)
  >     total += s[i];
  >   return total;
  > }
  > static size_t length(str s) { return s.len; }
  > static char no[] = "no";
  > static str word(int which) { return which ? "yes" : slice_from_array(no); }
  > static void index_once(void) {
  >   calls = 0;
  >   int x = counted(all)[at(2)];
  >   counted(all)[at(4)] = 55;
  >   size_t i = 0;
  >   int y = all[i++];
  >   printf("index: %d %d %d %zu calls %d\n", x, all[4], y, i, calls);
  > }
  > static void sub_once(void) {
  >   calls = 0;
  >   slice(int) middle = slice_sub(counted(all), at(1), at(4));
  >   slice(int) none = slice_sub(all, all.len, all.len);
  >   printf("sub: %zu %d %d %zu calls %d\n", middle.len, middle[0], middle[2],
  >          none.len, calls);
  > }
  > static void arrays(void) {
  >   char text[] = "abc";
  >   str t = slice_from_array(text);
  >   int local[3] = { 1, 2, 3 };
  >   int *p = local;
  >   slice(int) u = slice_unchecked(p + 1, 2);
  >   printf("arrays: %zu %d %d %zu %zu\n", t.len, sum(slice_from_array(local)),
  >          sum(u), slice_from_array((int[]){ 4, 5 }).len,
  >          sizeof(all[100]) + sizeof(slice_sub(all, 9, 1)));
  > }
  > static void conversions(int k) {
  >   slice(int) m = all;
  >   slice(const int) c = m;
  >   slice(const int) d;
  >   d = slice_sub(m, 1, 3);
  >   slice(const int) e = k ? m : c;
  >   calls = 0;
  >   slice(const int) f = (calls++, counted(m));
  >   printf("const: %d %d %d %d %zu calls %d\n", sum(m), c[0], d[1], e[4],
  >          f.len, calls);
  > }
  > static void strings(int k) {
  >   str s = (k ? "ab" : greeting);
  >   printf("str: %zu %zu %zu %zu %.*s %.*s\n", greeting.len, length("four"),
  >          length(word(1)), word(0).len, (int)s.len, s.data,
  >          (int)greeting.len, greeting.data);
  > }
  > static result(slice(int), int) whole(int k) {
  >   if (k)
  >     return Err(k);
  >   return Ok(all);
  > }
  > static result(size_t, int) tried(int k) {
  >   slice(const int) s = try whole(k);
  >   slice(const int) t;
  >   t = try whole(k);
  >   return Ok(s.len + t.len);
  > }
  > static void tries(int k) {
  >   match (tried(k)) {
  >   case Ok(n):
  >     printf("try: %zu\n", n);
  >     break;
  >   case Err(e):
  >     printf("try: error %d\n", e);
  >     break;
  >   }
  > }
  > static void trap(const char *how) {
  >   size_t n = 5, lo = 3, hi = 2;
  >   int minus = -1;
  >   if (strcmp(how, "index") == 0)
  >     printf("%d\n", all[n]);
  >   if (strcmp(how, "negative") == 0)
  >     printf("%d\n", all[minus]);
  >   if (strcmp(how, "order") == 0)
  >     printf("%zu\n", slice_sub(all, lo, hi).len);
  >   if (strcmp(how, "end") == 0)
  >     printf("%zu\n", slice_sub(all, 0, n + 1).len);
  >   if (strcmp(how, "str") == 0)
  >     printf("%c\n", greeting[n]);
  > }
  > int main(int argc, char **argv) {
  >   if (argc > 1) {
  >     trap(argv[1]);
  >     return 0;
  >   }
  >   index_once();
  >   sub_once();
  >   arrays();
  >   conversions(argc);
  >   strings(argc);
  >   tries(0);
  >   tries(3);
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   for build in "-O0 $sanitize" "-O2 $sanitize" "-O2"; do
  >     typec --cc=$cc $flags $build -o program program.tc && ./program &&
  >     for how in index negative order end str; do
  >       sh -c "ulimit -c 0; ./program $how; exit \$?" 2>/dev/null
  >       case $? in
  >       132 | 133) echo "$how trapped" ;;
  >       *) echo "$how did not trap" ;;
  >       esac
  >     done
  >   done
  > done
  index: 30 55 10 1 calls 4
  sub: 3 20 40 0 calls 3
  arrays: 4 6 5 2 20
  const: 155 10 30 55 5 calls 2
  str: 5 4 3 3 ab hello
  try: 10
  try: error 3
  index trapped
  negative trapped
  order trapped
  end trapped
  str trapped
  index: 30 55 10 1 calls 4
  sub: 3 20 40 0 calls 3
  arrays: 4 6 5 2 20
  const: 155 10 30 55 5 calls 2
  str: 5 4 3 3 ab hello
  try: 10
  try: error 3
  index trapped
  negative trapped
  order trapped
  end trapped
  str trapped
  index: 30 55 10 1 calls 4
  sub: 3 20 40 0 calls 3
  arrays: 4 6 5 2 20
  const: 155 10 30 55 5 calls 2
  str: 5 4 3 3 ab hello
  try: 10
  try: error 3
  index trapped
  negative trapped
  order trapped
  end trapped
  str trapped
  index: 30 55 10 1 calls 4
  sub: 3 20 40 0 calls 3
  arrays: 4 6 5 2 20
  const: 155 10 30 55 5 calls 2
  str: 5 4 3 3 ab hello
  try: 10
  try: error 3
  index trapped
  negative trapped
  order trapped
  end trapped
  str trapped
  index: 30 55 10 1 calls 4
  sub: 3 20 40 0 calls 3
  arrays: 4 6 5 2 20
  const: 155 10 30 55 5 calls 2
  str: 5 4 3 3 ab hello
  try: 10
  try: error 3
  index trapped
  negative trapped
  order trapped
  end trapped
  str trapped
  index: 30 55 10 1 calls 4
  sub: 3 20 40 0 calls 3
  arrays: 4 6 5 2 20
  const: 155 10 30 55 5 calls 2
  str: 5 4 3 3 ab hello
  try: 10
  try: error 3
  index trapped
  negative trapped
  order trapped
  end trapped
  str trapped
