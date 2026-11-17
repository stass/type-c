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
  pragma.tc:1: error: the definition of a generic type holds a pragma or a `#`, which the text of its instances cannot hold [generic-pragma]
  [80]

An argument is spelled through the one name of an untagged type, which
denotes the type with the qualifiers of its declaration, and its own
qualifiers are written beside the unqualified form of that name (design
10.3). The address of each member is a pointer to the argument itself.

  $ cat > qualified.tc <<'EOF'
  > typedef _Atomic struct { char a, b, c; } atomic_s;
  > typedef const struct { int x; } const_s;
  > typedef const enum { E0, E1 } const_e;
  > type box(T) = struct { T v; };
  > static box(atomic_s) atomic_a;
  > static box(const_s) const_c = { { 2 } };
  > static box(volatile const_e) volatile_e = { E1 };
  > int main(void) {
  >   atomic_s *to_atomic = &atomic_a.v;
  >   int exact = _Generic(&atomic_a.v, atomic_s *: 1, default: 0)
  >     && _Generic(&const_c.v, const_s *: 1, default: 0)
  >     && _Generic(&volatile_e.v, volatile const_e *: 1, default: 0);
  >   return !exact || !to_atomic || const_c.v.x != 2 || volatile_e.v != E1;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o qualified qualified.tc && ./qualified ||
  >     echo "$cc"
  > done

An argument holds no attribute (design 3.5 rule 2), and a structure
that holds an attributed member keeps the layout that the attribute
gives it. An attribute after one declarator of a typedef is that
declarator's alone.

  $ cat > attributed.tc <<'EOF'
  > typedef int wide __attribute__((aligned(16)));
  > struct holder { wide w; };
  > typedef int plain, aligned __attribute__((aligned(16)));
  > type box(T) = struct { T v; };
  > _Static_assert(_Alignof(box(struct holder)) == 16, "aligned");
  > _Static_assert(_Alignof(box(plain)) == _Alignof(int), "plain");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only attributed.tc || echo "$cc"
  > done
  $ cat > wide.tc <<'EOF'
  > typedef int wide __attribute__((aligned(16)));
  > type box(T) = struct { T v; };
  > box(wide) b;
  > EOF
  $ typec --cc=$clang $flags -fsyntax-only wide.tc
  wide.tc:3: error: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' [type-argument]
  [80]

A typedef name declared again with an attribute after an alias generic
that uses it gives the alias's text another type where an instance
first stands after that declaration (design 13.5); the backend would
read a(int) as aligned and box(a(int)) as box(int).

  $ cat > late.tc <<'EOF'
  > typedef int p;
  > type a(T) = p;
  > type box(T) = struct { T value; };
  > typedef int p __attribute__((aligned(16)));
  > box(a(int)) x;
  > EOF
  $ typec --cc=$clang $flags -fsyntax-only late.tc
  late.tc:5: error: in the instance 'a__i' that this application names, at late.tc:2: the declaration of the typedef name 'p' at late.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change each type written through it [generic-name-capture]
  [80]

An instance that stands before that declaration keeps the type that
typec reads, so the argument is exact on both backends.

  $ cat > early.tc <<'EOF'
  > typedef int p;
  > type a(T) = p;
  > type box(T) = struct { T value; };
  > type g(T) = struct { p v; T t; };
  > a(int) early_a;
  > box(a(int)) early_box;
  > g(int) early_g;
  > typedef int p __attribute__((aligned(16)));
  > box(a(int)) x;
  > g(int) z;
  > _Static_assert(_Alignof(p) == 16, "p");
  > _Static_assert(_Alignof(a(int)) == _Alignof(__typeof__(x.value)), "a");
  > _Static_assert(_Alignof(g(int)) == _Alignof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only early.tc || echo "$cc"
  > done

An object declared again through an inexact typedef name after a
generic whose text reads it gives the text another type where an
instance first stands after that declaration (design 13.5): Clang
aligns g(int) as wide there, and as int where the definition stands,
so one instance name would have two layouts.

  $ cat > object.tc <<'EOF'
  > extern int obj;
  > type g(T) = struct { __typeof__(obj) v; T t; };
  > typedef int wide __attribute__((aligned(16)));
  > extern wide obj;
  > g(int) x;
  > _Static_assert(_Alignof(g(int)) == _Alignof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only object.tc
  > done
  object.tc:5: error: in the instance 'g__i' that this application names, at object.tc:2: the declaration of 'obj' at object.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses [generic-name-capture]
  object.tc:5: error: in the instance 'g__i' that this application names, at object.tc:2: the declaration of 'obj' at object.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses [generic-name-capture]
  [80]

An instance that stands before that declaration reads obj as the
definition does, on both backends.

  $ cat > object_early.tc <<'EOF'
  > extern int obj;
  > type g(T) = struct { __typeof__(obj) v; T t; };
  > g(int) early;
  > typedef int wide __attribute__((aligned(16)));
  > extern wide obj;
  > g(int) x;
  > _Static_assert(_Alignof(g(int)) == _Alignof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only object_early.tc || echo "$cc"
  > done

A typedef name that the declaration of such an object is written
through, declared again with an attribute after the generic, gives the
text another type too (design 13.5): GCC changes the typedef in place,
so it aligns g(int) as 16 there, where the definition gives 4.

  $ cat > widened.tc <<'EOF'
  > typedef int plain;
  > extern plain obj;
  > type g(T) = struct { __typeof__(obj) v; T t; };
  > typedef int plain __attribute__((aligned(16)));
  > g(int) x;
  > _Static_assert(_Alignof(g(int)) == _Alignof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only widened.tc
  > done
  widened.tc:5: error: in the instance 'g__i' that this application names, at widened.tc:3: the declaration of the typedef name 'plain' at widened.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change each type written through it [generic-name-capture]
  widened.tc:5: error: in the instance 'g__i' that this application names, at widened.tc:3: the declaration of the typedef name 'plain' at widened.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change each type written through it [generic-name-capture]
  [80]

An instance that stands before the typedef's declaration reads obj as
the definition does, on both backends.

  $ cat > widened_early.tc <<'EOF'
  > typedef int plain;
  > extern plain obj;
  > type g(T) = struct { __typeof__(obj) v; T t; };
  > g(int) early;
  > typedef int plain __attribute__((aligned(16)));
  > g(int) x;
  > _Static_assert(_Alignof(g(int)) == _Alignof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only widened_early.tc || echo "$cc"
  > done

A typedef name declared again with an attribute between a generic and
an instance is refused whether or not the text uses it (design 13.5):
GCC changes the typedef in place, and with it the members written
through it, so it aligns g(int) as 16 there, where the definition gives
4.

  $ cat > member.tc <<'EOF'
  > typedef int plain;
  > struct holder { plain m; };
  > type g(T) = struct { __typeof__(((struct holder *)0)->m) v; T t; };
  > typedef int plain __attribute__((aligned(16)));
  > g(int) x;
  > _Static_assert(_Alignof(g(int)) == _Alignof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only member.tc
  > done
  member.tc:5: error: in the instance 'g__i' that this application names, at member.tc:3: the declaration of the typedef name 'plain' at member.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change each type written through it [generic-name-capture]
  member.tc:5: error: in the instance 'g__i' that this application names, at member.tc:3: the declaration of the typedef name 'plain' at member.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change each type written through it [generic-name-capture]
  [80]

An alignment specifier declares an object again inexactly as an
attribute does: both backends give the object alignment 16 after it.

  $ cat > alignas.tc <<'EOF'
  > extern int obj;
  > type g(T) = struct { char c[__alignof__(obj)]; T t; };
  > extern _Alignas(16) int obj;
  > g(int) x;
  > _Static_assert(sizeof(g(int)) == _Alignof(int) + sizeof(int), "g");
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -fsyntax-only alignas.tc
  > done
  alignas.tc:4: error: in the instance 'g__i' that this application names, at alignas.tc:2: the declaration of 'obj' at alignas.tc:3, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses [generic-name-capture]
  alignas.tc:4: error: in the instance 'g__i' that this application names, at alignas.tc:2: the declaration of 'obj' at alignas.tc:3, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses [generic-name-capture]
  [80]

A declaration in a block cannot hide a name of an instance that
lowering writes there (design 10.3): the enumerator would make the
constructor Some of option(int) the tag of None on both backends.

  $ cat > hidden_tag.tc <<'EOF'
  > #include <stdio.h>
  > option(int) f(void) { enum { option__i_Some = 0 }; return Some(123); }
  > int main(void) {
  >   match (f()) {
  >   case Some(v): printf("Some %d\n", v); break;
  >   case None: printf("None\n"); break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o hidden_tag hidden_tag.tc && ./hidden_tag
  > done
  hidden_tag.tc:2: error: the name `option__i_Some` is declared, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  hidden_tag.tc:2: error: the name `option__i_Some` is declared, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  [80]

An attribute argument that declares the enumerator would hide it the
same way, and typec, which does not read the argument, refuses every
name of the claimed space there (design 10.3, 13.5).

  $ cat > unread_tag.tc <<'EOF'
  > #include <stdio.h>
  > option(int) f(void) {
  >   int x __attribute__((aligned(sizeof(enum { option__i_Some = 0 }))));
  >   (void)x;
  >   return Some(123);
  > }
  > int main(void) {
  >   match (f()) {
  >   case Some(v): printf("Some %d\n", v); break;
  >   case None: printf("None\n"); break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o unread_tag unread_tag.tc && ./unread_tag
  > done
  unread_tag.tc:3: error: the name `option__i_Some` is spelled in the arguments of an attribute, which typing does not read, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  unread_tag.tc:3: error: the name `option__i_Some` is spelled in the arguments of an attribute, which typing does not read, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  [80]

The typedef of a type argument spells the one name of an untagged type
that the argument names, and a declaration of that name with an
attribute between the declaration that typec read and the place where
lowering writes the typedef would give the payload another type on the
backend (design 13.5): Apple Clang 21 aligns the pointee of p to 4 and
that of the payload to 16.

  $ cat > spelled.tc <<'EOF'
  > #include <stdio.h>
  > typedef struct { int x[4]; } s;
  > typedef s *p;
  > typedef s s __attribute__((aligned(16)));
  > int main(void) {
  >   option(p) o = Some((p)0);
  >   match (o) {
  >   case Some(v):
  >     printf("%d\n", __alignof__(*(p)0) == __alignof__(*v));
  >     break;
  >   case None:
  >     break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o spelled spelled.tc && ./spelled
  > done
  spelled.tc:6: error: in `typedef s *__tc_arg__P1s;`, which lowering writes for this application: the declaration of 's' at spelled.tc:4 gives it a type that may hold an attribute or `typeof` of an expression, which the text that lowering writes would carry [generic-name-capture]
  spelled.tc:6: error: in `typedef s *__tc_arg__P1s;`, which lowering writes for this application: the declaration of 's' at spelled.tc:4 gives it a type that may hold an attribute or `typeof` of an expression, which the text that lowering writes would carry [generic-name-capture]
  [80]

Where the typedef stands before that declaration, the name has the
type that typec read, and the payload is aligned as the pointee of p on
both backends.

  $ cat > spelled_early.tc <<'EOF'
  > #include <stdio.h>
  > typedef struct { int x[4]; } s;
  > typedef s *p;
  > option(p) early;
  > typedef s s __attribute__((aligned(16)));
  > int main(void) {
  >   option(p) o = Some((p)0);
  >   match (o) {
  >   case Some(v):
  >     printf("%d\n", __alignof__(*(p)0) == __alignof__(*v));
  >     break;
  >   case None:
  >     break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o spelled_early spelled_early.tc && ./spelled_early
  > done
  1
  1

So does a declarator of the one name that holds the attribute itself,
though the argument's declarator in the same declaration does not.

  $ cat > spelled_own.tc <<'EOF'
  > #include <stdio.h>
  > typedef struct { int x[4]; } s __attribute__((aligned(16))), *p;
  > int main(void) {
  >   option(p) o = Some((p)0);
  >   match (o) {
  >   case Some(v):
  >     printf("%d\n", __alignof__(*(p)0) == __alignof__(*v));
  >     break;
  >   case None:
  >     break;
  >   }
  >   return 0;
  > }
  > EOF
  $ for cc in $clang $gcc; do
  >   typec --cc=$cc $flags -o spelled_own spelled_own.tc && ./spelled_own
  > done
  spelled_own.tc:4: error: in `typedef s *__tc_arg__P1s;`, which lowering writes for this application: the declaration of 's' at spelled_own.tc:2 gives it a type that may hold an attribute or `typeof` of an expression, which the text that lowering writes would carry [generic-name-capture]
  spelled_own.tc:4: error: in `typedef s *__tc_arg__P1s;`, which lowering writes for this application: the declaration of 's' at spelled_own.tc:2 gives it a type that may hold an attribute or `typeof` of an expression, which the text that lowering writes would carry [generic-name-capture]
  [80]
