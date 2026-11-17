SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Unread text is every token that typing does not read (design 13.5):
attribute arguments, `#pragma` lines, the bodies of block literals and
the function bodies that are passed through unread. One scan passes
over each of them, and every rule that unread text is held to is
applied there (design section 6 rule 13).

`_Defer` is refused in unread text of any text, as the statement would
reach the backend as written.

  $ cat > defer_attribute.tc <<'EOF'
  > void f(void) { int x __attribute__((aligned(sizeof(_Defer)))); }
  > EOF
  $ ./golden.exe defer_attribute.tc
  defer_attribute.tc:1: error: `_Defer` in the arguments of an attribute, which typing does not read, begins a construct of Type-C that would reach the backend as written [unread-word]
  [1]
  $ cat > defer_c_attribute.tc <<'EOF'
  > # 1 "defer_c_attribute.tc"
  > # 1 "defer.h" 1
  > [[gnu::aligned(sizeof(_Defer))]] int x;
  > # 2 "defer_c_attribute.tc" 2
  > EOF
  $ ./golden.exe defer_c_attribute.tc
  defer.h:1: error: `_Defer` in the arguments of an attribute, which typing does not read, begins a construct of Type-C that would reach the backend as written [unread-word]
  [1]

A function body that C text of a system header opens is passed through
unread, and `_Defer` there is refused too.

  $ cat > defer_body.tc <<'EOF'
  > # 1 "defer_body.tc"
  > # 1 "system.h" 1 3
  > static void g(void) { _Defer (void)0; }
  > # 2 "defer_body.tc" 2
  > EOF
  $ ./golden.exe defer_body.tc
  system.h:1: error: `_Defer` in a function body that a system header opens, which typing does not read, begins a construct of Type-C that would reach the backend as written [unread-word]
  [1]

The parser reads the body of a block literal, which typing does not, so
a `_Defer` statement there is read as a statement and refused by the
scan of the literal after.

  $ cat > defer_block.tc <<'EOF'
  > # 1 "defer_block.tc"
  > # 1 "block.h" 1
  > static void g(void) { void (^b)(void) = ^{ _Defer (void)0; }; b(); }
  > # 2 "defer_block.tc" 2
  > EOF
  $ ./golden.exe defer_block.tc
  block.h:1: error: `_Defer` in a block literal, which typing does not read, begins a construct of Type-C that would reach the backend as written [unread-word]
  [1]

The words `defer` and `try` of Type-C text are refused in an attribute
argument of Type-C text, where no declaration hides them: of the unread
text that Type-C text writes, only an attribute argument holds words.

  $ cat > defer_word.tc <<'EOF'
  > void g(void);
  > void f(void) { int x __attribute__((cleanup(defer))); }
  > EOF
  $ ./golden.exe defer_word.tc
  defer_word.tc:2: error: `defer` in the arguments of an attribute, which typing does not read, begins a construct of Type-C that would reach the backend as written [unread-word]
  [1]
  $ cat > try_word.tc <<'EOF'
  > int g(void);
  > void f(void) { int x __attribute__((aligned(sizeof(try g())))); }
  > EOF
  $ ./golden.exe try_word.tc
  try_word.tc:2: error: `try` in the arguments of an attribute, which typing does not read, begins a construct of Type-C that would reach the backend as written [unread-word]
  [1]

A declaration hides the words, and in C text they are identifiers.

  $ cat > hidden_words.tc <<'EOF'
  > int try, defer;
  > int x __attribute__((aligned(sizeof(try + defer))));
  > # 1 "words.h" 1
  > int y __attribute__((aligned(sizeof(try + defer))));
  > EOF
  $ ./golden.exe hidden_words.tc
  # 1 "hidden_words.tc"
  int try, defer;
  int x __attribute__((aligned(sizeof(try + defer))));
  # 1 "words.h" 1
  int y __attribute__((aligned(sizeof(try + defer))));
  $ cat > c_words.tc <<'EOF'
  > # 1 "c_words.tc"
  > # 1 "words.h" 1
  > void f(void) { int y __attribute__((aligned(sizeof(try + defer)))); }
  > EOF
  $ ./golden.exe c_words.tc
  # 1 "c_words.tc"
  # 1 "c_words.tc"
  # 1 "words.h" 1
  void f(void) { int y __attribute__((aligned(sizeof(try + defer)))); }


A `#pragma` line holds no statement, so the words are not refused in
one: a `try` there reaches the backend as an identifier that nothing
declares.

  $ cat > pragma_words.tc <<'EOF'
  > int f(void);
  > #pragma omp parallel if(try f())
  > #pragma weak defer _Defer
  > EOF
  $ ./golden.exe pragma_words.tc
  # 1 "pragma_words.tc"
  int f(void);
  #pragma omp parallel if(try f())
  #pragma weak defer _Defer

A generic claims every name that begins with its own name and `__`
(design 10.3), and typec cannot tell whether unread text declares such a
name: an enumerator declared in an attribute argument would be what the
constructor `Some` of `option(int)` lowers to in the block. Every such
identifier of unread text is refused.

  $ cat > claim_enumerator.tc <<'EOF'
  > option(int) f(void) {
  >   int x __attribute__((aligned(sizeof(enum { option__i_Some = 0 }))));
  >   return Some(123);
  > }
  > EOF
  $ ./golden.exe claim_enumerator.tc
  claim_enumerator.tc:2: error: the name `option__i_Some` is spelled in the arguments of an attribute, which typing does not read, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  [1]
  $ cat > claim_tag.tc <<'EOF'
  > # 1 "claim_tag.tc"
  > # 1 "claim_tag.h" 1
  > int x __attribute__((aligned(sizeof(struct option__i { int a; }))));
  > EOF
  $ ./golden.exe claim_tag.tc
  claim_tag.h:1: error: the name `option__i` is spelled in the arguments of an attribute, which typing does not read, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  [1]
  $ cat > claim_body.tc <<'EOF'
  > # 1 "claim_body.tc"
  > # 1 "system.h" 1 3
  > static int g(void) { enum { result__i_Ok }; return result__i_Ok; }
  > EOF
  $ ./golden.exe claim_body.tc
  system.h:1: error: the name `result__i_Ok` is spelled in a function body that a system header opens, which typing does not read, but the generic `result` claims every name that begins with its own name and `__` for its instances [claimed-name]
  [1]

  $ cat > claim_block.tc <<'EOF'
  > # 1 "claim_block.tc"
  > # 1 "block.h" 1
  > static void g(void) { void (^b)(void) = ^{ (void)sizeof(option__i); }; b(); }
  > EOF
  $ ./golden.exe claim_block.tc
  block.h:1: error: the name `option__i` is spelled in a block literal, which typing does not read, but the generic `option` claims every name that begins with its own name and `__` for its instances [claimed-name]
  [1]

A name whose part before its first `__` is no generic is not claimed.

  $ cat > claim_other.tc <<'EOF'
  > int x __attribute__((aligned(sizeof(enum { options__i = 4 }))));
  > EOF
  $ ./golden.exe claim_other.tc
  # 1 "claim_other.tc"
  int x __attribute__((aligned(sizeof(enum { options__i = 4 }))));
