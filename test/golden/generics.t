SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The syntax of generic types (design 3.5): type parameters, type
applications and the refusals that the parser makes. Each source is
preprocessed text, as the backend writes it for -E; a file named *.tc
holds Type-C text.

A generic's definition is removed at its own place, each application
becomes the name of its instance, and each instance is written from the
definition's tokens in a packing bracket before the external
declaration of its first use: its declaration there, with the typedef
of each argument, and its definition before the first point that needs
it complete (design 10.3). A use under a pointer needs nothing
complete.

  $ cat > list.tc <<'EOF'
  > type list(T) = | Nil | Cons(T head, list(T) *tail);
  > list(int) *numbers;
  > EOF
  $ ./golden.exe list.tc
  # 1 "list.tc"
  
  # 1 "list.tc"
  
  # 1 "list.tc"
  
  
  # 2 "list.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "list.tc"
  typedef int __tc_arg__i; struct list__i; typedef struct list__i list__i;
  # 2 "list.tc"
  #pragma pack(pop)
  # 2 "list.tc"
  
  # 2 "list.tc"
  list__i
  # 2 "list.tc"
   *numbers;
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

A structure needed complete is defined where the need is: a file-scope
object needs its type complete. An argument that is an instance is
named by its tag, so that its typedef and the instances that take it
stand before the typedef name is declared, and the instance's own
forward declaration of the tag comes first (design 10.3).

  $ cat > pair.tc <<'EOF'
  > type vector(T) = struct { T *data; unsigned long length; };
  > type pair(A, B) = struct { A first; B second; };
  > vector(int) *numbers;
  > pair(vector(int), int) p;
  > EOF
  $ ./golden.exe pair.tc | sed '/<typec>/,$d'
  # 1 "pair.tc"
  
  # 1 "pair.tc"
  
  # 1 "pair.tc"
  
  
  # 2 "pair.tc"
  
  # 2 "pair.tc"
  
  
  # 3 "pair.tc"
  #pragma pack(push)
  #pragma pack()
  # 3 "pair.tc"
  typedef int __tc_arg__i; struct vector__i; typedef struct vector__i vector__i;
  # 3 "pair.tc"
  #pragma pack(pop)
  # 3 "pair.tc"
  
  # 3 "pair.tc"
  vector__i
  # 3 "pair.tc"
   *numbers;
  
  # 4 "pair.tc"
  #pragma pack(push)
  #pragma pack()
  # 4 "pair.tc"
  struct vector__i; typedef struct vector__i __tc_arg__I6vectoriE; struct pair__I6vectoriEi; typedef struct pair__I6vectoriEi pair__I6vectoriEi;
  # 1 "pair.tc"
  struct vector__i { __tc_arg__i * data ; unsigned long length ; } ;
  # 2 "pair.tc"
  struct pair__I6vectoriEi { __tc_arg__I6vectoriE first ; __tc_arg__i second ; } ;
  # 4 "pair.tc"
  #pragma pack(pop)
  # 4 "pair.tc"
  
  # 4 "pair.tc"
  pair__I6vectoriEi
  # 4 "pair.tc"
   p;
  

An association of an answered generic selection whose type name is an
application is steered as any other: the steering type replaces the
application (design 13.5).

  $ cat > steered.tc <<'EOF'
  > type handle(T) = distinct T *;
  > handle(int) h;
  > int a = _Generic(h, handle(int): 1, int *: 2);
  > EOF
  $ ./golden.exe steered.tc | grep -v '^#' | grep -F 'char (*)'
  ), (char (*)[1])0)
  char (*)[1]
  char (*)[2]

A generic whose definition holds a pragma line, which is also what a
_Pragma operator becomes, is refused: the text of an instance holds no
pragma (design 10.3, P25).

  $ cat > pragma.tc <<'EOF'
  > type box(T) = struct {
  > #pragma pack(1)
  >   T value;
  > };
  > EOF
  $ ./golden.exe pragma.tc
  pragma.tc:2: the definition of a generic type holds a pragma or a `#`, which the text of its instances cannot hold (design 10.3, P25) [TC0047]
  [1]

