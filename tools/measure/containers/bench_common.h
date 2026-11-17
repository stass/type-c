/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * What the Type-C benchmark and its C twins share, in plain C linked into
 * each: the phases, the random numbers, the clock and the report, so that
 * every program does the same work and prints it alike.
 */

#ifndef BENCH_COMMON_H
#define	BENCH_COMMON_H

#include <stddef.h>
#include <stdint.h>

/* The phases in the order each round runs them and the report lists. */
enum phase {
	PHASE_VECTOR_PUSH,
	PHASE_VECTOR_GET,
	PHASE_SUM_CHECKED,
	PHASE_SUM_UNCHECKED,
	PHASE_VECTOR_APPEND,
	PHASE_VECTOR_POP,
	PHASE_REGION_NEW,
	PHASE_MAP_PUT,
	PHASE_MAP_GET,
	PHASE_MAP_EACH,
	PHASE_COUNT
};

/* The state of the random numbers at the start of each round. */
#define	BENCH_SEED	2463534242u

/* The most elements, so that a key below 2 N fits in an int. */
#define	BENCH_MAX_N	(1 << 28)

uint32_t	next_random(uint32_t *state);
long long	now_ns(void);
void		phase_done(enum phase phase, long long start,
		    unsigned long long checksum);
void		print_phases(void);
int		bench_arguments(int argc, char **argv, size_t *n,
		    size_t *rounds);

#endif /* !BENCH_COMMON_H */
