SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The rules local to a defer statement and its statement S (design section
6). Each source is preprocessed text, as the backend writes it for -E; a
file named *.tc holds Type-C text, and a line marker opens C text.

The statement of a defer is typed, and lowering writes it at each exit
of its scope (design 13.5), so that none reaches the backend.

  $ cat > typed.tc <<'EOF'
  > void g(void);
  > void f(void) { defer g(); }
  > EOF
  $ ./golden.exe typed.tc
  # 1 "typed.tc"
  void g(void);
  void f(void) { 
  # 2 "typed.tc"
  
  # 2 "typed.tc"
   
  # 2 "typed.tc"
  { g ( ) ; }
  # 2 "typed.tc"
  }

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
  # 1 "c_text.tc"
  # 1 "c_text.tc"
  # 1 "c.h" 1
  void g(void);
  void f(void) { 
  # 2 "c.h"
  
  # 2 "c.h"
   
  # 2 "c.h"
  { g ( ) ; }
  # 2 "c.h"
  }
  # 2 "c_text.tc" 2

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
  deferred.tc:2: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0072]
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
  deferred_block.tc:6: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0072]
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
  deferred_value.tc:4: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0072]
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
  deferred_arm.tc:6: a `defer` statement in the statement of a defer, which lowering copies to each exit of its scope, where each copy would repeat every copy of the inner statement (design 6 rule 11) [TC0072]
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
  # 1 "allowed.tc"
  struct s { int a; };
  void g(int);
  void f(int c) {
    
  # 4 "allowed.tc"
  
  # 18 "allowed.tc"
  
  
  # 4 "allowed.tc"
  { {
  # 5 "allowed.tc"
  typedef struct s * p ;
  # 6 "allowed.tc"
  struct s v = { 0 } ;
  # 7 "allowed.tc"
  for ( ; ; ) {
  # 8 "allowed.tc"
  if ( c )
  # 9 "allowed.tc"
  break ;
  # 10 "allowed.tc"
  continue ;
  # 11 "allowed.tc"
  }
  # 12 "allowed.tc"
  switch ( c ) {
  # 13 "allowed.tc"
  case 1 :
  # 14 "allowed.tc"
  break ;
  # 15 "allowed.tc"
  }
  # 16 "allowed.tc"
  ;
  # 17 "allowed.tc"
  g ( v . a ) ;
  # 18 "allowed.tc"
  }
  # 4 "allowed.tc"
  }
  # 19 "allowed.tc"
  }

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
  # 1 "entry_allowed.tc"
  void g(void);
  void f(int c) {
  before:;
    
  # 4 "entry_allowed.tc"
  
  # 4 "entry_allowed.tc"
  
    switch (c) {
    case 1:
      g();
    }
  again:
    if (c--)
      goto again;
    void *p = &&before;
    (void)p;
    if (c)
      
  # 15 "entry_allowed.tc"
  {
  # 4 "entry_allowed.tc"
  { g ( ) ; }
  # 15 "entry_allowed.tc"
  goto before
  # 15 "entry_allowed.tc"
  ; }
  # 15 "entry_allowed.tc"
  
  
  # 4 "entry_allowed.tc"
  { g ( ) ; }
  # 16 "entry_allowed.tc"
  }

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
  # 1 "scope_ended.tc"
  # 1 "scope_ended.tc"
  void g(void);
  void f(int c, void *p) {
    if (c)
      goto *p;
    {
      
  # 6 "scope_ended.tc"
  
  # 6 "scope_ended.tc"
  
    
  # 6 "scope_ended.tc"
  { g ( ) ; }
  # 7 "scope_ended.tc"
  }
    goto *p;
  back:
    asm goto ("" : : : : back);
  # 1 "c.h" 1
    while (c) for (;; ({ break; })) ;
  # 12 "scope_ended.tc" 2
  }

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
  # 1 "return_linked.tc"
  void g(void);
  int f(void) 
  # 2 "return_linked.tc"
  { typedef __typeof__(((__typeof__(f) *)0)()) __tc_ret;
  # 2 "return_linked.tc"
  {
    
  # 3 "return_linked.tc"
  
  # 3 "return_linked.tc"
  
    
  # 4 "return_linked.tc"
  { __tc_ret __tc_r = (
  # 4 "return_linked.tc"
   ({ extern int o; o; })
  # 4 "return_linked.tc"
  );
  # 3 "return_linked.tc"
  { g ( ) ; }
  # 4 "return_linked.tc"
  return __tc_r; }
  # 4 "return_linked.tc"
  
  
  # 5 "return_linked.tc"
  __builtin_trap();
  # 5 "return_linked.tc"
  
  # 5 "return_linked.tc"
  } }
  # 5 "return_linked.tc"
  

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

A pragma line between the keyword and S moves with S, so it is read as
part of it, and each copy writes it on a line of its own.

  $ cat > pragma_before.tc <<'EOF'
  > enum { N = 4 };
  > void use(int);
  > void f(void) {
  >   defer
  > #pragma GCC unroll N
  >     for (int i = 0; i < 8; i++)
  >       use(i);
  >   enum { N = 2 };
  > }
  > EOF
  $ ./golden.exe pragma_before.tc
  pragma_before.tc:5: 'N' denotes another entity where lowering writes the text, the one declared at pragma_before.tc:8 (design 6 rule 8, 13.5) [TC0063]
  [1]
  $ cat > pragma_moved.tc <<'EOF'
  > void use(int);
  > void f(int c) {
  >   defer
  > #pragma GCC unroll 4
  >     for (int i = 0; i < 8; i++)
  >       use(i);
  >   if (c)
  >     return;
  >   use(c);
  > }
  > EOF
  $ ./golden.exe pragma_moved.tc | grep -v '^# ' | grep .
  void use(int);
  void f(int c) {
    
    if (c)
      
  {
  {
  #pragma GCC unroll 4
  for ( int i = 0 ; i < 8 ; i ++ )
  use ( i ) ;
  }
  return
  ; }
    use(c);
  {
  #pragma GCC unroll 4
  for ( int i = 0 ; i < 8 ; i ++ )
  use ( i ) ;
  }
  }

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
  # 1 "pragma_word.tc"
  void use(int);
  void f(void) {
    
  # 3 "pragma_word.tc"
  
  # 7 "pragma_word.tc"
  
    int ivdep = 0;
    use(ivdep);
  
  # 3 "pragma_word.tc"
  { {
  # 4 "pragma_word.tc"
  #pragma GCC ivdep
  # 5 "pragma_word.tc"
  for ( int i = 0 ; i < 8 ; i ++ )
  # 6 "pragma_word.tc"
  use ( i ) ;
  # 7 "pragma_word.tc"
  }
  # 3 "pragma_word.tc"
  }
  # 10 "pragma_word.tc"
  }

