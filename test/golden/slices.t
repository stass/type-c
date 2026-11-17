SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

Slices (design section 8). An index of a slice has an integer type no
wider than `size_t` (rule 1).

  $ cat > wide.tc <<'EOF'
  > int f(slice(int) s, unsigned __int128 i) { return s[i]; }
  > EOF
  $ ./golden.exe wide.tc
  wide.tc:1: error: the index of a slice has the type 'unsigned __int128', wider than `size_t`: the conversion would drop the bits that tell it from one in range; a cast to `size_t` writes the narrowing [slice-index]
  [1]

  $ cat > pointer.tc <<'EOF'
  > int f(slice(int) s, int *p) { return s[p]; }
  > EOF
  $ ./golden.exe pointer.tc
  pointer.tc:1: error: the index of a slice has no integer type (C11 6.5.2.1p1) [slice-index]
  [1]

  $ cat > real.tc <<'EOF'
  > int f(slice(int) s, double d) { return s[d]; }
  > EOF
  $ ./golden.exe real.tc
  real.tc:1: error: the index of a slice has no integer type (C11 6.5.2.1p1) [slice-index]
  [1]

An index that C evaluates stands in a function body, whose function
declares the temporaries of its test (rule 9). One that C does not
evaluate stands wherever an expression does.

  $ cat > outside.tc <<'EOF'
  > extern slice(int) s;
  > int n[sizeof(s[0])];
  > void f(int a[s[0]]);
  > EOF
  $ ./golden.exe outside.tc
  outside.tc:3: error: an index of a slice or a `slice_sub` that C evaluates stands in a function body, where the function declares the temporaries of its test [slice-check-place]
  [1]

`slice_sub(s, lo, hi)` takes a slice and two bounds of the types that an
index may have (rule 3), and is applied to its three operands where its
universe name is not hidden.

  $ cat > sub_operand.tc <<'EOF'
  > int *f(int *p) { return slice_sub(p, 0, 1).data; }
  > EOF
  $ ./golden.exe sub_operand.tc
  sub_operand.tc:1: error: the first operand of `slice_sub` has the type 'int *', which is no slice [slice-operand]
  [1]

  $ cat > sub_bound.tc <<'EOF'
  > slice(int) f(slice(int) s, float hi) { return slice_sub(s, 0, hi); }
  > EOF
  $ ./golden.exe sub_bound.tc
  sub_bound.tc:1: error: a bound of `slice_sub` has no integer type (C11 6.5.2.1p1) [slice-index]
  [1]

  $ cat > sub_outside.tc <<'EOF'
  > extern slice(int) s;
  > char n[sizeof(slice_sub(s, 0, 1))];
  > void f(int a[slice_sub(s, 0, 1).len]);
  > EOF
  $ ./golden.exe sub_outside.tc
  sub_outside.tc:3: error: an index of a slice or a `slice_sub` that C evaluates stands in a function body, where the function declares the temporaries of its test [slice-check-place]
  [1]

  $ cat > sub_count.tc <<'EOF'
  > slice(int) f(slice(int) s) { return slice_sub(s, 1); }
  > EOF
  $ ./golden.exe sub_count.tc
  sub_count.tc:1: error: expected `,` after an operand of `slice_sub`, found `)`
  [1]

  $ cat > sub_name.tc <<'EOF'
  > void *f(void) { return &slice_sub; }
  > EOF
  $ ./golden.exe sub_name.tc
  sub_name.tc:1: error: expected `(` after `slice_sub`, found `;`
  [1]

  $ cat > sub_hidden.tc <<'EOF'
  > int slice_sub(int a, int b, int c) { return a + b + c; }
  > int g(void) { return slice_sub(1, 2, 3); }
  > EOF
  $ ./golden.exe sub_hidden.tc
  # 1 "sub_hidden.tc"
  int slice_sub(int a, int b, int c) { return a + b + c; }
  int g(void) { return slice_sub(1, 2, 3); }

