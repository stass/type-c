/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The hand-written C twin of the container library of
 * test/run/containers.t: a region allocator, a growable vector and a hash
 * map that takes its hash and equality as function pointers, with the
 * same algorithms.  A vector or map of one element type is declared with
 * VECTOR_DECLARE or MAP_DECLARE and its functions defined with
 * VECTOR_DEFINE or MAP_DEFINE, as a C programmer writes containers
 * without generics; the first argument, empty or static inline, is the
 * storage of the functions.
 */

#ifndef CONTAINERS_H
#define	CONTAINERS_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* What a function that can fail returns: 0, or why it failed. */
enum container_error {
	CONTAINER_OK = 0,
	CONTAINER_OUT_OF_MEMORY,
	CONTAINER_TOO_LARGE
};

/* Regions. */

struct region_chunk;

struct region {
	struct region_chunk	*chunks;
	size_t			 chunk_size;
};

void	 region_init(struct region *r, size_t chunk_size);
void	*region_alloc(struct region *r, size_t size, size_t align);
void	 region_release(struct region *r);

#define	REGION_NEW(r, T)	((T *)region_alloc((r), sizeof(T), _Alignof(T)))

/* Vectors.  The capacity doubles, from VECTOR_FIRST_CAPACITY. */

#define	VECTOR_FIRST_CAPACITY	8

#define	VECTOR_DECLARE(scope, name, T)					\
struct name {								\
	T	*data;							\
	size_t	 length;						\
	size_t	 capacity;						\
};									\
scope void name##_init(struct name *v);				\
scope void name##_free(struct name *v);				\
scope enum container_error name##_reserve(struct name *v,		\
	    size_t capacity);						\
scope enum container_error name##_push(struct name *v, T value);	\
scope enum container_error name##_append(struct name *v,		\
	    const T *items, size_t count);				\
scope int name##_pop(struct name *v, T *value);			\
scope int name##_get(const struct name *v, size_t i, T *value);

#define	VECTOR_DEFINE(scope, name, T)					\
scope void								\
name##_init(struct name *v)						\
{									\
									\
	v->data = NULL;							\
	v->length = 0;							\
	v->capacity = 0;						\
}									\
									\
scope void								\
name##_free(struct name *v)						\
{									\
									\
	free(v->data);							\
	name##_init(v);							\
}									\
									\
scope enum container_error						\
name##_reserve(struct name *v, size_t capacity)				\
{									\
	T *data;							\
									\
	if (capacity <= v->capacity)					\
		return (CONTAINER_OK);					\
	if (capacity > SIZE_MAX / sizeof(T))				\
		return (CONTAINER_TOO_LARGE);				\
	data = realloc(v->data, capacity * sizeof(T));			\
	if (data == NULL)						\
		return (CONTAINER_OUT_OF_MEMORY);			\
	v->data = data;							\
	v->capacity = capacity;						\
	return (CONTAINER_OK);						\
}									\
									\
scope enum container_error						\
name##_push(struct name *v, T value)					\
{									\
	enum container_error error;					\
	size_t capacity;						\
									\
	if (v->length == v->capacity) {					\
		capacity = VECTOR_FIRST_CAPACITY;			\
		if (v->capacity != 0) {					\
			if (v->capacity > SIZE_MAX / 2)			\
				return (CONTAINER_TOO_LARGE);		\
			capacity = 2 * v->capacity;			\
		}							\
		error = name##_reserve(v, capacity);			\
		if (error != CONTAINER_OK)				\
			return (error);					\
	}								\
	v->data[v->length++] = value;					\
	return (CONTAINER_OK);						\
}									\
									\
/* Growing frees the old buffer after the copy, so items may lie in v. */\
scope enum container_error						\
name##_append(struct name *v, const T *items, size_t count)		\
{									\
	T *data;							\
	size_t capacity, i;						\
									\
	if (count > SIZE_MAX / sizeof(T) - v->length)			\
		return (CONTAINER_TOO_LARGE);				\
	data = v->data;							\
	capacity = v->capacity;						\
	if (v->length + count > capacity) {				\
		capacity = v->length + count;				\
		data = malloc(capacity * sizeof(T));			\
		if (data == NULL)					\
			return (CONTAINER_OUT_OF_MEMORY);		\
		for (i = 0; i < v->length; i++)				\
			data[i] = v->data[i];				\
	}								\
	for (i = 0; i < count; i++)					\
		data[v->length + i] = items[i];				\
	if (data != v->data) {						\
		free(v->data);						\
		v->data = data;						\
		v->capacity = capacity;					\
	}								\
	v->length += count;						\
	return (CONTAINER_OK);						\
}									\
									\
scope int								\
name##_pop(struct name *v, T *value)					\
{									\
									\
	if (v->length == 0)						\
		return (0);						\
	*value = v->data[--v->length];					\
	return (1);							\
}									\
									\
scope int								\
name##_get(const struct name *v, size_t i, T *value)			\
{									\
									\
	if (i >= v->length)						\
		return (0);						\
	*value = v->data[i];						\
	return (1);							\
}

/*
 * Maps.  The table grows before it is more than three quarters full, so a
 * probe always meets an empty entry; its capacity is a power of two.
 */

#define	MAP_LOAD_NUMERATOR	3
#define	MAP_LOAD_DENOMINATOR	4
#define	MAP_FIRST_CAPACITY	16

