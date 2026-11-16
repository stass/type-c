SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The words `try` and `defer` of Type-C text (design 2.3). A declaration
of the same identifier hides each from that point, under C's scope
rules, so C that names something `try` or `defer` keeps its meaning in
Type-C text. Each source is preprocessed text, as the backend writes it
for -E; a file named *.tc holds Type-C text.

A function `try` at file scope, defined and called.

  $ cat > function.tc <<'EOF'
  > static int try(char *hex, int err) { return hex != 0 && err == 0; }
  > int main(void) { return try("00", 0); }
  > EOF
  $ ./golden.exe function.tc
  # 1 "function.tc"
  static int try(char *hex, int err) { return hex != 0 && err == 0; }
  int main(void) { return try("00", 0); }

A parameter `try`, and an object `defer` in a block.

  $ cat > local.tc <<'EOF'
  > static int spill(int try) { return try + 1; }
  > void f(void) { int defer = spill(0); defer++; }
  > EOF
  $ ./golden.exe local.tc
  # 1 "local.tc"
  static int spill(int try) { return try + 1; }
  void f(void) { int defer = spill(0); defer++; }

A typedef and an enumerator hide them as well.

  $ cat > kinds.tc <<'EOF'
  > typedef int try;
  > enum { defer };
  > try f(void) { try x = defer; return x; }
  > EOF
  $ ./golden.exe kinds.tc
  # 1 "kinds.tc"
  typedef int try;
  enum { defer };
  try f(void) { try x = defer; return x; }

A tag, a member and a label have name spaces of their own, where the
words are names wherever they stand.

  $ cat > spaces.tc <<'EOF'
  > struct try { int defer; };
  > int f(struct try *p) { goto defer; defer: return p->defer; }
  > EOF
  $ ./golden.exe spaces.tc
  # 1 "spaces.tc"
  struct try { int defer; };
  int f(struct try *p) { goto defer; defer: return p->defer; }

Outside the scope of the declaration, `try` is the Type-C operator:
after the block that declares it ends, and before a file-scope
declaration of it begins. A parameter `try` does not hide `defer`.

  $ cat > block.tc <<'EOF'
  > int f(void);
  > int g(void) { { int try = 0; try++; } return try f(); }
  > EOF
  $ ./golden.exe block.tc
  block.tc:2: `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]
  $ cat > before.tc <<'EOF'
  > int f(void);
  > int g(void) { return try f(); }
  > int try;
  > EOF
  $ ./golden.exe before.tc
  before.tc:2: `try` is not implemented yet (design 5.1; work package 2.4) [TC0023]
  [1]
  $ printf 'void f(int try) { defer f(try); }\n' > defer.tc
  $ ./golden.exe defer.tc
  defer.tc:1: `defer` is not implemented yet (design 6; work package 2.5) [TC0023]
  [1]

`_Defer` is a keyword in all text, where `defer` is hidden as well.

  $ printf 'void f(void) { int defer = 0; _Defer f(); }\n' > spelling.tc
  $ ./golden.exe spelling.tc
  spelling.tc:1: `_Defer` is not implemented yet (design 6; work package 2.5) [TC0023]
  [1]

C text, here a header that the Type-C file includes, may declare `try`,
which hides the operator in the Type-C text after it.

  $ cat > header.tc <<'EOF'
  > int f(void);
  > # 1 "try.h" 1
  > int try(int err);
  > # 2 "header.tc" 2
  > int f(void) { return try(0); }
  > EOF
  $ ./golden.exe header.tc
  # 1 "header.tc"
  int f(void);
  # 1 "try.h" 1
  int try(int err);
  # 2 "header.tc" 2
  int f(void) { return try(0); }
