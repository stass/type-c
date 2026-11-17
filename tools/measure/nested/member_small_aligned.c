/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The member_small twin that reads the member through a pointer to a
 * typedef declared aligned(1), which is what lowering would write for
 * every scrutinee that is an lvalue: nothing is copied, and the backend
 * assumes no alignment of the member.
 */

#include "nested.h"

typedef small __attribute__((aligned(1))) small_unaligned;

long
member_small(const struct node *n)
{
	const small_unaligned *m;

	m = &n->small;
	switch (m->tag) {
	case small_Idle:
		return (arm(1, n->id, 0));
	case small_Busy:
		return (arm(2, m->u.Busy.load, n->id));
	case small_Gone:
		return (arm(3, n->id, 0));
	default:
		__builtin_trap();
	}
}
