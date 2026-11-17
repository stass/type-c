SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Nested patterns in a single-pattern test (design 4.6, 4.7 rule 9). The
pattern of a test nests as a label does, its sub-patterns are typed by
their position, and a constructor with fields may omit its field list
at any depth of a test and at no depth of a label.

  $ cat > types.h <<'EOF'
  > type eval_error = | DivByZero | Overflow;
  > type res = | Ok(int value) | Err(eval_error error);
  > type expr = | Num(int value) | Add(const expr *l, const expr *r);
  > type list = | Nil | Cons(int head, const list *tail);
  > EOF

A sub-pattern stands at a position as in a label: an identifier alone
at a field of variant type names a constructor, and a misspelled one is
refused (rule 3).

  $ cat types.h - > misspelled.tc <<'EOF'
  > int f(res r) {
  >   if (case Err(DivByZer) = r)
  >     return 1;
  >   return 0;
  > }
  > EOF
  $ ./golden.exe misspelled.tc
  misspelled.tc:6: error: 'DivByZer' names no constructor of the variant 'eval_error'; a field of a variant type is bound with its type, as in `T x` [match-pattern]
  [1]
  $ cat types.h - > pointer.tc <<'EOF'
  > int f(const list *l) {
  >   if (case Cons(_, Nil) = *l)
  >     return 1;
  >   return 0;
  > }
  > EOF
  $ ./golden.exe pointer.tc
  pointer.tc:6: error: the binding 'Nil' of a pointer to the variant 'list' has the name of one of its constructors; `*Nil` matches that constructor, and a binding of the pointer takes another name [match-pattern]
  [1]

A field list left out at depth: a test takes it, a label refuses it.

  $ cat types.h - > omitted.tc <<'EOF'
  > int f(const expr *e) {
  >   match (*e) {
  >   case Add(*Num, _):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe omitted.tc
  omitted.tc:7: error: the case label 'Num' omits the field list of a constructor with 1 field(s); write 'Num(_)' to ignore the fields [match-pattern]
  [1]

A binding at depth is in the scope of the statement, which may not
declare it again (4.6 rule 4).

  $ cat types.h - > redeclared.tc <<'EOF'
  > int f(const expr *e) {
  >   if (case Add(*Num(a), _) = *e) {
  >     int a = 0;
  >     return a;
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe redeclared.tc
  redeclared.tc:7: error: 'a' is declared twice in one scope without linkage (C11 6.7p3)
  [1]

The bounds on selection hold a test as they hold a match (rule 10).

  $ chain() {
  >   pattern=End
  >   for _ in $(seq "$1"); do pattern="Next(*$pattern)"; done
  >   printf 'type chain = | End | Next(const chain *n);\n'
  >   printf 'int f(chain c) {\n  if (case %s = c)\n' "$pattern"
  >   printf '    return 1;\n  return 0;\n}\n'
  > }
  $ chain 126 > deepest.tc
  $ ./golden.exe deepest.tc | grep -c __tc_arm
  1
  $ chain 127 > deeper.tc
  $ ./golden.exe deeper.tc
  deeper.tc:3: error: the selection tree of the test is deeper than 127 nodes, the most that typec takes (a translation limit, C11 5.2.4.1)
  [1]

The lowered form: the selection tree of the one pattern sets __tc_arm0
to 1 at its leaf and to 0 at every other, and the if of the test reads
it; the false branch checks no tag, since the tree has (13.5). A pattern
that reads no tag below its constructor keeps the form of a flat test.

  $ cat types.h - > lower.tc <<'EOF'
  > int f(res r) {
  >   if (case Err(DivByZero) = r)
  >     return -1;
  >   else
  >     return 0;
  > }
  > int g(const list *l) {
  >   int sum = 0;
  >   while (case Cons(h, *Cons(_, t)) = *l) {
  >     sum += h;
  >     l = t;
  >   }
  >   return sum;
  > }
  > int k(const expr *e) {
  >   if (case Add(*Num, r) = *e)
  >     return k(r);
  >   if (case Add = *e)
  >     return 1;
  >   return 0;
  > }
  > EOF
  $ ./golden.exe lower.tc | grep -v '^# ' | sed 's/ *$//' | grep . |
  >   sed -n '/^int f/,$p'
  int f(res r) {
  { const struct res *const __tc_match0 = &(
   r
  ); unsigned __tc_arm0; switch (__tc_match0->tag) { case res_Err: switch (__tc_match0->u.Err.error.tag) { case eval_error_DivByZero: __tc_arm0 = 1; break; case eval_error_Overflow: __tc_arm0 = 0; break; case __tc_tag_max__eval_error_tag: default: __builtin_trap(); } break; case res_Ok: __tc_arm0 = 0; break; case __tc_tag_max__res_tag: default: __builtin_trap(); } if (__tc_arm0 == 1) {
      return -1;
   }
  else {
      return 0;
   } }
  }
  int g(const list *l) {
    int sum = 0;
  for (;;) { const struct list *const __tc_match1 = &(
   *l
  ); unsigned __tc_arm1; const struct list *__tc_p1_1 = 0; switch (__tc_match1->tag) { case list_Cons: __tc_p1_1 = __tc_match1->u.Cons.tail; switch (__tc_p1_1->tag) { case list_Cons: __tc_arm1 = 1; break; case list_Nil: __tc_arm1 = 0; break; case __tc_tag_max__list_tag: default: __builtin_trap(); } break; case list_Nil: __tc_arm1 = 0; break; case __tc_tag_max__list_tag: default: __builtin_trap(); } if (__tc_arm1 == 1) { const __typeof__(__tc_match1->u.Cons.head) h = __tc_match1->u.Cons.head; const __typeof__(__tc_p1_1->u.Cons.tail) t = __tc_p1_1->u.Cons.tail;
   {
      sum += h;
      l = t;
    }
   } else { break; } }
  return sum;
  }
  int k(const expr *e) {
  { const struct expr *const __tc_match2 = &(
   *e
  ); unsigned __tc_arm2; const struct expr *__tc_p2_1 = 0; switch (__tc_match2->tag) { case expr_Add: __tc_p2_1 = __tc_match2->u.Add.l; switch (__tc_p2_1->tag) { case expr_Num: __tc_arm2 = 1; break; case expr_Add: __tc_arm2 = 0; break; case __tc_tag_max__expr_tag: default: __builtin_trap(); } break; case expr_Num: __tc_arm2 = 0; break; case __tc_tag_max__expr_tag: default: __builtin_trap(); } if (__tc_arm2 == 1) { const __typeof__(__tc_match2->u.Add.r) r = __tc_match2->u.Add.r;
      return k(r);
   } else { } }
  { const struct expr *const __tc_match3 = &(
   *e
  ); const __typeof__(__tc_match3->tag) __tc_tag3 = __tc_match3->tag; if (__tc_tag3 == expr_Add) {
      return 1;
   } else { switch (__tc_tag3) { case expr_Num: case expr_Add: break; case __tc_tag_max__expr_tag: default: __builtin_trap(); } } }
  return 0;
  }
