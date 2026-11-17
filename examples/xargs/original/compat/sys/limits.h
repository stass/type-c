/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * FreeBSD's <sys/limits.h>, which xargs.c includes for INT_MAX and
 * INT_MIN, is a part of <limits.h> on other systems.  The Makefile puts
 * this directory on the include path of xargs.c except on FreeBSD.
 */

#include <limits.h>
