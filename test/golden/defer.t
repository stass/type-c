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
  typed.tc:2: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
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
  c.h:2: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
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
  deferred.tc:2: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0057]
  [1]

No `defer` statement stands in the statement of another at any depth:
not in a block of it, a statement expression in it or a match arm in it.

  $ cat > deferred_block.tc <<'EOF'
  > void g(void);
  > void f(void) {
  >   defer {
  >     g();
  >     {
  >       defer g();
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe deferred_block.tc
  deferred_block.tc:6: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0057]
  [1]

  $ cat > deferred_value.tc <<'EOF'
  > void g(void);
  > void f(void) {
  >   defer (void)({
  >     { _Defer g(); }
  >     0;
  >   });
  > }
  > EOF
  $ ./golden.exe deferred_value.tc
  deferred_value.tc:4: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0057]
  [1]

  $ cat > deferred_arm.tc <<'EOF'
  > type t = | A | B;
  > void g(void);
  > void f(t v) {
  >   defer match (v) {
  >   case A:
  >     defer g();
  >     break;
  >   default:
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe deferred_arm.tc
  deferred_arm.tc:6: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0057]
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

Labels, the jumps of `asm goto`, follow the clobbers of no other asm,
which would otherwise jump without the qualifier.

  $ cat > asm_labels.tc <<'EOF'
  > # 1 "asm_labels.tc"
  > # 1 "c.h" 1
  > void f(void) { out:; _Defer __asm__ ("" : : : : out); }
  > # 2 "asm_labels.tc" 2
  > EOF
  $ ./golden.exe asm_labels.tc
  c.h:1: labels after the clobbers of an `asm` without `goto` (GCC manual, "Extended Asm")
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

What a copy can repeat is allowed: a typedef that declares no type, a
tag already visible, a loop that uses its own break and continue, a
switch with its own case labels and a null statement.

  $ cat > allowed.tc <<'EOF'
  > struct s { int a; };
  > void g(int);
  > void f(int c) {
  >   defer {
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
  >     ;
  >     g(v.a);
  >   }
  > }
  > EOF
  $ ./golden.exe allowed.tc
  allowed.tc:4: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
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

No jump from outside the statement of a defer or its scope enters it
(design 6 rule 5): not a switch around it at a case or default label in
it, not a goto from outside, and not a computed goto, which may be given
the address of a label in the scope wherever the address is taken.

  $ cat > case_in_statement.tc <<'EOF'
  > void g(void);
  > void f(int n) {
  >   switch (n) {
  >   case 0:;
  >     defer case 1: g();
  >   }
  > }
  > EOF
  $ ./golden.exe case_in_statement.tc
  case_in_statement.tc:5: a case or default label in the statement of a defer that belongs to a switch around it, which would jump into the statement (design 6 rule 5) [TC0060]
  [1]

  $ cat > default_in_scope.tc <<'EOF'
  > void g(void);
  > void f(int n) {
  >   switch (n) {
  >   case 0:;
  >     defer g();
  >     {
  >     default:;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe default_in_scope.tc
  default_in_scope.tc:7: a case or default label in the scope of a defer statement that belongs to a switch around the scope, which would jump into the scope past the defer (design 6 rule 5) [TC0060]
  [1]

  $ cat > goto_into_scope.tc <<'EOF'
  > void g(void);
  > void f(int c) {
  >   if (c)
  >     goto later;
  >   defer g();
  > later:
  >   g();
  > }
  > EOF
  $ ./golden.exe goto_into_scope.tc
  goto_into_scope.tc:4: a jump into the scope of a defer statement from outside it (design 6 rule 5) [TC0060]
  [1]

  $ cat > address_in_scope.tc <<'EOF'
  > void g(void);
  > void f(void) {
  >   void *p = &&later;
  >   defer g();
  > later:
  >   (void)p;
  > }
  > EOF
  $ ./golden.exe address_in_scope.tc
  address_in_scope.tc:3: the address of a label inside the scope of a defer statement, which a computed goto could jump to from outside the scope (design 6 rule 5) [TC0060]
  [1]

Where no switch is around the defer, a case label in it or its scope
belongs to none, as C says.

  $ cat > case_without_switch.tc <<'EOF'
  > void g(void);
  > void f(void) {
  >   defer g();
  >   case 1:;
  > }
  > EOF
  $ ./golden.exe case_without_switch.tc
  case_without_switch.tc:4: a case or default label outside a switch (C11 6.8.1p2)
  [1]

A switch in the scope jumps to its own labels, a goto may leave the scope
for a label before the defer, and the address of a label in no scope of
a defer may be taken.

  $ cat > entry_allowed.tc <<'EOF'
  > void g(void);
  > void f(int c) {
  > before:;
  >   defer g();
  >   switch (c) {
  >   case 1:
  >     g();
  >   }
  > again:
  >   if (c--)
  >     goto again;
  >   void *p = &&before;
  >   (void)p;
  >   if (c)
  >     goto before;
  > }
  > EOF
  $ ./golden.exe entry_allowed.tc
  entry_allowed.tc:4: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

In the scope of a defer statement there is no computed goto, no asm goto
and no disputed break or continue, in any text and in any statement
nested in the scope (design 6 rule 10).

  $ cat > scope_computed_goto.tc <<'EOF'
  > void g(void);
  > void f(void *p) {
  >   defer g();
  >   goto *p;
  > }
  > EOF
  $ ./golden.exe scope_computed_goto.tc
  scope_computed_goto.tc:4: a `goto *` in the scope of a defer statement, which may leave the scope where lowering cannot run the deferred statement first (design 6 rule 10) [TC0062]
  [1]

  $ cat > scope_asm_goto.tc <<'EOF'
  > void g(void);
  > void f(void) {
  > out:;
  >   defer g();
  >   asm goto ("" : : : : out);
  > }
  > EOF
  $ ./golden.exe scope_asm_goto.tc
  scope_asm_goto.tc:5: an `asm goto` in the scope of a defer statement, which may leave the scope where lowering cannot run the deferred statement first (design 6 rule 10) [TC0062]
  [1]

  $ cat > scope_disputed.tc <<'EOF'
  > # 1 "scope_disputed.tc"
  > void g(void);
  > void f(int c) {
  >   defer g();
  > # 1 "c.h" 1
  >   while (c) for (;; ({ break; })) ;
  > # 5 "scope_disputed.tc" 2
  > }
  > EOF
  $ ./golden.exe scope_disputed.tc
  c.h:1: a break in the condition of a loop or the step of a for, which Clang takes to leave the loop and GCC the statement around it (design 4.4) [TC0026]
  [1]

  $ cat > scope_c_text.tc <<'EOF'
  > # 1 "scope_c_text.tc"
  > # 1 "c.h" 1
  > void g(void);
  > void f(int c) {
  >   _Defer g();
  >   while (c) for (;; ({ continue; })) ;
  > }
  > # 2 "scope_c_text.tc" 2
  > EOF
  $ ./golden.exe scope_c_text.tc
  c.h:4: a continue in the condition of a loop or the step of a for, which Clang takes to leave the loop and GCC the statement around it (design 4.4) [TC0026]
  [1]

The scope holds every statement nested in it: a block, a statement
expression and a match arm, which a jump enters only from inside.

  $ cat > scope_nested.tc <<'EOF'
  > void g(void);
  > void f(int c, void *p) {
  >   defer g();
  >   if (c) {
  >     int x = ({ goto *p; 0; });
  >     (void)x;
  >   }
  > }
  > EOF
  $ ./golden.exe scope_nested.tc
  scope_nested.tc:5: a `goto *` in the scope of a defer statement, which may leave the scope where lowering cannot run the deferred statement first (design 6 rule 10) [TC0062]
  [1]

  $ cat > scope_arm.tc <<'EOF'
  > type e = | A | B(int i);
  > void g(void);
  > void f(e v, void *p) {
  >   defer g();
  >   match (v) {
  >   case A:
  >     goto *p;
  >   case B(_):
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe scope_arm.tc
  scope_arm.tc:7: a `goto *` in the scope of a defer statement, which may leave the scope where lowering cannot run the deferred statement first (design 6 rule 10) [TC0062]
  [1]

  $ cat > arm_scope.tc <<'EOF'
  > type e = | A | B(int i);
  > void g(void);
  > void f(e v, void *p) {
  >   match (v) {
  >   case A:
  >     defer g();
  >     goto *p;
  >   case B(_):
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe arm_scope.tc
  arm_scope.tc:7: a `goto *` in the scope of a defer statement, which may leave the scope where lowering cannot run the deferred statement first (design 6 rule 10) [TC0062]
  [1]

  $ cat > scope_tested.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > void g(void);
  > void f(const list *l, void *p) {
  >   defer g();
  >   if (case Cons(_, _) = *l)
  >     goto *p;
  > }
  > EOF
  $ ./golden.exe scope_tested.tc
  scope_tested.tc:6: a `goto *` in the scope of a defer statement, which may leave the scope where lowering cannot run the deferred statement first (design 6 rule 10) [TC0062]
  [1]

The first refusal in source order is named, of rule 10 or of an entry.

  $ cat > scope_order.tc <<'EOF'
  > void g(void);
  > void f(int c, void *p) {
  >   if (c)
  >     goto in;
  >   defer g();
  > in:
  >   goto *p;
  > }
  > EOF
  $ ./golden.exe scope_order.tc
  scope_order.tc:4: a jump into the scope of a defer statement from outside it (design 6 rule 5) [TC0060]
  [1]

Before the defer and after its block ends, the jumps are no concern of
the rule.

  $ cat > scope_ended.tc <<'EOF'
  > # 1 "scope_ended.tc"
  > void g(void);
  > void f(int c, void *p) {
  >   if (c)
  >     goto *p;
  >   {
  >     defer g();
  >   }
  >   goto *p;
  > back:
  >   asm goto ("" : : : : back);
  > # 1 "c.h" 1
  >   while (c) for (;; ({ break; })) ;
  > # 12 "scope_ended.tc" 2
  > }
  > EOF
  $ ./golden.exe scope_ended.tc
  scope_ended.tc:6: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

The statement S of a defer is moved text, written again at each exit of
its scope, and passes the one check of the resolution property there
(design 6 rule 8, 13.5): a declaration that would make a name of S read
otherwise at an exit is an error, under the code of rule 8 whichever
clause fails.

  $ cat > hidden_at_end.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(void) { defer use(x); int x = 0; }
  > EOF
  $ ./golden.exe hidden_at_end.tc
  hidden_at_end.tc:3: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_end.tc:3 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > hidden_at_return.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(int c) {
  >   defer use(x);
  >   {
  >     int x = c;
  >     if (x)
  >       return;
  >   }
  > }
  > EOF
  $ ./golden.exe hidden_at_return.tc
  hidden_at_return.tc:4: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_return.tc:6 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > hidden_at_break.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(int c) {
  >   while (c) {
  >     defer use(x);
  >     long x = c;
  >     if (x)
  >       break;
  >     c--;
  >   }
  > }
  > EOF
  $ ./golden.exe hidden_at_break.tc
  hidden_at_break.tc:5: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_break.tc:6 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > hidden_tag.tc <<'EOF'
  > struct s;
  > void use(unsigned long);
  > void f(void) {
  >   defer use(sizeof(struct s *));
  >   struct s { int a; };
  > }
  > EOF
  $ ./golden.exe hidden_tag.tc
  hidden_tag.tc:4: the tag 's' denotes another tag where lowering writes the text, the one declared at hidden_tag.tc:5 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > inexact_again.tc <<'EOF'
  > extern int o;
  > void use(int);
  > void f(void) {
  >   defer use(o);
  >   extern int o __attribute__((aligned(16)));
  > }
  > EOF
  $ ./golden.exe inexact_again.tc
  inexact_again.tc:4: the declaration of 'o' at inexact_again.tc:5, between the text and a place where lowering writes it, gives it a type that may hold an attribute or `typeof` of an expression, which may change the type that the text uses (design 6 rule 8, 13.5) [TC0063]
  [1]

S declares no object or function with linkage, which the text around
an exit would see (13.5), though rule 9 allows an `extern` declaration.
The operand of a return, written at its own place, may.

  $ cat > linked.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer {
  >     extern int o;
  >     use(o);
  >   }
  > }
  > EOF
  $ ./golden.exe linked.tc
  linked.tc:4: 'o' is declared with linkage in the text, which lowering writes elsewhere, so the declaration may change it for the text around it there; declare it outside the text (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > linked_no_exit.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer {
  >     extern int o;
  >     use(o);
  >   }
  >   for (;;)
  >     use(1);
  > }
  > EOF
  $ ./golden.exe linked_no_exit.tc
  linked_no_exit.tc:4: 'o' is declared with linkage in the text, which lowering writes elsewhere, so the declaration may change it for the text around it there; declare it outside the text (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > return_linked.tc <<'EOF'
  > void g(void);
  > int f(void) {
  >   defer g();
  >   return ({ extern int o; o; });
  > }
  > EOF
  $ ./golden.exe return_linked.tc
  return_linked.tc:3: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

A continue that leaves the scope is an exit, and so is a return with an
operand, whose copies follow the operand.

  $ cat > hidden_at_continue.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(int c) {
  >   while (c) {
  >     defer use(x);
  >     {
  >       long x = c--;
  >       if (x > 2)
  >         continue;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe hidden_at_continue.tc
  hidden_at_continue.tc:5: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_continue.tc:7 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > hidden_at_value_return.tc <<'EOF'
  > int x;
  > void use(int);
  > int f(int c) {
  >   defer use(x);
  >   {
  >     int x = c;
  >     return x + 1;
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe hidden_at_value_return.tc
  hidden_at_value_return.tc:4: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_value_return.tc:6 (design 6 rule 8, 13.5) [TC0063]
  [1]

A declaration whose effect on the type that S uses depends on a type
that typec does not compute is refused under the one code of P21.

  $ cat > unknown_type_again.tc <<'EOF'
  > _Float16 dot(_Float16);
  > void use(void *);
  > void f(void) {
  >   defer use((void *)dot);
  >   extern _Float16 dot(_Float16 x);
  > }
  > EOF
  $ ./golden.exe unknown_type_again.tc
  unknown_type_again.tc:4: the declaration of 'dot' at unknown_type_again.tc:5, between the text and a place where lowering writes it, may change the type that the text uses: that depends on '_Float16', whose type typec does not compute (design 13.5, P21) [TC0045]
  [1]

An identifier of a `#pragma` line of S that denotes something at the
defer statement is a use of it, as one in an attribute argument is; a
word of the pragma that denotes nothing there is not counted.

  $ cat > pragma_hidden.tc <<'EOF'
  > enum { N = 4 };
  > void use(int);
  > void f(void) {
  >   defer {
  > #pragma GCC unroll N
  >     for (int i = 0; i < 8; i++)
  >       use(i);
  >   }
  >   enum { N = 2 };
  > }
  > EOF
  $ ./golden.exe pragma_hidden.tc
  pragma_hidden.tc:5: 'N' denotes another entity where lowering writes the text, the one declared at pragma_hidden.tc:9 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > pragma_word.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer {
  > #pragma GCC ivdep
  >     for (int i = 0; i < 8; i++)
  >       use(i);
  >   }
  >   int ivdep = 0;
  >   use(ivdep);
  > }
  > EOF
  $ ./golden.exe pragma_word.tc
  pragma_word.tc:3: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

The name of a label whose address S takes reads, at an exit, the GNU
local label of its name that a block around the exit declares: such a
`__label__` is an error where the block holds an exit, and allowed where
it holds none.

  $ cat > label_hidden.tc <<'EOF'
  > void use(void *);
  > void f(int c) {
  > L:
  >   {
  >     defer use(&&L);
  >     {
  >       __label__ L;
  >     L:
  >       if (c--)
  >         return;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe label_hidden.tc
  label_hidden.tc:5: the label 'L' denotes another label where lowering writes the text, the one declared at label_hidden.tc:7 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > label_no_exit.tc <<'EOF'
  > void use(void *);
  > void f(int c) {
  > L:
  >   {
  >     defer use(&&L);
  >     {
  >       __label__ L;
  >     L:
  >       c--;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe label_no_exit.tc
  label_no_exit.tc:5: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

A goto that leaves the scope is an exit, a goto back to before the
defer included, and so is the error path of a try, whose copies stand
in front of the statement or declaration that holds the try.

  $ cat > hidden_at_goto.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(int c) {
  > again:
  >   {
  >     defer use(x);
  >     {
  >       int x = c--;
  >       if (x)
  >         goto again;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe hidden_at_goto.tc
  hidden_at_goto.tc:6: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_goto.tc:8 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > hidden_at_try.tc <<'EOF'
  > int x;
  > void use(int);
  > result(int, int) rd(void);
  > result(int, int) h(void) {
  >   defer use(x);
  >   {
  >     int x = 0;
  >     int y = try rd();
  >     use(x + y);
  >   }
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe hidden_at_try.tc
  hidden_at_try.tc:5: 'x' denotes another entity where lowering writes the text, the one declared at hidden_at_try.tc:7 (design 6 rule 8, 13.5) [TC0063]
  [1]

  $ cat > declared_by_try.tc <<'EOF'
  > int x;
  > void use(int);
  > result(int, int) rd(void);
  > result(int, int) h(void) {
  >   defer use(x);
  >   {
  >     int x = try rd();
  >     use(x);
  >   }
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe declared_by_try.tc
  declared_by_try.tc:5: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

A declaration in whose scope no exit lies reaches no copy; the end of a
block that cannot complete is no exit; completing a tag that S names
changes nothing for a copy after it; and what S declares is in scope in
S alone, S being a block.

  $ cat > no_exit_in_scope.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(void) { defer use(x); { int x = 0; use(x); } }
  > EOF
  $ ./golden.exe no_exit_in_scope.tc
  no_exit_in_scope.tc:3: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

  $ cat > end_not_reached.tc <<'EOF'
  > int x;
  > void use(int);
  > void f(int c) {
  >   defer use(x);
  >   if (c)
  >     return;
  >   int x = 0;
  >   for (;;)
  >     use(x);
  > }
  > EOF
  $ ./golden.exe end_not_reached.tc
  end_not_reached.tc:4: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

  $ cat > completed_after.tc <<'EOF'
  > void use(unsigned long);
  > void f(void) {
  >   struct s;
  >   defer use(sizeof(struct s *));
  >   struct s { int a; };
  > }
  > EOF
  $ ./golden.exe completed_after.tc
  completed_after.tc:4: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

  $ cat > own_block.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer { int y = 1; use(y); }
  >   use(y);
  > }
  > EOF
  $ ./golden.exe own_block.tc
  own_block.tc:4: 'y' is not declared (C11 6.5.1p2)
  [1]

Lowering writes a return in the scope of a defer statement as a block
that holds its operand (design 6 rule 12, 13.5), so the operand declares
no name that is in scope after it: the third clause of the resolution
property, under the code of the operand of a return.

  $ cat > return_declares.tc <<'EOF'
  > void g(void);
  > int f(int c) {
  >   defer g();
  >   if (c)
  >     goto skip;
  >   return sizeof(enum { K = 5 });
  > skip:
  >   return K;
  > }
  > EOF
  $ ./golden.exe return_declares.tc
  return_declares.tc:6: 'K' is declared in the scope around the text, which lowering writes elsewhere or in a block of its own, so the text after it would lose the declaration; declare it before the text (design 6 rule 12, 13.5) [TC0064]
  [1]

  $ cat > return_tag.tc <<'EOF'
  > void g(void);
  > int f(void) {
  >   defer g();
  >   return (struct p { int a; }){1}.a;
  > }
  > EOF
  $ ./golden.exe return_tag.tc
  return_tag.tc:4: the tag 'p' is declared in the scope around the text, which lowering writes elsewhere or in a block of its own, so the text after it would lose the declaration; declare it before the text (design 6 rule 12, 13.5) [TC0064]
  [1]

The same holds in a function that returns void, where lowering writes
the operand ahead of the copies in a block as well.

  $ cat > void_return_declares.tc <<'EOF'
  > enum { K = 1 };
  > void use(int);
  > void f(void) {
  >   defer use(K);
  >   return (void)sizeof(enum { K = 5 });
  > }
  > EOF
  $ ./golden.exe void_return_declares.tc
  void_return_declares.tc:5: 'K' is declared in the scope around the text, which lowering writes elsewhere or in a block of its own, so the text after it would lose the declaration; declare it before the text (design 6 rule 12, 13.5) [TC0064]
  [1]

A return that is the substatement of an `if` is held to the same.

  $ cat > if_return_declares.tc <<'EOF'
  > void g(void);
  > int f(int c) {
  >   defer g();
  >   if (c)
  >     return sizeof(struct q { int a; });
  >   return 0;
  > }
  > EOF
  $ ./golden.exe if_return_declares.tc
  if_return_declares.tc:5: the tag 'q' is declared in the scope around the text, which lowering writes elsewhere or in a block of its own, so the text after it would lose the declaration; declare it before the text (design 6 rule 12, 13.5) [TC0064]
  [1]

A return outside every scope of a defer is written as it stands, and an
operand that only uses a tag declares nothing.

  $ cat > return_outside.tc <<'EOF'
  > void g(void);
  > int f(void) {
  >   { defer g(); }
  >   return sizeof(enum { K = 5 });
  > }
  > EOF
  $ ./golden.exe return_outside.tc
  return_outside.tc:3: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]

  $ cat > return_uses.tc <<'EOF'
  > struct p { int a; };
  > void g(void);
  > int f(void) {
  >   defer g();
  >   return (struct p){1}.a;
  > }
  > EOF
  $ ./golden.exe return_uses.tc
  return_uses.tc:4: lowering of `defer` is not complete yet (design 13.5; work package 2.5) [TC0023]
  [1]
