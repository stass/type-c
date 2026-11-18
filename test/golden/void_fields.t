SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

In an instance, a variant field whose type is void does not exist
(design 3.5 rule 6): the struct of its constructor leaves it out, a
constructor left without fields has no payload and is written without
parentheses, and its patterns have no sub-pattern for it.

  $ cat > opt.tc <<'EOF'
  > type opt(T) = | No | Yes(T value);
  > opt(void) o = Yes;
  > opt(void) check(int ok) {
  >   if (case Yes = o)
  >     return No;
  >   match (o) {
  >   case No: return ok ? Yes : opt(void).No;
  >   case Yes: return o;
  >   }
  > }
  > EOF
  $ ./golden.exe opt.tc | grep -v '^# ' | grep . | sed -n '/^enum/,/^}/p'
  enum opt__v_tag { opt__v_No, opt__v_Yes, __tc_tag_max__opt__v_tag = 2147483647 }; struct opt__v { enum opt__v_tag tag; };
  #pragma pack(pop)
  opt__v
   o = 
  { .tag = opt__v_Yes }
  ;
  opt__v
   check(int ok) {
    
  { const struct opt__v *const __tc_match0 = &(
   o
  ); const __typeof__(__tc_match0->tag) __tc_tag0 = __tc_match0->tag; if (__tc_tag0 == opt__v_Yes) {
      return 
  ((struct opt__v){ .tag = opt__v_No })
  ;
    
   } else { switch (__tc_tag0) { case opt__v_No: case opt__v_Yes: break; case __tc_tag_max__opt__v_tag: default: __builtin_trap(); } } }
  { const struct opt__v *const __tc_match1 = &(
  o
  ); switch (__tc_match1->tag) {
    
  case opt__v_No: {
   return ok ? 
  ((struct opt__v){ .tag = opt__v_Yes })
   : 
  ((struct opt__v){ .tag = opt__v_No })
  ;
    
   __builtin_trap(); }
  case opt__v_Yes: {
   return o;
    
   __builtin_trap(); }
  case __tc_tag_max__opt__v_tag: default: __builtin_trap(); } }
  }

A void field in the middle of several goes with the comma after it.

  $ cat > pair.tc <<'EOF'
  > type three(A) = | Three(int first, A middle, long last) | Only(A only);
  > three(void) t = Three(1, 2);
  > EOF
  $ ./golden.exe pair.tc | grep -v '^# ' | grep . | sed -n '/^enum/,/^;/p'
  enum three__v_tag { three__v_Three, three__v_Only, __tc_tag_max__three__v_tag = 2147483647 }; struct three__v { enum three__v_tag tag; union { struct { int first ; long last ; } Three; } u; };
  #pragma pack(pop)
  three__v
   t = 
  { .tag = three__v_Three, .u.Three = { 
  1, 2
   } }
  ;

A constructor whose fields a void argument removed takes no arguments
and has no field list, and the error names the field that void
removed.

  $ printf 'type opt(T) = | No | Yes(T value);\nopt(void) o = Yes();\n' > empty.tc
  $ ./golden.exe empty.tc
  empty.tc:2: error: the constructor 'Yes' has no fields, so it is written without parentheses (in this instance the type void removes the field(s) 'value') [constructor-expression]
  [1]
  $ printf 'type opt(T) = | No | Yes(T value);\nopt(void) o = Yes(1);\n' > argument.tc
  $ ./golden.exe argument.tc
  argument.tc:2: error: the constructor 'Yes' has no fields, so it is written without parentheses (in this instance the type void removes the field(s) 'value') [constructor-expression]
  [1]
  $ printf 'type two(A, B) = | Two(A a, B b);\ntwo(void, int) t = Two(1, 2);\n' > arity.tc
  $ ./golden.exe arity.tc
  arity.tc:2: error: the constructor 'Two' takes 1 argument, its field 'b'; 2 are given (in this instance the type void removes the field(s) 'a') [constructor-expression]
  [1]
  $ printf 'type two(A, B) = | Two(A a, B b);\ntwo(void, int) t = Two;\n' > bare.tc
  $ ./golden.exe bare.tc
  bare.tc:2: error: the constructor 'Two' takes arguments (in this instance the type void removes the field(s) 'a') [constructor-expression]
  [1]
  $ cat > label.tc <<'EOF'
  > type two(A, B) = | Two(A a, B b);
  > int f(two(void, int) t) {
  >   match (t) {
  >   case Two: return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe label.tc
  label.tc:4: error: the case label 'Two' omits the field list of a constructor with 1 field(s); write 'Two(_)' to ignore the fields (in this instance the type void removes the field(s) 'a') [match-pattern]
  [1]
  $ cat > pattern.tc <<'EOF'
  > type opt(T) = | No | Yes(T value);
  > int f(opt(void) o) {
  >   match (o) {
  >   case No: return 0;
  >   case Yes(x): return 1;
  >   }
  > }
  > EOF
  $ ./golden.exe pattern.tc
  pattern.tc:5: error: the pattern 'Yes' has 1 sub-pattern(s), and the constructor has 0 field(s) (in this instance the type void removes the field(s) 'value') [match-pattern]
  [1]

Only substitution removes a field: void written as the type of a field
is refused where the definition is checked, and an array of a void
argument is an error.

  $ printf 'type bad(T) = | Bad(void x, T y);\n' > literal.tc
  $ ./golden.exe literal.tc
  literal.tc:1: error: the field 'x' of 'Bad' is not a value type: it is not a complete object type [field-type]
  [1]
  $ printf 'type arr(T) = | Arr(T a[2]);\narr(void) a;\n' > array.tc
  $ ./golden.exe array.tc
  array.tc:1: error: the field 'a' of 'Arr' is not a value type: it is an array; wrap it in a struct, which is one [field-type]
  [1]
