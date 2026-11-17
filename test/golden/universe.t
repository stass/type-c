SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The universe generics option and result (design 3.6) are declared in
the universe scope around file scope of every Type-C unit (design 2.3).
Their definitions are not in the emitted text; each instance is written
from their tokens under markers for the lines of <universe>, with flag
3 as typec's own text (design 13.4).

  $ cat > some.tc <<'EOF'
  > int f(int x) {
  >   option(int) o = x ? Some(3) : None;
  >   match (o) {
  >     case Some(v): return v;
  >     case None: return 0;
  >   }
  > }
  > EOF
  $ ./golden.exe some.tc
  # 1 "some.tc"
  
  # 2 "some.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "some.tc"
  typedef int __tc_arg__i; struct option__i; typedef struct option__i option__i;
  # 1 "<universe>" 3
  enum option__i_tag { option__i_None, option__i_Some, __tc_tag_max__option__i_tag = 2147483647 }; struct option__i { enum option__i_tag tag; union { struct { __tc_arg__i value ; } Some; } u; };
  # 2 "some.tc"
  #pragma pack(pop)
  # 1 "some.tc"
  int f(int x) {
    
  # 2 "some.tc"
  option__i
  # 2 "some.tc"
   o = x ? 
  # 2 "some.tc"
  ((struct option__i){ .tag = option__i_Some, .u.Some = { 
  # 2 "some.tc"
  3
  # 2 "some.tc"
   } })
  # 2 "some.tc"
   : 
  # 2 "some.tc"
  ((struct option__i){ .tag = option__i_None })
  # 2 "some.tc"
  ;
    
  # 3 "some.tc"
  { const struct option__i *const __tc_match0 = &(
  # 3 "some.tc"
  o
  # 3 "some.tc"
  ); switch (__tc_match0->tag) {
  # 3 "some.tc"
  
      
  # 4 "some.tc"
  case option__i_Some: { const __typeof__(__tc_match0->u.Some.value) v = __tc_match0->u.Some.value; {
  # 4 "some.tc"
   return v;
      
  # 4 "some.tc"
   } __builtin_trap(); }
  # 5 "some.tc"
  
  # 5 "some.tc"
  case option__i_None: {
  # 5 "some.tc"
   return 0;
    
  # 5 "some.tc"
   __builtin_trap(); }
  # 6 "some.tc"
  
  # 6 "some.tc"
  case __tc_tag_max__option__i_tag: default: __builtin_trap(); } }
  # 6 "some.tc"
  
  }
  
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

The emitted text holds no universe text but the instance's.

  $ ./golden.exe some.tc | grep -c 'type option\|type result\|Err'
  0
  [1]

The instance name encodes the arguments after typedef expansion
(design 10.3).

  $ cat > parse.tc <<'EOF'
  > typedef unsigned int u32;
  > type parse_error = | Bad_line(int line);
  > result(u32, parse_error) parse(void);
  > EOF
  $ ./golden.exe parse.tc
  # 1 "parse.tc"
  typedef unsigned int u32;
  
  # 2 "parse.tc"
  struct parse_error; typedef struct parse_error parse_error;
  # 2 "parse.tc"
   
  # 2 "parse.tc"
  enum parse_error_tag { parse_error_Bad_line, __tc_tag_max__parse_error_tag = 2147483647 }; struct parse_error { enum parse_error_tag tag; union {
  # 2 "parse.tc"
   
  # 2 "parse.tc"
  struct {
  # 2 "parse.tc"
  int line
  # 2 "parse.tc"
  ; } Bad_line;
  # 2 "parse.tc"
  
  # 2 "parse.tc"
  } u; };
  # 2 "parse.tc"
  
  
  # 3 "parse.tc"
  #pragma pack(push)
  #pragma pack()
  # 3 "parse.tc"
  typedef unsigned int __tc_arg__j; struct parse_error; typedef struct parse_error __tc_arg__11parse_error; struct result__j11parse_error; typedef struct result__j11parse_error result__j11parse_error;
  # 3 "parse.tc"
  #pragma pack(pop)
  # 3 "parse.tc"
  
  # 3 "parse.tc"
  result__j11parse_error
  # 3 "parse.tc"
   parse(void);
  
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

An argument that the definition needs complete is refused at the
application, citing the line of the universe text that needs it.

  $ printf 'struct s;\noption(struct s) o;\n' > incomplete.tc
  $ ./golden.exe incomplete.tc
  incomplete.tc:2: error: in the instance 'option(struct s)' that this application names, at <universe>:1: the field 'value' of 'Some' is not a value type: it is not a complete object type [field-type]
  [1]