A pragma that sets state for the text after it is refused in S,
whatever it is: each copy at an exit would set it again, so with two
exits a `pack(push, 1)` would push twice and the one `pack(pop)` after
the function would leave the struct after it packed. Only the pragmas
of the one list that apply to the statement after them (design 13.5)
may stand there.

  $ cat > pragma_pack.tc <<'EOF'
  > void use(int);
  > void f(int c) {
  >   defer {
  > #pragma pack(push, 1)
  >     ;
  >   }
  >   if (c)
  >     return;
  >   use(c);
  > }
  > #pragma pack(pop)
  > struct s { char c; int i; };
  > EOF
  $ ./golden.exe pragma_pack.tc
  pragma_pack.tc:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  [1]
  $ cat > pragma_diagnostic.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer {
  > #pragma GCC diagnostic push
  >     use(0);
  >   }
  > }
  > EOF
  $ ./golden.exe pragma_diagnostic.tc
  pragma_diagnostic.tc:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  [1]
  $ cat > pragma_visibility.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer
  > #pragma GCC visibility push(hidden)
  >     use(0);
  > }
  > EOF
  $ ./golden.exe pragma_visibility.tc
  pragma_visibility.tc:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  [1]
  $ cat > pragma_unknown.tc <<'EOF'
  > void use(int);
  > void f(void) {
  >   defer {
  > #pragma frobnicate
  >     use(0);
  >   }
  > }
  > EOF
  $ ./golden.exe pragma_unknown.tc
  pragma_unknown.tc:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  [1]

Lowering removes a defer statement from its place, so a pragma line
directly before it would apply to the statement after it, here a loop
that the source does not annotate. A `;` between them keeps the
pragma on a statement of its own.

  $ cat > pragma_before_defer.tc <<'EOF'
  > void use(int);
  > void f(int n) {
  > #pragma GCC ivdep
  >   defer use(0);
  >   for (int i = 0; i < n; i++)
  >     use(i);
  > }
  > EOF
  $ ./golden.exe pragma_before_defer.tc
  pragma_before_defer.tc:3: a `#pragma` line directly before a defer statement, which lowering removes, so the pragma would apply to the statement after it; put a `;` between them (design 6 rule 9) [TC0074]
  [1]
  $ cat > pragma_null_before_defer.tc <<'EOF'
  > void use(int);
  > void f(int n) {
  > #pragma GCC diagnostic push
  >   ;
  >   defer use(0);
  >   for (int i = 0; i < n; i++)
  >     use(i);
  > }
  > EOF
  $ ./golden.exe pragma_null_before_defer.tc | grep -v '^# ' | grep .
  void use(int);
  void f(int n) {
  #pragma GCC diagnostic push
    ;
    
    for (int i = 0; i < n; i++)
      use(i);
  { use ( 0 ) ; }
  }

C text is held to the list too, as `_Defer`.

  $ cat > pragma_c.tc <<'EOF'
  > # 1 "pragma_c.tc"
  > # 1 "c.h" 1
  > void g(void);
  > void f(void) {
  >   _Defer {
  > #pragma GCC optimize("O3")
  >     g();
  >   }
  > }
  > # 2 "pragma_c.tc" 2
  > EOF
  $ ./golden.exe pragma_c.tc
  c.h:4: a `#pragma` line in a deferred statement, which lowering copies to each exit, that is not one of the pragmas that apply only to the statement after them (design 6 rule 9) [TC0074]
  [1]

A pragma of C11 7.12.2 at the start of a block of S is in force to the
end of that block, and each copy writes S in a block of its own.

  $ cat > pragma_contract.tc <<'EOF'
  > double f(double a, double b, double c) {
  >   double r = 0;
  >   defer {
  > #pragma STDC FP_CONTRACT OFF
  >     r = a * b + c;
  >   }
  >   return a * b + c;
  > }
  > EOF
  $ ./golden.exe pragma_contract.tc | grep -v '^# ' | grep .
  double f(double a, double b, double c) 
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(a) *)0, *(__typeof__(b) *)0, *(__typeof__(c) *)0)) __tc_ret;
  {
    double r = 0;
    
    
  { __tc_ret __tc_r = (
   a * b + c
  );
  { {
  #pragma STDC FP_CONTRACT OFF
  r = a * b + c ;
  }
  }
  return __tc_r; }
  __builtin_trap();
  } }

A copy of S is compiled under the pragmas in force at its exit, so the
scope of a defer statement holds only the pragmas that annotate the
loop after them. Here the copy at the `return` would be contracted to
an FMA under `-mfma` and the one at the end of the block would not.

  $ cat > scope_fp_contract.tc <<'EOF'
  > double r;
  > void f(double x, double y, double z, int c) {
  > #pragma clang fp contract(off)
  >   ;
  >   defer r = x * y + z;
  >   if (c) {
  > #pragma clang fp contract(on)
  >     return;
  >   }
  > }
  > EOF
  $ ./golden.exe scope_fp_contract.tc
  scope_fp_contract.tc:7: a `#pragma` line in the scope of a defer statement that is not one of the pragmas that annotate only the loop after them: a copy of the deferred statement at an exit after it would be compiled under what the pragma sets, and not as at the defer statement (design 6 rule 9) [TC0074]
  [1]

A pragma of C11 7.12.2 is in force to the end of its block, here one
that holds an exit, so the scope holds none, at any depth.

  $ cat > scope_stdc.tc <<'EOF'
  > double r;
  > void f(double x, double y, int c) {
  >   defer r = x * y + 1;
  >   while (c--) {
  >     {
  > #pragma STDC FP_CONTRACT ON
  >       if (c == 3)
  >         return;
  >     }
  >   }
  > }
  > EOF
  $ ./golden.exe scope_stdc.tc
  scope_stdc.tc:6: a `#pragma` line in the scope of a defer statement that is not one of the pragmas that annotate only the loop after them: a copy of the deferred statement at an exit after it would be compiled under what the pragma sets, and not as at the defer statement (design 6 rule 9) [TC0074]
  [1]
  $ cat > scope_pack.tc <<'EOF'
  > struct s { char c; int i; };
  > void use(int);
  > void f(int c) {
  >   defer use(sizeof(struct s));
  > #pragma pack(push, 1)
  >   use(c);
  > #pragma pack(pop)
  > }
  > EOF
  $ ./golden.exe scope_pack.tc
  scope_pack.tc:5: a `#pragma` line in the scope of a defer statement that is not one of the pragmas that annotate only the loop after them: a copy of the deferred statement at an exit after it would be compiled under what the pragma sets, and not as at the defer statement (design 6 rule 9) [TC0074]
  [1]

