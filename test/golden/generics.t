SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The syntax of generic types (design 3.5): type parameters, type
applications and the refusals that the parser makes. Each source is
preprocessed text, as the backend writes it for -E; a file named *.tc
holds Type-C text.

Lowering writes no instance yet, so a program that declares a generic
type is refused once its typing has passed (design 10.3; work package
2.1).

  $ cat > list.tc <<'EOF'
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > list(int) *numbers;
  > EOF
  $ ./golden.exe list.tc
  list.tc:1: lowering generic types is not implemented yet (design 10.3; work package 2.1) [TC0023]
  [1]

An instance of a generic variant is a variant (design 3.5 rule 3): its
constructors build it, qualified or against a target type, and matching
opens it (design 3.3, 4). Typing passes here, and lowering refuses the
unit.

  $ cat > construct.tc <<'EOF'
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > int sum(list(int) l) {
  >   list(int) rest = Nil, first = list(int).Cons(1, &rest);
  >   (void)first;
  >   match (l) {
  >   case Nil: return 0;
  >   case Cons(head, tail): return head + (tail ? sum(*tail) : 0);
  >   }
  > }
  > EOF
  $ ./golden.exe construct.tc
  construct.tc:1: lowering generic types is not implemented yet (design 10.3; work package 2.1) [TC0023]
  [1]