An instance of a generic variant is a variant (design 3.5 rule 3): its
constructors build it, qualified or against a target type, and matching
opens it (design 3.3, 4).

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
  # 1 "construct.tc"
  
  # 1 "construct.tc"
  
  # 1 "construct.tc"
  
  
  # 2 "construct.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "construct.tc"
  typedef int __tc_arg__i; struct list__i; typedef struct list__i list__i;
  # 1 "construct.tc"
  enum list__i_tag { list__i_Nil, list__i_Cons }; struct list__i { enum list__i_tag tag; union { struct { __tc_arg__i head ; list__i * tail ; } Cons; } u; };
  # 2 "construct.tc"
  #pragma pack(pop)
  # 2 "construct.tc"
  int sum(
  # 2 "construct.tc"
  list__i
  # 2 "construct.tc"
   l) {
    
  # 3 "construct.tc"
  list__i
  # 3 "construct.tc"
   rest = 
  # 3 "construct.tc"
  { .tag = list__i_Nil }
  # 3 "construct.tc"
  , first = 
  # 3 "construct.tc"
  { .tag = list__i_Cons, .u.Cons = { 
  # 3 "construct.tc"
  1, &rest
  # 3 "construct.tc"
   } }
  # 3 "construct.tc"
  ;
    (void)first;
    
  # 5 "construct.tc"
  { const struct list__i *const __tc_match = &(
  # 5 "construct.tc"
  l
  # 5 "construct.tc"
  ); switch (__tc_match->tag) {
  # 5 "construct.tc"
  
    
  # 6 "construct.tc"
  case list__i_Nil: {
  # 6 "construct.tc"
   return 0;
    
  # 7 "construct.tc"
   __builtin_trap(); }
  # 7 "construct.tc"
  
  # 7 "construct.tc"
  case list__i_Cons: { const __typeof__(__tc_match->u.Cons.head) head = __tc_match->u.Cons.head; const __typeof__(__tc_match->u.Cons.tail) tail = __tc_match->u.Cons.tail; {
  # 7 "construct.tc"
   return head + (tail ? sum(*tail) : 0);
    
  # 8 "construct.tc"
   } __builtin_trap(); }
  # 8 "construct.tc"
  
  # 8 "construct.tc"
  default: __builtin_trap(); } }
  # 8 "construct.tc"
  
  }
  
  # 1 "<typec>" 3
  #pragma pack(push)
  #pragma pack(1)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_1 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(2)
  #pragma pack(push)
  #pragma pack()
  struct __tc_pack_probe_2 { char c; int i; };
  #pragma pack(pop)
  #pragma pack(pop)
  _Static_assert(_Alignof(struct __tc_pack_probe_1) == _Alignof(struct __tc_pack_probe_2), "typec assumes '#pragma pack()' restores the packing of the command line (-fapple-pragma-pack or -fxl-pragma-pack?)");

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

The arguments of an attribute are unread text, which lowering leaves as
the source spells it, so a type parameter there would reach every
instance as written; it is refused at the definition, whatever text
writes it.

  $ cat > attribute.tc <<'EOF'
  > type a(T) = struct { T v __attribute__((aligned(sizeof(T)))); };
  > EOF
  $ ./golden.exe attribute.tc
  attribute.tc:1: the type parameter `T` is used in the arguments of an attribute (design 3.5 rule 4) [TC0038]
  [1]
  $ cat > c_attribute.tc <<'EOF'
  > # 1 "c.h" 1
  > type a(T) = struct { T v __attribute__((aligned(sizeof(T)))); };
  > EOF
  $ ./golden.exe c_attribute.tc
  c.h:1: the type parameter `T` is used in the arguments of an attribute (design 3.5 rule 4) [TC0038]
  [1]
  $ cat > standard.tc <<'EOF'
  > type a(T) = struct { [[gnu::aligned(sizeof(T))]] T v; };
  > EOF
  $ ./golden.exe standard.tc
  standard.tc:1: the type parameter `T` is used in the arguments of an attribute (design 3.5 rule 4) [TC0038]
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
  first_mention.tc:1: the tag 'node' is declared in the scope around the text, which lowering writes elsewhere, so the text after it would lose the declaration; declare it before the text (design 13.5) [TC0039]
  [1]
  $ printf 'type step(T) = | Done | Next(struct node *n, T v);\n' \
  >   > first_mention_field.tc
  $ ./golden.exe first_mention_field.tc
  first_mention_field.tc:1: the tag 'node' is declared in the scope around the text, which lowering writes elsewhere, so the text after it would lose the declaration; declare it before the text (design 13.5) [TC0039]
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