C text is held to the rule too.

  $ cat > scope_c.tc <<'EOF'
  > # 1 "scope_c.tc"
  > # 1 "c.h" 1
  > void g(void);
  > void f(void) {
  >   _Defer g();
  > #pragma GCC optimize("O3")
  >   g();
  > }
  > # 2 "scope_c.tc" 2
  > EOF
  $ ./golden.exe scope_c.tc
  c.h:4: a `#pragma` line in the scope of a defer statement that is not one of the pragmas that annotate only the loop after them: a copy of the deferred statement at an exit after it would be compiled under what the pragma sets, and not as at the defer statement (design 6 rule 9) [TC0074]
  [1]

A loop pragma in the scope stands before no exit, before the end of
the block, or before a statement that holds an exit, where lowering
writes a copy that the pragma would reach. A loop holds a `return` in
its body, and the copy at the `return` would be part of the loop it
annotates.

  $ cat > scope_before_break.tc <<'EOF'
  > void use(int);
  > void f(int c) {
  >   while (c) {
  >     defer use(c);
  > #pragma GCC unroll 2
  >     break;
  >   }
  > }
  > EOF
  $ ./golden.exe scope_before_break.tc
  scope_before_break.tc:5: a `#pragma` line in the scope of a defer statement directly before an exit of the scope, the end of its block, or a statement or declaration that holds an exit, where lowering writes text that the pragma would reach (design 6 rule 9) [TC0074]
  [1]
  $ cat > scope_loop_return.tc <<'EOF'
  > void use(int);
  > void f(int n) {
  >   defer use(n);
  > #pragma GCC unroll 2
  >   for (int i = 0; i < n; i++)
  >     if (i == 5)
  >       return;
  > }
  > EOF
  $ ./golden.exe scope_loop_return.tc
  scope_loop_return.tc:4: a `#pragma` line in the scope of a defer statement directly before an exit of the scope, the end of its block, or a statement or declaration that holds an exit, where lowering writes text that the pragma would reach (design 6 rule 9) [TC0074]
  [1]
  $ cat > scope_before_end.tc <<'EOF'
  > void use(int);
  > void f(int n) {
  >   defer use(n);
  >   use(0);
  > #pragma unroll
  > }
  > EOF
  $ ./golden.exe scope_before_end.tc
  scope_before_end.tc:5: a `#pragma` line in the scope of a defer statement directly before an exit of the scope, the end of its block, or a statement or declaration that holds an exit, where lowering writes text that the pragma would reach (design 6 rule 9) [TC0074]
  [1]

A `goto` that leaves the inner scope alone and the error path of a
try are exits as well.

  $ cat > scope_nested_goto.tc <<'EOF'
  > void use(int);
  > void f(int c) {
  >   defer use(0);
  >   {
  >     defer use(1);
  > #pragma GCC unroll 2
  >     for (int i = 0; i < c; i++)
  >       if (i == 3)
  >         goto out;
  >   }
  > out:;
  > }
  > EOF
  $ ./golden.exe scope_nested_goto.tc
  scope_nested_goto.tc:6: a `#pragma` line in the scope of a defer statement directly before an exit of the scope, the end of its block, or a statement or declaration that holds an exit, where lowering writes text that the pragma would reach (design 6 rule 9) [TC0074]
  [1]
  $ cat > scope_loop_try.tc <<'EOF'
  > type r = result(int, int);
  > r g(int);
  > void use(int);
  > r f(int n) {
  >   defer use(n);
  > #pragma GCC unroll 2
  >   for (int i = 0; i < n; i++)
  >     try g(i);
  >   return Ok(0);
  > }
  > EOF
  $ ./golden.exe scope_loop_try.tc
  scope_loop_try.tc:6: a `#pragma` line in the scope of a defer statement directly before an exit of the scope, the end of its block, or a statement or declaration that holds an exit, where lowering writes text that the pragma would reach (design 6 rule 9) [TC0074]
  [1]

The pragma lines of a later deferred statement in the scope are held
to the rule on deferred statements, which allows a pragma of C11
7.12.2: each copy is a block of its own.

  $ cat > scope_moved_stdc.tc <<'EOF'
  > double r;
  > double f(double a, double b, double c) {
  >   defer r = 0;
  >   defer {
  > #pragma STDC FP_CONTRACT OFF
  >     r = a * b + c;
  >   }
  >   return a * b + c;
  > }
  > EOF
  $ ./golden.exe scope_moved_stdc.tc > /dev/null

