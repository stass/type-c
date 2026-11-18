SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Type declarations (design 3.1) and their lowering (design 10.2, 13.5).
Each source is preprocessed text, as the backend writes it for -E; a
file named *.tc holds Type-C text.

An alias becomes a typedef at its own point, with the name where the
declarator of its type name would put it. The edits carry line markers,
so the C keeps the lines of the source.

  $ cat > alias.tc <<'EOF'
  > type id = unsigned int;
  > type handler = void (*)(int);
  > handler handlers[2];
  > EOF
  $ ./golden.exe alias.tc
  # 1 "alias.tc"
  
  # 1 "alias.tc"
  typedef
  # 1 "alias.tc"
   unsigned int
  # 1 "alias.tc"
  id
  # 1 "alias.tc"
  ;
  
  # 2 "alias.tc"
  typedef
  # 2 "alias.tc"
   void (*
  # 2 "alias.tc"
  handler
  # 2 "alias.tc"
  )(int);
  handler handlers[2];

A forward declaration and a definition that is a structure specifier
declare the structure tag first, in the scope of the declaration, and
the specifier without a tag of its own takes the declared name.

  $ cat > records.tc <<'EOF'
  > type node;
  > type list = struct {
  >   int value;
  >   list *next;
  > };
  > type tree = union branch { tree *left; node *leaf; };
  > EOF
  $ ./golden.exe records.tc
  # 1 "records.tc"
  
  # 1 "records.tc"
  struct node; typedef struct node node;
  # 1 "records.tc"
  
  
  # 2 "records.tc"
  struct list; typedef struct list list;
  # 2 "records.tc"
   struct 
  # 2 "records.tc"
  list
  # 2 "records.tc"
  {
    int value;
    list *next;
  };
  
  # 6 "records.tc"
  union branch; typedef union branch tree;
  # 6 "records.tc"
   union branch { tree *left; node *leaf; };

A type declaration in a block is lowered in place.

  $ cat > block.tc <<'EOF'
  > int f(void) {
  >   type small = short;
  >   small s = 1;
  >   return s;
  > }
  > EOF
  $ ./golden.exe block.tc
  # 1 "block.tc"
  int f(void) {
    
  # 2 "block.tc"
  typedef
  # 2 "block.tc"
   short
  # 2 "block.tc"
  small
  # 2 "block.tc"
  ;
    small s = 1;
    return s;
  }

Text without a Type-C construct is emitted as it was read, in Type-C
text and in C text, where try and defer are identifiers.

  $ cat > plain.tc <<'EOF'
  > typedef int type;
  > type x;
  > int result = 1;
  > EOF
  $ ./golden.exe plain.tc
  # 1 "plain.tc"
  typedef int type;
  type x;
  int result = 1;
  $ cat > plain.c <<'EOF'
  > int try, defer;
  > EOF
  $ ./golden.exe plain.c
  # 1 "plain.c"
  int try, defer;

Each rule that a type declaration breaks is an error at the token that
breaks it, naming the rule.

  $ printf 'type t = int;\ntype t = long;\n' > twice.tc
  $ ./golden.exe twice.tc
  twice.tc:2: error: `t` is declared twice in one scope, and one of them is a type declaration [type-redeclaration]
  [1]
  $ printf 'type t = t *;\n' > own.tc
  $ ./golden.exe own.tc
  own.tc:1: error: `t` is used in its own definition, which is not a structure or union specifier [self-reference]
  [1]
  $ printf 'type t = int[t];\n' > own_operand.tc
  $ ./golden.exe own_operand.tc
  own_operand.tc:1: error: `t` is used in its own definition, which is not a structure or union specifier [self-reference]
  [1]
  $ printf 'type pair = struct { int a; };\nstruct pair { int b; };\n' > tag.tc
  $ ./golden.exe tag.tc
  tag.tc:2: error: the tag `pair` is declared again, as a type declaration claims it [claimed-name]
  [1]
  $ printf 'type node;\nstruct node *p;\n' > named.tc
  $ ./golden.exe named.tc
  named.tc:2: error: the tag `node` is not available to Type-C text, as a type declaration claims it [claimed-name]
  [1]
  $ printf 'int __tc_x;\n' > generated.tc
  $ ./golden.exe generated.tc
  generated.tc:1: error: `__tc_x` begins with `__tc_`, which is reserved for the names that typec generates [generated-name]
  [1]

