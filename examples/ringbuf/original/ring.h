/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * A queue of bytes in storage that the caller supplies. It wraps around
 * by comparison rather than by a modulo, which a small processor may
 * lack, so its size need not be a power of two.
 */

#ifndef RING_H
#define RING_H

#include <stddef.h>

struct ring {
	unsigned char	*buf;
	size_t		size;		/* bytes in buf */
	size_t		head;		/* the index of the oldest byte */
	size_t		count;		/* the bytes queued */
};

static inline void
ring_init(struct ring *r, unsigned char *buf, size_t size)
{
	r->buf = buf;
	r->size = size;
	r->head = 0;
	r->count = 0;
}

/* Queues byte; returns 0, and drops it, when the ring is full. */
static inline int
ring_put(struct ring *r, unsigned char byte)
{
	size_t tail;

	if (r->count == r->size)
		return (0);
	tail = r->head + r->count;
	if (tail >= r->size)
		tail -= r->size;
	r->buf[tail] = byte;
	r->count++;
	return (1);
}

/* Takes the oldest byte; returns -1 when the ring is empty. */
static inline int
ring_get(struct ring *r)
{
	unsigned char byte;

	if (r->count == 0)
		return (-1);
	byte = r->buf[r->head];
	if (++r->head == r->size)
		r->head = 0;
	r->count--;
	return (byte);
}

#endif /* !RING_H */
