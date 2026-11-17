/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The member_large twin that reads the member through a pointer to a
 * typedef declared aligned(1); see member_small_aligned.c.
 */

#include "nested.h"

typedef large __attribute__((aligned(1))) large_unaligned;

long
member_large(const struct node *n)
{
	const large_unaligned *m;

	m = &n->large;
	switch (m->tag) {
	case large_Empty:
		return (arm(1, n->id, 0));
	case large_Wide:
		return (arm(2, m->u.Wide.a + m->u.Wide.b + m->u.Wide.c,
		    m->u.Wide.d + m->u.Wide.e + m->u.Wide.f));
	default:
		__builtin_trap();
	}
}