#define	MAP_DECLARE(scope, name, K, V)					\
struct name##_entry {							\
	K	key;							\
	V	value;							\
	int	used;							\
};									\
struct name {								\
	struct name##_entry	*entries;				\
	size_t			 count;					\
	size_t			 capacity;				\
	size_t			(*hash)(const K *);			\
	int			(*equal)(const K *, const K *);		\
};									\
scope void name##_init(struct name *m, size_t (*hash)(const K *),	\
	    int (*equal)(const K *, const K *));			\
scope void name##_free(struct name *m);				\
scope enum container_error name##_put(struct name *m, K key, V value);	\
scope int name##_get(const struct name *m, K key, V *value);		\
scope void name##_each(struct name *m,				\
	    void (*visit)(const K *, V *, void *), void *context);

#define	MAP_DEFINE(scope, name, K, V)					\
scope void								\
name##_init(struct name *m, size_t (*hash)(const K *),			\
    int (*equal)(const K *, const K *))					\
{									\
									\
	m->entries = NULL;						\
	m->count = 0;							\
	m->capacity = 0;						\
	m->hash = hash;							\
	m->equal = equal;						\
}									\
									\
scope void								\
name##_free(struct name *m)						\
{									\
									\
	free(m->entries);						\
	name##_init(m, m->hash, m->equal);				\
}									\
									\
/* The entry that holds key, or the empty one where it belongs. */	\
static inline struct name##_entry *				\
name##_find(const struct name *m, const K *key)				\
{									\
	struct name##_entry *e;						\
	size_t i, mask;							\
									\
	mask = m->capacity - 1;						\
	for (i = m->hash(key) & mask;; i = (i + 1) & mask) {		\
		e = &m->entries[i];					\
		if (!e->used || m->equal(&e->key, key))			\
			return (e);					\
	}								\
}									\
									\
static inline enum container_error				\
name##_grow(struct name *m)						\
{									\
	struct name bigger;						\
	size_t capacity, i;						\
									\
	capacity = MAP_FIRST_CAPACITY;					\
	if (m->capacity != 0) {						\
		if (m->capacity >					\
		    SIZE_MAX / 2 / sizeof(struct name##_entry))		\
			return (CONTAINER_TOO_LARGE);			\
		capacity = 2 * m->capacity;				\
	}								\
	bigger = *m;							\
	bigger.capacity = capacity;					\
	bigger.entries = calloc(capacity, sizeof(struct name##_entry));	\
	if (bigger.entries == NULL)					\
		return (CONTAINER_OUT_OF_MEMORY);			\
	for (i = 0; i < m->capacity; i++)				\
		if (m->entries[i].used)					\
			*name##_find(&bigger, &m->entries[i].key) =	\
			    m->entries[i];				\
	free(m->entries);						\
	*m = bigger;							\
	return (CONTAINER_OK);						\
}									\
									\
scope enum container_error						\
name##_put(struct name *m, K key, V value)				\
{									\
	struct name##_entry *e;						\
	enum container_error error;					\
									\
	if (m->capacity != 0) {						\
		e = name##_find(m, &key);				\
		if (e->used) {						\
			e->value = value;				\
			return (CONTAINER_OK);				\
		}							\
	}								\
	if ((m->count + 1) * MAP_LOAD_DENOMINATOR >			\
	    m->capacity * MAP_LOAD_NUMERATOR) {				\
		error = name##_grow(m);					\
		if (error != CONTAINER_OK)				\
			return (error);					\
	}								\
	e = name##_find(m, &key);					\
	e->key = key;							\
	e->value = value;						\
	e->used = 1;							\
	m->count++;							\
	return (CONTAINER_OK);						\
}									\
									\
scope int								\
name##_get(const struct name *m, K key, V *value)			\
{									\
	struct name##_entry *e;						\
									\
	if (m->count == 0)						\
		return (0);						\
	e = name##_find(m, &key);					\
	if (!e->used)							\
		return (0);						\
	*value = e->value;						\
	return (1);							\
}									\
									\
scope void								\
name##_each(struct name *m, void (*visit)(const K *, V *, void *),	\
    void *context)							\
{									\
	size_t i;							\
									\
	for (i = 0; i < m->capacity; i++)				\
		if (m->entries[i].used)					\
			visit(&m->entries[i].key, &m->entries[i].value,	\
			    context);					\
}

/* Hashes and equalities of common keys. */
size_t	hash_int(const int *key);
int	equal_int(const int *a, const int *b);

/*
 * The instances that the benchmark uses: external functions defined once,
 * in containers.c, or with CONTAINERS_INLINE static inline ones defined
 * in each unit that includes this, as a library of headers defines them.
 * Type-C's instances are static in each unit too, but without inline,
 * which a unit that left one unused would be warned of here; GCC weighs
 * inlining a function declared inline more generously.
 */
#ifdef CONTAINERS_INLINE
#define	CONTAINERS_SCOPE	static inline
#else
#define	CONTAINERS_SCOPE
#endif

VECTOR_DECLARE(CONTAINERS_SCOPE, vector_int, int)
MAP_DECLARE(CONTAINERS_SCOPE, map_int_int, int, int)

#ifdef CONTAINERS_INLINE
VECTOR_DEFINE(CONTAINERS_SCOPE, vector_int, int)
MAP_DEFINE(CONTAINERS_SCOPE, map_int_int, int, int)
#endif

#endif /* !CONTAINERS_H */