A variant (design 10.1) becomes the structure and typedef, the
enumeration of its tags and the structure of a tag and a union of the
fields of each constructor. The fields keep their tokens and lines;
the definition that completes a forward declaration declares no second
typedef.

  $ cat > variant.tc <<'EOF'
  > type expr;
  > type expr =
  >     | Number(long value)
  >     | Nil
  >     | Add(expr *left,
  >           expr *right);
  > EOF
  $ ./golden.exe variant.tc
  # 1 "variant.tc"
  
  # 1 "variant.tc"
  struct expr; typedef struct expr expr;
  # 1 "variant.tc"
  
  
  # 2 "variant.tc"
  
  # 2 "variant.tc"
   
  # 2 "variant.tc"
  enum expr_tag { expr_Number, expr_Nil, expr_Add, __tc_tag_max__expr_tag = 2147483647 }; struct expr { enum expr_tag tag; union {
  # 2 "variant.tc"
  
      
  # 3 "variant.tc"
  struct {
  # 3 "variant.tc"
  long value
  # 3 "variant.tc"
  ; } Number;
  # 3 "variant.tc"
  
      
  # 4 "variant.tc"
  
  # 4 "variant.tc"
  
      
  # 5 "variant.tc"
  struct {
  # 5 "variant.tc"
  expr *left
  # 5 "variant.tc"
  ;
  # 5 "variant.tc"
  
            expr *right
  # 6 "variant.tc"
  ; } Add;
  # 6 "variant.tc"
  
  # 6 "variant.tc"
  } u; };
  # 6 "variant.tc"
  

