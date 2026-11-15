SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

C code and Type-C code call each other across the C ABI of design 10:
variants are the tagged structures of 10.1, distinct types are their
underlying types (10.2), and functions are C functions under their own
names (10.4), which is all that C code sees of them (10.6). Objects that
typec compiles link with objects that a plain backend compiles, in every
pairing of the backends that backends.sh names, and values cross in each
direction unchanged.

  $ . ./backends.sh
  $ mkdir include

The interface declares variants whose fields span the classes of C
object types: each integer and floating type, pointers to objects, to a
variant and to functions, a structure, a union, an array and bit-fields
inside a structure (a field is never an array or a bit-field itself,
design 3.2 rule 4), and a variant by value. measure, ratio and flag are
small enough to travel in registers on x86-64, the last as a bare tag.
Each distinct type has an arithmetic or pointer type of its own class
as its representation.

  $ cat > include/fields.h <<'EOF'
  > #ifndef FIELDS_H
  > #define FIELDS_H
  > #include <stddef.h>
  > struct point { double x, y; };
  > union bits { unsigned u; float f; };
  > struct name { char text[7]; };
  > struct flags { unsigned ready : 1; unsigned level : 3; signed delta : 4; };
  > #endif
  > EOF
  $ cat > include/abi.tci <<'EOF'
  > #include "fields.h"
  > type scalar =
  >     | Empty
  >     | Chars(char c, signed char sc, unsigned char uc)
  >     | Shorts(short s, unsigned short us)
  >     | Ints(int i, unsigned u, _Bool b)
  >     | Longs(long l, long long ll, unsigned long long ull)
  >     | Reals(float f, double d, long double ld)
  >     | Pointers(const char *text, scalar *next, long (*twice)(long));
  > type compound =
  >     | Point(struct point p)
  >     | Bits(union bits b)
  >     | Name(struct name n)
  >     | Flags(struct flags f)
  >     | Inner(scalar s, char after);
  > type measure = | Metres(double m) | Count(long n);
  > type ratio = | Ratio(float num, float den);
  > type flag = | Off | On;
  > type d_char = distinct char;
  > type d_schar = distinct signed char;
  > type d_uchar = distinct unsigned char;
  > type d_short = distinct short;
  > type d_ushort = distinct unsigned short;
  > type d_int = distinct int;
  > type d_uint = distinct unsigned;
  > type d_long = distinct long;
  > type d_ulong = distinct unsigned long;
  > type d_llong = distinct long long;
  > type d_ullong = distinct unsigned long long;
  > type d_bool = distinct _Bool;
  > type d_float = distinct float;
  > type d_double = distinct double;
  > type d_ldouble = distinct long double;
  > type d_cdouble = distinct _Complex double;
  > type d_text = distinct const char *;
  > type d_fn = distinct long (*)(long);
  > type distinct_printer = void (*)(d_char, d_schar, d_uchar, d_short,
  >     d_ushort, d_int, d_uint, d_long, d_ulong, d_llong, d_ullong, d_bool,
  >     d_float, d_double, d_ldouble, d_cdouble, d_text, d_fn);
  > EOF

hand.h is the C a client writes for these variants by hand, as 10.1
gives it; the C file below reads it in place of the header that
--emit-c-header writes (9.3), and writes the underlying type of each
distinct type itself (10.2). Its struct tags, enumeration tags and
enumerators take the prefix c_ so that a translation unit can hold them
next to the lowering, which claims the unprefixed names.

  $ cat > include/hand.h <<'EOF'
  > #include "fields.h"
  > enum c_scalar_tag {
  >   c_scalar_Empty, c_scalar_Chars, c_scalar_Shorts, c_scalar_Ints,
  >   c_scalar_Longs, c_scalar_Reals, c_scalar_Pointers
  > };
  > struct c_scalar {
  >   enum c_scalar_tag tag;
  >   union {
  >     struct { char c; signed char sc; unsigned char uc; } Chars;
  >     struct { short s; unsigned short us; } Shorts;
  >     struct { int i; unsigned u; _Bool b; } Ints;
  >     struct { long l; long long ll; unsigned long long ull; } Longs;
  >     struct { float f; double d; long double ld; } Reals;
  >     struct {
  >       const char *text; struct c_scalar *next; long (*twice)(long);
  >     } Pointers;
  >   } u;
  > };
  > enum c_compound_tag {
  >   c_compound_Point, c_compound_Bits, c_compound_Name, c_compound_Flags,
  >   c_compound_Inner
  > };
  > struct c_compound {
  >   enum c_compound_tag tag;
  >   union {
  >     struct { struct point p; } Point;
  >     struct { union bits b; } Bits;
  >     struct { struct name n; } Name;
  >     struct { struct flags f; } Flags;
  >     struct { struct c_scalar s; char after; } Inner;
  >   } u;
  > };
  > enum c_measure_tag { c_measure_Metres, c_measure_Count };
  > struct c_measure {
  >   enum c_measure_tag tag;
  >   union { struct { double m; } Metres; struct { long n; } Count; } u;
  > };
  > enum c_ratio_tag { c_ratio_Ratio };
  > struct c_ratio {
  >   enum c_ratio_tag tag;
  >   union { struct { float num; float den; } Ratio; } u;
  > };
  > enum c_flag_tag { c_flag_Off, c_flag_On };
  > struct c_flag { enum c_flag_tag tag; };
  > EOF

