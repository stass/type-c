SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The rules local to a defer statement and its statement S (design section
6). Each source is preprocessed text, as the backend writes it for -E; a
file named *.tc holds Type-C text, and a line marker opens C text.

The statement of a defer is typed, then refused until lowering of
package 2.5 writes it, so that none reaches the backend.

  $ cat > typed.tc <<'EOF'
  > void g(void);
  > void f(void) { defer g(); }
  > EOF
  $ ./golden.exe typed.tc
  typed.tc:2: lowering of `defer` is not implemented yet (design 13.5; work package 2.5) [TC0023]
  [1]

  $ cat > typed_error.tc <<'EOF'
  > void f(void) { defer undeclared(); }
  > EOF
  $ ./golden.exe typed_error.tc
  typed_error.tc:1: 'undeclared' is not declared (C11 6.5.1p2)
  [1]

  $ cat > c_text.tc <<'EOF'
  > # 1 "c_text.tc"
  > # 1 "c.h" 1
  > void g(void);
  > void f(void) { _Defer g(); }
  > # 2 "c_text.tc" 2
  > EOF
  $ ./golden.exe c_text.tc
  c.h:2: lowering of `defer` is not implemented yet (design 13.5; work package 2.5) [TC0023]
  [1]

A defer statement is a block item of a compound statement or a match arm
in a function body (design 6 rule 11).

  $ cat > substatement.tc <<'EOF'
  > void g(void);
  > void f(int c) {
  >   if (c)
  >     defer g();
  > }
  > EOF
  $ ./golden.exe substatement.tc
  substatement.tc:4: a `defer` statement is a block item of a compound statement or a match arm in a function body, not the substatement of a statement; write it in a compound statement (design 6 rule 11) [TC0057]
  [1]

  $ cat > labelled.tc <<'EOF'
  > void g(void);
  > void f(void) {
  > l:
  >   defer g();
  > }
  > EOF
  $ ./golden.exe labelled.tc
  labelled.tc:4: a `defer` statement is a block item of a compound statement or a match arm in a function body, not the statement of a label; write it in a compound statement (design 6 rule 11) [TC0057]
  [1]

  $ cat > case.tc <<'EOF'
  > void g(void);
  > void f(int c) {
  >   switch (c) {
  >   case 1:
  >     defer g();
  >   }
  > }
  > EOF
  $ ./golden.exe case.tc
  case.tc:5: a `defer` statement is a block item of a compound statement or a match arm in a function body, not the statement of a label; write it in a compound statement (design 6 rule 11) [TC0057]
  [1]

  $ cat > deferred.tc <<'EOF'
  > void g(void);
  > void f(void) { defer defer g(); }
  > EOF
  $ ./golden.exe deferred.tc
  deferred.tc:2: a `defer` statement is a block item of a compound statement or a match arm in a function body, not the statement of a `defer`; write it in a compound statement (design 6 rule 11) [TC0057]
  [1]

  $ cat > statement_expression.tc <<'EOF'
  > void g(void);
  > void f(void) { (void)({ defer g(); 0; }); }
  > EOF
  $ ./golden.exe statement_expression.tc
  statement_expression.tc:2: a `defer` statement is a block item of a compound statement or a match arm in a function body, not a block item of the compound statement of a statement expression, whose last item gives its value (design 6 rule 11) [TC0057]
  [1]

  $ cat > file_scope.tc <<'EOF'
  > void g(void);
  > int a[({ { _Defer g(); } 1; })];
  > EOF
  $ ./golden.exe file_scope.tc
  file_scope.tc:2: a `defer` statement is a block item of a compound statement or a match arm in a function body, not outside every function body (design 6 rule 11) [TC0057]
  [1]

