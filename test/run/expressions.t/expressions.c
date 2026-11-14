/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* Function bodies whose expressions typec types; expression_probe asserts
   the type of each expression statement after it. */

struct s { int m; const char k; unsigned b : 3; long long w : 40; };
union u { int i; double d; };
struct anonymous { int x; union { int y; struct { char z; }; }; };
enum e { E0, E1 = -1 };
enum big { B0 = 0x100000000LL };

int f(int);
int g(int, ...);
int h();
double vd(void);
const int cf(void);
struct s sf(void);
int (*fp)(int);
_Bool flag;

void operators(int x, const int cx, char c, signed char sc, unsigned char uc,
               short sh, unsigned short us, unsigned u, long l,
               unsigned long ul, long long ll, unsigned long long ull,
               float fl, double d, long double ld, _Complex float zf,
               _Complex double z, enum e en, enum big eb, const char *p,
               int *ip, const int *cip, volatile int *vip, void *vp,
               const void *cvp, struct s s, const struct s cs,
               struct s *ps, const struct s *cps, union u un,
               struct anonymous an)
{
	int a[3];
	const int ca[2] = { 1, 2 };
	int m[2][3];
	register int r = 0;

	/* Constants and string literals */
	1; 1u; 1l; 1ul; 1ll; 0x7fffffff; 0x80000000; 4294967296;
	1.0f; 1.0; 1.0L; 'a'; L'a'; u'a'; U'a';
	"ab"; "a" "bc"; "\x41\n"; L"ab"; u"ab"; U"ab"; u8"ab"; "a" L"b";
	"\xc3\xa9"; u"\U0001F600"; U"\U0001F600"; L"\u00e9";
	__func__; __FUNCTION__;

	/* Identifiers and parentheses */
	x; cx; (cx); a; ca; m; f; fp; en; E0; E1; eb; B0; flag;

	/* Postfix operators */
	a[1]; 1[a]; ca[0]; m[1]; m[1][2]; p[x]; ip[-1];
	f(1); fp(2); (*fp)(3); (**fp)(4); g(1, 2.0, "x"); h(1, 2); vd();
	cf(); sf(); sf().m;
	s.m; s.k; cs.m; ps->m; cps->m; cps->k; un.d; an.y; an.z;
	x++; c--; p++; d--; s.m++; ps->m--;
	(struct s){ 1 }; (int[2]){ 1, 2 }; (const char *){ 0 };

	/* Unary operators */
	&x; &cx; &a; &ca; &m; &m[1]; &f; &fp; &s; &cs.m; &*p; &*a; &a[1];
	*p; *a; *m; *f; *fp; **m; *cps;
	+c; -sh; +us; -u; +l; -ul; +fl; -d; +ld; -z;
	~c; ~sc; ~uc; ~sh; ~us; ~u; ~l; ~ul; ~ll; ~ull; ~en; ~eb; ~flag; ~z;
	!x; !p; !d; !z; !flag;
	++x; --c; ++p; ++d; --s.m;
	sizeof x; sizeof a; sizeof (int); sizeof s; _Alignof (int);
	__alignof__ (x);
	__real__ z; __imag__ zf; __real__ d; __imag__ x;
	(int)d; (const int)x; (void)x; (char *)vp; (struct s *)vp;
	(unsigned char)x; (float)x;

	/* Multiplicative, additive and shift operators */
	c * c; sc * uc; sh * us; u * x; u * l; ul * ll; ull * ll; l * ull;
	x / d; fl * x; fl * d; d * ld; zf * fl; zf * d; z * x; en * u;
	eb * x; flag * flag;
	x % c; ul % u; ll % ull;
	p + 1; 1 + p; p - 1; a + 1; m + 1; vp + 1; ip + l;
	p - p; ip - ip; cip - ip;
	c << 1; x << l; u >> c; ull >> 1; sh << ull; flag << 1;

	/* Relations, equality, bitwise and logical operators */
	x < d; p < p; ip <= cip; z == 1; p == 0; ip == vp; ip != cip;
	fp == 0; x & u; c ^ sc; l | ul; flag & flag;
	x && p; d || z; !x && !p;

	/* The conditional operator */
	x ? c : us; x ? 1 : 2.0; x ? u : l; x ? fl : z; x ? en : en;
	x ? p : 0; x ? 0 : ip; x ? (void *)0 : ip; x ? ip : (void *)0;
	x ? vp : ip; x ? cvp : ip; x ? ip : cip; x ? cip : vip;
	x ? s : cs; x ? (void)0 : (void)1; x ? a : ip; x ? f : fp;
	x ?: 1.0; p ?: 0; d ?: x;

	/* Assignments and the comma operator */
	x = d; c = x; p = 0; un = un; ps->m = 1; s.b = 1; d += x;
	p += 1; x <<= 1; ul ^= 1; ip -= l;
	(x, d); (d, x); (x, a); (x, f); (x, cx); (x, s);

	/* Generic selections, each association of a type of its own */
	_Generic(x, int: d, default: c); _Generic(cx, int: 1L, const int: 'c');
	_Generic(a, int *: fl, default: 0); _Generic(f, int (*)(int): f, default: 0);
	_Generic(en, enum e: ul, default: 0); _Generic(p, const char *: p, char *: 1);
	_Generic(1.0f, double: 1, float: 2u, default: 3L);
	_Generic(s, struct s: s, default: 0); _Generic(cs, struct s: un, default: 0);
	_Generic(x, long: 1, default: ip); _Generic(l, int: 1, long: 2u);
	_Generic(z, _Complex double: zf, default: 0); _Generic("ab", char *: ca);
	_Generic(x, int: x) = 1; x ? _Generic(0, int: (void *)0) : ip;
	x ? _Generic(0, int: 0) : ip; x ? _Generic(0, int: vp) : ip;

	/* GNU */
	__builtin_types_compatible_p(const int, int);
	__builtin_types_compatible_p(int[], const int[3]);
	__builtin_types_compatible_p(enum e, int);
	__builtin_types_compatible_p(enum e, unsigned);
	__builtin_types_compatible_p(int (*)(), int (*)(int));
	__builtin_types_compatible_p(char, signed char);
	__builtin_types_compatible_p(long, long long);
	__builtin_types_compatible_p(_Atomic int, _Atomic int);
	__builtin_types_compatible_p(struct s, const struct s);
	({ 1; }); ({ x; d; }); ({ a; }); ({ int y = 2; y + 1; }); ({ ; });
	({ s; });
	__builtin_types_compatible_p(int, long);
	__builtin_offsetof(struct s, m);
	r + 1;
	(void)ca;
}

void blocks(int n)
{
	int vla[n];
	struct local { int a; } v;
	enum { L0 = 5 } le;
	typedef const long CL;
	CL cl = 0;
	extern int f(int);
	static int counter;

	vla; vla[0]; sizeof vla; v; v.a; le; L0; cl; f; counter;
	{
		struct local { double d; } inner;
		inner.d;
		inner;
	}
	v;
	for (int i = 0; i < n; i++) {
		i;
		i++;
	}
	switch (n) {
	case 1:
	case L0:
		n;
		break;
	default:
		;
	}
	do {
		n--;
		if (n)
			continue;
	} while (n > 0);
}

int old_style(a, b, c)
	int a;
	char *b;
	double c;
{
	a + *b;
	c * a;
	return a;
}
