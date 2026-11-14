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
  twice.tc:2: `t` is declared twice in one scope, and one of them is a type declaration (design 3.1 rule 5)
  [1]
  $ printf 'type t = t *;\n' > own.tc
  $ ./golden.exe own.tc
  own.tc:1: `t` is used in its own definition, which is not a structure or union specifier (design 3.1 rule 2)
  [1]
  $ printf 'type pair = struct { int a; };\nstruct pair { int b; };\n' > tag.tc
  $ ./golden.exe tag.tc
  tag.tc:2: the tag `pair` is declared again, as a type declaration claims it (design 10.2)
  [1]
  $ printf 'type node;\nstruct node *p;\n' > named.tc
  $ ./golden.exe named.tc
  named.tc:2: the tag `node` is not available to Type-C text, as a type declaration claims it (design 10.2)
  [1]
  $ printf 'int __tc_x;\n' > generated.tc
  $ ./golden.exe generated.tc
  generated.tc:1: `__tc_x` begins with `__tc_`, which is reserved for the names that typec generates (design 2.3)
  [1]

The constructs of later work packages are refused with the package that
implements them.

  $ printf 'type e = | A | B;\n' > variant.tc
  $ ./golden.exe variant.tc
  variant.tc:1: variants are not implemented yet (design 3.2; work package 1.2)
  [1]
  $ printf 'type d = distinct int;\n' > distinct.tc
  $ ./golden.exe distinct.tc
  distinct.tc:1: distinct types are not implemented yet (design 3.4; work package 1.4)
  [1]
  $ printf 'type box(T) = struct { T value; };\n' > generic.tc
  $ ./golden.exe generic.tc
  generic.tc:1: type parameters are not implemented yet (design 3.5; work package 2.1)
  [1]
  $ printf 'void f(void) { defer f(); }\n' > defer.tc
  $ ./golden.exe defer.tc
  defer.tc:1: `defer` is not implemented yet (design 6; work package 2.5)
  [1]
  $ printf 'int f(void) { return result; }\n' > universe.tc
  $ ./golden.exe universe.tc
  universe.tc:1: `result` is a universe name that typec does not implement yet (design 3.6; work package 2.3)
  [1]
