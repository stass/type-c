SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The instances of generic types (design 10.3), built on each backend
with -Wall -Wextra -pedantic-errors: a structure, a variant and an
instance that takes another as its argument, laid out as the C of 10.1
and 10.2 under the instance name.

  $ . ./backends.sh

The layout is checked through sizeof and offsetof, and against another
unit that declares the structure of list(int) by hand, which reads the
lists that the program builds.

  $ cat > program.tc <<'EOF'
  > #include <stdio.h>
  > type vector(T) = struct { T *data; unsigned long length; };
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > type pair(A, B) = struct { A first; B second; };
  > type ptr(T) = T *;
  > type handle(T) = distinct T *;
  > type expr = | Call(vector(expr *) args) | Leaf(int v);
  > #include <stddef.h>
  > _Static_assert(offsetof(pair(vector(int), int), second)
  >                == sizeof(vector(int)), "second");
  > _Static_assert(sizeof(vector(ptr(int))) == sizeof(vector(int)), "size");
  > int sum_by_hand(const list(int) *l);
  > size_t size_by_hand(void);
  > size_t alignment_by_hand(void);
  > static int values[3] = { 1, 2, 3 };
  > static vector(int) v = { values, 3 };
  > static pair(vector(int), int) p;
  > static vector(ptr(int)) pointers;
  > static int sum(list(int) l) {
  >   match (l) {
  >   case Nil: return 0;
  >   case Cons(head, tail): return head + (tail ? sum(*tail) : 0);
  >   }
  > }
  > int main(void) {
  >   list(int) end = Nil, two = list(int).Cons(2, &end), one = Cons(1, &two);
  >   handle(int) h = (handle(int))values;
  >   expr e = Leaf(4);
  >   p.first = v;
  >   p.second = 7;
  >   pointers.length = 0;
  >   (void)h;
  >   (void)e;
  >   printf("%d %d %lu %d %lu %d\n", sum(one), sum_by_hand(&one),
  >          p.first.length, p.second, pointers.length,
  >          sizeof(list(int)) == size_by_hand()
  >              && _Alignof(list(int)) == alignment_by_hand());
  >   return 0;
  > }
  > EOF

  $ cat > hand.c <<'EOF'
  > struct list__i {
  >   enum list__i_tag { list__i_Nil, list__i_Cons } tag;
  >   union { struct { int head; struct list__i *tail; } Cons; } u;
  > };
  > #include <stddef.h>
  > int sum_by_hand(const struct list__i *l);
  > size_t size_by_hand(void);
  > size_t alignment_by_hand(void);
  > size_t size_by_hand(void) { return sizeof(struct list__i); }
  > size_t alignment_by_hand(void) { return _Alignof(struct list__i); }
  > int sum_by_hand(const struct list__i *l) {
  >   if (l->tag == list__i_Nil) return 0;
  >   return l->u.Cons.head + (l->u.Cons.tail ? sum_by_hand(l->u.Cons.tail) : 0);
  > }
  > EOF
  $ flags="-std=c11 -Wall -Wextra -pedantic-errors -Werror"
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -c -o program.o program.tc &&
  >     $cc $flags -c -o hand.o hand.c &&
  >     $cc -o program program.o hand.o && ./program
  > done
  3 3 3 7 0 1
  3 3 3 7 0 1

An instance first used inside a region of '#pragma pack(1)' has the
packing of the command line, and the region is in force after it.

  $ cat > packed.tc <<'EOF'
  > type pair(A, B) = struct { A first; B second; };
  > #pragma pack(1)
  > _Static_assert(_Alignof(pair(char, int)) == _Alignof(int), "unpacked");
  > struct after { char c; int i; };
  > _Static_assert(_Alignof(struct after) == 1, "the region is kept");
  > #pragma pack()
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only packed.tc || echo "$cc"
  > done

An error that the backend finds in the text of an instance is reported
at the line of the generic's definition, where the token stands, and
not at the application.

  $ cat > zero.tc <<'EOF'
  > type box(T) = struct {
  >   T value;
  >   int bad[0];
  > };
  > box(int) b;
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only zero.tc 2>&1 |
  >     grep -o '^[^ :]*:[0-9]*:[0-9]*: error' | cut -d: -f1,2
  > done
  zero.tc:3
  zero.tc:3

A generic whose definition holds a _Pragma operator, which the
preprocessor makes a pragma line, is refused (design 10.3, P25).

  $ cat > pragma.tc <<'EOF'
  > type box(T) = struct { _Pragma("pack(1)") T value; };
  > EOF
  $ typec --cc=$clang -fsyntax-only pragma.tc
  typec: pragma.tc:1: the definition of a generic type holds a pragma or a `#`, which the text of its instances cannot hold (design 10.3, P25) [TC0047]
  [80]
