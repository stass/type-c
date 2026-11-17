/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/* The C twin of bench_map.tc. */

#include "bench.h"

static void
add_value(const int *key, int *value, void *total)
{

	(void)key;
	*(unsigned long long *)total += (unsigned)*value;
}

/* A random key below 2 n, which BENCH_MAX_N keeps within an int. */
static int
random_key(uint32_t *seed, size_t n)
{

	return ((int)(next_random(seed) % (2 * n)));
}

static enum container_error
run_map_phases(struct map_int_int *m, struct vector_int *keys, size_t n)
{
	enum container_error error;
	unsigned long long sum;
	long long start;
	uint32_t seed;
	size_t i, hits;
	int value;

	seed = BENCH_SEED;
	for (i = 0; i < n; i++) {
		error = vector_int_push(keys, random_key(&seed, n));
		if (error != CONTAINER_OK)
			return (error);
	}

	start = now_ns();
	for (i = 0; i < n; i++) {
		error = map_int_int_put(m, keys->data[i], (int)i);
		if (error != CONTAINER_OK)
			return (error);
	}
	phase_done(PHASE_MAP_PUT, start, m->count);

	start = now_ns();
	sum = 0;
	hits = 0;
	for (i = 0; i < n; i++) {
		if (map_int_int_get(m, random_key(&seed, n), &value)) {
			sum += (unsigned)value;
			hits++;
		}
	}
	phase_done(PHASE_MAP_GET, start, sum + hits);

	start = now_ns();
	sum = 0;
	map_int_int_each(m, add_value, &sum);
	phase_done(PHASE_MAP_EACH, start, sum);
	return (CONTAINER_OK);
}

enum container_error
run_map(size_t n)
{
	struct map_int_int m;
	struct vector_int keys;
	enum container_error error;

	map_int_int_init(&m, hash_int, equal_int);
	vector_int_init(&keys);
	error = run_map_phases(&m, &keys, n);
	vector_int_free(&keys);
	map_int_int_free(&m);
	return (error);
}
