/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * FreeBSD's <sys/limits.h>, which xargs.c includes for INT_MAX and
 * INT_MIN, is a part of <limits.h> on other systems.  The Makefile puts
 * this directory after the system's with -idirafter, so FreeBSD's own
 * header is found first.
 */

#include <limits.h>