A match on an instance covers each of its constructors (design 4.2 rule
1), and only constructors and matching open it (design 3.2 rule 6). Its
messages name it by its instance name (design 10.3).

  $ cat > uncovered.tc <<'EOF'
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > int first(list(int) l) {
  >   match (l) {
  >   case Nil: return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe uncovered.tc
  uncovered.tc:3: the match does not cover the constructor 'Cons' of the variant 'list__i' (design 4.2 rule 1) [TC0018]
  [1]
  $ cat > opened.tc <<'EOF'
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > int tag(list(int) l) { return l.tag; }
  > EOF
  $ ./golden.exe opened.tc
  opened.tc:2: the variant 'list__i' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching (design 3.2 rule 6) [TC0007]
  [1]

A generic type is declared at file scope only (design 3.1).

  $ printf 'void f(void) { type box(T) = struct { T value; }; }\n' > block.tc
  $ ./golden.exe block.tc
  block.tc:1: the generic type `box` is declared in a block; a generic type is declared at file scope only (design 3.1) [TC0033]
  [1]

No generic type has a universe name (design 3.6), whether or not a
declaration hides it.

  $ printf 'int option;\ntype option(T) = | None | Some(T value);\n' \
  >   > universe.tc
  $ ./golden.exe universe.tc
  universe.tc:2: `option` is a universe name, which no generic type has (design 3.6) [TC0034]
  [1]

The name of a generic type alone is not a type, and an application has
one argument for each type parameter (design 3.5 rule 1).

  $ printf 'type box(T) = struct { T value; };\nbox b;\n' > bare.tc
  $ ./golden.exe bare.tc
  bare.tc:2: the generic type `box` names a type only in a type application, `box(...)` (design 3.5 rule 1) [TC0035]
  [1]
  $ printf 'type pair(A, B) = struct { A a; B b; };\npair(int) p;\n' \
  >   > arity.tc
  $ ./golden.exe arity.tc
  arity.tc:2: the generic type `pair` takes 2 type arguments, not 1 (design 3.5 rule 1) [TC0035]
  [1]

The definition that completes an incomplete variant has as many type
parameters (design 3.1 rule 4); their names may differ.

  $ printf 'type list(T);\ntype list(A, B) = | Nil;\n' > completion.tc
  $ ./golden.exe completion.tc
  completion.tc:2: the variant `list` has 2 type parameters, and the incomplete variant that it completes has 1 type parameter (design 3.1 rule 4) [TC0036]
  [1]

A tag that a type argument is the first to mention is declared where C
declares it, which outside file scope gives it no name that an instance
could take (design 3.5 rule 2).

  $ cat > argument.tc <<'EOF'
  > type box(T) = struct { T *value; };
  > void f(void) { box(struct s) b; }
  > EOF
  $ ./golden.exe argument.tc
  argument.tc:2: a type argument declares the tag `s` in a parameter list or a block (C11 6.7.2.3p8); declare the tag at file scope before it (design 3.5 rule 2) [TC0037]
  [1]
  $ cat > prototype.tc <<'EOF'
  > type box(T) = struct { T *value; };
  > box(void (*)(struct s *)) b;
  > EOF
  $ ./golden.exe prototype.tc
  prototype.tc:2: a type argument declares the tag `s` in a parameter list or a block (C11 6.7.2.3p8); declare the tag at file scope before it (design 3.5 rule 2) [TC0037]
  [1]

The definition of a generic type uses a type parameter only as a type,
and holds a structure or union body only where an instance's definition
holds it (design 3.5 rule 4).

  $ printf 'type id(T) = distinct T;\n' > distinct.tc
  $ ./golden.exe distinct.tc
  distinct.tc:1: the type parameter `T` is the representation after `distinct` (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type bits(T) = struct { T b : 3; };\n' > bit_field.tc
  $ ./golden.exe bit_field.tc
  bit_field.tc:1: the type parameter `T` is the type of a bit-field (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type a(T) = struct { _Alignas(T) char c; T v; };\n' > align.tc
  $ ./golden.exe align.tc
  align.tc:1: the type parameter `T` is used in `_Alignas` (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type a(T) = struct { _Alignas(sizeof(T *)) char c; };\n' \
  >   > align_expression.tc
  $ ./golden.exe align_expression.tc
  align_expression.tc:1: the type parameter `T` is used in `_Alignas` (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type node(T) = struct node { T v; };\n' > tagged.tc
  $ ./golden.exe tagged.tc
  tagged.tc:1: the structure or union `node` has a body in the definition of a generic type, where a body has no tag (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type p(T) = struct { T x; } *;\n' > pointer.tc
  $ ./golden.exe pointer.tc
  pointer.tc:1: a structure or union body stands in the definition of a generic type only as the whole definition or in a field of a variant, or inside either, and not in a type argument (design 3.5 rule 4) [TC0038]
  [1]
  $ cat > argument_body.tc <<'EOF'
  > type box(T) = struct { T *value; };
  > type nest(T) = | Leaf | Node(box(struct { T v; }) b);
  > EOF
  $ ./golden.exe argument_body.tc
  argument_body.tc:2: a structure or union body stands in the definition of a generic type only as the whole definition or in a field of a variant, or inside either, and not in a type argument (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type e(T) = struct { enum { A, B } k; T v; };\n' > enum.tc
  $ ./golden.exe enum.tc
  enum.tc:1: an enumeration specifier has a body in the definition of a generic type, so that every instance would declare its enumerators again (design 3.5 rule 4) [TC0038]
  [1]

The definition of a generic type is written in each instance and not at
its own place, so it declares no tag at file scope (design 3.5 rule 8).
A tag that a prototype scope of a member declares is the instance's
own, and a tag declared before the definition is named by it.

  $ printf 'type link(T) = struct { struct node *next; T v; };\n' \
  >   > first_mention.tc
  $ ./golden.exe first_mention.tc
  first_mention.tc:1: the definition of a generic type is the first to mention the tag `node` at file scope; declare the tag before the definition (design 3.5 rule 8) [TC0039]
  [1]
  $ printf 'type step(T) = | Done | Next(struct node *n, T v);\n' \
  >   > first_mention_field.tc
  $ ./golden.exe first_mention_field.tc
  first_mention_field.tc:1: the definition of a generic type is the first to mention the tag `node` at file scope; declare the tag before the definition (design 3.5 rule 8) [TC0039]
  [1]

Typing reads the definition again for each instance, with the
arguments bound. An instance is defined where a point first needs it
complete, and an error of its definition is reported at the
application (design 3.5 rule 5).

  $ cat > incomplete.tc <<'EOF'
  > type box(T) = struct { T value; };
  > struct s;
  > struct holder { box(struct s) b; };
  > EOF
  $ ./golden.exe incomplete.tc
  incomplete.tc:3: in the instance 'box__T1s' that this application names, at incomplete.tc:1: member has an incomplete or function type
  [1]

A type argument has a row in the table of design 10.3 for every type in
it (design 3.5 rule 2).

  $ printf 'type box(T) = struct { T value; };\nbox(int[2]) *b;\n' \
  >   > array.tc
  $ ./golden.exe array.tc
  array.tc:2: the type argument 'int[2]' is an array (design 3.5 rule 2) [TC0041]
  [1]

A chain of instances that each define the next holds at most 64
(design 3.5 rule 7); one under a pointer defines nothing.

  $ printf 'type box(T) = struct { T value; };\nstruct w { %sint%s deep; };\n' \
  >   "$(printf 'box(%.0s' $(seq 65))" "$(printf ')%.0s' $(seq 65))" > deep.tc
  $ ./golden.exe deep.tc
  deep.tc:2: the application would define the instance 'box__i' after a chain of 64 instances that each define the next, which the application at deep.tc:2 began; a chain holds at most 64 (design 3.5 rule 7) [TC0042]
  [1]

The texts of an instance stand before the external declaration of its
first use, so what they need complete is complete before it (design
10.3).

  $ printf 'type a2(T) = T[2];\nstruct s { int a; } *f(a2(struct s) *p);\n' \
  >   > early.tc
  $ ./golden.exe early.tc
  early.tc:2: the instance 'a2__T1s' needs 'struct s' complete where its text stands, before the external declaration that completes it at early.tc:2; complete it in an earlier one (design 10.3) [TC0043]
  [1]

The definition is checked once with each type parameter an opaque value
type, so a use that the parser cannot see, through a transparent alias
or in a constant expression, is refused there (design 3.5 rule 4).

  $ printf 'type same(U) = U;\ntype d(T) = distinct same(T);\n' > through.tc
  $ ./golden.exe through.tc
  through.tc:2: the representation after `distinct` depends on a type parameter (design 3.5 rule 4) [TC0038]
  [1]
  $ printf 'type a(T) = struct { char b[sizeof(T)]; T v; };\n' > size.tc
  $ ./golden.exe size.tc
  size.tc:1: a type in an expression in the definition of a generic type depends on a type parameter (design 3.5 rule 4) [TC0038]
  [1]