Control leaves the statement only at its end (design 6 rule 4, 5.1 rule
4).

  $ cat > return.tc <<'EOF'
  > void f(void) { defer return; }
  > EOF
  $ ./golden.exe return.tc
  return.tc:1: `return` in the statement of a defer, which control leaves only at its end (design 6 rule 4) [TC0058]
  [1]

  $ cat > return_in_value.tc <<'EOF'
  > void f(void) {
  >   defer {
  >     (void)({ return; 0; });
  >   }
  > }
  > EOF
  $ ./golden.exe return_in_value.tc
  return_in_value.tc:3: `return` in the statement of a defer, which control leaves only at its end (design 6 rule 4) [TC0058]
  [1]

  $ cat > break.tc <<'EOF'
  > void f(void) {
  >   for (;;) {
  >     defer break;
  >   }
  > }
  > EOF
  $ ./golden.exe break.tc
  break.tc:3: a `break` that leaves the statement of a defer (design 6 rule 4) [TC0058]
  [1]

  $ cat > continue.tc <<'EOF'
  > void f(int c) {
  >   for (;;) {
  >     defer switch (c) {
  >     case 1:
  >       continue;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe continue.tc
  continue.tc:5: a `continue` that leaves the statement of a defer (design 6 rule 4) [TC0058]
  [1]

  $ cat > break_in_condition.tc <<'EOF'
  > void f(void) {
  >   for (;;) {
  >     defer if (({ break; 0; }))
  >       ;
  >   }
  > }
  > EOF
  $ ./golden.exe break_in_condition.tc
  break_in_condition.tc:3: a `break` that leaves the statement of a defer (design 6 rule 4) [TC0058]
  [1]

  $ cat > goto.tc <<'EOF'
  > void f(void) {
  >   defer {
  >     goto out;
  >   }
  > out:;
  > }
  > EOF
  $ ./golden.exe goto.tc
  goto.tc:3: `goto` in the statement of a defer, which control leaves only at its end (design 6 rule 4) [TC0058]
  [1]

  $ cat > computed_goto.tc <<'EOF'
  > # 1 "computed_goto.tc"
  > # 1 "c.h" 1
  > void f(void *p) { _Defer goto *p; }
  > # 2 "computed_goto.tc" 2
  > EOF
  $ ./golden.exe computed_goto.tc
  c.h:1: `goto *` in the statement of a defer, which control leaves only at its end (design 6 rule 4) [TC0058]
  [1]

  $ cat > asm_goto.tc <<'EOF'
  > # 1 "asm_goto.tc"
  > # 1 "c.h" 1
  > void f(void) { _Defer asm goto ("" : : : : out); out:; }
  > # 2 "asm_goto.tc" 2
  > EOF
  $ ./golden.exe asm_goto.tc
  c.h:1: `asm goto` in the statement of a defer, which control leaves only at its end (design 6 rule 4) [TC0058]
  [1]

  $ cat > try.tc <<'EOF'
  > void f(void) { defer try g(); }
  > EOF
  $ ./golden.exe try.tc
  try.tc:1: try stands in none of its positions: a whole expression statement, the whole right operand of a simple assignment that is one, or the whole initialiser of a declaration in a block; give it a statement or declaration of its own (design 5.1 rule 3) [TC0054]
  [1]

  $ cat > disputed.tc <<'EOF'
  > # 1 "disputed.tc"
  > # 1 "c.h" 1
  > void f(int c) { _Defer while (c) for (;; ({ break; })) ; }
  > # 2 "disputed.tc" 2
  > EOF
  $ ./golden.exe disputed.tc
  c.h:1: a break in the condition of a loop or the step of a for, which Clang takes to leave the loop and GCC the statement around it (design 4.4) [TC0026]
  [1]

Lowering copies the statement to each exit, so it defines nothing that a
copy would define again (design 6 rule 9).

  $ cat > label.tc <<'EOF'
  > void f(void) { defer { again:; } }
  > EOF
  $ ./golden.exe label.tc
  label.tc:1: the label `again` in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > local_label.tc <<'EOF'
  > # 1 "local_label.tc"
  > # 1 "c.h" 1
  > void f(void) { _Defer { __label__ l; l:; } }
  > # 2 "local_label.tc" 2
  > EOF
  $ ./golden.exe local_label.tc
  c.h:1: `__label__` in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > static.tc <<'EOF'
  > void g(int *);
  > void f(void) { defer { static int n; g(&n); } }
  > EOF
  $ ./golden.exe static.tc
  static.tc:2: a declaration with static or thread storage duration and no `extern` in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > thread_local.tc <<'EOF'
  > void g(int *);
  > void f(void) { defer { _Thread_local static int n; g(&n); } }
  > EOF
  $ ./golden.exe thread_local.tc
  thread_local.tc:2: a declaration with static or thread storage duration and no `extern` in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > struct_body.tc <<'EOF'
  > void f(void) { defer { struct { int a; } v; (void)v; } }
  > EOF
  $ ./golden.exe struct_body.tc
  struct_body.tc:1: a structure or union with a body in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > enum_body.tc <<'EOF'
  > void f(void) { defer { enum { K }; } }
  > EOF
  $ ./golden.exe enum_body.tc
  enum_body.tc:1: an enumeration with a body in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > tag.tc <<'EOF'
  > void f(void) { defer { struct s; } }
  > EOF
  $ ./golden.exe tag.tc
  tag.tc:1: the declaration of the tag `s` in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > implicit_tag.tc <<'EOF'
  > void f(void *p) { defer (void)(struct s *)p; }
  > EOF
  $ ./golden.exe implicit_tag.tc
  implicit_tag.tc:1: the declaration of the tag `s` in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > type_declaration.tc <<'EOF'
  > void f(void) { defer { type t = int; } }
  > EOF
  $ ./golden.exe type_declaration.tc
  type_declaration.tc:1: a type declaration in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

  $ cat > block_literal.tc <<'EOF'
  > # 1 "block_literal.tc"
  > # 1 "c.h" 1
  > void f(void) { _Defer (void)^{ }; }
  > # 2 "block_literal.tc" 2
  > EOF
  $ ./golden.exe block_literal.tc
  c.h:1: a block literal in the statement of a defer, which lowering copies to each exit of its scope, where each copy would define it again (design 6 rule 9, 13.5) [TC0059]
  [1]

What a copy can repeat is allowed: a declaration with extern, a typedef
that declares no type, a tag already visible, a loop that uses its own
break and continue, a switch with its own case labels, a nested defer
and a null statement.

  $ cat > allowed.tc <<'EOF'
  > struct s { int a; };
  > void g(int);
  > void f(int c) {
  >   defer {
  >     extern int n;
  >     extern _Thread_local int t;
  >     typedef struct s *p;
  >     struct s v = { 0 };
  >     for (;;) {
  >       if (c)
  >         break;
  >       continue;
  >     }
  >     switch (c) {
  >     case 1:
  >       break;
  >     }
  >     defer g(n);
  >     defer;
  >     g(v.a);
  >   }
  > }
  > EOF
  $ ./golden.exe allowed.tc
  allowed.tc:18: lowering of `defer` is not implemented yet (design 13.5; work package 2.5) [TC0023]
  [1]

  $ cat > pragma.tc <<'EOF'
  > # 1 "pragma.tc"
  > # 1 "c.h" 1
  > void g(void);
  > void f(void) {
  >   _Defer {
  > #pragma mark - Don't
  >     g();
  >   }
  > }
  > # 2 "pragma.tc" 2
  > EOF
  $ ./golden.exe pragma.tc
  c.h:4: a `#pragma` line whose text is no sequence of preprocessing tokens: unterminated literal (design 13.5) [TC0040]
  [1]