A generic that uses option in its definition reads it where the
definition stands, so a later declaration that hides the name does not
change the definition (design 3.5 rule 8).

  $ cat > hidden.tc <<'EOF'
  > type w(T) = struct { option(T) v; };
  > int option;
  > w(int) x;
  > EOF
  $ ./golden.exe hidden.tc
  # 1 "hidden.tc"
  
  # 1 "hidden.tc"
  
  # 1 "hidden.tc"
  
  int option;
  
  # 3 "hidden.tc"
  #pragma pack(push)
  #pragma pack()
  # 3 "hidden.tc"
  typedef int __tc_arg__i; struct w__i; typedef struct w__i w__i;
  # 1 "hidden.tc"
  struct option__i; typedef struct option__i option__i;
  # 1 "<universe>" 3
  enum option__i_tag { option__i_None, option__i_Some, __tc_tag_max__option__i_tag = 2147483647 }; struct option__i { enum option__i_tag tag; union { struct { __tc_arg__i value ; } Some; } u; };
  # 1 "hidden.tc"
  struct w__i { option__i v ; } ;
  # 3 "hidden.tc"
  #pragma pack(pop)
  # 3 "hidden.tc"
  
  # 3 "hidden.tc"
  w__i
  # 3 "hidden.tc"
   x;
  
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

An enumerator None in scope does not hide the constructor where the
target type is an option: the constructor is selected by the target
type (design 3.3), and an int reads the enumerator.

  $ cat > enumerator.tc <<'EOF'
  > enum { None = 7 };
  > option(int) o = None;
  > int n = None;
  > EOF
  $ ./golden.exe enumerator.tc
  # 1 "enumerator.tc"
  enum { None = 7 };
  
  # 2 "enumerator.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "enumerator.tc"
  typedef int __tc_arg__i; struct option__i; typedef struct option__i option__i;
  # 1 "<universe>" 3
  enum option__i_tag { option__i_None, option__i_Some, __tc_tag_max__option__i_tag = 2147483647 }; struct option__i { enum option__i_tag tag; union { struct { __tc_arg__i value ; } Some; } u; };
  # 2 "enumerator.tc"
  #pragma pack(pop)
  # 2 "enumerator.tc"
  
  # 2 "enumerator.tc"
  option__i
  # 2 "enumerator.tc"
   o = 
  # 2 "enumerator.tc"
  { .tag = option__i_None }
  # 2 "enumerator.tc"
  ;
  int n = None;
  
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

In C text, an old-style definition keeps C's meaning: a universe name in
its identifier list is the parameter it names (design 2.3). In Type-C
text it is the bare generic.

  $ cat > old.i <<'EOF'
  > # 1 "old.tc"
  > # 1 "old.h" 1
  > int f(result) int result; { return result; }
  > # 2 "old.tc" 2
  > int g(void) { return f(1); }
  > EOF
  $ ./golden.exe old.i
  # 1 "old.tc"
  # 1 "old.h" 1
  int f(result) int result; { return result; }
  # 2 "old.tc" 2
  int g(void) { return f(1); }
  $ printf 'int f(result) int result; { return result; }\n' > old.tc
  $ ./golden.exe old.tc
  old.tc:1: error: the generic type `result` names a type only in a type application, `result(...)` [generic-type-use]
  [1]

A later name of the list is the parameter too, while a universe name
that begins a prototype's parameter or an abstract one is the bare
generic in C text as well.

  $ cat > later.i <<'EOF'
  > # 1 "later.tc"
  > # 1 "later.h" 1
  > int f(a, option) int a; int option; { return a + option; }
  > EOF
  $ ./golden.exe later.i
  # 1 "later.tc"
  # 1 "later.h" 1
  int f(a, option) int a; int option; { return a + option; }
  $ cat > typed.i <<'EOF'
  > # 1 "typed.tc"
  > # 1 "typed.h" 1
  > int f(option x);
  > EOF
  $ ./golden.exe typed.i
  typed.h:1: error: the generic type `option` names a type only in a type application, `option(...)` [generic-type-use]
  [1]
  $ cat > abstract.i <<'EOF'
  > # 1 "abstract.tc"
  > # 1 "abstract.h" 1
  > int s = sizeof(void (*)(option));
  > EOF
  $ ./golden.exe abstract.i
  abstract.h:1: error: the generic type `option` names a type only in a type application, `option(...)` [generic-type-use]
  [1]
