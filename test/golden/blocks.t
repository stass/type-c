SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Clang's block literals are C text only (design 13.3): typec does not
type the body of one, so the Type-C constructs that typing lowers, a
type declaration, a match and a constructor, could not be lowered there.
Type-C text that writes a block literal, or that is written inside one,
is refused at its first token.

  $ cat > declaration.tc <<'EOF'
  > void f(void) {
  >   void (^b)(void) = ^{ type x = | a; };
  >   b();
  > }
  > EOF
  $ ./golden.exe declaration.tc
  declaration.tc:2: error: a block literal is C text only, so Type-C text cannot write one or be included in one [block-literal]
  [1]

  $ cat > match.tc <<'EOF'
  > type e = | A | B(int i);
  > int f(e v) {
  >   int (^b)(void) = ^(void) {
  >     match (v) { case B(i): return i; default: return 0; }
  >   };
  >   return b();
  > }
  > EOF
  $ ./golden.exe match.tc
  match.tc:3: error: a block literal is C text only, so Type-C text cannot write one or be included in one [block-literal]
  [1]

  $ cat > constructor.tc <<'EOF'
  > type e = | A | B(int i);
  > e f(void) {
  >   e (^b)(void) = ^{ return B(1); };
  >   return b();
  > }
  > EOF
  $ ./golden.exe constructor.tc
  constructor.tc:3: error: a block literal is C text only, so Type-C text cannot write one or be included in one [block-literal]
  [1]

A block literal in C text keeps its tokens, also in a unit of Type-C
text; Type-C text written inside one, as through an include, is refused
at its first token.

  $ cat > header.tc <<'EOF'
  > type e = | A | B(int i);
  > # 1 "header.h" 1
  > static int twice(int x) { int (^b)(int) = ^(int y) { return 2 * y; }; return b(x); }
  > # 2 "header.tc" 2
  > e f(void) { return B(twice(1)); }
  > EOF
  $ ./golden.exe header.tc | grep 'static int twice'
  static int twice(int x) { int (^b)(int) = ^(int y) { return 2 * y; }; return b(x); }

  $ cat > inside.tc <<'EOF'
  > # 1 "inside.tc"
  > # 1 "header.h" 1
  > static int (^b)(void) = ^{
  > # 1 "inside.tci" 1
  >   type x = | a;
  > # 3 "header.h" 2
  >   return 0; };
  > # 2 "inside.tc" 2
  > EOF
  $ ./golden.exe inside.tc
  inside.tci:1: error: a block literal is C text only, so Type-C text cannot write one or be included in one [block-literal]
  [1]