`slice_from_array(a)` takes an lvalue of a complete array type that is
not variably modified (rule 2), and `slice_unchecked(p, n)` a pointer
(rule 4).

  $ cat > array_pointer.tc <<'EOF'
  > slice(int) f(int *p) { return slice_from_array(p); }
  > EOF
  $ ./golden.exe array_pointer.tc
  array_pointer.tc:1: error: the operand of `slice_from_array` has the type 'int *', which is no array [slice-operand]
  [1]
  $ cat > array_unknown.tc <<'EOF'
  > extern int rows[];
  > slice(int) f(void) { return slice_from_array(rows); }
  > EOF
  $ ./golden.exe array_unknown.tc
  array_unknown.tc:2: error: the operand of `slice_from_array` is an array of unknown or variable length; `slice_unchecked` takes the count that the program holds [slice-operand]
  [1]
  $ cat > array_variable.tc <<'EOF'
  > slice(int) f(int n) { int a[n]; return slice_from_array(a); }
  > EOF
  $ ./golden.exe array_variable.tc
  array_variable.tc:1: error: the operand of `slice_from_array` is an array of unknown or variable length; `slice_unchecked` takes the count that the program holds [slice-operand]
  [1]
  $ cat > array_modified.tc <<'EOF'
  > int f(int n) { int a[2][n]; return (int)slice_from_array(a).len; }
  > EOF
  $ ./golden.exe array_modified.tc
  array_modified.tc:1: error: the operand of `slice_from_array` is variably modified, and C would evaluate it again as the operand of `sizeof`; `slice_unchecked` takes the count that the program holds [slice-operand]
  [1]
  $ cat > array_value.tc <<'EOF'
  > struct box { int a[2]; };
  > struct box g(void);
  > int f(void) { return (int)slice_from_array(g().a).len; }
  > EOF
  $ ./golden.exe array_value.tc
  array_value.tc:3: error: the operand of `slice_from_array` is no lvalue [slice-operand]
  [1]

An array of arrays is no operand: its elements are of array type, which
no type argument is (design section 8 rule 2, 3.5 rule 2).

  $ cat > array_rows.tc <<'EOF'
  > int rows[3][4];
  > int f(void) { return (int)slice_from_array(rows).len; }
  > EOF
  $ ./golden.exe array_rows.tc
  array_rows.tc:2: error: the type argument 'int[4]' is an array [type-argument]
  [1]

The operand declares no name whose scope reaches beyond it, which its
second writing would declare again: no tag or enumeration constant in
the scope around it and no label of the function. A label that a
statement expression of the operand declares with `__label__` is its
own (design section 8 rule 2).

  $ cat > array_enumerator.tc <<'EOF'
  > int a[3];
  > int f(void) {
  >   return (int)slice_from_array(*(int (*)[sizeof(enum { K = 3 })])&a).len;
  > }
  > EOF
  $ ./golden.exe array_enumerator.tc
  array_enumerator.tc:3: error: 'K' is declared in the scope around the text, which lowering writes again as the operand of `sizeof`, where it would declare it a second time; declare it before the text [array-operand-name-capture]
  [1]
  $ cat > array_label.tc <<'EOF'
  > int a[3];
  > int f(void) { return (int)slice_from_array(*({ l: ; &a; })).len; }
  > EOF
  $ ./golden.exe array_label.tc
  array_label.tc:2: error: the label `l` is defined in the operand of `slice_from_array`, which lowering writes again as the operand of `sizeof`, and its scope reaches beyond the operand; declare it with `__label__` in a statement expression of the operand [array-operand-name-capture]
  [1]
  $ cat > array_outer_label.tc <<'EOF'
  > int a[3];
  > int f(void) {
  >   __label__ l;
  >   return (int)slice_from_array(*({ l: ; &a; })).len;
  > }
  > EOF
  $ ./golden.exe array_outer_label.tc
  array_outer_label.tc:4: error: the label `l` is defined in the operand of `slice_from_array`, which lowering writes again as the operand of `sizeof`, and its scope reaches beyond the operand; declare it with `__label__` in a statement expression of the operand [array-operand-name-capture]
  [1]
  $ cat > array_local_label.tc <<'EOF'
  > int a[3];
  > int f(void) {
  >   return (int)slice_from_array(*({ __label__ l; l: ; &a; })).len;
  > }
  > EOF
  $ ./golden.exe array_local_label.tc > /dev/null

  $ cat > array_pragma.tc <<'EOF'
  > int rows[2][3];
  > int f(void) {
  >   return (int)slice_from_array(rows[
  > #pragma GCC diagnostic push
  >   0]).len;
  > }
  > EOF
  $ ./golden.exe array_pragma.tc
  array_pragma.tc:3: error: the operand of `slice_from_array` holds a pragma line, which its second writing, as the operand of `sizeof`, would repeat [slice-operand]
  [1]
  $ cat > unchecked_integer.tc <<'EOF'
  > slice(int) f(long p) { return slice_unchecked(p, 1); }
  > EOF
  $ ./golden.exe unchecked_integer.tc
  unchecked_integer.tc:1: error: the first operand of `slice_unchecked` has the type 'long', which is no pointer [slice-operand]
  [1]

