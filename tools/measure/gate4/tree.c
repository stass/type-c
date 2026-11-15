/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* The hand-written twin of tree.tc: a tag, a union and a switch, with
   the guarantees of the Type-C match (a trap on an invalid tag and the
   payload copied into locals when the case is entered), so that the
   gate measures the lowering and not the guarantees. */

#include <stdio.h>
#include <stdlib.h>

enum kind { NUMBER, ADD, SUBTRACT, MULTIPLY };
struct expr {
  enum kind kind;
  union {
    unsigned long value;
    struct { const struct expr *left, *right; } pair;
  } u;
};

static unsigned long eval(const struct expr *e) {
  switch (e->kind) {
  case NUMBER: return e->u.value;
  case ADD: {
    const struct expr *l = e->u.pair.left, *r = e->u.pair.right;
    return eval(l) + eval(r);
  }
  case SUBTRACT: {
    const struct expr *l = e->u.pair.left, *r = e->u.pair.right;
    return eval(l) - eval(r);
  }
  case MULTIPLY: {
    const struct expr *l = e->u.pair.left, *r = e->u.pair.right;
    return eval(l) * eval(r);
  }
  default:
    __builtin_trap();
  }
}

static unsigned long next_random(unsigned long *state) {
  *state = *state * 6364136223846793005UL + 1442695040888963407UL;
  return *state >> 33;
}

static struct expr number(unsigned long value) {
  struct expr e = { NUMBER, { .value = value } };
  return e;
}

static struct expr pair(enum kind kind, const struct expr *l,
                        const struct expr *r) {
  struct expr e = { kind, { .pair = { l, r } } };
  return e;
}

static void build(struct expr *nodes, unsigned long leaves,
                  unsigned long seed) {
  unsigned long internal = leaves - 1;
  for (unsigned long i = internal; i < internal + leaves; i++)
    nodes[i] = number(next_random(&seed));
  for (unsigned long i = internal; i-- > 0;) {
    const struct expr *l = &nodes[2 * i + 1], *r = &nodes[2 * i + 2];
    switch (next_random(&seed) % 3) {
    case 0: nodes[i] = pair(ADD, l, r); break;
    case 1: nodes[i] = pair(SUBTRACT, l, r); break;
    default: nodes[i] = pair(MULTIPLY, l, r); break;
    }
  }
}

int main(int argc, char **argv) {
  if (argc != 4)
    return 2;
  unsigned long leaves = strtoul(argv[1], NULL, 0);
  unsigned long rounds = strtoul(argv[2], NULL, 0);
  unsigned long seed = strtoul(argv[3], NULL, 0);
  if (leaves == 0)
    return 2;
  unsigned long internal = leaves - 1;
  struct expr *nodes = malloc((internal + leaves) * sizeof *nodes);
  if (nodes == NULL)
    return 1;
  build(nodes, leaves, seed);
  unsigned long sum = 0;
  for (unsigned long round = 0; round < rounds; round++) {
    nodes[internal + round % leaves] = number(round);
    sum += eval(&nodes[0]);
  }
  printf("%lu\n", sum);
  free(nodes);
  return 0;
}
