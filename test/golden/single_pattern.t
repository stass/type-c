SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A single-pattern test (design 4.6) becomes a block that holds its
operand as a match holds its scrutinee, reads the tag once into a
local, and tests it with an if. The true branch is the controlled
statement with the bindings declared first in its block, after its GNU
local labels, or in a block made around a statement that is not a
compound statement. The false branch traps on a tag that is no
constructor's, with the cases of a match, and then holds the else
statement. A while test is the same block as the body of an endless
loop, whose false branch ends in break (design 13.5, 4.5, 10.5).

  $ cat > lower.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(const list *l, list v) {
  >   long total = 0;
  >   if (case Cons(head, _) = *l)
  >     total = head;
  >   if (case Nil = v) {
  >     __label__ again;
  >   again:
  >     total++;
  >   } else
  >     total--;
  >   while (case Cons(head, tail) = *l) {
  >     total += head;
  >     l = tail;
  >   }
  >   if (case Cons(head, _) = v) if (case Nil = *l) return head;
  >   return total;
  > }
  > EOF
  $ ./golden.exe lower.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^long f/,$p'
  long f(const list *l, list v) {
    long total = 0;
  { const struct list *const __tc_match = &(
   *l
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Cons)
  { const __typeof__(__tc_match->u.Cons.head) head = __tc_match->u.Cons.head;
  total = head;
   } else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } } }
  { const struct list *const __tc_match = &(
   v
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Nil)
   {
      __label__ again;
    again:
      total++;
    }
  else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); }
      total--;
   } }
  for (;;) { const struct list *const __tc_match = &(
   *l
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Cons)
   {
   const __typeof__(__tc_match->u.Cons.head) head = __tc_match->u.Cons.head; const __typeof__(__tc_match->u.Cons.tail) tail = __tc_match->u.Cons.tail;
  total += head;
      l = tail;
    }
   else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } break; } }
  { const struct list *const __tc_match = &(
   v
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Cons)
  { const __typeof__(__tc_match->u.Cons.head) head = __tc_match->u.Cons.head;
  { const struct list *const __tc_match = &(
   *l
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Nil)
  {
  return head;
   } else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } } }
   } else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } } }
  return total;
  }

A break or continue in the controlled statement stays unchanged: in an
if it goes to the loop around the if, and in a while it leaves or
repeats the loop that the test becomes. So does one in a statement
expression in the operand, which the lowering evaluates in the block
before the if, or in the body of that loop (design 4.4).

  $ cat > jumps.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(const list *l, int n) {
  >   long total = 0;
  >   for (; n; n--)
  >     if (case Cons(head, _) = ({ if (n == 2) continue; *l; }))
  >       total += head;
  >   while (case Cons(head, tail) = ({ if (total > 9) break; *l; })) {
  >     l = tail;
  >     if (head < 0)
  >       break;
  >     total += head;
  >   }
  >   return total;
  > }
  > EOF
  $ ./golden.exe jumps.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^long f/,$p'
  long f(const list *l, int n) {
    long total = 0;
    for (; n; n--)
  { const struct list __tc_copy = (
   ({ if (n == 2) continue; *l; })
  ), *const __tc_match = &__tc_copy; const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Cons)
  { const __typeof__(__tc_match->u.Cons.head) head = __tc_match->u.Cons.head;
  total += head;
   } else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } } }
  for (;;) { const struct list __tc_copy = (
   ({ if (total > 9) break; *l; })
  ), *const __tc_match = &__tc_copy; const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Cons)
   {
   const __typeof__(__tc_match->u.Cons.head) head = __tc_match->u.Cons.head; const __typeof__(__tc_match->u.Cons.tail) tail = __tc_match->u.Cons.tail;
  l = tail;
      if (head < 0)
        break;
      total += head;
    }
   else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } break; } }
  return total;
  }

