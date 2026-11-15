/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* The hand-written twin of nodes.tc: a tag and a union built as a
   compound literal and passed by value, and a switch with the guarantees
   of the Type-C match (a trap on an invalid tag and the payload copied
   into locals when the case is entered), so that the gate measures the
   lowering and not the guarantees. */

#include <stdio.h>
#include <stdlib.h>

struct node;

enum kind { CONSTANT, ADD, SELECT, CALL };
struct op {
  enum kind kind;
  union {
    struct { unsigned long value; } constant;
    struct { const struct node *left, *right; } add;
    struct { const struct node *test, *then, *otherwise; } select;
    struct {
      unsigned long callee;
      const struct node *a, *b, *c, *d, *e, *f;
    } call;
  } u;
};

struct node {
  struct op op;
  unsigned long value;
};

struct arena {
  struct node *nodes;
  unsigned long used;
};

static unsigned long next_random(unsigned long *state) {
  *state = *state * 6364136223846793005UL + 1442695040888963407UL;
  return *state >> 33;
}

static void add_node(struct arena *arena, struct op op) {
  arena->nodes[arena->used++].op = op;
}

static const struct node *pick(struct arena *arena, unsigned long *seed) {
  return &arena->nodes[next_random(seed) % arena->used];
}

static void build_node(struct arena *arena, unsigned long *seed) {
  unsigned long v = next_random(seed) % 1000;
  const struct node *a = pick(arena, seed), *b = pick(arena, seed);
  const struct node *c = pick(arena, seed), *d = pick(arena, seed);
  const struct node *e = pick(arena, seed), *f = pick(arena, seed);
  switch (next_random(seed) % 4) {
  case 0:
    add_node(arena, (struct op){ CONSTANT, { .constant = { v } } });
    break;
  case 1:
    add_node(arena, (struct op){ ADD, { .add = { a, b } } });
    break;
  case 2:
    add_node(arena, (struct op){ SELECT, { .select = { a, b, c } } });
    break;
  default:
    add_node(arena,
             (struct op){ CALL, { .call = { v, a, b, c, d, e, f } } });
    break;
  }
}

static unsigned long evaluate(struct node *nodes, unsigned long count) {
  unsigned long total = 0;
  for (unsigned long i = 0; i < count; i++) {
    const struct op *op = &nodes[i].op;
    unsigned long value;
    switch (op->kind) {
    case CONSTANT: {
      unsigned long v = op->u.constant.value;
      value = v;
      break;
    }
    case ADD: {
      const struct node *l = op->u.add.left, *r = op->u.add.right;
      value = l->value + r->value;
      break;
    }
    case SELECT: {
      const struct node *t = op->u.select.test, *y = op->u.select.then;
      const struct node *n = op->u.select.otherwise;
      value = t->value & 1 ? y->value : n->value;
      break;
    }
    case CALL: {
      unsigned long callee = op->u.call.callee;
      const struct node *a = op->u.call.a, *b = op->u.call.b;
      const struct node *c = op->u.call.c, *d = op->u.call.d;
      const struct node *e = op->u.call.e, *f = op->u.call.f;
      value = callee + a->value - b->value + c->value - d->value +
              e->value - f->value;
      break;
    }
    default:
      __builtin_trap();
    }
    nodes[i].value = value;
    total += value;
  }
  return total;
}

int main(int argc, char **argv) {
  if (argc != 4)
    return 2;
  unsigned long count = strtoul(argv[1], NULL, 0);
  unsigned long rounds = strtoul(argv[2], NULL, 0);
  unsigned long seed = strtoul(argv[3], NULL, 0);
  if (count == 0)
    return 2;
  struct arena arena = { malloc(count * sizeof *arena.nodes), 0 };
  if (arena.nodes == NULL)
    return 1;
  unsigned long total = 0;
  for (unsigned long round = 0; round < rounds; round++) {
    arena.used = 0;
    add_node(&arena, (struct op){ CONSTANT, { .constant = { round } } });
    while (arena.used < count)
      build_node(&arena, &seed);
    total += evaluate(arena.nodes, count);
  }
  printf("%lu\n", total);
  free(arena.nodes);
  return 0;
}