A loop that holds a `break` of its own leaves no scope by it, so a loop
pragma may stand before it; and a pragma before the defer statement's
block, or before the defer statement with a `;` between them, is
outside the scope.

  $ cat > scope_loop.tc <<'EOF'
  > void use(int);
  > void f(int n) {
  > #pragma STDC FP_CONTRACT OFF
  >   ;
  >   defer use(n);
  > #pragma GCC unroll 2
  >   for (int i = 0; i < n; i++)
  >     if (i == 5)
  >       break;
  > }
  > EOF
  $ ./golden.exe scope_loop.tc | grep -v '^# ' | grep .
  void use(int);
  void f(int n) {
  #pragma STDC FP_CONTRACT OFF
    ;
    
  #pragma GCC unroll 2
    for (int i = 0; i < n; i++)
      if (i == 5)
        break;
  { use ( n ) ; }
  }

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
  # 1 "label_no_exit.tc"
  void use(void *);
  void f(int c) {
  L:
    {
      
  # 5 "label_no_exit.tc"
  
  # 5 "label_no_exit.tc"
  
      {
        __label__ L;
      L:
        c--;
      }
    
  # 5 "label_no_exit.tc"
  { use ( && L ) ; }
  # 11 "label_no_exit.tc"
  }
  }

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
  # 1 "declared_by_try.tc"
  int x;
  void use(int);
  
  # 3 "declared_by_try.tc"
  #pragma pack(push)
  #pragma pack()
  # 3 "declared_by_try.tc"
  typedef int __tc_arg__i; struct result__ii; typedef struct result__ii result__ii;
  # 3 "declared_by_try.tc"
  #pragma pack(pop)
  # 3 "declared_by_try.tc"
  
  # 3 "declared_by_try.tc"
  result__ii
  # 3 "declared_by_try.tc"
   rd(void);
  
  # 4 "declared_by_try.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "<universe>" 3
  enum result__ii_tag { result__ii_Err, result__ii_Ok }; struct result__ii { enum result__ii_tag tag; union { struct { __tc_arg__i error ; } Err; struct { __tc_arg__i value ; } Ok; } u; };
  # 4 "declared_by_try.tc"
  #pragma pack(pop)
  # 4 "declared_by_try.tc"
  
  # 4 "declared_by_try.tc"
  result__ii
  # 4 "declared_by_try.tc"
   h(void) 
  # 4 "declared_by_try.tc"
  { typedef __typeof__(((__typeof__(h) *)0)()) __tc_ret;
  # 4 "declared_by_try.tc"
  {
    
  # 5 "declared_by_try.tc"
  
  # 5 "declared_by_try.tc"
  
    {
      
  # 7 "declared_by_try.tc"
  const struct result__ii __tc_t0 = rd ( ) ; if (__tc_t0.tag != result__ii_Ok) { if (__tc_t0.tag != result__ii_Err) __builtin_trap();
  # 5 "declared_by_try.tc"
  { use ( x ) ; }
  # 7 "declared_by_try.tc"
  return ((struct result__ii){ .tag = result__ii_Err, .u.Err = { __tc_t0.u.Err.error } }); }
  # 7 "declared_by_try.tc"
  int x = 
  # 7 "declared_by_try.tc"
  __tc_t0.u.Ok.value
  # 7 "declared_by_try.tc"
  ;
      use(x);
    }
    
  # 10 "declared_by_try.tc"
  { __tc_ret __tc_r = (
  # 10 "declared_by_try.tc"
   
  # 10 "declared_by_try.tc"
  ((struct result__ii){ .tag = result__ii_Ok, .u.Ok = { 
  # 10 "declared_by_try.tc"
  0
  # 10 "declared_by_try.tc"
   } })
  # 10 "declared_by_try.tc"
  
  # 10 "declared_by_try.tc"
  );
  # 5 "declared_by_try.tc"
  { use ( x ) ; }
  # 10 "declared_by_try.tc"
  return __tc_r; }
  # 10 "declared_by_try.tc"
  
  
  # 11 "declared_by_try.tc"
  __builtin_trap();
  # 11 "declared_by_try.tc"
  
  # 11 "declared_by_try.tc"
  } }
  # 11 "declared_by_try.tc"
  
  
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
  # 1 "no_exit_in_scope.tc"
  int x;
  void use(int);
  void f(void) { 
  # 3 "no_exit_in_scope.tc"
  
  # 3 "no_exit_in_scope.tc"
   { int x = 0; use(x); } 
  # 3 "no_exit_in_scope.tc"
  { use ( x ) ; }
  # 3 "no_exit_in_scope.tc"
  }

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
  # 1 "end_not_reached.tc"
  int x;
  void use(int);
  void f(int c) {
    
  # 4 "end_not_reached.tc"
  
  # 4 "end_not_reached.tc"
  
    if (c)
      
  # 6 "end_not_reached.tc"
  {
  # 4 "end_not_reached.tc"
  { use ( x ) ; }
  # 6 "end_not_reached.tc"
  return
  # 6 "end_not_reached.tc"
  ; }
  # 6 "end_not_reached.tc"
  
    int x = 0;
    for (;;)
      use(x);
  
  # 10 "end_not_reached.tc"
  __builtin_trap();
  # 10 "end_not_reached.tc"
  }

  $ cat > completed_after.tc <<'EOF'
  > void use(unsigned long);
  > void f(void) {
  >   struct s;
  >   defer use(sizeof(struct s *));
  >   struct s { int a; };
  > }
  > EOF
  $ ./golden.exe completed_after.tc
  # 1 "completed_after.tc"
  void use(unsigned long);
  void f(void) {
    struct s;
    
  # 4 "completed_after.tc"
  
  # 4 "completed_after.tc"
  
    struct s { int a; };
  
  # 4 "completed_after.tc"
  { use ( sizeof ( struct s * ) ) ; }
  # 6 "completed_after.tc"
  }

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

