/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The two names of the BSD C library that cut.c and its port cut.tc use
 * and glibc lacks, so that the unchanged cut.c and the port build on
 * Linux too. The Makefile puts it before each file with -include; on
 * FreeBSD and macOS it adds nothing.
 */

#ifdef __linux__
#include <err.h>
#include <errno.h>

#define __unused	__attribute__((__unused__))
#define warnc(code, ...)	(errno = (code), warn(__VA_ARGS__))
#endif