An argument holds no attribute: none is written in it, and no typedef
name, alias or transparent alias generic that it uses, at any depth, is
declared with one (design 3.5 rule 2). Its instance name would not tell
it from the argument without the attribute.

  $ for argument in wide 'wider *' 'int * _Nonnull' 'void (*)(wide)' \
  >     'int __attribute__((aligned(16))) *' alias 'over(int)'; do
  >   printf '%s\n' 'typedef int wide __attribute__((aligned(16)));' \
  >     'typedef wide wider;' 'type alias = wider;' 'type over(T) = wide;' \
  >     'type box(T) = struct { T value; };' "box($argument) *b;" \
  >     > attributed.tc
  >   ./golden.exe attributed.tc
  > done
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int *' (design 3.5 rule 2) [TC0041]
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int *' (design 3.5 rule 2) [TC0041]
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'void (*)(int)' (design 3.5 rule 2) [TC0041]
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int *' (design 3.5 rule 2) [TC0041]
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  attributed.tc:6: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  [1]

A typedef name redeclared keeps the attribute of either declaration, as
both backends do.

  $ for first in '' ' __attribute__((aligned(16)))'; do
  >   second=' __attribute__((aligned(16)))'
  >   test -z "$first" || second=
  >   printf '%s\n' "typedef int t$first;" "typedef int t$second;" \
  >     'type box(T) = struct { T value; };' 'box(t) *b;' > redeclared.tc
  >   ./golden.exe redeclared.tc
  > done
  redeclared.tc:4: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  redeclared.tc:4: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  [1]

A typedef name that an alias generic uses, declared again with an
attribute after the alias, gives the alias's text another type where an
instance first stands after that declaration (design 13.5). Declared
again before the alias, it makes the alias inexact, and the argument is
refused.

  $ printf '%s\n' 'typedef int p;' 'type a(T) = p;' \
  >   'type box(T) = struct { T value; };' \
  >   'typedef int p __attribute__((aligned(16)));' 'box(a(int)) x;' > late.tc
  $ ./golden.exe late.tc
  late.tc:5: in the instance 'a__i' that this application names, at late.tc:2: the declaration of 'p' at late.tc:4, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses (design 13.5) [TC0044]
  [1]
  $ printf '%s\n' 'typedef int p;' \
  >   'typedef int p __attribute__((aligned(16)));' 'type a(T) = p;' \
  >   'type box(T) = struct { T value; };' 'box(a(int)) x;' > before.tc
  $ ./golden.exe before.tc
  before.tc:5: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  [1]

An argument holds no `__typeof__` of an expression at the same depth,
as the backend gives the expression the type of the typedef that
declared it, attribute included (design 3.5 rule 2). `__typeof__` of a
type name is valid.

  $ for argument in '__typeof__(w)' '__typeof__(w) *' 'typeof(h.w)' \
  >     '__typeof(*p)' W alias 'over(int)' '__typeof__(__typeof__(w))'; do
  >   printf '%s\n' 'typedef int wide __attribute__((aligned(16)));' \
  >     'extern wide w, *p;' 'extern struct { wide w; } h;' \
  >     'typedef __typeof__(w) W;' 'type alias = __typeof__(w);' \
  >     'type over(T) = __typeof__(w);' \
  >     'type box(T) = struct { T value; };' "box($argument) *b;" \
  >     > typeof.tc
  >   ./golden.exe typeof.tc
  > done
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int *' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  typeof.tc:8: the type argument may carry an attribute that no instance name encodes, as it holds an attribute or `typeof` of an expression, or a typedef name or an alias declared with one: it would share the instance of 'int' (design 3.5 rule 2) [TC0041]
  [1]
  $ printf '%s\n' 'type box(T) = struct { T value; };' \
  >   'box(__typeof__(int)) *b;' > typeof_type.tc
  $ ./golden.exe typeof_type.tc | grep -c box__i
  2

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

