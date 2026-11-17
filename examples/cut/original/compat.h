/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The two names of the BSD C library that cut.c uses and glibc lacks,
 * so that the unchanged cut.c builds on Linux too. The Makefile puts it
 * before cut.c with -include; on FreeBSD and macOS it adds nothing.
 */

#ifdef __linux__
#include <err.h>
#include <errno.h>

#define __unused	__attribute__((__unused__))
#define warnc(code, ...)	(errno = (code), warn(__VA_ARGS__))
#endif
