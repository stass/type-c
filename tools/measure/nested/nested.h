/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>
 */

/*
 * The types and matchers that the driver and the C twins share: the
 * declarations of nested.tci as typec lowers them, so that the driver
 * builds one set of values that a Type-C matcher and its twin both read.
 * A layout that differs shows as checksums that do.
 */

#ifndef NESTED_H
#define	NESTED_H

struct expr;
typedef struct expr expr;
enum expr_tag { expr_Num, expr_Add, expr_Mul, expr_Neg };
struct expr {
	enum expr_tag	tag;
	union {
		struct { int value; } Num;
		struct { const expr *l; const expr *r; } Add;
		struct { const expr *l; const expr *r; } Mul;
		struct { const expr *e; } Neg;
	} u;
};

struct list;
typedef struct list list;
enum list_tag { list_Nil, list_Cons };
struct list {
	enum list_tag	tag;
	union {
		struct { int head; const list *tail; } Cons;
	} u;
};

struct fault;
typedef struct fault fault;
enum fault_tag { fault_NoMem, fault_Inval, fault_Io };
struct fault {
	enum fault_tag	tag;
	union {
		struct { int error; } Io;
	} u;
};

struct result;
typedef struct result result;
enum result_tag { result_Ok, result_Err };
struct result {
	enum result_tag	tag;
	union {
		struct { int value; } Ok;
		struct { fault fault; } Err;
	} u;
};

struct small;
typedef struct small small;
enum small_tag { small_Idle, small_Busy, small_Gone };
struct small {
	enum small_tag	tag;
	union {
		struct { int load; } Busy;
	} u;
};

struct large;
typedef struct large large;
enum large_tag { large_Empty, large_Wide };
struct large {
	enum large_tag	tag;
	union {
		struct { long a; long b; long c; long d; long e; long f; } Wide;
	} u;
};

struct node {
	int	id;
	small	small;
	large	large;
};

/* Defined by the driver, so that no backend inlines an arm into a matcher. */
long	arm(int id, long a, long b);

/* The matchers: a Type-C unit and a C twin of each name. */
long	fold(const expr *e);
long	fold_test(const expr *e);
long	sum_list(const list *l);
long	outcome(const result *r);
long	member_small(const struct node *n);
long	member_large(const struct node *n);

#endif /* !NESTED_H */
