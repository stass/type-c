/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of member_small.tc: a switch on the tag of the member in
 * place, with a trap for a tag that is no constructor, as typec checks.
 */

#include "nested.h"

long
member_small(const struct node *n)
{

	switch (n->small.tag) {
	case small_Idle:
		return (arm(1, n->id, 0));
	case small_Busy:
		return (arm(2, n->small.u.Busy.load, n->id));
	case small_Gone:
		return (arm(3, n->id, 0));
	default:
		__builtin_trap();
	}
}
