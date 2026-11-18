/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * An empty <sys/cdefs.h> for a C library that has none, as musl:
 * strnsubst.c includes it and needs nothing from it.  The Makefile puts
 * this directory after the system's with -idirafter, so a system header
 * of this name is found first.
 */
