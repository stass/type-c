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
  block.tc:2: error: the operand of try is of type 'int', not a result type [try-operand]
  [1]
  $ cat > before.tc <<'EOF'
  > int f(void);
  > int g(void) { return try f(); }
  > int try;
  > EOF
  $ ./golden.exe before.tc
  before.tc:2: error: the operand of try is of type 'int', not a result type [try-operand]
  [1]
  $ printf 'void f(int try) { defer f(try); }\n' > defer.tc
  $ ./golden.exe defer.tc
  # 1 "defer.tc"
  void f(int try) { 
  # 1 "defer.tc"
  
  # 1 "defer.tc"
   
  # 1 "defer.tc"
  { f ( try ) ; }
  # 1 "defer.tc"
  }
  $ printf 'void g(void);\nvoid f(void) { { int defer = 0; defer++; } defer g(); }\n' > ended.tc
  $ ./golden.exe ended.tc
  # 1 "ended.tc"
  void g(void);
  void f(void) { { int defer = 0; defer++; } 
  # 2 "ended.tc"
  
  # 2 "ended.tc"
   
  # 2 "ended.tc"
  { g ( ) ; }
  # 2 "ended.tc"
  }

A `defer` statement is a block item, so an unhidden `defer` in an
operand begins nothing there.

  $ printf 'int f(int x) { return x + defer; }\n' > bare_defer.tc
  $ ./golden.exe bare_defer.tc
  bare_defer.tc:1: error: expected an expression, found `defer`
  [1]

The parser reads a `try` wherever it stands, in an operand as well,
and typing refuses each one outside its positions (design 5.1 rule 3).
A `try` takes an operand.

  $ cat > operand.tc <<'EOF'
  > int f(void);
  > int g(void) { int n = 1; n = n + try f(); return n; }
  > EOF
  $ ./golden.exe operand.tc
  operand.tc:2: error: the operand of try is of type 'int', not a result type [try-operand]
  [1]
  $ cat > measured.tc <<'EOF'
  > int f(void);
  > unsigned long g(void) { return sizeof try f(); }
  > EOF
  $ ./golden.exe measured.tc
  measured.tc:2: error: try stands in no holder, or under an operator or in a place that design 5.1 rule 3 does not name; give it a statement or declaration of its own [try-position]
  [1]
  $ printf 'void f(void) { try; }\n' > bare.tc
  $ ./golden.exe bare.tc
  bare.tc:1: error: expected an expression, found `;`
  [1]

`_Defer` is a keyword in all text, where `defer` is hidden as well.

  $ printf 'void f(void) { int defer = 0; _Defer f(); }\n' > spelling.tc
  $ ./golden.exe spelling.tc
  # 1 "spelling.tc"
  void f(void) { int defer = 0; 
  # 1 "spelling.tc"
  
  # 1 "spelling.tc"
   
  # 1 "spelling.tc"
  { f ( ) ; }
  # 1 "spelling.tc"
  }

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