No goto, break or continue leaves the operand of such a return (design 6
rule 12), whether or not it leaves the scope; a jump that stays in the
operand, and a return in it, which leaves the function, are allowed.

  $ cat > operand_goto.tc <<'EOF'
  > void g(void);
  > int f(int c) {
  >   defer g();
  >   if (c)
  >     return ({ if (c > 1) goto out; 1; });
  > out:
  >   return 0;
  > }
  > EOF
  $ ./golden.exe operand_goto.tc
  operand_goto.tc:5: a `goto` that leaves the operand of a `return` in the scope of a defer statement, which lowering writes in a block of its own (design 6 rule 12) [TC0073]
  [1]
  $ cat > operand_break.tc <<'EOF'
  > void g(void);
  > int f(int c) {
  >   defer g();
  >   for (;;)
  >     return ({ if (c) break; 1; });
  >   return 0;
  > }
  > EOF
  $ ./golden.exe operand_break.tc
  operand_break.tc:5: a `break` that leaves the operand of a `return` in the scope of a defer statement, which lowering writes in a block of its own (design 6 rule 12) [TC0073]
  [1]
  $ cat > operand_continue.tc <<'EOF'
  > void g(void);
  > int f(int c) {
  >   while (c--) {
  >     defer g();
  >     return ({ if (c) continue; 1; });
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe operand_continue.tc
  operand_continue.tc:5: a `continue` that leaves the operand of a `return` in the scope of a defer statement, which lowering writes in a block of its own (design 6 rule 12) [TC0073]
  [1]
  $ cat > operand_inner_jumps.tc <<'EOF'
  > void g(void);
  > int f(int c) {
  >   defer g();
  >   return ({
  >     for (;;) { if (c) break; continue; }
  >     if (c) goto in;
  >   in:
  >     if (c > 1) return 2;
  >     1;
  >   });
  > }
  > EOF
  $ ./golden.exe operand_inner_jumps.tc
  # 1 "operand_inner_jumps.tc"
  void g(void);
  int f(int c) 
  # 2 "operand_inner_jumps.tc"
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(c) *)0)) __tc_ret;
  # 2 "operand_inner_jumps.tc"
  {
    
  # 3 "operand_inner_jumps.tc"
  
  # 3 "operand_inner_jumps.tc"
  
    
  # 4 "operand_inner_jumps.tc"
  { __tc_ret __tc_r = (
  # 4 "operand_inner_jumps.tc"
   ({
      for (;;) { if (c) break; continue; }
      if (c) goto in;
    in:
      if (c > 1) 
  # 8 "operand_inner_jumps.tc"
  { __tc_ret __tc_r = (
  # 8 "operand_inner_jumps.tc"
   2
  # 8 "operand_inner_jumps.tc"
  );
  # 3 "operand_inner_jumps.tc"
  { g ( ) ; }
  # 8 "operand_inner_jumps.tc"
  return __tc_r; }
  # 8 "operand_inner_jumps.tc"
  
      1;
    })
  # 10 "operand_inner_jumps.tc"
  );
  # 3 "operand_inner_jumps.tc"
  { g ( ) ; }
  # 10 "operand_inner_jumps.tc"
  return __tc_r; }
  # 10 "operand_inner_jumps.tc"
  
  
  # 11 "operand_inner_jumps.tc"
  __builtin_trap();
  # 11 "operand_inner_jumps.tc"
  
  # 11 "operand_inner_jumps.tc"
  } }
  # 11 "operand_inner_jumps.tc"
  

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
  # 1 "return_outside.tc"
  void g(void);
  int f(void) {
    { 
  # 3 "return_outside.tc"
  
  # 3 "return_outside.tc"
   
  # 3 "return_outside.tc"
  { g ( ) ; }
  # 3 "return_outside.tc"
  }
    return sizeof(enum { K = 5 });
  }

  $ cat > return_uses.tc <<'EOF'
  > struct p { int a; };
  > void g(void);
  > int f(void) {
  >   defer g();
  >   return (struct p){1}.a;
  > }
  > EOF
  $ ./golden.exe return_uses.tc
  # 1 "return_uses.tc"
  struct p { int a; };
  void g(void);
  int f(void) 
  # 3 "return_uses.tc"
  { typedef __typeof__(((__typeof__(f) *)0)()) __tc_ret;
  # 3 "return_uses.tc"
  {
    
  # 4 "return_uses.tc"
  
  # 4 "return_uses.tc"
  
    
  # 5 "return_uses.tc"
  { __tc_ret __tc_r = (
  # 5 "return_uses.tc"
   (struct p){1}.a
  # 5 "return_uses.tc"
  );
  # 4 "return_uses.tc"
  { g ( ) ; }
  # 5 "return_uses.tc"
  return __tc_r; }
  # 5 "return_uses.tc"
  
  
  # 6 "return_uses.tc"
  __builtin_trap();
  # 6 "return_uses.tc"
  
  # 6 "return_uses.tc"
  } }
  # 6 "return_uses.tc"
  

A function that returns a value and holds a `return e;` in the scope of
a defer statement names its return type through a call of its own name
(design 13.5). Where that call cannot be written, the function is
refused, each case with a code of its own; a function without such a
`return` is not.

  $ cat > form_allowed.tc <<'EOF'
  > void g(void);
  > int f(int a, char *b) { defer g(); return a + *b; }
  > int h(void) { defer g(); return 1; }
  > void v(int) { defer g(); return; }
  > long w(int w) { if (w) return 1; { defer g(); } return 0; }
  > void x(void) { defer g(); return g(); }
  > EOF
  $ ./golden.exe form_allowed.tc
  # 1 "form_allowed.tc"
  void g(void);
  int f(int a, char *b) 
  # 2 "form_allowed.tc"
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(a) *)0, *(__typeof__(b) *)0)) __tc_ret;
  # 2 "form_allowed.tc"
  { 
  # 2 "form_allowed.tc"
  
  # 2 "form_allowed.tc"
   
  # 2 "form_allowed.tc"
  { __tc_ret __tc_r = (
  # 2 "form_allowed.tc"
   a + *b
  # 2 "form_allowed.tc"
  ); { g ( ) ; } return __tc_r; }
  # 2 "form_allowed.tc"
   
  # 2 "form_allowed.tc"
  __builtin_trap();
  # 2 "form_allowed.tc"
  
  # 2 "form_allowed.tc"
  } }
  # 2 "form_allowed.tc"
  
  int h(void) 
  # 3 "form_allowed.tc"
  { typedef __typeof__(((__typeof__(h) *)0)()) __tc_ret;
  # 3 "form_allowed.tc"
  { 
  # 3 "form_allowed.tc"
  
  # 3 "form_allowed.tc"
   
  # 3 "form_allowed.tc"
  { __tc_ret __tc_r = (
  # 3 "form_allowed.tc"
   1
  # 3 "form_allowed.tc"
  ); { g ( ) ; } return __tc_r; }
  # 3 "form_allowed.tc"
   
  # 3 "form_allowed.tc"
  __builtin_trap();
  # 3 "form_allowed.tc"
  
  # 3 "form_allowed.tc"
  } }
  # 3 "form_allowed.tc"
  
  void v(int) { 
  # 4 "form_allowed.tc"
  
  # 4 "form_allowed.tc"
   
  # 4 "form_allowed.tc"
  { { g ( ) ; }
  # 4 "form_allowed.tc"
  return
  # 4 "form_allowed.tc"
  ; }
  # 4 "form_allowed.tc"
   
  # 4 "form_allowed.tc"
  __builtin_trap();
  # 4 "form_allowed.tc"
  }
  long w(int w) { if (w) return 1; { 
  # 5 "form_allowed.tc"
  
  # 5 "form_allowed.tc"
   
  # 5 "form_allowed.tc"
  { g ( ) ; }
  # 5 "form_allowed.tc"
  } return 0; }
  void x(void) { 
  # 6 "form_allowed.tc"
  
  # 6 "form_allowed.tc"
   
  # 6 "form_allowed.tc"
  {
  # 6 "form_allowed.tc"
   g()
  # 6 "form_allowed.tc"
  ; { g ( ) ; } return; }
  # 6 "form_allowed.tc"
   
  # 6 "form_allowed.tc"
  __builtin_trap();
  # 6 "form_allowed.tc"
  }

