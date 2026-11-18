SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Nested patterns in a match (design 4.7). The type of a position decides
what stands there (rules 2 to 5), and the selection tree decides what a
match misses and which labels it never selects (rule 6).

  $ cat > types.h <<'EOF'
  > type eval_error = | DivByZero | Overflow;
  > type res = | Ok(int value) | Err(eval_error error);
  > type expr = | Num(int value) | Add(const expr *l, const expr *r);
  > type list = | Nil | Cons(int head, const list *tail);
  > EOF

An identifier alone at a field of variant type is a constructor, also
where an object or an enumeration constant of its name is visible
(rule 3); the typed binding binds the field.

  $ cat types.h - > misspelled.tc <<'EOF'
  > int DivByZer;
  > int f(res r) {
  >   match (r) {
  >   case Err(DivByZer):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe misspelled.tc
  misspelled.tc:8: error: 'DivByZer' names no constructor of the variant 'eval_error'; a field of a variant type is bound with its type, as in `T x`; did you mean 'DivByZero'? [match-pattern]
  [1]
  $ cat types.h - > enumerator.tc <<'EOF'
  > enum { Failure };
  > int f(res r) {
  >   match (r) {
  >   case Err(Failure):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe enumerator.tc
  enumerator.tc:8: error: 'Failure' names no constructor of the variant 'eval_error'; a field of a variant type is bound with its type, as in `T x` [match-pattern]
  [1]
  $ cat types.h - > typed.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Err(eval_error DivByZer):
  >     match (DivByZer) { case DivByZero: return 1; case Overflow: return 2; }
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe typed.tc | grep -c __tc_match
  5
  $ cat types.h - > wrong_type.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Err(res e):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe wrong_type.tc
  wrong_type.tc:7: error: the typed binding names the type 'res', and its field is of the variant 'eval_error'; a binding converts nothing [match-pattern]
  [1]

The parser declares an identifier alone in the scope of the arm before
typing reads it as a constructor (provisional, rule 3), so a use of its
name in the arm is refused unless a target type makes it the
constructor (3.3); the qualified constructor is the same value.

  $ cat types.h - > stray.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Err(DivByZero):
  >     match (DivByZero) { case DivByZero: return 1; case Overflow: return 2; }
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe stray.tc
  stray.tc:8: error: 'DivByZero' is a constructor of 'eval_error' in a pattern of this arm and binds nothing; the arm writes it 'eval_error.DivByZero' [match-pattern]
  [1]
  $ sed 's/match (DivByZero)/match (eval_error.DivByZero)/' stray.tc > qualified.tc
  $ ./golden.exe qualified.tc | grep -c __tc_arm
  1
  $ cat types.h - > stray_instance.tc <<'EOF'
  > type wrapped = | W(option(int) o);
  > int f(wrapped w) {
  >   match (w) {
  >   case W(None):
  >     match (None) { case None: return 1; case Some(v): return v; }
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe stray_instance.tc
  stray_instance.tc:9: error: 'None' is a constructor of 'option(int)' in a pattern of this arm and binds nothing; the arm writes it 'option(int).None' [match-pattern]
  [1]
  $ sed 's/match (None)/match (option(int).None)/' stray_instance.tc > qualified_instance.tc
  $ ./golden.exe qualified_instance.tc | grep -c __tc_arm
  1
  $ cat types.h - > targeted.tc <<'EOF'
  > eval_error f(res r) {
  >   match (r) {
  >   case Err(DivByZero):
  >     return DivByZero;
  >   default:
  >     return Overflow;
  >   }
  > }
  > EOF
  $ ./golden.exe targeted.tc | grep -c __tc_arm
  1

A field whose type is a type parameter of a generic function takes a
binding in the definition (rule 2), here one named `Overflow`, and an
instance whose argument is a variant reads the identifier as the
definition did, a binding, so it reads no tag below `Some`. A
constructor pattern there is refused at the definition, since the type
is opaque.

  $ cat types.h - > generic.tc <<'EOF'
  > generic(T) int present(option(T) o) {
  >   match (o) {
  >   case Some(Overflow):
  >     return 1;
  >   case None:
  >     return 0;
  >   }
  > }
  > int f(void) {
  >   option(eval_error) o = Some(DivByZero);
  >   return present(o);
  > }
  > EOF
  $ ./golden.exe generic.tc > generic.c && grep -c '__tc_match0->tag' generic.c
  1
  $ grep -c __tc_arm generic.c
  0
  [1]
  $ sed 's/case Some(Overflow):/case Some(Some(y)):/' generic.tc > opaque.tc
  $ ./golden.exe opaque.tc
  opaque.tc:7: error: the sub-pattern 'Some(y)' stands at a field of type 'T', which takes `_` or a binding [match-pattern]
  [1]

A binding of a pointer to a variant does not take the name of one of
its constructors, and `*` follows the pointer (rule 5).

  $ cat types.h - > tail.tc <<'EOF'
  > int last(list l) {
  >   match (l) {
  >   case Cons(head, Nil):
  >     return head;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe tail.tc
  tail.tc:7: error: the binding 'Nil' of a pointer to the variant 'list' has the name of one of its constructors; `*Nil` matches that constructor, and a binding of the pointer takes another name [match-pattern]
  [1]
  $ sed 's/Nil):/*Nil):/' tail.tc > followed.tc
  $ ./golden.exe followed.tc | grep -c __tc_arm
  1

A sub-pattern that the type of its position does not list is refused,
with the type: a constructor without `*` at a pointer, `*` at a variant,
a constructor at an integer.

  $ cat types.h - > forgotten.tc <<'EOF'
  > int f(expr e) {
  >   match (e) {
  >   case Add(Num(a), _):
  >     return a;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe forgotten.tc
  forgotten.tc:7: error: the sub-pattern 'Num(a)' stands at a field of type 'const expr *', which takes `_`, a binding or `*` and a constructor pattern [match-pattern]
  [1]
  $ sed 's/case Add(Num(a), _)/case Add(*Num(a), *Num)/' forgotten.tc > fields.tc
  $ ./golden.exe fields.tc
  fields.tc:7: error: the case label 'Num' omits the field list of a constructor with 1 field(s); write 'Num(_)' to ignore the fields [match-pattern]
  [1]
  $ cat types.h - > star.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Err(*DivByZero):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe star.tc
  star.tc:7: error: the sub-pattern '*DivByZero' stands at a field of type 'eval_error', which takes `_`, a constructor pattern or a typed binding [match-pattern]
  [1]
  $ sed 's/Err(\*DivByZero)/Ok(DivByZero(x))/' star.tc > integer.tc
  $ ./golden.exe integer.tc
  integer.tc:7: error: the sub-pattern 'DivByZero(x)' stands at a field of type 'int', which takes `_` or a binding [match-pattern]
  [1]

A binding written as C declares one, with its type, is refused with the
binding as a pattern writes it; only a field of a variant type takes a
type before its binding.

  $ sed 's/Err(\*DivByZero)/Ok(int value)/' star.tc > declared.tc
  $ ./golden.exe declared.tc
  declared.tc:7: error: a pattern binds a field by its name alone, not as C declares it; write `value`, not `int value` (at a field of a variant type, a typedef name may stand before the name)
  [1]
  $ sed 's/Err(\*DivByZero)/Ok(const unsigned *value)/' star.tc > declared_pointer.tc
  $ ./golden.exe declared_pointer.tc
  declared_pointer.tc:7: error: a pattern binds a field by its name alone, not as C declares it; write `value`, not `const unsigned *value` (at a field of a variant type, a typedef name may stand before the name)
  [1]
  $ sed 's/Err(\*DivByZero)/Ok(double)/' star.tc > declared_type.tc
  $ ./golden.exe declared_type.tc
  declared_type.tc:7: error: a sub-pattern may not be the type `double`; write the name of a binding, `_` or a constructor pattern
  [1]
  $ sed 's/Err(\*DivByZero)/Ok(eval_error value)/' star.tc > typed_integer.tc
  $ ./golden.exe typed_integer.tc
  typed_integer.tc:7: error: the sub-pattern 'eval_error value' stands at a field of type 'int', which is bound by its name alone; write 'value' [match-pattern]
  [1]

The values that no label takes are named as patterns; a constructor
added to the variant of a field is named under its holder; a default
takes them (4.2 rule 1, 4.7 rule 6).

  $ cat types.h - > missing.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Ok(value):
  >     return value;
  >   case Err(DivByZero):
  >     return -1;
  >   }
  > }
  > EOF
  $ ./golden.exe missing.tc
  missing.tc:6: error: the match does not cover the value 'Err(Overflow)' [match-coverage]
  [1]
  $ sed 's/| DivByZero | Overflow;/| DivByZero | Overflow | Underflow;/' types.h > grown.h
  $ cat grown.h - > grown.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Ok(value):
  >     return value;
  >   case Err(DivByZero):
  >     return -1;
  >   case Err(Overflow):
  >     return -2;
  >   }
  > }
  > EOF
  $ ./golden.exe grown.tc
  grown.tc:6: error: the match does not cover the value 'Err(Underflow)' [match-coverage]
  [1]
  $ sed 's/case Err(Overflow):/default:/' grown.tc > defaulted.tc
  $ ./golden.exe defaulted.tc | grep -c __tc_arm
  1

A label after a wider one is never selected; in the other order both
are (rule 6). A default that no value reaches is refused.

  $ cat types.h - > overlap.tc <<'EOF'
  > int f(expr e) {
  >   match (e) {
  >   case Add(l, r):
  >     return l == r;
  >   case Add(*Num(a), *Num(b)):
  >     return a + b;
  >   case Num(value):
  >     return value;
  >   }
  > }
  > EOF
  $ ./golden.exe overlap.tc
  overlap.tc:9: error: the case label is never selected, since the labels before it match every value that it matches [match-coverage]
  [1]
  $ cat types.h - > unreached.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Ok(_):
  >     return 0;
  >   case Err(DivByZero):
  >     return 1;
  >   case Err(Overflow):
  >     return 2;
  >   default:
  >     return 3;
  >   }
  > }
  > EOF
  $ ./golden.exe unreached.tc
  unreached.tc:13: error: the `default` of the match takes no value, since its case labels match every value [match-default]
  [1]

A label that binds at any depth shares its arm with no other (4.7 rule
7).

  $ cat types.h - > shared.tc <<'EOF'
  > int f(expr e) {
  >   match (e) {
  >   case Add(*Num(a), _):
  >   case Add(_, *Num(b)):
  >     return 1;
  >   default:
  >     return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe shared.tc
  shared.tc:7: error: the labels 'Add(*Num(a), _)' and 'Add(_, *Num(b))' share an arm, so 'a' may not be bound in it; give each label its own arm [shared-arm-binding]
  [1]

The bounds on selection (rule 10) are translation limits, so their
refusals carry no rule name. A label that follows a chain of pointers
reads one more tag at each: 127 nodes deep are taken, 128 are refused.

  $ chain() {
  >   pattern=End
  >   for _ in $(seq "$1"); do pattern="Next(*$pattern)"; done
  >   printf 'type chain = | End | Next(const chain *n);\n'
  >   printf 'int f(chain c) {\n  match (c) {\n  case %s:\n' "$pattern"
  >   printf '    return 1;\n  default:\n    return 0;\n  }\n}\n'
  > }
  $ chain 126 > deepest.tc
  $ ./golden.exe deepest.tc | grep -c __tc_arm
  1
  $ chain 127 > deeper.tc
  $ ./golden.exe deeper.tc
  deeper.tc:3: error: the selection tree of the match is deeper than 127 nodes, the most that typec takes (a translation limit, C11 5.2.4.1)
  [1]

Labels that each ask two fields of their own leave every later label
possible on both sides of a test, so the tree doubles with each label:
ten are taken, twenty pass the step bound, which refuses them before
the work grows.

  $ pairs() {
  >   fields=$(for i in $(seq "$1"); do printf 'bit x%d, bit y%d, ' $i $i; done)
  >   printf 'type bit = | O | I;\ntype word = | W(%s);\n' "${fields%, }"
  >   printf 'int f(word w) {\n  match (w) {\n'
  >   for i in $(seq "$1"); do
  >     tests=$(for j in $(seq "$1"); do
  >       if [ "$j" -eq "$i" ]; then printf 'I, I, '; else printf '_, _, '; fi
  >     done)
  >     printf '  case W(%s):\n    return %d;\n' "${tests%, }" "$i"
  >   done
  >   printf '  default:\n    return 0;\n  }\n}\n'
  > }
  $ pairs 10 > ten.tc
  $ ./golden.exe ten.tc | grep -c __tc_arm
  1
  $ pairs 20 > twenty.tc
  $ ./golden.exe twenty.tc
  twenty.tc:4: error: the match needs more than 4194304 steps of selection, the most that typec takes (a translation limit, C11 5.2.4.1)
  [1]

The lowered form: nested switch statements on the tags that set
__tc_arm0, then one switch on it over the arms (13.5).

  $ cat types.h - > lower.tc <<'EOF'
  > int f(res r) {
  >   match (r) {
  >   case Ok(value):
  >     return value;
  >   case Err(DivByZero):
  >     return -1;
  >   case Err(Overflow):
  >     return -2;
  >   }
  > }
  > int g(const expr *e) {
  >   match (*e) {
  >   case Add(*Num(a), *Num(b)):
  >     return a + b;
  >   case Add(l, r):
  >     return g(l) + g(r);
  >   case Num(value):
  >     return value;
  >   }
  > }
  > EOF
  $ ./golden.exe lower.tc | grep -v '^# ' | sed 's/ *$//' | grep . | sed -n '/^int f/,$p'
  int f(res r) {
  { const struct res *const __tc_match0 = &(
  r
  ); unsigned __tc_arm0; switch (__tc_match0->tag) { case res_Ok: __tc_arm0 = 0; break; case res_Err: switch (__tc_match0->u.Err.error.tag) { case eval_error_DivByZero: __tc_arm0 = 1; break; case eval_error_Overflow: __tc_arm0 = 2; break; case __tc_tag_max__eval_error_tag: default: __builtin_trap(); } break; case __tc_tag_max__res_tag: default: __builtin_trap(); } switch (__tc_arm0) {
  case 0: { const __typeof__(__tc_match0->u.Ok.value) value = __tc_match0->u.Ok.value; {
      return value;
   } __builtin_trap(); }
  case 1: {
      return -1;
   __builtin_trap(); }
  case 2: {
      return -2;
   __builtin_trap(); }
  default: __builtin_trap(); } }
  }
  int g(const expr *e) {
  { const struct expr *const __tc_match1 = &(
  *e
  ); unsigned __tc_arm1; const struct expr *__tc_p1_1 = 0; const struct expr *__tc_p1_2 = 0; switch (__tc_match1->tag) { case expr_Num: __tc_arm1 = 2; break; case expr_Add: __tc_p1_1 = __tc_match1->u.Add.l; switch (__tc_p1_1->tag) { case expr_Num: __tc_p1_2 = __tc_match1->u.Add.r; switch (__tc_p1_2->tag) { case expr_Num: __tc_arm1 = 0; break; case expr_Add: __tc_arm1 = 1; break; case __tc_tag_max__expr_tag: default: __builtin_trap(); } break; case expr_Add: __tc_arm1 = 1; break; case __tc_tag_max__expr_tag: default: __builtin_trap(); } break; case __tc_tag_max__expr_tag: default: __builtin_trap(); } switch (__tc_arm1) {
  case 0: { const __typeof__(__tc_p1_1->u.Num.value) a = __tc_p1_1->u.Num.value; const __typeof__(__tc_p1_2->u.Num.value) b = __tc_p1_2->u.Num.value; {
      return a + b;
   } __builtin_trap(); }
  case 1: { const __typeof__(__tc_match1->u.Add.l) l = __tc_match1->u.Add.l; const __typeof__(__tc_match1->u.Add.r) r = __tc_match1->u.Add.r; {
      return g(l) + g(r);
   } __builtin_trap(); }
  case 2: { const __typeof__(__tc_match1->u.Num.value) value = __tc_match1->u.Num.value; {
      return value;
   } __builtin_trap(); }
  default: __builtin_trap(); } }
  }

The type name of a typed binding goes with the labels that the match
replaces, whatever lowering writes for a name in it: an application,
and in an instance a local typedef name (design 7.3 rule 7), in an arm
and in a test.

  $ cat > typed_names.tc <<'EOF'
  > type inner = | X(int a) | Y;
  > type outer = | W(inner i) | Z;
  > type box(T) = | Full(T *a) | Empty;
  > type boxed = | B(box(int) i) | N;
  > generic(T) static int f(T *p) {
  >   typedef inner in2;
  >   outer o = W(X(3));
  >   if (case W(in2 w) = o)
  >     (void)w;
  >   match (o) {
  >   case W(in2 v):
  >     match (v) { case X(a): return a + (p != 0); case Y: return 1; }
  >   case Z:
  >     return 0;
  >   }
  > }
  > static int g(void) {
  >   boxed o = B(Full((int *)0));
  >   match (o) {
  >   case B(box(int) v):
  >     match (v) { case Full(a): return a != 0; case Empty: return 1; }
  >   case N:
  >     return 0;
  >   }
  > }
  > int use(int *q) { return f(q) + g(); }
  > EOF
  $ ./golden.exe typed_names.tc | grep -o '__typeof__([^)]*) [_a-z0-9]* ='
  __typeof__(__tc_match0->u.B.i) v =
  __typeof__(__tc_match1->u.Full.a) a =
  __typeof__(__tc_match0->tag) __tc_tag0 =
  __typeof__(__tc_match0->u.W.i) __tc_local_w =
  __typeof__(__tc_match1->u.W.i) __tc_local_v =
  __typeof__(__tc_match2->u.X.a) __tc_local_a =