Derived names, field types and constructor names are checked.

  $ printf 'type e = | A | A;\n' > constructors.tc
  $ ./golden.exe constructors.tc
  constructors.tc:1: error: `A` names two constructors of one variant [duplicate-constructor]
  [1]
  $ printf 'type e = | try;\n' > try.tc
  $ ./golden.exe try.tc
  try.tc:1: error: `try` cannot name a constructor, as it is a word of Type-C [reserved-constructor]
  [1]
  $ printf 'type e = | A | defer;\n' > defer.tc
  $ ./golden.exe defer.tc
  defer.tc:1: error: `defer` cannot name a constructor, as it is a word of Type-C [reserved-constructor]
  [1]
  $ printf 'type e = | str(int x);\n' > str.tc
  $ ./golden.exe str.tc
  str.tc:1: error: `str` cannot name a constructor, as it is a universe name [reserved-constructor]
  [1]
  $ printf 'type e = | result;\n' > result.tc
  $ ./golden.exe result.tc
  result.tc:1: error: `result` cannot name a constructor, as it is a universe name [reserved-constructor]
  [1]
  $ printf 'void f(void) {\n  type e;\n  type e = | slice;\n}\n' > block.tc
  $ ./golden.exe block.tc
  block.tc:3: error: `slice` cannot name a constructor, as it is a universe name [reserved-constructor]
  [1]
  $ printf 'int e_A;\ntype e = | A;\n' > derived.tc
  $ ./golden.exe derived.tc
  derived.tc:2: error: the variant `e` claims the enumerator `e_A`, which this scope declares already [claimed-name]
  [1]
  $ for decl in 'type _Static = | assert;' 'type __x = struct { int a; };' \
  >     'void f(void) { type _Thread = | local; }' 'type _ = | attribute__;' \
  >     'type __x = int;' 'type _Y = distinct int;' \
  >     'type __s = struct t { int a; };' 'type __v;' \
  >     'type __g(A) = struct { A a; };' 'type a__b = int;' 'type a_ = int;' \
  >     'type vector_ = | i;' 'void f(void) { type _X = int; }' \
  >     'type _x = int;' 'type _v;' 'type _x_lower = | A | B;' \
  >     'type _A_ = int;' 'void f(void) { { type _A = int; } }'; do
  >   printf '%s\n' "$decl" > reserved.tc
  >   ./golden.exe reserved.tc
  > done
  reserved.tc:1: error: `_Static` cannot name a type declaration, as it begins with `_` and an uppercase letter [reserved-type-name]
  reserved.tc:1: error: `__x` cannot name a type declaration, as it contains `__` [reserved-type-name]
  reserved.tc:1: error: `_Thread` cannot name a type declaration, as it begins with `_` and an uppercase letter [reserved-type-name]
  reserved.tc:1: error: `_` cannot name a type declaration, as it ends with `_` [reserved-type-name]
  reserved.tc:1: error: `__x` cannot name a type declaration, as it contains `__` [reserved-type-name]
  reserved.tc:1: error: `_Y` cannot name a type declaration, as it begins with `_` and an uppercase letter [reserved-type-name]
  reserved.tc:1: error: `__s` cannot name a type declaration, as it contains `__` [reserved-type-name]
  reserved.tc:1: error: `__v` cannot name a type declaration, as it contains `__` [reserved-type-name]
  reserved.tc:1: error: `__g` cannot name a type declaration, as it contains `__` [reserved-type-name]
  reserved.tc:1: error: `a__b` cannot name a type declaration, as it contains `__` [reserved-type-name]
  reserved.tc:1: error: `a_` cannot name a type declaration, as it ends with `_` [reserved-type-name]
  reserved.tc:1: error: `vector_` cannot name a type declaration, as it ends with `_` [reserved-type-name]
  reserved.tc:1: error: `_X` cannot name a type declaration, as it begins with `_` and an uppercase letter [reserved-type-name]
  reserved.tc:1: error: `_x` cannot name a type declaration at file scope, as it begins with `_` [reserved-type-name]
  reserved.tc:1: error: `_v` cannot name a type declaration at file scope, as it begins with `_` [reserved-type-name]
  reserved.tc:1: error: `_x_lower` cannot name a type declaration at file scope, as it begins with `_` [reserved-type-name]
  reserved.tc:1: error: `_A_` cannot name a type declaration, as it ends with `_` [reserved-type-name]
  reserved.tc:1: error: `_A` cannot name a type declaration, as it begins with `_` and an uppercase letter [reserved-type-name]
  [1]
  $ for decl in 'type e = | _BitInt(int x);' 'type e = | __A;' \
  >     'type e = | A__B;' 'type e = | _a;' 'type f = | _a(int y);' \
  >     'void f(void) { type e = | _a; }' \
  >     'type e = | A(int __x);' 'type e = | A(int _Y);' \
  >     'type e = | A(int a, int *_P);' 'type e = | A(int (*__f)(int));'; do
  >   printf '%s\n' "$decl" > member.tc
  >   ./golden.exe member.tc
  > done
  member.tc:1: error: `_BitInt` cannot name a constructor, as it begins with `_` [reserved-constructor]
  member.tc:1: error: `__A` cannot name a constructor, as it begins with `_` [reserved-constructor]
  member.tc:1: error: `A__B` cannot name a constructor, as it contains `__` [reserved-constructor]
  member.tc:1: error: `_a` cannot name a constructor, as it begins with `_` [reserved-constructor]
  member.tc:1: error: `_a` cannot name a constructor, as it begins with `_` [reserved-constructor]
  member.tc:1: error: `_a` cannot name a constructor, as it begins with `_` [reserved-constructor]
  member.tc:1: error: `__x` cannot name a field, as C reserves it for any use [reserved-constructor]
  member.tc:1: error: `_Y` cannot name a field, as C reserves it for any use [reserved-constructor]
  member.tc:1: error: `_P` cannot name a field, as C reserves it for any use [reserved-constructor]
  member.tc:1: error: `__f` cannot name a field, as C reserves it for any use [reserved-constructor]
  [1]
  $ printf '%s\n' 'type f = | A(int _y) | B_;' \
  >   'void g(void) { type _x_lower = | A | B; type _y = int; type _1 = f; }' \
  >   'void h(void) { { type _x = | a; } }' \
  >   > usable.tc
  $ ./golden.exe usable.tc > usable.c
  $ printf 'type e = | A(e inner);\n' > recursive.tc
  $ ./golden.exe recursive.tc
  recursive.tc:1: error: the field 'inner' of 'A' is not a value type: it is not a complete object type [field-type]
  [1]
  $ printf 'type e = | A(int values[4]);\n' > array.tc
  $ ./golden.exe array.tc
  array.tc:1: error: the field 'values' of 'A' is not a value type: it is an array; wrap it in a struct, which is one [field-type]
  [1]
  $ printf 'type e = | A(__builtin_va_list ap);\n' > va_list.tc
  $ ./golden.exe va_list.tc
  va_list.tc:1: error: the field 'ap' of 'A' is not a value type: it is a va_list, which is an array on some targets [field-type]
  [1]

