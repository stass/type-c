SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The instances of generic functions (design 7.3, 10.3), built and run on
each backend with -Wall -Wextra -pedantic-errors -Werror: deduced calls
over several types, a call through a comparator, generic functions that
call each other, instances that need instances of other generic
functions and of a generic type, and an explicit instance used as a
function pointer.

  $ . ./backends.sh

  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > #include <stdlib.h>
  > type vector(T) = struct { T *data; unsigned long length, capacity; };
  > generic(T) const T *max(const T *a, const T *b,
  >                         int (*less)(const T *, const T *)) {
  >   return less(a, b) ? b : a;
  > }
  > generic(T) void swap(T *a, T *b) { T t = *a; *a = *b; *b = t; }
  > generic(T) int vector_push(vector(T) *v, T value) {
  >   if (v->length == v->capacity) {
  >     unsigned long capacity = v->capacity ? 2 * v->capacity : 4;
  >     T *data = realloc(v->data, capacity * sizeof *data);
  >     if (!data) return 0;
  >     v->data = data;
  >     v->capacity = capacity;
  >   }
  >   v->data[v->length++] = value;
  >   return 1;
  > }
  > generic(T) void reverse(T *items, unsigned long n) {
  >   for (unsigned long i = 0; i < n / 2; i++)
  >     swap(&items[i], &items[n - 1 - i]);
  > }
  > generic(T) int is_even(const T *p, int n);
  > generic(T) int is_odd(const T *p, int n) {
  >   return n ? is_even(p, n - 1) : 0;
  > }
  > generic(T) int is_even(const T *p, int n) {
  >   return n ? is_odd(p, n - 1) : 1;
  > }
  > static int less_long(const long *a, const long *b) { return *a < *b; }
  > static int less_double(const double *a, const double *b) {
  >   return *a < *b;
  > }
  > int main(void) {
  >   long a = 3, b = 7;
  >   double x = 2.5, y = -1.0;
  >   printf("%ld %g\n", *max(&a, &b, less_long), *max(&x, &y, less_double));
  >   swap(&a, &b);
  >   swap(&x, &y);
  >   printf("%ld %ld %g %g\n", a, b, x, y);
  >   vector(int) vi = { 0, 0, 0 };
  >   vector(long) vl = { 0, 0, 0 };
  >   vector(double) vd = { 0, 0, 0 };
  >   for (int i = 0; i < 10; i++) {
  >     if (!vector_push(&vi, i) || !vector_push(&vl, 100L * i) ||
  >         !vector_push(&vd, i / 4.0))
  >       return 1;
  >   }
  >   reverse(vi.data, vi.length);
  >   reverse(vd.data, vd.length);
  >   printf("%lu %d %d %ld %g\n", vi.length, vi.data[0], vi.data[9],
  >          vl.data[9], vd.data[0]);
  >   printf("%d %d %d\n", is_odd(&a, 3), is_even(&x, 3), is_even(&vi, 10));
  >   void (*swap_int)(int *, int *) = swap(int);
  >   swap_int(&vi.data[0], &vi.data[1]);
  >   printf("%d %d\n", vi.data[0], vi.data[1]);
  >   free(vi.data);
  >   free(vl.data);
  >   free(vd.data);
  >   return 0;
  > }
  > EOF
  $ flags="-std=c11 -Wall -Wextra -pedantic-errors -Werror"
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o program program.tc && ./program
  > done
  7 2.5
  7 3 -1 2.5
  10 9 0 900 2.25
  1 0 1
  8 9
  7 2.5
  7 3 -1 2.5
  10 9 0 900 2.25
  1 0 1
  8 9

The shallow branching chain of 10 generic functions compiles and runs:
its one use defines 1023 instances.

  $ { echo 'generic(T) void g9(T *p) { (void)p; }'; i=8
  >   while [ $i -ge 0 ]; do
  >     echo "generic(T) void g$i(T *p) { const T *q = p;" \
  >       "g$((i + 1))(&p); g$((i + 1))(&q); }"
  >     i=$((i - 1))
  >   done
  >   echo 'int main(void) { int x = 0; g0(&x); return x; }'
  > } > chain.tc
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o chain chain.tc && ./chain && echo ok
  > done
  ok
  ok
