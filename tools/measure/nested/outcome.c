/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of outcome.tc: a switch on the tag of the fault nested in
 * the switch on the tag of the result, with a trap for a tag that is no
 * constructor, as typec checks.
 */

#include "nested.h"

long
outcome(const result *r)
{

	switch (r->tag) {
	case result_Ok:
		return (arm(1, r->u.Ok.value, 0));
	case result_Err:
		switch (r->u.Err.fault.tag) {
		case fault_NoMem:
			return (arm(2, 0, 0));
		case fault_Inval:
			return (arm(3, 0, 0));
		case fault_Io:
			return (arm(4, r->u.Err.fault.u.Io.error, 0));
		default:
			__builtin_trap();
		}
	default:
		__builtin_trap();
	}
}
