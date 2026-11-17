/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The C twin of bench.tc: the same phases over the same random numbers,
 * which print the same checksums.  C has no checked index, so both sums
 * index the data pointer.
 */

#include <stdio.h>

#include "bench.h"

struct point {
	int	x;
	int	y;
};

static unsigned long long
sum_items(const int *items, size_t count)
{
	unsigned long long sum;
	size_t i;

	sum = 0;
	for (i = 0; i < count; i++)
		sum += (unsigned)items[i];
	return (sum);
}

static unsigned long long
sum_vector(const struct vector_int *v)
{
	unsigned long long sum;
	size_t i;

	sum = 0;
	for (i = 0; i < v->length; i++)
		sum += (unsigned)v->data[i];
	return (sum);
}

static enum container_error
run_vector_phases(struct vector_int *v, size_t n)
{
	enum container_error error;
	unsigned long long sum;
	long long start;
	uint32_t seed;
	size_t i;
	int x;

	seed = BENCH_SEED;
	start = now_ns();
	for (i = 0; i < n; i++) {
		error = vector_int_push(v, (int)(next_random(&seed) >> 1));
		if (error != CONTAINER_OK)
			return (error);
	}
	phase_done(PHASE_VECTOR_PUSH, start, v->length);

	start = now_ns();
	sum = 0;
	for (i = 0; i < n; i++)
		if (vector_int_get(v, next_random(&seed) % n, &x))
			sum += (unsigned)x;
	phase_done(PHASE_VECTOR_GET, start, sum);

	start = now_ns();
	sum = sum_items(v->data, v->length);
	phase_done(PHASE_SUM_CHECKED, start, sum);

	start = now_ns();
	sum = sum_vector(v);
	phase_done(PHASE_SUM_UNCHECKED, start, sum);

	start = now_ns();
	error = vector_int_append(v, v->data, v->length);
	if (error != CONTAINER_OK)
		return (error);
	phase_done(PHASE_VECTOR_APPEND, start, v->length);

	start = now_ns();
	sum = 0;
	while (v->length > 0)
		if (vector_int_pop(v, &x))
			sum += (unsigned)x;
	phase_done(PHASE_VECTOR_POP, start, sum);
	return (CONTAINER_OK);
}

static enum container_error
run_vector(size_t n)
{
	struct vector_int v;
	enum container_error error;

	vector_int_init(&v);
	error = run_vector_phases(&v, n);
	vector_int_free(&v);
	return (error);
}

static enum container_error
run_region(size_t n)
{
	struct region r;
	struct point *p;
	unsigned long long sum;
	long long start;
	size_t i;

	region_init(&r, 4096);
	start = now_ns();
	sum = 0;
	for (i = 0; i < n; i++) {
		p = REGION_NEW(&r, struct point);
		if (p == NULL) {
			region_release(&r);
			return (CONTAINER_OUT_OF_MEMORY);
		}
		p->x = (int)(i % 1000);
		p->y = (int)(i % 7);
		sum += (unsigned)(p->x + p->y);
	}
	phase_done(PHASE_REGION_NEW, start, sum);
	region_release(&r);
	return (CONTAINER_OK);
}

static int
failed(enum container_error error)
{

	switch (error) {
	case CONTAINER_OK:
		return (0);
	case CONTAINER_OUT_OF_MEMORY:
		fprintf(stderr, "bench: out of memory\n");
		break;
	case CONTAINER_TOO_LARGE:
		fprintf(stderr, "bench: too large\n");
		break;
	}
	return (1);
}

int
main(int argc, char **argv)
{
	size_t n, rounds, round;

	if (!bench_arguments(argc, argv, &n, &rounds))
		return (2);
	for (round = 0; round < rounds; round++)
		if (failed(run_vector(n)) || failed(run_region(n)) ||
		    failed(run_map(n)))
			return (1);
	print_phases();
	return (0);
}
