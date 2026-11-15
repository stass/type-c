/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* Calls of the builtins that a rule of their own types (design 13.3),
   and of those whose type typec leaves unknown, and the selections of
   __builtin_choose_expr; expression_probe asserts the type of each
   expression statement after it, and builtin_probe writes the calls of
   the builtins with a prototype. */

struct s { unsigned b : 3; int m; };

int g(const char *, ...);
float sinf(float);
double sin(double);
long double sinl(long double);

void rules(int x, long l, unsigned u, double d, float f, long double ld,
           int *ip, const volatile long *cvlp, char **pp, void *vp,
           struct s s, ...)
{
	__builtin_va_list ap, aq;

	/* Arguments of any type, a result of one type */
	__builtin_constant_p(x); __builtin_constant_p(ip);
	__builtin_classify_type(d); __builtin_classify_type(s);
	__builtin_isnan(d); __builtin_isinf(f); __builtin_isfinite(ld);
	__builtin_isinf_sign(d); __builtin_isnormal(f); __builtin_signbit(ld);
	__builtin_fpclassify(0, 1, 2, 3, 4, d);
	__builtin_isgreater(d, f); __builtin_isgreaterequal(d, ld);
	__builtin_isless(f, f); __builtin_islessequal(d, d);
	__builtin_islessgreater(d, d); __builtin_isunordered(ld, d);
	__builtin_add_overflow(x, l, &x); __builtin_sub_overflow(u, x, &l);
	__builtin_mul_overflow(l, l, &u);
	__builtin_va_start(ap, s); __builtin_va_copy(aq, ap);
	__builtin_va_end(aq); __builtin_va_end(ap);
	__atomic_store_n(ip, 1, 0); __atomic_load(cvlp, &l, 0);
	__atomic_store(ip, &x, 0); __atomic_exchange(ip, &x, &x, 0);
	__atomic_compare_exchange(ip, &x, &x, 0, 0, 0);
	__atomic_compare_exchange_n(ip, &x, 1, 0, 0, 0);
	__sync_bool_compare_and_swap(ip, 1, 2); __sync_lock_release(ip);

	/* The unqualified type that the first argument points to */
	__atomic_load_n(cvlp, 0); __atomic_exchange_n(ip, 1, 0);
	__sync_val_compare_and_swap(ip, 1, 2); __sync_lock_test_and_set(ip, 1);
	__atomic_fetch_add(ip, 1, 0); __atomic_add_fetch(pp, 1, 0);
	__sync_fetch_and_add(ip, 1); __sync_add_and_fetch(ip, 1);
	__atomic_fetch_sub(pp, 1, 0); __atomic_sub_fetch(ip, 1, 0);
	__sync_fetch_and_sub(ip, 1); __sync_sub_and_fetch(ip, 1);
	__atomic_fetch_and(ip, 1, 0); __atomic_and_fetch(ip, 1, 0);
	__sync_fetch_and_and(ip, 1); __sync_and_and_fetch(ip, 1);
	__atomic_fetch_or(ip, 1, 0); __atomic_or_fetch(ip, 1, 0);
	__sync_fetch_and_or(ip, 1); __sync_or_and_fetch(ip, 1);
	__atomic_fetch_xor(ip, 1, 0); __atomic_xor_fetch(ip, 1, 0);
	__sync_fetch_and_xor(ip, 1); __sync_xor_and_fetch(ip, 1);
	__atomic_fetch_nand(ip, 1, 0); __atomic_nand_fetch(ip, 1, 0);
	__sync_fetch_and_nand(ip, 1); __sync_nand_and_fetch(ip, 1);

	/* The complex type of the first argument */
	__builtin_complex(d, d); __builtin_complex(f, f);
	__builtin_complex(ld, ld);

	/* Of the optional floating types, which typec does not compute */
	__builtin_huge_valf128(); __builtin_inff128();
	__builtin_nanf128(""); __builtin_nansf128("");

	/* The chosen operand, an lvalue or a bit-field where it is one */
	__builtin_choose_expr(1, x, d); __builtin_choose_expr(0, x, d);
	__builtin_choose_expr(sizeof(int) == 4, "ab", 0);
	__builtin_choose_expr(1, s.b, 0) + 0;
	__builtin_choose_expr(1, x, 0) = 2;
	__builtin_choose_expr(__builtin_choose_expr(1, 0, 1), x, d);
	x ? __builtin_choose_expr(1, (void *)0, 1) : ip;
	x ? __builtin_choose_expr(0, (void *)0, vp) : ip;
	__builtin_choose_expr(__builtin_constant_p(x), x, d);
}

/* An integer constant expression where the chosen operand is one. */
enum { chosen = __builtin_choose_expr(1, 2, 3) };

#if __has_builtin(__builtin_c23_va_start)
/* C23's va_start, whose second argument is optional, which GCC 15 and
   Clang 21 have in C23. */
void c23(int n, ...)
{
	__builtin_va_list ap;

	__builtin_c23_va_start(ap, n); __builtin_va_end(ap);
	__builtin_c23_va_start(ap); __builtin_va_end(ap);
}
#endif

#ifdef __clang__
/* Clang's builtins of C11's atomic operations take a pointer to an atomic
   type and give the type without _Atomic. Its __atomic max and min
   operations give the type that the first argument points to. */
void c11(_Atomic int *ai, _Atomic(long) *al, int x, long *lp)
{
	__c11_atomic_init(ai, 1); __c11_atomic_store(ai, 1, 0);
	__c11_atomic_load(ai, 0); __c11_atomic_exchange(al, 1, 0);
	__c11_atomic_fetch_add(ai, 1, 0); __c11_atomic_fetch_sub(al, 1, 0);
	__c11_atomic_fetch_and(ai, 1, 0); __c11_atomic_fetch_or(ai, 1, 0);
	__c11_atomic_fetch_xor(ai, 1, 0); __c11_atomic_fetch_nand(al, 1, 0);
	__c11_atomic_fetch_max(ai, 1, 0); __c11_atomic_fetch_min(al, 1, 0);
	__atomic_fetch_max(lp, 1, 0); __atomic_max_fetch(&x, 1, 0);
	__atomic_fetch_min(&x, 1, 0); __atomic_min_fetch(lp, 1, 0);
	__c11_atomic_compare_exchange_strong(ai, &x, 1, 0, 0);
	__c11_atomic_compare_exchange_weak(ai, &x, 1, 0, 0);
	__builtin_os_log_format_buffer_size("x %d", x);
	__builtin_os_log_format(&x, "x %d", x);
}
#else
typedef int v4 __attribute__((vector_size(16)));

/* __builtin_va_arg_pack stands for the variable arguments of a function
   that is always inlined. */
static inline __attribute__((always_inline)) int pass(const char *f, ...)
{
	return g(f, __builtin_va_arg_pack());
}

void gcc(long l, double d, v4 v)
{
	__builtin_mul_overflow_p(l, l, (long)0);
	__builtin_shuffle(v, v);
	__builtin_apply((void (*)())gcc, __builtin_apply_args(), 16);
	__builtin_tgmath(sinf, sin, sinl, d);
	__builtin_huge_valf32(); __builtin_inff32();
	__builtin_nanf32(""); __builtin_nansf32("");
	__builtin_huge_valf64(); __builtin_inff64();
	__builtin_nanf64(""); __builtin_nansf64("");
	__builtin_huge_valf32x(); __builtin_inff32x();
	__builtin_nanf32x(""); __builtin_nansf32x("");
	__builtin_huge_valf64x(); __builtin_inff64x();
	__builtin_nanf64x(""); __builtin_nansf64x("");
}
#endif
