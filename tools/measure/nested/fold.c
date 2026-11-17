/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of fold.tc: the same decisions as nested switch statements,
 * each arm written where its leaf is, and a trap for a tag that is no
 * constructor, as typec checks.
 */

#include "nested.h"

long
fold(const expr *e)
{
	const expr *l, *r;

	switch (e->tag) {
	case expr_Num:
		return (arm(7, e->u.Num.value, 0));
	case expr_Add:
		l = e->u.Add.l;
		r = e->u.Add.r;
		switch (l->tag) {
		case expr_Num:
			switch (r->tag) {
			case expr_Num:
				return (arm(1, l->u.Num.value,
				    r->u.Num.value));
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				return (arm(3, l->u.Num.value, 0));
			default:
				__builtin_trap();
			}
		case expr_Add:
		case expr_Mul:
		case expr_Neg:
			switch (r->tag) {
			case expr_Num:
				return (arm(4, 0, r->u.Num.value));
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				return (arm(8, 0, 0));
			default:
				__builtin_trap();
			}
		default:
			__builtin_trap();
		}
	case expr_Mul:
		l = e->u.Mul.l;
		r = e->u.Mul.r;
		switch (l->tag) {
		case expr_Num:
			switch (r->tag) {
			case expr_Num:
				return (arm(2, l->u.Num.value,
				    r->u.Num.value));
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				return (arm(8, 0, 0));
			default:
				__builtin_trap();
			}
		case expr_Add:
		case expr_Mul:
		case expr_Neg:
			switch (r->tag) {
			case expr_Num:
				return (arm(5, 0, r->u.Num.value));
			case expr_Add:
			case expr_Mul:
			case expr_Neg:
				return (arm(8, 0, 0));
			default:
				__builtin_trap();
			}
		default:
			__builtin_trap();
		}
	case expr_Neg:
		switch (e->u.Neg.e->tag) {
		case expr_Neg:
			return (arm(6, 0, 0));
		case expr_Num:
		case expr_Add:
		case expr_Mul:
			return (arm(8, 0, 0));
		default:
			__builtin_trap();
		}
	default:
		__builtin_trap();
	}
}
