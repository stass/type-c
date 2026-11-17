/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The region allocator, the hashes of common keys and the instances of
 * the C twin of the container library; region.tc is the Type-C side.
 */

#include <string.h>

#include "containers.h"

/*
 * A chunk is one malloc'd block; the region hands out its bytes in order
 * and frees the chunks together.  The data member aligns the bytes for
 * any object.
 */
struct region_chunk {
	struct region_chunk	*next;
	size_t			 used;
	size_t			 size;
	max_align_t		 data[];
};

void
region_init(struct region *r, size_t chunk_size)
{

	r->chunks = NULL;
	r->chunk_size = chunk_size;
}

/* The bytes of size from offset up to the next multiple of align. */
static size_t
padding(size_t offset, size_t align)
{

	return ((align - offset % align) % align);
}

static struct region_chunk *
region_add_chunk(struct region *r, size_t size)
{
	struct region_chunk *c;

	if (size < r->chunk_size)
		size = r->chunk_size;
	if (size > SIZE_MAX - sizeof(*c))
		return (NULL);
	c = malloc(sizeof(*c) + size);
	if (c == NULL)
		return (NULL);
	c->next = r->chunks;
	c->used = 0;
	c->size = size;
	r->chunks = c;
	return (c);
}

/* An align that is not a power of two at most max_align_t's gets none. */
void *
region_alloc(struct region *r, size_t size, size_t align)
{
	struct region_chunk *c;
	size_t start;

	if (align == 0 || (align & (align - 1)) != 0 ||
	    align > _Alignof(max_align_t))
		return (NULL);
	c = r->chunks;
	if (c != NULL) {
		start = c->used + padding(c->used, align);
		if (start <= c->size && size <= c->size - start) {
			c->used = start + size;
			return ((char *)c->data + start);
		}
	}
	c = region_add_chunk(r, size);
	if (c == NULL)
		return (NULL);
	c->used = size;
	return (c->data);
}

void
region_release(struct region *r)
{
	struct region_chunk *c, *next;

	for (c = r->chunks; c != NULL; c = next) {
		next = c->next;
		free(c);
	}
	r->chunks = NULL;
}

/* FNV-1a over the bytes of a key. */
#define	FNV_OFFSET_BASIS	2166136261u
#define	FNV_PRIME		16777619u

static size_t
fnv1a(const unsigned char *bytes, size_t n)
{
	uint32_t h;
	size_t i;

	h = FNV_OFFSET_BASIS;
	for (i = 0; i < n; i++) {
		h ^= bytes[i];
		h *= FNV_PRIME;
	}
	return (h);
}

size_t
hash_int(const int *key)
{

	return (fnv1a((const unsigned char *)key, sizeof(*key)));
}

int
equal_int(const int *a, const int *b)
{

	return (*a == *b);
}

#ifndef CONTAINERS_INLINE
VECTOR_DEFINE(CONTAINERS_SCOPE, vector_int, int)
MAP_DEFINE(CONTAINERS_SCOPE, map_int_int, int, int)
#endif
