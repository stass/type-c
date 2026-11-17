/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of member_large.tc: a switch on the tag of the member in
 * place, with a trap for a tag that is no constructor, as typec checks.
 */

#include "nested.h"

long
member_large(const struct node *n)
{

	switch (n->large.tag) {
	case large_Empty:
		return (arm(1, n->id, 0));
	case large_Wide:
		return (arm(2,
		    n->large.u.Wide.a + n->large.u.Wide.b + n->large.u.Wide.c,
		    n->large.u.Wide.d + n->large.u.Wide.e + n->large.u.Wide.f));
	default:
		__builtin_trap();
	}
}