The parameter list declares the function's own name, which would hide
the function at the call, as a parameter or as an enumeration constant.

  $ cat > own_name.tc <<'EOF'
  > void g(void);
  > long f(int f) { defer g(); return f; }
  > EOF
  $ ./golden.exe own_name.tc
  own_name.tc:2: the parameter list declares 'f', the name of the function, which hides the function from the call of it that the form of a `return e;` in the scope of a `defer` statement writes; rename it (design 13.5) [TC0065]
  [1]

  $ cat > own_enumerator.tc <<'EOF'
  > void g(void);
  > long f(enum { f } e) { defer g(); return e; }
  > EOF
  $ ./golden.exe own_enumerator.tc
  own_enumerator.tc:2: the parameter list declares 'f', the name of the function, which hides the function from the call of it that the form of a `return e;` in the scope of a `defer` statement writes; rename it (design 13.5) [TC0065]
  [1]

  $ cat > own_name_c.tc <<'EOF'
  > # 1 "own_name_c.tc"
  > # 1 "c.h" 1
  > void g(void);
  > long f(int f) { _Defer g(); return f; }
  > # 2 "own_name_c.tc" 2
  > EOF
  $ ./golden.exe own_name_c.tc
  c.h:2: the parameter list declares 'f', the name of the function, which hides the function from the call of it that the form of a `return e;` in the scope of a `defer` statement writes; rename it (design 13.5) [TC0065]
  [1]

  $ cat > own_name_old_style.tc <<'EOF'
  > void g(void);
  > long f(f) long f; { defer g(); return f; }
  > EOF
  $ ./golden.exe own_name_old_style.tc
  own_name_old_style.tc:2: the parameter list declares 'f', the name of the function, which hides the function from the call of it that the form of a `return e;` in the scope of a `defer` statement writes; rename it (design 13.5) [TC0065]
  [1]

A name that a nested parameter list declares hides nothing at the call.

  $ cat > own_name_nested.tc <<'EOF'
  > void g(void);
  > long f(long (*p)(int f)) { defer g(); return p(0); }
  > EOF
  $ ./golden.exe own_name_nested.tc
  # 1 "own_name_nested.tc"
  void g(void);
  long f(long (*p)(int f)) 
  # 2 "own_name_nested.tc"
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(p) *)0)) __tc_ret;
  # 2 "own_name_nested.tc"
  { 
  # 2 "own_name_nested.tc"
  
  # 2 "own_name_nested.tc"
   
  # 2 "own_name_nested.tc"
  { __tc_ret __tc_r = (
  # 2 "own_name_nested.tc"
   p(0)
  # 2 "own_name_nested.tc"
  ); { g ( ) ; } return __tc_r; }
  # 2 "own_name_nested.tc"
   
  # 2 "own_name_nested.tc"
  __builtin_trap();
  # 2 "own_name_nested.tc"
  
  # 2 "own_name_nested.tc"
  } }
  # 2 "own_name_nested.tc"
  

A prototype scope of the head other than the parameter list, as that of
a returned function pointer or of a member, is another scope.

  $ cat > head_prototypes.tc <<'EOF'
  > void g(void);
  > long (*f(int a))(int f) { defer g(); return 0; }
  > long (*h(int a))(int b) { int b = a; defer g(); return 0; }
  > long (*k(int a))(struct s *b) { struct s { int x; }; defer g(); return 0; }
  > struct r { int (*fp)(int x); } m(int a) {
  >   int x = a;
  >   defer g();
  >   return (struct r){0};
  > }
  > EOF
  $ ./golden.exe head_prototypes.tc
  # 1 "head_prototypes.tc"
  void g(void);
  long (*f(int a))(int f) 
  # 2 "head_prototypes.tc"
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(a) *)0)) __tc_ret;
  # 2 "head_prototypes.tc"
  { 
  # 2 "head_prototypes.tc"
  
  # 2 "head_prototypes.tc"
   
  # 2 "head_prototypes.tc"
  { __tc_ret __tc_r = (
  # 2 "head_prototypes.tc"
   0
  # 2 "head_prototypes.tc"
  ); { g ( ) ; } return __tc_r; }
  # 2 "head_prototypes.tc"
   
  # 2 "head_prototypes.tc"
  __builtin_trap();
  # 2 "head_prototypes.tc"
  
  # 2 "head_prototypes.tc"
  } }
  # 2 "head_prototypes.tc"
  
  long (*h(int a))(int b) 
  # 3 "head_prototypes.tc"
  { typedef __typeof__(((__typeof__(h) *)0)(*(__typeof__(a) *)0)) __tc_ret;
  # 3 "head_prototypes.tc"
  { int b = a; 
  # 3 "head_prototypes.tc"
  
  # 3 "head_prototypes.tc"
   
  # 3 "head_prototypes.tc"
  { __tc_ret __tc_r = (
  # 3 "head_prototypes.tc"
   0
  # 3 "head_prototypes.tc"
  ); { g ( ) ; } return __tc_r; }
  # 3 "head_prototypes.tc"
   
  # 3 "head_prototypes.tc"
  __builtin_trap();
  # 3 "head_prototypes.tc"
  
  # 3 "head_prototypes.tc"
  } }
  # 3 "head_prototypes.tc"
  
  long (*k(int a))(struct s *b) 
  # 4 "head_prototypes.tc"
  { typedef __typeof__(((__typeof__(k) *)0)(*(__typeof__(a) *)0)) __tc_ret;
  # 4 "head_prototypes.tc"
  { struct s { int x; }; 
  # 4 "head_prototypes.tc"
  
  # 4 "head_prototypes.tc"
   
  # 4 "head_prototypes.tc"
  { __tc_ret __tc_r = (
  # 4 "head_prototypes.tc"
   0
  # 4 "head_prototypes.tc"
  ); { g ( ) ; } return __tc_r; }
  # 4 "head_prototypes.tc"
   
  # 4 "head_prototypes.tc"
  __builtin_trap();
  # 4 "head_prototypes.tc"
  
  # 4 "head_prototypes.tc"
  } }
  # 4 "head_prototypes.tc"
  
  struct r { int (*fp)(int x); } m(int a) 
  # 5 "head_prototypes.tc"
  { typedef __typeof__(((__typeof__(m) *)0)(*(__typeof__(a) *)0)) __tc_ret;
  # 5 "head_prototypes.tc"
  {
    int x = a;
    
  # 7 "head_prototypes.tc"
  
  # 7 "head_prototypes.tc"
  
    
  # 8 "head_prototypes.tc"
  { __tc_ret __tc_r = (
  # 8 "head_prototypes.tc"
   (struct r){0}
  # 8 "head_prototypes.tc"
  );
  # 7 "head_prototypes.tc"
  { g ( ) ; }
  # 8 "head_prototypes.tc"
  return __tc_r; }
  # 8 "head_prototypes.tc"
  
  
  # 9 "head_prototypes.tc"
  __builtin_trap();
  # 9 "head_prototypes.tc"
  
  # 9 "head_prototypes.tc"
  } }
  # 9 "head_prototypes.tc"
  