Type-C text takes a variant only whole (design 3.2 rule 6): no member
access, no comparison and no cast to or from one.

  $ printf 'type e = | A;\nint f(e v) { return v.tag; }\n' > member.tc
  $ ./golden.exe member.tc
  member.tc:2: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  [1]
  $ printf 'type e = | A;\nint f(e v, e w) { return v == w; }\n' > equal.tc
  $ ./golden.exe equal.tc
  equal.tc:2: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching; a single-pattern test, 'if (case Pattern = value)', tells which constructor made it [variant-operation]
  [1]
  $ printf 'type e = | A;\nint f(e v) { switch (v) { default: return 0; } }\n' > switch.tc
  $ ./golden.exe switch.tc
  switch.tc:2: error: the controlling expression of a switch is not an integer (C11 6.8.4.2p1); a variant is taken apart with match
  [1]
  $ cat > tested.tc <<'EOF'
  > type e = | A | B(int x);
  > int f(e v) { if (case A = v) return 1; match (v) { case A: return 2; case B(x): return x; } }
  > EOF
  $ ./golden.exe tested.tc > /dev/null
  $ printf 'type e = | A;\nvoid f(e v) { (void)(long)v; }\n' > cast.tc
  $ ./golden.exe cast.tc
  cast.tc:2: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  [1]
  $ printf 'type e = | A;\ne f(void) { return (e)0; }\n' > cast_to.tc
  $ ./golden.exe cast_to.tc
  cast_to.tc:2: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  [1]

The member path of offsetof, which expands to __builtin_offsetof, may
end at a variant but not reach into one.

  $ cat > offsetof.h <<'EOF'
  > type e = | A | B(int x);
  > struct t { e v; };
  > struct s { e v; int n; struct t a[2]; e w[2];
  >   const struct { struct t q; }; e *p; };
  > EOF
  $ for path in v.tag v.u.B.x a[0].v.tag w[1].tag q.v.tag p[1].tag; do
  >   cat offsetof.h > offsetof.tc
  >   printf 'unsigned long f(void) { return __builtin_offsetof(struct s, %s); }\n' "$path" >> offsetof.tc
  >   ./golden.exe offsetof.tc
  > done
  offsetof.tc:5: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  offsetof.tc:5: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  offsetof.tc:5: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  offsetof.tc:5: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  offsetof.tc:5: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  offsetof.tc:5: error: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and matching [variant-operation]
  [1]
  $ cat offsetof.h > offsetof.tc
  $ cat >> offsetof.tc <<'EOF'
  > unsigned long f(void) {
  >   return __builtin_offsetof(struct s, v) + __builtin_offsetof(struct s, n)
  >     + __builtin_offsetof(struct s, a[1].v) + __builtin_offsetof(struct s, w[1]);
  > }
  > # 1 "e.h" 1
  > static unsigned long g(void) { return __builtin_offsetof(struct s, a[1].v.u.B.x); }
  > EOF
  $ ./golden.exe offsetof.tc > offsetof.c || cat offsetof.c

