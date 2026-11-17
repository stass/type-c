/* SPDX-License-Identifier: BSD-2-Clause */
/* Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/*
 * An empty <sys/cdefs.h> for a C library that has none, as musl: queue.h
 * includes it, and the macros that sched.c uses need nothing from it.
 * The Makefile puts it after the system directories with -idirafter.
 */