The outermost block of the body declares a name that the parameter list
declares. C refuses an ordinary identifier there and lets a tag be
completed, which the body's block of its own would make another tag.

  $ cat > redeclared_tag.tc <<'EOF'
  > void g(void);
  > int f(struct s *p) {
  >   struct s { int a; };
  >   defer g();
  >   return p->a;
  > }
  > EOF
  $ ./golden.exe redeclared_tag.tc
  redeclared_tag.tc:3: the outermost block of the body declares 's' again, which the parameter list declares; the form of a `return e;` in the scope of a `defer` statement puts the body in a block of its own, where this would declare another (design 13.5) [TC0066]
  [1]

  $ cat > redeclared_ordinary.tc <<'EOF'
  > void g(void);
  > int f(int a) { int a = 0; defer g(); return a; }
  > EOF
  $ ./golden.exe redeclared_ordinary.tc
  redeclared_ordinary.tc:2: 'a' is declared twice in one scope without linkage (C11 6.7p3)
  [1]

A tag that an inner block declares is another tag in C as well.

  $ cat > inner_tag.tc <<'EOF'
  > void g(void);
  > int f(struct s *p) {
  >   { struct s { int b; }; }
  >   defer g();
  >   return p != 0;
  > }
  > EOF
  $ ./golden.exe inner_tag.tc
  # 1 "inner_tag.tc"
  void g(void);
  int f(struct s *p) 
  # 2 "inner_tag.tc"
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(p) *)0)) __tc_ret;
  # 2 "inner_tag.tc"
  {
    { struct s { int b; }; }
    
  # 4 "inner_tag.tc"
  
  # 4 "inner_tag.tc"
  
    
  # 5 "inner_tag.tc"
  { __tc_ret __tc_r = (
  # 5 "inner_tag.tc"
   p != 0
  # 5 "inner_tag.tc"
  );
  # 4 "inner_tag.tc"
  { g ( ) ; }
  # 5 "inner_tag.tc"
  return __tc_r; }
  # 5 "inner_tag.tc"
  
  
  # 6 "inner_tag.tc"
  __builtin_trap();
  # 6 "inner_tag.tc"
  
  # 6 "inner_tag.tc"
  } }
  # 6 "inner_tag.tc"
  

Two declarations of the function carry `target` attributes whose
arguments differ, token for token: they declare two versions.

  $ cat > target_versions.tc <<'EOF'
  > void g(void);
  > int f(void) __attribute__((target("avx2,fma")));
  > __attribute__((target("fma,avx2"))) int f(void) { defer g(); return 1; }
  > EOF
  $ ./golden.exe target_versions.tc
  target_versions.tc:3: 'f' is declared with `target` attributes whose arguments differ, as versions of one function, which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes cannot name (design 13.5) [TC0067]
  [1]

  $ cat > target_same.tc <<'EOF'
  > void g(void);
  > int f(void) __attribute__((target("avx2")));
  > __attribute__((target("avx2"))) int f(void) { defer g(); return 1; }
  > EOF
  $ ./golden.exe target_same.tc
  # 1 "target_same.tc"
  void g(void);
  int f(void) __attribute__((target("avx2")));
  __attribute__((target("avx2"))) int f(void) 
  # 3 "target_same.tc"
  { typedef __typeof__(((__typeof__(f) *)0)()) __tc_ret;
  # 3 "target_same.tc"
  { 
  # 3 "target_same.tc"
  
  # 3 "target_same.tc"
   
  # 3 "target_same.tc"
  { __tc_ret __tc_r = (
  # 3 "target_same.tc"
   1
  # 3 "target_same.tc"
  ); { g ( ) ; } return __tc_r; }
  # 3 "target_same.tc"
   
  # 3 "target_same.tc"
  __builtin_trap();
  # 3 "target_same.tc"
  
  # 3 "target_same.tc"
  } }
  # 3 "target_same.tc"
  

The `target` attributes of one declaration are one fact of it.

  $ cat > target_pair.tc <<'EOF'
  > void g(void);
  > int f(int a) __attribute__((target("avx2"), target("fma")));
  > __attribute__((target("avx2"), target("fma"))) int f(int a) {
  >   defer g();
  >   return a;
  > }
  > EOF
  $ ./golden.exe target_pair.tc
  # 1 "target_pair.tc"
  void g(void);
  int f(int a) __attribute__((target("avx2"), target("fma")));
  __attribute__((target("avx2"), target("fma"))) int f(int a) 
  # 3 "target_pair.tc"
  { typedef __typeof__(((__typeof__(f) *)0)(*(__typeof__(a) *)0)) __tc_ret;
  # 3 "target_pair.tc"
  {
    
  # 4 "target_pair.tc"
  
  # 4 "target_pair.tc"
  
    
  # 5 "target_pair.tc"
  { __tc_ret __tc_r = (
  # 5 "target_pair.tc"
   a
  # 5 "target_pair.tc"
  );
  # 4 "target_pair.tc"
  { g ( ) ; }
  # 5 "target_pair.tc"
  return __tc_r; }
  # 5 "target_pair.tc"
  
  
  # 6 "target_pair.tc"
  __builtin_trap();
  # 6 "target_pair.tc"
  
  # 6 "target_pair.tc"
  } }
  # 6 "target_pair.tc"
  

A declaration of the function carries a marked attribute (design 13.3),
under any of its spellings, or follows a Clang overload of its name.

  $ cat > marked.tc <<'EOF'
  > void g(void);
  > __attribute__((overloadable)) int f(int a) { defer g(); return a; }
  > EOF
  $ ./golden.exe marked.tc
  marked.tc:2: a declaration of 'f' carries the attribute 'overloadable', with which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes may name more than one function or be an error (design 13.5) [TC0068]
  [1]

  $ cat > marked_earlier.tc <<'EOF'
  > void g(void);
  > [[clang::availability(macos, introduced = 10.15)]] int f(int a);
  > int f(int a) { defer g(); return a; }
  > EOF
  $ ./golden.exe marked_earlier.tc
  marked_earlier.tc:3: a declaration of 'f' carries the attribute 'clang::availability', with which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes may name more than one function or be an error (design 13.5) [TC0068]
  [1]

  $ cat > marked_beside.tc <<'EOF'
  > void g(void);
  > int f(long a) __attribute__((overloadable));
  > int f(int a) { defer g(); return a; }
  > EOF
  $ ./golden.exe marked_beside.tc
  marked_beside.tc:3: a declaration of 'f' carries the attribute 'overloadable', with which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes may name more than one function or be an error (design 13.5) [TC0068]
  [1]

  $ cat > marked_inner.tc <<'EOF'
  > void g(void);
  > int (__attribute__((unavailable)) f)(int a) { defer g(); return a; }
  > EOF
  $ ./golden.exe marked_inner.tc
  marked_inner.tc:2: a declaration of 'f' carries the attribute 'unavailable', with which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes may name more than one function or be an error (design 13.5) [TC0068]
  [1]