Statements that end at one token nest, and the inner one closes first:
a test that ends a match arm, an else-if chain of tests, and a while
test whose body is an if test with an else.

  $ cat > nested.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(const list *l, list v) {
  >   match (v) {
  >   case Nil:
  >     return 0;
  >   case Cons(_, _):
  >     if (case Nil = *l) return 1; else return 2;
  >   }
  > }
  > long g(const list *l, list v) {
  >   if (case Nil = v) return 0; else if (case Nil = *l) return 1; else return 2;
  > }
  > long h(const list *l) {
  >   long n = 0;
  >   while (case Cons(_, tail) = *l) if (case Nil = *tail) break; else l = tail, n++;
  >   return n;
  > }
  > EOF
  $ ./golden.exe nested.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^long f/,$p'
  long f(const list *l, list v) {
  { const struct list *const __tc_match = &(
  v
  ); switch (__tc_match->tag) {
  case list_Nil: {
      return 0;
   __builtin_trap(); }
  case list_Cons: {
  { const struct list *const __tc_match = &(
   *l
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Nil)
  {
  return 1;
   }
  else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); }
   return 2;
   } }
   __builtin_trap(); }
  default: __builtin_trap(); } }
  }
  long g(const list *l, list v) {
  { const struct list *const __tc_match = &(
   v
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Nil)
  {
  return 0;
   }
  else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); }
  { const struct list *const __tc_match = &(
   *l
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Nil)
  {
  return 1;
   }
  else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); }
   return 2;
   } }
   } }
  }
  long h(const list *l) {
    long n = 0;
  for (;;) { const struct list *const __tc_match = &(
   *l
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Cons)
  { const __typeof__(__tc_match->u.Cons.tail) tail = __tc_match->u.Cons.tail;
  { const struct list *const __tc_match = &(
   *tail
  ); const __typeof__(__tc_match->tag) __tc_tag = __tc_match->tag; if (__tc_tag == list_Nil)
  {
  break;
   }
  else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); }
   l = tail, n++;
   } }
   } else { switch (__tc_tag) { case list_Nil: case list_Cons: break; default: __builtin_trap(); } break; } }
  return n;
  }

The operand obeys 4.1 rule 1 as a scrutinee does: it has a variant
type, and a pointer is not dereferenced implicitly. It extends to the
closing parenthesis, so a test joined with && is refused.

  $ cat > operand.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(const list *l) {
  >   if (case Nil = l)
  >     return 0;
  >   return 1;
  > }
  > EOF
  $ ./golden.exe operand.tc
  operand.tc:3: the operand of a single-pattern test is not of a variant type; a pointer is not dereferenced implicitly (design 4.1 rule 1) [TC0014]
  [1]

  $ cat > joined.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(const list *l, int n) {
  >   while (case Cons(head, tail) = l && n)
  >     return head;
  >   return 1;
  > }
  > EOF
  $ ./golden.exe joined.tc
  joined.tc:3: the operand of a single-pattern test is not of a variant type; a pointer is not dereferenced implicitly (design 4.1 rule 1) [TC0014]
  [1]

The pattern is that of a case label (4.1 rule 3): a constructor of the
operand's type, unqualified, with one sub-pattern per field.

  $ cat > foreign.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > type other = | Empty;
  > long f(list v) {
  >   if (case Empty = v)
  >     return 0;
  >   return 1;
  > }
  > EOF
  $ ./golden.exe foreign.tc
  foreign.tc:4: 'Empty' names no constructor of the variant 'list' (design 4.1 rule 3) [TC0016]
  [1]

  $ cat > arity.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(list v) {
  >   if (case Cons(head) = v)
  >     return head;
  >   return 1;
  > }
  > EOF
  $ ./golden.exe arity.tc
  arity.tc:3: the pattern 'Cons' has 1 sub-pattern(s), and the constructor has 2 field(s) (design 4.1 rule 3) [TC0016]
  [1]

The bindings and the controlled statement are one scope: a declaration
in its block that redeclares a binding is refused, and a binding is not
visible in the else statement (4.6 rule 4).

  $ cat > redeclared.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(list v) {
  >   if (case Cons(head, _) = v) {
  >     long head = 1;
  >     return head;
  >   }
  >   return 1;
  > }
  > EOF
  $ ./golden.exe redeclared.tc
  redeclared.tc:4: 'head' is declared twice in one scope without linkage (C11 6.7p3)
  [1]

  $ cat > otherwise.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(list v) {
  >   if (case Cons(head, _) = v)
  >     return 0;
  >   else
  >     return head;
  > }
  > EOF
  $ ./golden.exe otherwise.tc
  otherwise.tc:6: 'head' is not declared (C11 6.5.1p2)
  [1]

Only a successful test enters the controlled statement, so no goto from
outside it reaches a label inside it, and no case label of a switch
around it stands in it (4.6 rule 6, 4.3 rule 3).

  $ cat > entry.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(list v, int n) {
  >   if (n)
  >     goto inside;
  >   if (case Nil = v) {
  >   inside:
  >     return 1;
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe entry.tc
  entry.tc:4: a jump into the statement of a single-pattern test from outside it (design 4.3 rule 3) [TC0022]
  [1]

  $ cat > label.tc <<'EOF'
  > type list = | Nil | Cons(long head, list *tail);
  > long f(list v, int n) {
  >   switch (n) {
  >   case 1:
  >     while (case Nil = v) {
  >     case 2:
  >       return 1;
  >     }
  >   }
  >   return 0;
  > }
  > EOF
  $ ./golden.exe label.tc
  label.tc:6: a case or default label inside the statement of a single-pattern test, which only a successful test enters (design 4.3 rule 3) [TC0020]
  [1]
