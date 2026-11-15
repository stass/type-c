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
  typedef int type;
  type x;
  int result = 1;
  $ cat > plain.c <<'EOF'
  > int try, defer;
  > EOF
  $ ./golden.exe plain.c
  int try, defer;

Each rule that a type declaration breaks is an error at the token that
breaks it, naming the rule.

  $ printf 'type t = int;\ntype t = long;\n' > twice.tc
  $ ./golden.exe twice.tc
  twice.tc:2: `t` is declared twice in one scope, and one of them is a type declaration (design 3.1 rule 5) [TC0003]
  [1]
  $ printf 'type t = t *;\n' > own.tc
  $ ./golden.exe own.tc
  own.tc:1: `t` is used in its own definition, which is not a structure or union specifier (design 3.1 rule 2) [TC0002]
  [1]
  $ printf 'type t = int[t];\n' > own_operand.tc
  $ ./golden.exe own_operand.tc
  own_operand.tc:1: `t` is used in its own definition, which is not a structure or union specifier (design 3.1 rule 2) [TC0002]
  [1]
  $ printf 'type pair = struct { int a; };\nstruct pair { int b; };\n' > tag.tc
  $ ./golden.exe tag.tc
  tag.tc:2: the tag `pair` is declared again, as a type declaration claims it (design 10.1 rule 6) [TC0004]
  [1]
  $ printf 'type node;\nstruct node *p;\n' > named.tc
  $ ./golden.exe named.tc
  named.tc:2: the tag `node` is not available to Type-C text, as a type declaration claims it (design 10.1 rule 6) [TC0004]
  [1]
  $ printf 'int __tc_x;\n' > generated.tc
  $ ./golden.exe generated.tc
  generated.tc:1: `__tc_x` begins with `__tc_`, which is reserved for the names that typec generates (design 2.3) [TC0001]
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
  struct expr; typedef struct expr expr;
  # 1 "variant.tc"
  
  
  # 2 "variant.tc"
  enum expr_tag { expr_Number, expr_Nil, expr_Add }; struct expr { enum expr_tag tag; union {
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
  constructors.tc:1: `A` names two constructors of one variant (design 3.2 rule 2) [TC0005]
  [1]
  $ printf 'type e = | try;\n' > try.tc
  $ ./golden.exe try.tc
  try.tc:1: `try` cannot name a constructor, as it is a word of Type-C (design 3.2 rule 2) [TC0025]
  [1]
  $ printf 'type e = | A | defer;\n' > defer.tc
  $ ./golden.exe defer.tc
  defer.tc:1: `defer` cannot name a constructor, as it is a word of Type-C (design 3.2 rule 2) [TC0025]
  [1]
  $ printf 'type e = | str(int x);\n' > str.tc
  $ ./golden.exe str.tc
  str.tc:1: `str` cannot name a constructor, as it is a universe name (design 3.2 rule 2) [TC0025]
  [1]
  $ printf 'type e = | result;\n' > result.tc
  $ ./golden.exe result.tc
  result.tc:1: `result` cannot name a constructor, as it is a universe name (design 3.2 rule 2) [TC0025]
  [1]
  $ printf 'void f(void) {\n  type e;\n  type e = | slice;\n}\n' > block.tc
  $ ./golden.exe block.tc
  block.tc:3: `slice` cannot name a constructor, as it is a universe name (design 3.2 rule 2) [TC0025]
  [1]
  $ printf 'int e_A;\ntype e = | A;\n' > derived.tc
  $ ./golden.exe derived.tc
  derived.tc:2: the variant `e` claims the enumerator `e_A`, which this scope declares already (design 10.1 rule 6) [TC0004]
  [1]
  $ printf 'type e = | A(e inner);\n' > recursive.tc
  $ ./golden.exe recursive.tc
  recursive.tc:1: the field 'inner' of 'A' is not a complete object type, so it is not a value type (design 3.2 rule 4) [TC0006]
  [1]
  $ printf 'type e = | A(int values[4]);\n' > array.tc
  $ ./golden.exe array.tc
  array.tc:1: the field 'values' of 'A' is an array, which a struct can wrap, so it is not a value type (design 3.2 rule 4) [TC0006]
  [1]
  $ printf 'type e = | A(__builtin_va_list ap);\n' > va_list.tc
  $ ./golden.exe va_list.tc
  va_list.tc:1: the field 'ap' of 'A' is a va_list, which is an array on some targets, so it is not a value type (design 3.2 rule 4) [TC0006]
  [1]

Type-C text takes a variant only whole (design 3.2 rule 6): no member
access, no comparison and no cast to or from one.

  $ printf 'type e = | A;\nint f(e v) { return v.tag; }\n' > member.tc
  $ ./golden.exe member.tc
  member.tc:2: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and match (design 3.2 rule 6) [TC0007]
  [1]
  $ printf 'type e = | A;\nint f(e v, e w) { return v == w; }\n' > equal.tc
  $ ./golden.exe equal.tc
  equal.tc:2: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and match (design 3.2 rule 6) [TC0007]
  [1]
  $ printf 'type e = | A;\nvoid f(e v) { (void)(long)v; }\n' > cast.tc
  $ ./golden.exe cast.tc
  cast.tc:2: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and match (design 3.2 rule 6) [TC0007]
  [1]
  $ printf 'type e = | A;\ne f(void) { return (e)0; }\n' > cast_to.tc
  $ ./golden.exe cast_to.tc
  cast_to.tc:2: the variant 'e' takes no such operation; Type-C text reaches its tag and fields only through constructors and match (design 3.2 rule 6) [TC0007]
  [1]

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
  struct e; typedef struct e e; enum e_tag { e_A, e_B }; struct e { enum e_tag tag; union {
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

The constructs of later work packages are refused with the package that
implements them.

  $ printf 'type box(T) = struct { T value; };\n' > generic.tc
  $ ./golden.exe generic.tc
  generic.tc:1: type parameters are not implemented yet (design 3.5; work package 2.1) [TC0023]
  [1]
  $ printf 'void f(void) { defer f(); }\n' > defer.tc
  $ ./golden.exe defer.tc
  defer.tc:1: `defer` is not implemented yet (design 6; work package 2.5) [TC0023]
  [1]
  $ printf 'int f(void) { return result; }\n' > universe.tc
  $ ./golden.exe universe.tc
  universe.tc:1: `result` is a universe name that typec does not implement yet (design 3.6; work package 2.3) [TC0023]
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
  add.tc:2: a value of the distinct type 'd' takes no such operation; a cast to its underlying type crosses to it (design 3.4) [TC0011]
  [1]
  $ printf 'type d = distinct int;\nd f(int a) { return a; }\n' > convert.tc
  $ ./golden.exe convert.tc
  convert.tc:2: a value of type 'int' does not convert to 'd' without a cast (design 3.4) [TC0012]
  [1]
  $ printf 'type d = distinct int;\nint f(d a, int b) { return a == b; }\n' > mixed.tc
  $ ./golden.exe mixed.tc
  mixed.tc:2: the operands are not both of the distinct type 'd' (design 3.4) [TC0011]
  [1]
  $ printf 'struct s;\ntype d = distinct struct s;\n' > over.tc
  $ ./golden.exe over.tc
  over.tc:2: the distinct type 'd' is not over an unqualified arithmetic or pointer type (design 3.4) [TC0010]
  [1]

An atomic builtin that only moves the value of a distinct object takes
its other value operands of that distinct type; one that does arithmetic
on the object refuses it (design 3.4).

  $ cat > atomic.tc <<'EOF'
  > type id = distinct unsigned;
  > void f(id *p) { (void)__atomic_fetch_add(p, 1, 5); }
  > EOF
  $ ./golden.exe atomic.tc
  atomic.tc:2: a value of the distinct type 'id' takes no such operation; a cast to its underlying type crosses to it (design 3.4) [TC0011]
  [1]
  $ cat > exchange.tc <<'EOF'
  > type id = distinct unsigned;
  > type bid = distinct unsigned;
  > _Bool f(id *p, id *e, bid d) {
  >   return __atomic_compare_exchange_n(p, e, d, 0, 5, 5);
  > }
  > EOF
  $ ./golden.exe exchange.tc
  exchange.tc:4: a value of type 'bid' does not convert to 'id' without a cast (design 3.4) [TC0012]
  [1]
  $ cat > qualified.tc <<'EOF'
  > type id = distinct unsigned;
  > unsigned f(volatile id *p) { return __atomic_load_n(p, 5) * 2u; }
  > EOF
  $ ./golden.exe qualified.tc
  qualified.tc:2: a value of the distinct type 'id' takes no such operation; a cast to its underlying type crosses to it (design 3.4) [TC0011]
  [1]
  $ cat > load.tc <<'EOF'
  > type id = distinct unsigned;
  > void f(id *p, unsigned *r) { __atomic_load(p, r, 5); }
  > EOF
  $ ./golden.exe load.tc
  load.tc:2: a value of type 'unsigned int *' does not convert to 'id *' without a cast (design 3.4) [TC0012]
  [1]
  $ cat > store.tc <<'EOF'
  > type id = distinct unsigned;
  > void f(id *p) { __atomic_store_n(p, 0, 5); }
  > EOF
  $ ./golden.exe store.tc
  store.tc:2: a value of type 'int' does not convert to 'id' without a cast (design 3.4) [TC0012]
  [1]