Each is a compound literal of its instance, whose length is the size of
the operand over that of an element, with a term of the value 0 that
the backend refuses where an element has no size. As the initialiser of
an object of that instance, a member or a field of a constructor, it is
the braced list alone, in place of the parentheses around it too
(13.5).

  $ cat > making.tc <<'EOF'
  > unsigned char buffer[4];
  > slice(unsigned char) bytes = slice_from_array(buffer);
  > slice(unsigned char) paren = ((slice_from_array(buffer)));
  > type held = | Held(slice(unsigned char) s) | Empty;
  > held h = Held(slice_from_array(buffer));
  > struct pair { slice(unsigned char) a, b; } p = { slice_from_array(buffer) };
  > unsigned long f(int *q, int n) {
  >   int a[3];
  >   slice(int) u = slice_unchecked(q + 1, n);
  >   return slice_from_array(a).len + u.len
  >     + slice_from_array((int[]){ 1, 2 }).len;
  > }
  > EOF
  $ ./golden.exe making.tc
  # 1 "making.tc"
  unsigned char buffer[4];
  
  # 2 "making.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "making.tc"
  typedef unsigned char __tc_arg__h; struct slice__h; typedef struct slice__h slice__h;
  # 3 "<universe>" 3
  struct slice__h { __tc_arg__h * data ; __typeof__ ( sizeof 0 ) len ; } ;
  # 2 "making.tc"
  #pragma pack(pop)
  # 2 "making.tc"
  
  # 2 "making.tc"
  slice__h
  # 2 "making.tc"
   bytes = 
  # 2 "making.tc"
  { (
  # 2 "making.tc"
  buffer
  # 2 "making.tc"
  ),  sizeof( buffer ) / sizeof(__tc_arg__h) + 0 * sizeof(char[sizeof(__tc_arg__h) != 0 ? 1 : -1])  }
  # 2 "making.tc"
  ;
  
  # 3 "making.tc"
  slice__h
  # 3 "making.tc"
   paren = 
  # 3 "making.tc"
  { (
  # 3 "making.tc"
  buffer
  # 3 "making.tc"
  ),  sizeof( buffer ) / sizeof(__tc_arg__h) + 0 * sizeof(char[sizeof(__tc_arg__h) != 0 ? 1 : -1])  }
  # 3 "making.tc"
  
  # 3 "making.tc"
  
  # 3 "making.tc"
  
  # 3 "making.tc"
  
  # 3 "making.tc"
  ;
  
  # 4 "making.tc"
  struct held; typedef struct held held;
  # 4 "making.tc"
   
  # 4 "making.tc"
  enum held_tag { held_Held, held_Empty }; struct held { enum held_tag tag; union {
  # 4 "making.tc"
   
  # 4 "making.tc"
  struct {
  # 4 "making.tc"
  
  # 4 "making.tc"
  slice__h
  # 4 "making.tc"
   s
  # 4 "making.tc"
  ; } Held;
  # 4 "making.tc"
   
  # 4 "making.tc"
  
  # 4 "making.tc"
  
  # 4 "making.tc"
  } u; };
  # 4 "making.tc"
  
  held h = 
  # 5 "making.tc"
  { .tag = held_Held, .u.Held = { 
  # 5 "making.tc"
  
  # 5 "making.tc"
  { (
  # 5 "making.tc"
  buffer
  # 5 "making.tc"
  ),  sizeof( buffer ) / sizeof(__tc_arg__h) + 0 * sizeof(char[sizeof(__tc_arg__h) != 0 ? 1 : -1])  }
  # 5 "making.tc"
  
  # 5 "making.tc"
   } }
  # 5 "making.tc"
  ;
  struct pair { 
  # 6 "making.tc"
  slice__h
  # 6 "making.tc"
   a, b; } p = { 
  # 6 "making.tc"
  { (
  # 6 "making.tc"
  buffer
  # 6 "making.tc"
  ),  sizeof( buffer ) / sizeof(__tc_arg__h) + 0 * sizeof(char[sizeof(__tc_arg__h) != 0 ? 1 : -1])  }
  # 6 "making.tc"
   };
  
  # 9 "making.tc"
  #pragma pack(push)
  #pragma pack()
  # 9 "making.tc"
  typedef int __tc_arg__i; struct slice__i; typedef struct slice__i slice__i;
  # 3 "<universe>" 3
  struct slice__i { __tc_arg__i * data ; __typeof__ ( sizeof 0 ) len ; } ;
  # 9 "making.tc"
  #pragma pack(pop)
  # 7 "making.tc"
  unsigned long f(int *q, int n) {
    int a[3];
    
  # 9 "making.tc"
  slice__i
  # 9 "making.tc"
   u = 
  # 9 "making.tc"
  { (
  # 9 "making.tc"
  q + 1
  # 9 "making.tc"
  ), (
  # 9 "making.tc"
   n
  # 9 "making.tc"
  ) }
  # 9 "making.tc"
  ;
    return 
  # 10 "making.tc"
  (struct slice__i){ (
  # 10 "making.tc"
  a
  # 10 "making.tc"
  ),  sizeof( a ) / sizeof(__tc_arg__i) + 0 * sizeof(char[sizeof(__tc_arg__i) != 0 ? 1 : -1])  }
  # 10 "making.tc"
  .len + u.len
      + 
  # 11 "making.tc"
  (struct slice__i){ (
  # 11 "making.tc"
  (int[]){ 1, 2 }
  # 11 "making.tc"
  ),  sizeof( ( int [ ] ) { 1 , 2 } ) / sizeof(__tc_arg__i) + 0 * sizeof(char[sizeof(__tc_arg__i) != 0 ? 1 : -1])  }
  # 11 "making.tc"
  .len;
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

A slice converts to the slice of its elements made const (design
section 8 rule 5): in a position that has a target type, and as the
branch of a conditional whose other branch is the const slice. It
converts through a temporary of the function, and where C does not
evaluate it, it is the trap and its operand. A `slice_from_array`, a
`slice_unchecked` and a string literal of plain or UTF-8 characters
(rule 6) are made as slices of the instance converted to, with no
temporary, so they stand at file scope (13.5).

  $ cat > conversion.tc <<'EOF'
  > char letters[3];
  > str name = (slice_from_array(letters));
  > str greeting = "hi";
  > static const str both = ("a" "b");
  > unsigned long f(slice(char) m, int k) {
  >   str c = m;
  >   return c.len + (k ? m : c).len + sizeof(c = m) + (k ? u8"x" : c).len;
  > }
  > EOF
  $ ./golden.exe conversion.tc | grep -v '^#' | tr -s ' \n' ' ' | tr ';' '\n' | grep -v 'pragma\|probe\|typedef __tc_arg\|^ *$'
  char letters[3]
   typedef const char __tc_arg__Kc
   struct slice__Kc
   typedef struct slice__Kc slice__Kc
   struct slice__Kc { __tc_arg__Kc * data 
   __typeof__ ( sizeof 0 ) len 
   } 
   typedef char __tc_arg__c
   struct slice__c
   typedef struct slice__c slice__c
   struct slice__c { __tc_arg__c * data 
   __typeof__ ( sizeof 0 ) len 
   } 
   slice__Kc name = { ( letters ), sizeof( letters ) / sizeof(__tc_arg__Kc) + 0 * sizeof(char[sizeof(__tc_arg__Kc) != 0 ? 1 : -1]) } 
   slice__Kc greeting = { "hi" , sizeof( "hi" ) - 1 } 
   static const slice__Kc both = { "a" "b" , sizeof( "a" "b" ) - 1 } 
   unsigned long f( slice__c m, int k) { struct slice__c __tc_s0
   struct slice__c __tc_s1
   { slice__Kc c = ((void)(__tc_s0 = ( m )), (struct slice__Kc){ __tc_s0.data, __tc_s0.len }) 
   return c.len + (k ? ((void)(__tc_s1 = ( m )), (struct slice__Kc){ __tc_s1.data, __tc_s1.len }) : c).len + sizeof(c = ((void)__builtin_trap(), (void)( m ), (struct slice__Kc){ 0 }) ) + (k ? (struct slice__Kc){ u8"x" , sizeof( u8"x" ) - 1 } : c).len
   int i
   }
   int i
   }

A slice that converts through a temporary is no constant, and a wide
string literal denotes no `str`: it stays as written, for the backend
to refuse.

  $ printf 'slice(char) m;\nstr c = m;\n' > conversion_outside.tc
  $ ./golden.exe conversion_outside.tc
  conversion_outside.tc:2: error: an initialiser of an object with static or thread storage duration is not a constant expression (C11 6.7.9p4)
  [1]
  $ printf 'str w = L"w";\n' > conversion_wide.tc
  $ ./golden.exe conversion_wide.tc | grep -o '= L"w"'
  = L"w"

An index in a range that lowering drops, as the operands of a
`__builtin_types_compatible_p` that typec answers, declares no
temporaries.

  $ cat > dropped.tc <<'EOF'
  > type d = distinct int;
  > int f(slice(int) s) {
  >   return __builtin_types_compatible_p(__typeof__(char[s[0]]), d);
  > }
  > EOF
  $ ./golden.exe dropped.tc
  # 1 "dropped.tc"
  
  # 1 "dropped.tc"
  typedef
  # 1 "dropped.tc"
   int
  # 1 "dropped.tc"
  d
  # 1 "dropped.tc"
  ;
  
  # 2 "dropped.tc"
  #pragma pack(push)
  #pragma pack()
  # 2 "dropped.tc"
  typedef int __tc_arg__i; struct slice__i; typedef struct slice__i slice__i;
  # 3 "<universe>" 3
  struct slice__i { __tc_arg__i * data ; __typeof__ ( sizeof 0 ) len ; } ;
  # 2 "dropped.tc"
  #pragma pack(pop)
  # 2 "dropped.tc"
  int f(
  # 2 "dropped.tc"
  slice__i
  # 2 "dropped.tc"
   s) {
    return 
  # 3 "dropped.tc"
  0
  # 3 "dropped.tc"
  ;
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

The count of `slice_unchecked` has an integer type no wider than
`size_t`, as an index does (rule 4).

  $ cat > count.tc <<'EOF'
  > slice(int) f(int *p, double d) { return slice_unchecked(p, d); }
  > EOF
  $ ./golden.exe count.tc
  count.tc:1: error: the count of `slice_unchecked` has no integer type (C11 6.5.2.1p1) [slice-index]
  [1]

  $ cat > wide_count.tc <<'EOF'
  > slice(int) g(int *p, unsigned __int128 n) { return slice_unchecked(p, n); }
  > EOF
  $ ./golden.exe wide_count.tc
  wide_count.tc:1: error: the count of `slice_unchecked` has the type 'unsigned __int128', wider than `size_t`: the conversion would drop the bits that tell it from one in range; a cast to `size_t` writes the narrowing [slice-index]
  [1]