A parameter has no name; `(void)` has none to give.

  $ cat > unnamed.tc <<'EOF'
  > void g(void);
  > int f(int a, char *) { defer g(); return a; }
  > EOF
  $ ./golden.exe unnamed.tc
  unnamed.tc:2: a parameter without a name, of which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes cannot pass an lvalue; name it (design 13.5) [TC0069]
  [1]

  $ cat > unnamed_only.tc <<'EOF'
  > void g(void);
  > int f(int) { defer g(); return 1; }
  > EOF
  $ ./golden.exe unnamed_only.tc
  unnamed_only.tc:2: a parameter without a name, of which the call of 'f' that the form of a `return e;` in the scope of a `defer` statement writes cannot pass an lvalue; name it (design 13.5) [TC0069]
  [1]

  $ cat > void_typedef.tc <<'EOF'
  > typedef void nothing;
  > void g(void);
  > int f(nothing) { defer g(); return 1; }
  > EOF
  $ ./golden.exe void_typedef.tc
  # 1 "void_typedef.tc"
  typedef void nothing;
  void g(void);
  int f(nothing) 
  # 3 "void_typedef.tc"
  { typedef __typeof__(((__typeof__(f) *)0)()) __tc_ret;
  # 3 "void_typedef.tc"
  { 
  # 3 "void_typedef.tc"
  
  # 3 "void_typedef.tc"
   
  # 3 "void_typedef.tc"
  { __tc_ret __tc_r = (
  # 3 "void_typedef.tc"
   1
  # 3 "void_typedef.tc"
  ); { g ( ) ; } return __tc_r; }
  # 3 "void_typedef.tc"
   
  # 3 "void_typedef.tc"
  __builtin_trap();
  # 3 "void_typedef.tc"
  
  # 3 "void_typedef.tc"
  } }
  # 3 "void_typedef.tc"
  

In a function that returns void, the operand of a `return e;` is a void
expression, in Type-C text and in C text.

  $ cat > void_value.tc <<'EOF'
  > void g(void);
  > void f(int c) { defer g(); if (c) return g(); return c; }
  > EOF
  $ ./golden.exe void_value.tc
  void_value.tc:2: a `return e;` of a value in the scope of a `defer` statement, in a function that returns void: lowering writes it as the statement `e;`, which loses C's diagnostic of the return (C11 6.8.6.4p1) (design 13.5) [TC0070]
  [1]

  $ cat > void_value_c.tc <<'EOF'
  > # 1 "void_value_c.tc"
  > # 1 "c.h" 1
  > void g(void);
  > void f(int c) { _Defer g(); return c; }
  > # 2 "void_value_c.tc" 2
  > EOF
  $ ./golden.exe void_value_c.tc
  c.h:2: a `return e;` of a value in the scope of a `defer` statement, in a function that returns void: lowering writes it as the statement `e;`, which loses C's diagnostic of the return (C11 6.8.6.4p1) (design 13.5) [TC0070]
  [1]

  $ cat > void_unknown.tc <<'EOF'
  > typedef int vector __attribute__((vector_size(16)));
  > vector h(void);
  > void g(void);
  > void f(void) { defer g(); return h(); }
  > EOF
  $ ./golden.exe void_unknown.tc
  void_unknown.tc:4: a `return e;` in the scope of a `defer` statement, in a function that returns void, whose operand depends on the attribute 'vector_size' at void_unknown.tc:1: typec cannot tell whether it is void, which lowering needs to know (design 13.5) [TC0070]
  [1]

A return type that typec does not know may be void, so a `return e;`
depends on it.

  $ cat > unknown_return.tc <<'EOF'
  > typedef int vector __attribute__((vector_size(16)));
  > void g(void);
  > vector f(vector v) { defer g(); return v; }
  > EOF
  $ ./golden.exe unknown_return.tc
  unknown_return.tc:3: the form of a `return e;` in the scope of a `defer` statement depends on the attribute 'vector_size' at unknown_return.tc:1, which typec does not type yet (design 13.3) [TC0031]
  [1]

  $ cat > unknown_bare_return.tc <<'EOF'
  > typedef int vector __attribute__((vector_size(16)));
  > void g(void);
  > vector f(int) { defer g(); return; }
  > EOF
  $ ./golden.exe unknown_bare_return.tc
  # 1 "unknown_bare_return.tc"
  typedef int vector __attribute__((vector_size(16)));
  void g(void);
  vector f(int) { 
  # 3 "unknown_bare_return.tc"
  
  # 3 "unknown_bare_return.tc"
   
  # 3 "unknown_bare_return.tc"
  { { g ( ) ; }
  # 3 "unknown_bare_return.tc"
  return
  # 3 "unknown_bare_return.tc"
  ; }
  # 3 "unknown_bare_return.tc"
   
  # 3 "unknown_bare_return.tc"
  __builtin_trap();
  # 3 "unknown_bare_return.tc"
  }

A defer statement, its exits and the end of its block in text that
lowering drops, here a statement expression in the type name of an
answered __builtin_types_compatible_p, go with that text: it never runs.
The defer around it is written as anywhere else.

  $ cat > dropped.tc <<'EOF'
  > type d = distinct int;
  > void g(int);
  > int f(void) {
  >   defer g(0);
  >   int c = __builtin_types_compatible_p(
  >       __typeof__(({ for (;;) { defer g(1); break; } 1; })), d);
  >   return c;
  > }
  > EOF
  $ ./golden.exe dropped.tc | grep -v '^# ' | grep .
  typedef
   int
  d
  ;
  void g(int);
  int f(void) 
  { typedef __typeof__(((__typeof__(f) *)0)()) __tc_ret;
  {
    
    int c = 
  0
  ;
    
  { __tc_ret __tc_r = (
   c
  );
  { g ( 0 ) ; }
  return __tc_r; }
  __builtin_trap();
  } }
