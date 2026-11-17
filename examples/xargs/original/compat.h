/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * strtonum(3) of the BSD C library, which xargs.c and its port xargs.tc
 * use and glibc lacks, so that the unchanged xargs.c and the port build
 * on Linux too.  The Makefile puts it before each file with -include; on
 * FreeBSD and macOS it adds nothing.  Its messages are those of the BSD
 * strtonum, which xargs prints.
 */

#ifdef __linux__
#include <errno.h>
#include <limits.h>
#include <stdlib.h>

static inline long long
strtonum(const char *numstr, long long minval, long long maxval,
    const char **errstrp)
{
	long long ll;
	char *end;

	*errstrp = NULL;
	if (minval > maxval) {
		*errstrp = "invalid";
		errno = EINVAL;
		return (0);
	}
	errno = 0;
	ll = strtoll(numstr, &end, 10);
	if (numstr == end || *end != '\0') {
		*errstrp = "invalid";
		errno = EINVAL;
		return (0);
	}
	if ((ll == LLONG_MIN && errno == ERANGE) || ll < minval) {
		*errstrp = "too small";
		errno = ERANGE;
		return (0);
	}
	if ((ll == LLONG_MAX && errno == ERANGE) || ll > maxval) {
		*errstrp = "too large";
		errno = ERANGE;
		return (0);
	}
	return (ll);
}
#endif