Every operation that does not open the variant takes it: the branches
of ?:, parentheses, the comma operator, an expression statement, a cast
to void, a _Generic selection and {0} for a structure that starts with
a variant.

  $ cat > whole.tc <<'EOF'
  > type e = | A | B(int x);
  > e g(void);
  > struct s { e v; int n; };
  > e f(int c, e v, e w) {
  >   e r = c ? v : w;
  >   r = (v);
  >   r = (g(), v);
  >   v;
  >   (void)v;
  >   struct s z = {0};
  >   (void)z;
  >   return _Generic(v, e: r, default: w);
  > }
  > EOF
  $ ./golden.exe whole.tc > whole.c || cat whole.c

C text, here a header that the Type-C file includes, may use the
structure that a variant lowers to (design 10.6).

  $ cat > header.tc <<'EOF'
  > type e = | A | B(int i);
  > # 1 "e.h" 1
  > static int is_b(e v) { return v.tag == e_B; }
  > # 3 "header.tc" 2
  > int f(e v) { return is_b(v); }
  > EOF
  $ ./golden.exe header.tc
  # 1 "header.tc"
  
  # 1 "header.tc"
  struct e; typedef struct e e;
  # 1 "header.tc"
   
  # 1 "header.tc"
  enum e_tag { e_A, e_B, __tc_tag_max__e_tag = 2147483647 }; struct e { enum e_tag tag; union {
  # 1 "header.tc"
   
  # 1 "header.tc"
  
  # 1 "header.tc"
   
  # 1 "header.tc"
  struct {
  # 1 "header.tc"
  int i
  # 1 "header.tc"
  ; } B;
  # 1 "header.tc"
  
  # 1 "header.tc"
  } u; };
  # 1 "header.tc"
  
  # 1 "e.h" 1
  static int is_b(e v) { return v.tag == e_B; }
  # 3 "header.tc" 2
  int f(e v) { return is_b(v); }

A defer statement lowers to a copy of its statement at each exit of its
scope (design 13.5), here the end of the body.

  $ printf 'void f(void) { defer f(); }\n' > defer.tc
  $ ./golden.exe defer.tc
  # 1 "defer.tc"
  void f(void) { 
  # 1 "defer.tc"
  
  # 1 "defer.tc"
   
  # 1 "defer.tc"
  { f ( ) ; }
  # 1 "defer.tc"
  }

An operator of design section 8 is a universe name that names no type,
so no declaration begins with one.

  $ printf 'slice_sub s;\n' > universe.tc
  $ ./golden.exe universe.tc
  universe.tc:1: error: expected a declaration, found `slice_sub`
  [1]

A distinct type lowers to the typedef of its representation (design
10.2); its casts are kept. Type-C text refuses the operations and the
implicit conversions that design 3.4 leaves out, each at its operation.

  $ printf 'type d = distinct int *;\nd x = (d)0;\n' > distinct.tc
  $ ./golden.exe distinct.tc | grep -v '^#' | grep .
  typedef
   int *
  d
  ;
  d x = (d)0;
  $ printf 'type d = distinct int;\nint f(d a) { return a + 1; }\n' > add.tc
  $ ./golden.exe add.tc
  add.tc:2: error: '+' is not defined on the distinct type 'd'; cast to 'int' [distinct-operation]
  [1]
  $ printf 'type idx = distinct int;\nint f(idx i) { i++; return ((int)i); }\n' > increment.tc
  $ ./golden.exe increment.tc
  increment.tc:2: error: '++' is not defined on the distinct type 'idx'; cast to 'int' [distinct-operation]
  [1]
  $ printf 'type idx = distinct int;\nint f(int *a, idx i) { return (a[i]); }\n' > index.tc
  $ ./golden.exe index.tc
  index.tc:2: error: an index may not be of the distinct type 'idx'; cast it to 'int' [distinct-operation]
  [1]
  $ printf 'type idx = distinct int;\nint f(idx i, idx j) { return (i < j); }\n' > less.tc
  $ ./golden.exe less.tc
  less.tc:2: error: '<' is not defined on the distinct type 'idx'; cast to 'int' [distinct-operation]
  [1]
  $ printf 'type d = distinct int;\nd f(int a) { return a; }\n' > convert.tc
  $ ./golden.exe convert.tc
  convert.tc:2: error: a value of type 'int' does not convert to 'd' without a cast [distinct-conversion]
  [1]
  $ printf 'type d = distinct int;\nint f(d a, int b) { return a == b; }\n' > mixed.tc
  $ ./golden.exe mixed.tc
  mixed.tc:2: error: the operands are not both of the distinct type 'd' [distinct-operation]
  [1]
  $ printf 'struct s;\ntype d = distinct struct s;\n' > over.tc
  $ ./golden.exe over.tc
  over.tc:2: error: the distinct type 'd' is not over an unqualified arithmetic or pointer type [distinct-base]
  [1]