layout.h asserts that the lowering and the hand-written structures
agree: size and alignment of each variant and of its tag enumeration,
the offset of every field, the numbering of the tags from 0 in
declaration order, a variant without fields as its bare tag (10.1 rules
1 to 3), and the size and alignment of each distinct type as its
representation, with the signedness of each integer type (10.2). The
backend checks them on both targets.

  $ cat > include/layout.h <<'EOF'
  > #include <limits.h>
  > #define SAME_SIZE(t)                                                    \
  >   _Static_assert(sizeof (t) == sizeof (struct c_##t)                    \
  >                  && _Alignof (t) == _Alignof (struct c_##t)             \
  >                  && sizeof (enum t##_tag) == sizeof (enum c_##t##_tag), \
  >                  #t)
  > #define SAME_OFFSET(t, m)                                               \
  >   _Static_assert(offsetof(struct t, m) == offsetof(struct c_##t, m),    \
  >                  #t "." #m)
  > #define TAG(t, c, n) _Static_assert(t##_##c == n, #t "_" #c)
  > #define SAME_AS(d, u)                                                   \
  >   _Static_assert(sizeof (d) == sizeof (u) && _Alignof (d) == _Alignof (u), \
  >                  #d)
  > SAME_SIZE(scalar);
  > SAME_OFFSET(scalar, tag);
  > SAME_OFFSET(scalar, u);
  > SAME_OFFSET(scalar, u.Chars.c);
  > SAME_OFFSET(scalar, u.Chars.sc);
  > SAME_OFFSET(scalar, u.Chars.uc);
  > SAME_OFFSET(scalar, u.Shorts.s);
  > SAME_OFFSET(scalar, u.Shorts.us);
  > SAME_OFFSET(scalar, u.Ints.i);
  > SAME_OFFSET(scalar, u.Ints.u);
  > SAME_OFFSET(scalar, u.Ints.b);
  > SAME_OFFSET(scalar, u.Longs.l);
  > SAME_OFFSET(scalar, u.Longs.ll);
  > SAME_OFFSET(scalar, u.Longs.ull);
  > SAME_OFFSET(scalar, u.Reals.f);
  > SAME_OFFSET(scalar, u.Reals.d);
  > SAME_OFFSET(scalar, u.Reals.ld);
  > SAME_OFFSET(scalar, u.Pointers.text);
  > SAME_OFFSET(scalar, u.Pointers.next);
  > SAME_OFFSET(scalar, u.Pointers.twice);
  > TAG(scalar, Empty, 0);
  > TAG(scalar, Chars, 1);
  > TAG(scalar, Shorts, 2);
  > TAG(scalar, Ints, 3);
  > TAG(scalar, Longs, 4);
  > TAG(scalar, Reals, 5);
  > TAG(scalar, Pointers, 6);
  > SAME_SIZE(compound);
  > SAME_OFFSET(compound, u);
  > SAME_OFFSET(compound, u.Point.p);
  > SAME_OFFSET(compound, u.Bits.b);
  > SAME_OFFSET(compound, u.Name.n);
  > SAME_OFFSET(compound, u.Flags.f);
  > SAME_OFFSET(compound, u.Inner.s);
  > SAME_OFFSET(compound, u.Inner.after);
  > TAG(compound, Point, 0);
  > TAG(compound, Bits, 1);
  > TAG(compound, Name, 2);
  > TAG(compound, Flags, 3);
  > TAG(compound, Inner, 4);
  > SAME_SIZE(measure);
  > SAME_OFFSET(measure, u.Metres.m);
  > SAME_OFFSET(measure, u.Count.n);
  > TAG(measure, Metres, 0);
  > TAG(measure, Count, 1);
  > SAME_SIZE(ratio);
  > SAME_OFFSET(ratio, u.Ratio.num);
  > SAME_OFFSET(ratio, u.Ratio.den);
  > TAG(ratio, Ratio, 0);
  > SAME_SIZE(flag);
  > TAG(flag, Off, 0);
  > TAG(flag, On, 1);
  > SAME_AS(d_char, char);
  > SAME_AS(d_schar, signed char);
  > SAME_AS(d_uchar, unsigned char);
  > SAME_AS(d_short, short);
  > SAME_AS(d_ushort, unsigned short);
  > SAME_AS(d_int, int);
  > SAME_AS(d_uint, unsigned);
  > SAME_AS(d_long, long);
  > SAME_AS(d_ulong, unsigned long);
  > SAME_AS(d_llong, long long);
  > SAME_AS(d_ullong, unsigned long long);
  > SAME_AS(d_bool, _Bool);
  > SAME_AS(d_float, float);
  > SAME_AS(d_double, double);
  > SAME_AS(d_ldouble, long double);
  > SAME_AS(d_cdouble, _Complex double);
  > SAME_AS(d_text, const char *);
  > SAME_AS(d_fn, long (*)(long));
  > /* Integer types of one size differ in the value a conversion gives. */
  > _Static_assert((int)(d_char)-1 == (int)(char)-1, "d_char sign");
  > _Static_assert((int)(d_schar)-1 == -1, "d_schar sign");
  > _Static_assert((int)(d_uchar)-1 == UCHAR_MAX, "d_uchar sign");
  > _Static_assert((int)(d_short)-1 == -1, "d_short sign");
  > _Static_assert((int)(d_ushort)-1 == USHRT_MAX, "d_ushort sign");
  > _Static_assert((long long)(d_int)-1 == -1, "d_int sign");
  > _Static_assert((long long)(d_uint)-1 == UINT_MAX, "d_uint sign");
  > _Static_assert((long long)(d_long)-1 == -1, "d_long sign");
  > _Static_assert((unsigned long long)(d_ulong)-1 == ULONG_MAX,
  >                "d_ulong sign");
  > _Static_assert((int)(d_bool)2 == 1, "d_bool");
  > EOF

  $ printf '#include "abi.tci"\n#include "hand.h"\n#include "layout.h"\n' \
  >   > layout.tc
  $ for cc in "$clang" "$gcc"; do
  >   for target in "" "$second_target"; do
  >     typec --cc="$cc" $target -Wall -Wextra -Werror -Iinclude \
  >       -fsyntax-only layout.tc || echo "failed: $cc $target"
  >   done
  > done

A variant without fields is its bare tag: it has no union, not even an
empty one, which GNU C would allow at the same size (10.1 rule 3).

  $ printf 'size_t u = offsetof(struct flag, u);\n' > bare.h
  $ printf '#include "abi.tci"\n#include "bare.h"\n' > bare.tc
  $ typec --cc="$clang" -Iinclude -fsyntax-only bare.tc 2>&1 |
  >   grep -o "no member named 'u' in '[a-z ]*flag'"
  no member named 'u' in 'flag'

The assertions see a difference: the fields of Reals in another order
in hand.h move the offsets of its first two fields.

  $ mkdir swapped
  $ sed 's/float f; double d;/double d; float f;/' include/hand.h \
  >   > swapped/hand.h
  $ typec --cc="$clang" -Iswapped -Iinclude -fsyntax-only layout.tc 2>&1 |
  >   grep -o 'scalar\.u\.Reals\.[a-z]*' | sort -u
  scalar.u.Reals.d
  scalar.u.Reals.f

The Type-C side defines functions that take and return the variants and
the distinct types by value, prints values through match, rebuilds them
through constructors, and calls C directly, through function pointers
in both directions and through the ellipsis. A distinct value does not
cross the ellipsis (3.4); its cast to the representation does.

  $ cat > side.tc <<'EOF'
  > #include <limits.h>
  > #include <stdarg.h>
  > #include <stdio.h>
  > #include "abi.tci"
  > 
  > /* The C side, declared with the Type-C types whose lowering it sees. */
  > long twice(long n);
  > void c_print_scalar(scalar v);
  > scalar c_make_scalar(int which);
  > void c_send_scalar(int which, void (*print)(scalar));
  > void c_print_small(const char *kinds, ...);
  > measure c_scale(measure m, ratio r);
  > flag c_flip(flag f);
  > void c_print_distinct(d_char, d_schar, d_uchar, d_short, d_ushort, d_int,
  >     d_uint, d_long, d_ulong, d_llong, d_ullong, d_bool, d_float, d_double,
  >     d_ldouble, d_cdouble, d_text, d_fn);
  > void c_send_distinct(distinct_printer print);
  > 
  > static const char *scalar_name(const scalar *v) {
  >   match (*v) {
  >   case Empty: return "Empty";
  >   case Chars(_, _, _): return "Chars";
  >   case Shorts(_, _): return "Shorts";
  >   case Ints(_, _, _): return "Ints";
  >   case Longs(_, _, _): return "Longs";
  >   case Reals(_, _, _): return "Reals";
  >   case Pointers(_, _, _): return "Pointers";
  >   }
  > }
  > 
  > static void scalar_fields(scalar v) {
  >   printf("%s", scalar_name(&v));
  >   match (v) {
  >   case Empty:
  >     break;
  >   case Chars(c, sc, uc):
  >     printf(" %c %d %d", c, sc, uc);
  >     break;
  >   case Shorts(s, us):
  >     printf(" %d %d", s, us);
  >     break;
  >   case Ints(i, u, b):
  >     printf(" %d %u %d", i, u, b);
  >     break;
  >   case Longs(l, ll, ull):
  >     printf(" %ld %lld %llu", l, ll, ull);
  >     break;
  >   case Reals(f, d, ld):
  >     printf(" %a %a %La", f, d, ld);
  >     break;
  >   case Pointers(text, next, fn):
  >     printf(" %s %s %ld", text, scalar_name(next), fn(21));
  >     break;
  >   }
  > }
  > 
  > void tc_print_scalar(scalar v) {
  >   scalar_fields(v);
  >   printf("\n");
  > }
  > 
  > scalar tc_rebuild_scalar(scalar v) {
  >   match (v) {
  >   case Empty: return Empty;
  >   case Chars(c, sc, uc): return Chars(c, sc, uc);
  >   case Shorts(s, us): return Shorts(s, us);
  >   case Ints(i, u, b): return Ints(i, u, b);
  >   case Longs(l, ll, ull): return Longs(l, ll, ull);
  >   case Reals(f, d, ld): return Reals(f, d, ld);
  >   case Pointers(text, next, fn): return Pointers(text, next, fn);
  >   }
  > }
  > 
  > /* The values of c_make_scalar, made by constructors. */
  > static scalar chars = Chars('A', SCHAR_MIN, UCHAR_MAX);
  > 
  > static scalar make_scalar(int which) {
  >   switch (which) {
  >   case 1: return chars;
  >   case 2: return Shorts(SHRT_MIN, USHRT_MAX);
  >   case 3: return Ints(INT_MIN, UINT_MAX, 1);
  >   case 4: return Longs(LONG_MIN, LLONG_MIN, ULLONG_MAX);
  >   case 5: return Reals(0.1f, 0.1, 1.0L / 3);
  >   case 6: return Pointers("text", &chars, twice);
  >   }
  >   return Empty;
  > }
  > 
  > void tc_send_scalar(int which, void (*print)(scalar)) {
  >   print(make_scalar(which));
  > }
  > 
  > void tc_receive_scalar(int which) {
  >   c_print_scalar(c_make_scalar(which));
  >   c_send_scalar(which, tc_print_scalar);
  > }
  > 
  > void tc_print_compound(compound v) {
  >   match (v) {
  >   case Point(p):
  >     printf("Point %a %a\n", p.x, p.y);
  >     break;
  >   case Bits(b):
  >     printf("Bits %#x\n", b.u);
  >     break;
  >   case Name(n):
  >     printf("Name %s\n", n.text);
  >     break;
  >   case Flags(f):
  >     printf("Flags %d %d %d\n", f.ready, f.level, f.delta);
  >     break;
  >   case Inner(s, after):
  >     printf("Inner %c ", after);
  >     scalar_fields(s);
  >     printf("\n");
  >     break;
  >   }
  > }
  > 
  > compound tc_rebuild_compound(compound v) {
  >   match (v) {
  >   case Point(p): return Point(p);
  >   case Bits(b): return Bits(b);
  >   case Name(n): return Name(n);
  >   case Flags(f): return Flags(f);
  >   case Inner(s, after): return Inner(tc_rebuild_scalar(s), after);
  >   }
  > }
  > 
  > static float factor(ratio r) {
  >   match (r) {
  >   case Ratio(num, den): return num / den;
  >   }
  > }
  > 
  > measure tc_scale(measure m, ratio r) {
  >   match (m) {
  >   case Metres(x): return Metres(x * factor(r));
  >   case Count(n): return Count((long)(n * factor(r)));
  >   }
  > }
  > 
  > flag tc_flip(flag f) {
  >   match (f) {
  >   case Off: return On;
  >   case On: return Off;
  >   }
  > }
  > 
  > /* Each character of kinds names the type of the next argument: m measure,
  >    r ratio, f flag, d double. */
  > void tc_print_small(const char *kinds, ...) {
  >   va_list ap;
  >   va_start(ap, kinds);
  >   for (; *kinds; kinds++) {
  >     if (*kinds == 'm') {
  >       match (va_arg(ap, measure)) {
  >       case Metres(x): printf(" Metres %a", x); break;
  >       case Count(n): printf(" Count %ld", n); break;
  >       }
  >     } else if (*kinds == 'r') {
  >       match (va_arg(ap, ratio)) {
  >       case Ratio(num, den): printf(" Ratio %a %a", num, den); break;
  >       }
  >     } else if (*kinds == 'f') {
  >       match (va_arg(ap, flag)) {
  >       case Off: printf(" Off"); break;
  >       case On: printf(" On"); break;
  >       }
  >     } else {
  >       printf(" %a", va_arg(ap, double));
  >     }
  >   }
  >   va_end(ap);
  >   printf("\n");
  > }
  > 
  > void tc_print_distinct(d_char c, d_schar sc, d_uchar uc, d_short s,
  >     d_ushort us, d_int i, d_uint u, d_long l, d_ulong ul, d_llong ll,
  >     d_ullong ull, d_bool b, d_float f, d_double d, d_ldouble ld,
  >     d_cdouble z, d_text text, d_fn fn) {
  >   printf("%c %d %d %d %d %d %u %d %s %ld\n", (char)c, (signed char)sc,
  >          (unsigned char)uc, (short)s, (unsigned short)us, (int)i,
  >          (unsigned)u, (_Bool)b, (const char *)text,
  >          ((long (*)(long))fn)(21));
  >   printf("%ld %lu %lld %llu\n", (long)l, (unsigned long)ul, (long long)ll,
  >          (unsigned long long)ull);
  >   printf("%a %a %La %a%+ai\n", (float)f, (double)d, (long double)ld,
  >          __real__ (_Complex double)z, __imag__ (_Complex double)z);
  > }
  > 
  > /* The values of c_send_distinct, made by casts. */
  > #define DISTINCT_VALUES                                                 \
  >   (d_char)'A', (d_schar)SCHAR_MIN, (d_uchar)UCHAR_MAX, (d_short)SHRT_MIN, \
  >   (d_ushort)USHRT_MAX, (d_int)INT_MIN, (d_uint)UINT_MAX, (d_long)LONG_MIN, \
  >   (d_ulong)ULONG_MAX, (d_llong)LLONG_MIN, (d_ullong)ULLONG_MAX, (d_bool)1, \
  >   (d_float)0.1f, (d_double)0.1, (d_ldouble)(1.0L / 3),                  \
  >   (d_cdouble)(1.5 - 2.0i), (d_text)"text", (d_fn)twice
  > 
  > void tc_send_distinct(distinct_printer print) { print(DISTINCT_VALUES); }
  > 
  > d_schar tc_lowest(void) { return (d_schar)SCHAR_MIN; }
  > d_ullong tc_highest(void) { return (d_ullong)ULLONG_MAX; }
  > d_float tc_tenth(void) { return (d_float)0.1f; }
  > d_ldouble tc_third(void) { return (d_ldouble)(1.0L / 3); }
  > d_cdouble tc_unit(void) { return (d_cdouble)(1.5 - 2.0i); }
  > d_text tc_text(void) { return (d_text)"text"; }
  > 
  > /* Type-C calls C directly and through a callback, and through the
  >    ellipsis, where a distinct value crosses as its representation. */
  > void tc_call_c(void) {
  >   d_double tenth = (d_double)0.1;
  >   measure metres = Metres(2.5), count = Count(-7);
  >   ratio half = Ratio(1, 2);
  >   flag on = On;
  >   c_print_small("mmrfd", metres, count, half, on, (double)tenth);
  >   tc_print_small("mmrfd", metres, count, half, on, (double)tenth);
  >   c_print_small("mf", c_scale(metres, half), c_flip(on));
  >   tc_print_small("mf", c_scale(metres, half), c_flip(on));
  >   c_print_distinct(DISTINCT_VALUES);
  >   c_send_distinct(tc_print_distinct);
  > }
  > EOF

The C side declares the functions of the Type-C side with the
representation of their types, and the functions that the Type-C side
calls; it prints values with switch on the tag.

  $ cat > side.c <<'EOF'
  > #include <limits.h>
  > #include <stdarg.h>
  > #include <stdio.h>
  > #include "hand.h"
  > 
  > typedef struct c_scalar scalar;
  > typedef struct c_compound compound;
  > typedef struct c_measure measure;
  > typedef struct c_ratio ratio;
  > typedef struct c_flag flag;
  > typedef void (*distinct_printer)(char, signed char, unsigned char, short,
  >     unsigned short, int, unsigned, long, unsigned long, long long,
  >     unsigned long long, _Bool, float, double, long double, _Complex double,
  >     const char *, long (*)(long));
  > 
  > /* The Type-C side, declared with the representation it has in C. */
  > void tc_print_scalar(scalar v);
  > scalar tc_rebuild_scalar(scalar v);
  > void tc_send_scalar(int which, void (*print)(scalar));
  > void tc_receive_scalar(int which);
  > void tc_print_compound(compound v);
  > compound tc_rebuild_compound(compound v);
  > measure tc_scale(measure m, ratio r);
  > flag tc_flip(flag f);
  > void tc_print_small(const char *kinds, ...);
  > void tc_print_distinct(char, signed char, unsigned char, short,
  >     unsigned short, int, unsigned, long, unsigned long, long long,
  >     unsigned long long, _Bool, float, double, long double, _Complex double,
  >     const char *, long (*)(long));
  > void tc_send_distinct(distinct_printer print);
  > signed char tc_lowest(void);
  > unsigned long long tc_highest(void);
  > float tc_tenth(void);
  > long double tc_third(void);
  > _Complex double tc_unit(void);
  > const char *tc_text(void);
  > void tc_call_c(void);
  > 
  > long twice(long n) { return 2 * n; }
  > 
  > static const char *const scalar_names[] = {
  >   "Empty", "Chars", "Shorts", "Ints", "Longs", "Reals", "Pointers"
  > };
  > 
  > static void scalar_fields(scalar v) {
  >   printf("%s", scalar_names[v.tag]);
  >   switch (v.tag) {
  >   case c_scalar_Empty:
  >     break;
  >   case c_scalar_Chars:
  >     printf(" %c %d %d", v.u.Chars.c, v.u.Chars.sc, v.u.Chars.uc);
  >     break;
  >   case c_scalar_Shorts:
  >     printf(" %d %d", v.u.Shorts.s, v.u.Shorts.us);
  >     break;
  >   case c_scalar_Ints:
  >     printf(" %d %u %d", v.u.Ints.i, v.u.Ints.u, v.u.Ints.b);
  >     break;
  >   case c_scalar_Longs:
  >     printf(" %ld %lld %llu", v.u.Longs.l, v.u.Longs.ll, v.u.Longs.ull);
  >     break;
  >   case c_scalar_Reals:
  >     printf(" %a %a %La", v.u.Reals.f, v.u.Reals.d, v.u.Reals.ld);
  >     break;
  >   case c_scalar_Pointers:
  >     printf(" %s %s %ld", v.u.Pointers.text,
  >            scalar_names[v.u.Pointers.next->tag], v.u.Pointers.twice(21));
  >     break;
  >   }
  > }
  > 
  > void c_print_scalar(scalar v) {
  >   scalar_fields(v);
  >   printf("\n");
  > }
  > 
  > static void c_print_compound(compound v) {
  >   switch (v.tag) {
  >   case c_compound_Point:
  >     printf("Point %a %a\n", v.u.Point.p.x, v.u.Point.p.y);
  >     break;
  >   case c_compound_Bits:
  >     printf("Bits %#x\n", v.u.Bits.b.u);
  >     break;
  >   case c_compound_Name:
  >     printf("Name %s\n", v.u.Name.n.text);
  >     break;
  >   case c_compound_Flags:
  >     printf("Flags %d %d %d\n", v.u.Flags.f.ready, v.u.Flags.f.level,
  >            v.u.Flags.f.delta);
  >     break;
  >   case c_compound_Inner:
  >     printf("Inner %c ", v.u.Inner.after);
  >     scalar_fields(v.u.Inner.s);
  >     printf("\n");
  >     break;
  >   }
  > }
  > 
  > /* The values that C makes, the same as those of make_scalar in Type-C. */
  > static scalar chars = { c_scalar_Chars,
  >                         .u.Chars = { 'A', SCHAR_MIN, UCHAR_MAX } };
  > static const scalar scalars[] = {
  >   { .tag = c_scalar_Empty },
  >   { c_scalar_Chars, .u.Chars = { 'A', SCHAR_MIN, UCHAR_MAX } },
  >   { c_scalar_Shorts, .u.Shorts = { SHRT_MIN, USHRT_MAX } },
  >   { c_scalar_Ints, .u.Ints = { INT_MIN, UINT_MAX, 1 } },
  >   { c_scalar_Longs, .u.Longs = { LONG_MIN, LLONG_MIN, ULLONG_MAX } },
  >   { c_scalar_Reals, .u.Reals = { 0.1f, 0.1, 1.0L / 3 } },
  >   { c_scalar_Pointers, .u.Pointers = { "text", &chars, twice } },
  > };
  > static const compound compounds[] = {
  >   { c_compound_Point, .u.Point = { { 1.5, -2.25 } } },
  >   { c_compound_Bits, .u.Bits = { { 0x3f800000u } } },
  >   { c_compound_Name, .u.Name = { { "abcdef" } } },
  >   { c_compound_Flags, .u.Flags = { { 1, 5, -3 } } },
  >   { c_compound_Inner,
  >     .u.Inner = { { c_scalar_Reals, .u.Reals = { 0.1f, 0.1, 1.0L / 3 } },
  >                  'z' } },
  > };
  > #define COUNT(a) (sizeof (a) / sizeof (a)[0])
  > 
  > scalar c_make_scalar(int which) { return scalars[which]; }
  > 
  > measure c_scale(measure m, ratio r) {
  >   float factor = r.u.Ratio.num / r.u.Ratio.den;
  >   if (m.tag == c_measure_Metres)
  >     m.u.Metres.m *= factor;
  >   else
  >     m.u.Count.n = (long)(m.u.Count.n * factor);
  >   return m;
  > }
  > 
  > flag c_flip(flag f) {
  >   if (f.tag == c_flag_On)
  >     f.tag = c_flag_Off;
  >   else
  >     f.tag = c_flag_On;
  >   return f;
  > }
  > 
  > void c_send_scalar(int which, void (*print)(scalar)) {
  >   print(scalars[which]);
  > }
  > 
  > /* Each character of kinds names the type of the next argument, as for
  >    tc_print_small. */
  > void c_print_small(const char *kinds, ...) {
  >   va_list ap;
  >   va_start(ap, kinds);
  >   for (; *kinds; kinds++) {
  >     if (*kinds == 'm') {
  >       measure m = va_arg(ap, measure);
  >       if (m.tag == c_measure_Metres)
  >         printf(" Metres %a", m.u.Metres.m);
  >       else
  >         printf(" Count %ld", m.u.Count.n);
  >     } else if (*kinds == 'r') {
  >       ratio r = va_arg(ap, ratio);
  >       printf(" Ratio %a %a", r.u.Ratio.num, r.u.Ratio.den);
  >     } else if (*kinds == 'f') {
  >       flag f = va_arg(ap, flag);
  >       printf(f.tag == c_flag_On ? " On" : " Off");
  >     } else {
  >       printf(" %a", va_arg(ap, double));
  >     }
  >   }
  >   va_end(ap);
  >   printf("\n");
  > }
  > 
  > void c_print_distinct(char c, signed char sc, unsigned char uc, short s,
  >     unsigned short us, int i, unsigned u, long l, unsigned long ul,
  >     long long ll, unsigned long long ull, _Bool b, float f, double d,
  >     long double ld, _Complex double z, const char *text, long (*fn)(long)) {
  >   printf("%c %d %d %d %d %d %u %d %s %ld\n", c, sc, uc, s, us, i, u, b,
  >          text, fn(21));
  >   printf("%ld %lu %lld %llu\n", l, ul, ll, ull);
  >   printf("%a %a %La %a%+ai\n", f, d, ld, __real__ z, __imag__ z);
  > }
  > 
  > /* The values of tc_send_distinct, as their representation. */
  > #define DISTINCT_VALUES                                                 \
  >   'A', SCHAR_MIN, UCHAR_MAX, SHRT_MIN, USHRT_MAX, INT_MIN, UINT_MAX,    \
  >   LONG_MIN, ULONG_MAX, LLONG_MIN, ULLONG_MAX, 1, 0.1f, 0.1, 1.0L / 3,   \
  >   1.5 - 2.0i, "text", twice
  > 
  > void c_send_distinct(distinct_printer print) { print(DISTINCT_VALUES); }
  > 
  > int main(void) {
  >   for (int i = 0; i < (int)COUNT(scalars); i++) {
  >     c_print_scalar(scalars[i]);
  >     tc_print_scalar(scalars[i]);
  >     c_print_scalar(tc_rebuild_scalar(scalars[i]));
  >     tc_send_scalar(i, c_print_scalar);
  >     tc_receive_scalar(i);
  >   }
  >   for (size_t i = 0; i < COUNT(compounds); i++) {
  >     c_print_compound(compounds[i]);
  >     tc_print_compound(compounds[i]);
  >     c_print_compound(tc_rebuild_compound(compounds[i]));
  >   }
  >   measure metres = { c_measure_Metres, .u.Metres = { 2.5 } };
  >   measure count = { c_measure_Count, .u.Count = { -7 } };
  >   ratio three_halves = { c_ratio_Ratio, .u.Ratio = { 3, 2 } };
  >   flag on = { c_flag_On };
  >   c_print_small("mmf", tc_scale(metres, three_halves),
  >                 tc_scale(count, three_halves), tc_flip(on));
  >   tc_print_small("mmf", tc_scale(metres, three_halves),
  >                  tc_scale(count, three_halves), tc_flip(on));
  >   tc_print_distinct(DISTINCT_VALUES);
  >   tc_send_distinct(c_print_distinct);
  >   printf("returned %d %llu %a %La %a%+ai %s\n", tc_lowest(), tc_highest(),
  >          tc_tenth(), tc_third(), __real__ tc_unit(), __imag__ tc_unit(),
  >          tc_text());
  >   tc_call_c();
  >   return 0;
  > }
  > EOF

Every pairing of a backend that compiles side.tc through typec with one
that compiles side.c gives the same output. Each value of scalar is
printed six times: by C from its own table; by Type-C, passed by value;
by C after Type-C rebuilds and returns it; by C called through a pointer
from Type-C, which made it; by C after Type-C passes it back from a C
function that returned it; and by Type-C called through a pointer from
C. Each compound is printed three times, as the first three. The small
variants go by value to each side and back, and across the ellipsis to
both sides; the distinct values cross by direct calls and callbacks
each way. The output is sorted so that every crossing of a value lands
on the same line, and the count shows how many agreed.

The text of a long double is that of the x87 format of x86-64.

  $ for tc_cc in "$clang" "$gcc"; do
  >   rm -f tc.o
  >   typec --cc="$tc_cc" -Wall -Wextra -Werror -Iinclude -c side.tc \
  >     -o tc.o &&
  >   for c_cc in "$clang" "$gcc"; do
  >     "$c_cc" -Wall -Wextra -Werror -Iinclude -c side.c -o c.o &&
  >     "$c_cc" -o prog tc.o c.o && ./prog > raw &&
  >     LC_ALL=C sort raw | uniq -c | sed 's/^ *//' \
  >       > "out-${tc_cc##*/}-${c_cc##*/}"
  >   done
  > done
  $ ls out-* | wc -l | tr -d ' '
  4
  $ cat "out-${clang##*/}-${clang##*/}"
  2  Metres 0x1.4p+0 Off
  2  Metres 0x1.4p+1 Count -7 Ratio 0x1p+0 0x1p+1 On 0x1.999999999999ap-4
  2  Metres 0x1.ep+1 Count -10 Off
  4 -9223372036854775808 18446744073709551615 -9223372036854775808 18446744073709551615
  4 0x1.99999ap-4 0x1.999999999999ap-4 0xa.aaaaaaaaaaaaaabp-5 0x1.8p+0-0x1p+1i
  4 A -128 255 -32768 65535 -2147483648 4294967295 1 text 42
  3 Bits 0x3f800000
  6 Chars A -128 255
  6 Empty
  3 Flags 1 5 -3
  3 Inner z Reals 0x1.99999ap-4 0x1.999999999999ap-4 0xa.aaaaaaaaaaaaaabp-5
  6 Ints -2147483648 4294967295 1
  6 Longs -9223372036854775808 -9223372036854775808 18446744073709551615
  3 Name abcdef
  3 Point 0x1.8p+0 -0x1.2p+1
  6 Pointers text Chars 42
  6 Reals 0x1.99999ap-4 0x1.999999999999ap-4 0xa.aaaaaaaaaaaaaabp-5
  6 Shorts -32768 65535
  1 returned -128 18446744073709551615 0x1.99999ap-4 0xa.aaaaaaaaaaaaaabp-5 0x1.8p+0-0x1p+1i text
  $ for out in out-*; do
  >   cmp "out-${clang##*/}-${clang##*/}" "$out"
  > done

The second target is only compiled: a host may link no program for it,
as macOS has no i386 libraries.

  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" $second_target -Wall -Wextra -Werror -Iinclude \
  >     -fsyntax-only side.tc &&
  >   "$cc" $second_target -Wall -Wextra -Werror -Iinclude -fsyntax-only \
  >     side.c
  > done

Passing a distinct value itself through the ellipsis is refused, with
status 80.

  $ printf '#include <stdio.h>\ntype reg_id = distinct unsigned;\n' \
  >   > ellipsis.tc
  $ printf 'void f(reg_id r) { printf("%%u", r); }\n' >> ellipsis.tc
  $ typec --cc="$clang" -c ellipsis.tc -o ellipsis.o
  typec: ellipsis.tc:3: a value of the distinct type 'reg_id' takes no such operation; a cast to its underlying type crosses to it (design 3.4) [TC0011]
  [80]

A small program in Type-C and its hand-written C equivalent, a tagged
structure read by switch, give the same output at -O2 on each backend
(plan, Stage 1 exit gate 4). The gate also compares their size and
speed, which a run test does not measure.

  $ cat > eval.tc <<'EOF'
  > #include <stdio.h>
  > type expr =
  >     | Number(long value)
  >     | Negate(const expr *operand)
  >     | Add(const expr *left, const expr *right)
  >     | Multiply(const expr *left, const expr *right);
  > static long eval(const expr *e) {
  >   match (*e) {
  >   case Number(n): return n;
  >   case Negate(x): return -eval(x);
  >   case Add(l, r): return eval(l) + eval(r);
  >   case Multiply(l, r): return eval(l) * eval(r);
  >   }
  > }
  > static void show(const expr *e) {
  >   match (*e) {
  >   case Number(n):
  >     printf("%ld", n);
  >     break;
  >   case Negate(x):
  >     printf("-");
  >     show(x);
  >     break;
  >   case Add(l, r):
  >     printf("(");
  >     show(l);
  >     printf(" + ");
  >     show(r);
  >     printf(")");
  >     break;
  >   case Multiply(l, r):
  >     show(l);
  >     printf(" * ");
  >     show(r);
  >     break;
  >   }
  > }
  > int main(void) {
  >   expr two = Number(2), three = Number(3), seven = Number(7);
  >   expr sum = Add(&two, &three), minus_seven = Negate(&seven);
  >   expr product = Multiply(&sum, &minus_seven);
  >   const expr *all[] = { &two, &sum, &minus_seven, &product };
  >   for (int i = 0; i < 4; i++) {
  >     show(all[i]);
  >     printf(" = %ld\n", eval(all[i]));
  >   }
  >   return 0;
  > }
  > EOF
  $ cat > eval.c <<'EOF'
  > #include <stdio.h>
  > enum kind { NUMBER, NEGATE, ADD, MULTIPLY };
  > struct expr {
  >   enum kind kind;
  >   union {
  >     long value;
  >     const struct expr *operand;
  >     struct { const struct expr *left, *right; } pair;
  >   } u;
  > };
  > static long eval(const struct expr *e) {
  >   switch (e->kind) {
  >   case NUMBER: return e->u.value;
  >   case NEGATE: return -eval(e->u.operand);
  >   case ADD: return eval(e->u.pair.left) + eval(e->u.pair.right);
  >   case MULTIPLY: return eval(e->u.pair.left) * eval(e->u.pair.right);
  >   }
  >   return 0;
  > }
  > static void show(const struct expr *e) {
  >   switch (e->kind) {
  >   case NUMBER:
  >     printf("%ld", e->u.value);
  >     break;
  >   case NEGATE:
  >     printf("-");
  >     show(e->u.operand);
  >     break;
  >   case ADD:
  >     printf("(");
  >     show(e->u.pair.left);
  >     printf(" + ");
  >     show(e->u.pair.right);
  >     printf(")");
  >     break;
  >   case MULTIPLY:
  >     show(e->u.pair.left);
  >     printf(" * ");
  >     show(e->u.pair.right);
  >     break;
  >   }
  > }
  > int main(void) {
  >   struct expr two = { NUMBER, { .value = 2 } };
  >   struct expr three = { NUMBER, { .value = 3 } };
  >   struct expr seven = { NUMBER, { .value = 7 } };
  >   struct expr sum = { ADD, { .pair = { &two, &three } } };
  >   struct expr minus_seven = { NEGATE, { .operand = &seven } };
  >   struct expr product = { MULTIPLY, { .pair = { &sum, &minus_seven } } };
  >   const struct expr *all[] = { &two, &sum, &minus_seven, &product };
  >   for (int i = 0; i < 4; i++) {
  >     show(all[i]);
  >     printf(" = %ld\n", eval(all[i]));
  >   }
  >   return 0;
  > }
  > EOF

  $ for cc in "$clang" "$gcc"; do
  >   typec --cc="$cc" -O2 -Wall -Wextra -Werror -o eval-tc eval.tc &&
  >   "$cc" -O2 -Wall -Wextra -Werror -o eval-c eval.c &&
  >   ./eval-tc > tc.out && ./eval-c > c.out && cmp tc.out c.out
  > done
  $ cat tc.out
  2 = 2
  (2 + 3) = 5
  -7 = -7
  (2 + 3) * -7 = -35