The definition of a generic reads where the text of an instance stands
as at the definition (design 13.5, 3.5 rule 8). A tag of a prototype's
own scope that file scope declares before the instance is refused at
the application, as is a declaration of a used entity whose type may
change through a type that typec does not compute (P21), and, in a
generic that C text defines, a universe name in an attribute whose
spelling C declares there.

  $ cat > handler.tc <<'EOF'
  > type handler(T) = struct { void (*call)(struct ctx *c, T value); };
  > struct ctx { int depth; };
  > handler(int) h;
  > EOF
  $ ./golden.exe handler.tc
  handler.tc:3: in the instance 'handler__i' that this application names, at handler.tc:1: the text declares the tag 'ctx' in a scope of its own, but where lowering writes it the tag is the one declared at handler.tc:2 (design 13.5) [TC0044]
  [1]

  $ cat > dot.tc <<'EOF'
  > static _Float16 dot(_Float16);
  > type g(T) = struct { T v; typeof(dot) *f; };
  > static _Float16 dot(_Float16 x) { return x; }
  > g(int) x;
  > EOF
  $ ./golden.exe dot.tc
  dot.tc:4: in the instance 'g__i' that this application names, at dot.tc:2: the declaration of 'dot' at dot.tc:3, between the text and a place where lowering writes it, may change the type that the text uses: that depends on '_Float16', whose type typec does not compute (design 13.5, P21) [TC0045]
  [1]

  $ cat > aligned.tc <<'EOF'
  > # 1 "c.h" 1
  > type g(T) = struct { T v __attribute__((aligned(sizeof(option)))); };
  > int option;
  > # 2 "aligned.tc" 2
  > g(int) x;
  > EOF
  $ ./golden.exe aligned.tc
  aligned.tc:2: in the instance 'g__i' that this application names, at c.h:1: 'option' in the arguments of an attribute denotes a universe name, but where lowering writes the text the backend reads the declaration of 'option' there, the one declared at c.h:2 (design 13.5) [TC0046]
  [1]

Type-C text names no generic and no universe name in the arguments of an
attribute, whether a declaration of C would take the spelling or not:
lowering leaves the arguments as written, so the backend would find
nothing under the spelling or read it as a word of the attribute
(design 13.5). A universe name that a declaration hides denotes what
the declaration declares, and C text that does not move is the
backend's to read.

  $ cat > application.tc <<'EOF'
  > type vector(T) = struct { T *data; long n; };
  > vector(int) v;
  > int y __attribute__((aligned(_Alignof(vector(int)))));
  > EOF
  $ ./golden.exe application.tc
  application.tc:3: `vector` in the arguments of an attribute denotes a generic, which lowering writes under a name of its own, but it leaves the arguments as written (design 13.5) [TC0046]
  [1]
  $ cat > bare.tc <<'EOF'
  > type g(T) = struct { T v; };
  > int y __attribute__((aligned(sizeof(g))));
  > EOF
  $ ./golden.exe bare.tc
  bare.tc:2: `g` in the arguments of an attribute denotes a generic, which lowering writes under a name of its own, but it leaves the arguments as written (design 13.5) [TC0046]
  [1]
  $ printf 'int y __attribute__((aligned(_Alignof(option(int)))));\n' \
  >   > universe.tc
  $ ./golden.exe universe.tc
  universe.tc:1: `option` in the arguments of an attribute denotes a universe name, which lowering writes under a name of its own, but it leaves the arguments as written (design 13.5) [TC0046]
  [1]
  $ cat > hidden.tc <<'EOF'
  > int option;
  > int y __attribute__((aligned(sizeof(option))));
  > EOF
  $ ./golden.exe hidden.tc
  # 1 "hidden.tc"
  int option;
  int y __attribute__((aligned(sizeof(option))));
  $ cat > c_word.tc <<'EOF'
  > type open(T) = struct { T v; };
  > # 1 "c.h" 1
  > enum __attribute__((enum_extensibility(open))) k { K };
  > EOF
  $ ./golden.exe c_word.tc
  # 1 "c_word.tc"
  
  # 1 "c_word.tc"
  
  # 1 "c_word.tc"
  
  # 1 "c.h" 1
  enum __attribute__((enum_extensibility(open))) k { K };

