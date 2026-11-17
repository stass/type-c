/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of sum_list.tc: the same decisions as nested switch
 * statements, each arm written where its leaf is, and a trap for a tag
 * that is no constructor, as typec checks.
 */

#include "nested.h"

long
sum_list(const list *l)
{
	const list *l1, *l2, *l3, *l4;

	switch (l->tag) {
	case list_Nil:
		return (arm(5, 0, 0));
	case list_Cons:
		l1 = l->u.Cons.tail;
		switch (l1->tag) {
		case list_Nil:
			return (arm(4, l->u.Cons.head, 0));
		case list_Cons:
			l2 = l1->u.Cons.tail;
			switch (l2->tag) {
			case list_Nil:
				return (arm(3, l->u.Cons.head,
				    l1->u.Cons.head));
			case list_Cons:
				l3 = l2->u.Cons.tail;
				switch (l3->tag) {
				case list_Nil:
					return (arm(2, l->u.Cons.head +
					    l1->u.Cons.head,
					    l2->u.Cons.head));
				case list_Cons:
					l4 = l3->u.Cons.tail;
					switch (l4->tag) {
					case list_Nil:
						return (arm(1, l->u.Cons.head +
						    l1->u.Cons.head,
						    l2->u.Cons.head +
						    l3->u.Cons.head));
					case list_Cons:
						return (arm(6, 0, 0));
					default:
						__builtin_trap();
					}
				default:
					__builtin_trap();
				}
			default:
				__builtin_trap();
			}
		default:
			__builtin_trap();
		}
	default:
		__builtin_trap();
	}
}