An atomic builtin that only moves the value of a distinct object takes
its other value operands of that distinct type; one that does arithmetic
on the object refuses it (design 3.4).

  $ cat > atomic.tc <<'EOF'
  > type id = distinct unsigned;
  > void f(id *p) { (void)__atomic_fetch_add(p, 1, 5); }
  > EOF
  $ ./golden.exe atomic.tc
  atomic.tc:2: error: '__atomic_fetch_add' is not defined on the distinct type 'id'; cast to 'unsigned int' [distinct-operation]
  [1]
  $ cat > exchange.tc <<'EOF'
  > type id = distinct unsigned;
  > type bid = distinct unsigned;
  > _Bool f(id *p, id *e, bid d) {
  >   return __atomic_compare_exchange_n(p, e, d, 0, 5, 5);
  > }
  > EOF
  $ ./golden.exe exchange.tc
  exchange.tc:4: error: a value of type 'bid' does not convert to 'id' without a cast [distinct-conversion]
  [1]
  $ cat > qualified.tc <<'EOF'
  > type id = distinct unsigned;
  > unsigned f(volatile id *p) { return __atomic_load_n(p, 5) * 2u; }
  > EOF
  $ ./golden.exe qualified.tc
  qualified.tc:2: error: '*' is not defined on the distinct type 'id'; cast to 'unsigned int' [distinct-operation]
  [1]
  $ cat > load.tc <<'EOF'
  > type id = distinct unsigned;
  > void f(id *p, unsigned *r) { __atomic_load(p, r, 5); }
  > EOF
  $ ./golden.exe load.tc
  load.tc:2: error: a value of type 'unsigned int *' does not convert to 'id *' without a cast [distinct-conversion]
  [1]
  $ cat > store.tc <<'EOF'
  > type id = distinct unsigned;
  > void f(id *p) { __atomic_store_n(p, 0, 5); }
  > EOF
  $ ./golden.exe store.tc
  store.tc:2: error: a value of type 'int' does not convert to 'id' without a cast [distinct-conversion]
  [1]

The enumeration of the tags ends with a hidden enumerator of the value
INT_MAX of the target, which a constructor's tag may not reach. Only an
int of 16 bits makes that reachable: there INT_MAX is 32767, and a
variant of 32768 constructors is refused.

  $ cat > one.tc <<'EOF'
  > type one = | A;
  > EOF
  $ ./golden.exe --int16 one.tc | grep enum
  enum one_tag { one_A, __tc_tag_max__one_tag = 32767 }; struct one { enum one_tag tag;
  $ awk 'BEGIN { printf "type v ="
  >   for (i = 0; i < 32768; i++) printf " | C%d", i
  >   print ";" }' > count.tc
  $ ./golden.exe --int16 count.tc
  count.tc:1: error: a variant has 32768 constructors, more than INT_MAX (32767) on this target [constructor-count]
  [1]
