/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of fold_test.tc: each test as nested switch statements,
 * with the arm where its leaf is, and a trap for a tag that is no
 * constructor, as typec checks.
 */

#include "nested.h"

long
fold_test(const expr *e)
{
	const expr *l, *r, *a;

	switch (e->tag) {
	case expr_Add:
		l = e->u.Add.l;
		switch (l->tag) {
		case expr_Num:
			r = e->u.Add.r;
			switch (r->tag) {
			case expr_Num:
				return (arm(1, l->u.Num.value,
				    r->u.Num.value));
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				break;
			default:
				__builtin_trap();
			}
			break;
		case expr_Add:
		case expr_Mul:
		case expr_Neg:
			break;
		default:
			__builtin_trap();
		}
		break;
	case expr_Num:
	case expr_Mul:
	case expr_Neg:
		break;
	default:
		__builtin_trap();
	}
	switch (e->tag) {
	case expr_Mul:
		l = e->u.Mul.l;
		switch (l->tag) {
		case expr_Add:
			a = l->u.Add.l;
			switch (a->tag) {
			case expr_Num:
				switch (e->u.Mul.r->tag) {
				case expr_Num:
					return (arm(2, a->u.Num.value,
					    e->u.Mul.r->u.Num.value));
				case expr_Add:
				case expr_Mul:
				case expr_Neg:
					break;
				default:
					__builtin_trap();
				}
				break;
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				break;
			default:
				__builtin_trap();
			}
			break;
		case expr_Num:
		case expr_Mul:
		case expr_Neg:
			break;
		default:
			__builtin_trap();
		}
		break;
	case expr_Num:
	case expr_Add:
	case expr_Neg:
		break;
	default:
		__builtin_trap();
	}
	switch (e->tag) {
	case expr_Neg:
		l = e->u.Neg.e;
		switch (l->tag) {
		case expr_Neg:
			a = l->u.Neg.e;
			switch (a->tag) {
			case expr_Num:
				return (arm(3, a->u.Num.value, 0));
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				break;
			default:
				__builtin_trap();
			}
			break;
		case expr_Num:
		case expr_Add:
		case expr_Mul:
			break;
		default:
			__builtin_trap();
		}
		break;
	case expr_Num:
	case expr_Add:
	case expr_Mul:
		break;
	default:
		__builtin_trap();
	}
	return (arm(4, 0, 0));
}