A generic claims every name that begins with its own name and `__`, as
an ordinary identifier and as a tag, in every scope and in C text as
well, whichever comes first (design 10.3): the names of its instances
are among them, and lowering writes them wherever an instance is used.
An enumerator of a block would otherwise be what the constructor of
option(int) lowers to.

  $ cat > claim_enumerator.tc <<'EOF'
  > option(int) f(void) { enum { option__i_Some = 0 }; return Some(123); }
  > EOF
  $ ./golden.exe claim_enumerator.tc
  claim_enumerator.tc:1: the name `option__i_Some` is declared, but the generic `option` claims every name that begins with its own name and `__` for its instances (design 10.1 rule 6) [TC0004]
  [1]
  $ cat > claim_typedef.tc <<'EOF'
  > type box(T) = struct { T v; };
  > void g(void) { typedef int box__i; }
  > EOF
  $ ./golden.exe claim_typedef.tc
  claim_typedef.tc:2: the name `box__i` is declared, but the generic `box` claims every name that begins with its own name and `__` for its instances (design 10.1 rule 6) [TC0004]
  [1]
  $ cat > claim_tag.i <<'EOF'
  > # 1 "claim_tag.tc"
  > # 1 "claim_tag.h" 1
  > void g(struct option__i_tag *p);
  > EOF
  $ ./golden.exe claim_tag.i
  claim_tag.h:1: the tag `option__i_tag` is named, but the generic `option` claims every name that begins with its own name and `__` for its instances (design 10.1 rule 6) [TC0004]
  [1]
  $ cat > claim_before.tc <<'EOF'
  > int box__i;
  > type box(T) = struct { T v; };
  > EOF
  $ ./golden.exe claim_before.tc
  claim_before.tc:2: the generic `box` claims every name that begins with its own name and `__` for its instances, and this scope declares `box__i` already (design 10.1 rule 6) [TC0004]
  [1]

A tag declared before is refused as well, and the message names the
name of the space that the scope declares first.

  $ cat > claim_tag_before.tc <<'EOF'
  > struct box__z;
  > int box__a;
  > type box(T) = struct { T v; };
  > EOF
  $ ./golden.exe claim_tag_before.tc
  claim_tag_before.tc:3: the generic `box` claims every name that begins with its own name and `__` for its instances, and this scope declares `box__z` already (design 10.1 rule 6) [TC0004]
  [1]

A name whose part before its first `__` is no generic is no claimed
name.

  $ cat > claim_other.tc <<'EOF'
  > type box(T) = struct { T v; };
  > int boxes__i, box_i, __box__i;
  > EOF
  $ ./golden.exe claim_other.tc
  # 1 "claim_other.tc"
  
  # 1 "claim_other.tc"
  
  # 1 "claim_other.tc"
  
  int boxes__i, box_i, __box__i;

A declaration of the generic's name in a block does not end the claim:
the constructor of the return type is still written there.

  $ cat > claim_hidden.tc <<'EOF'
  > option(int) f(void) { int option; enum { option__i_None = 1 }; return None; }
  > EOF
  $ ./golden.exe claim_hidden.tc
  claim_hidden.tc:1: the name `option__i_None` is declared, but the generic `option` claims every name that begins with its own name and `__` for its instances (design 10.1 rule 6) [TC0004]
  [1]

The typedef of a type argument spells the one name of an untagged type
that the argument names, and it reads that name where it stands as at
the declaration that gives the type the name (design 13.5): a
declaration of the name with an attribute between the two is refused,
though the argument's own declaration is exact.

  $ cat > spelled.tc <<'EOF'
  > typedef struct { int x[4]; } s;
  > typedef s *p;
  > typedef s s __attribute__((aligned(16)));
  > option(p) o;
  > EOF
  $ ./golden.exe spelled.tc
  spelled.tc:4: in `typedef s *__tc_arg__P1s;`, which lowering writes for this application: the declaration of 's' at spelled.tc:3, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses (design 13.5) [TC0044]
  [1]

The one name is that of the first declarator that gives it, as a later
one in the same declaration may add an attribute.

  $ cat > spelled_twice.tc <<'EOF'
  > typedef struct { int x[4]; } n, *q, n __attribute__((aligned(16)));
  > option(q) o;
  > EOF
  $ ./golden.exe spelled_twice.tc
  spelled_twice.tc:2: in `typedef n *__tc_arg__P1n;`, which lowering writes for this application: the declaration of 'n' at spelled_twice.tc:1, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses (design 13.5) [TC0044]
  [1]

The declarator that gives the one name may hold the attribute itself,
which no declaration of the argument shows.

  $ cat > spelled_own.tc <<'EOF'
  > typedef struct { int x[4]; } s __attribute__((aligned(16))), *p;
  > option(p) o;
  > EOF
  $ ./golden.exe spelled_own.tc
  spelled_own.tc:2: in `typedef s *__tc_arg__P1s;`, which lowering writes for this application: the declaration of 's' at spelled_own.tc:1 gives it a type that may hold an attribute or `typeof` of an expression, which the text that lowering writes would carry (design 13.5) [TC0044]
  [1]
