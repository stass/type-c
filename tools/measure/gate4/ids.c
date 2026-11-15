/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* The hand-written twin of ids.tc: the ids are a typedef of unsigned. */

#include <stdio.h>
#include <stdlib.h>

typedef unsigned node_id;

struct graph {
  node_id *next;
  node_id start;
};

static unsigned long next_random(unsigned long *state) {
  *state = *state * 6364136223846793005UL + 1442695040888963407UL;
  return *state >> 33;
}

__attribute__((noinline)) static node_id follow(const struct graph *g,
                                                node_id at) {
  return g->next[at];
}

static void build(struct graph *g, unsigned count, unsigned long seed) {
  for (unsigned i = 0; i < count; i++)
    g->next[i] = i;
  for (unsigned i = count - 1; i > 0; i--) {
    unsigned j = next_random(&seed) % i;
    node_id swap = g->next[i];
    g->next[i] = g->next[j];
    g->next[j] = swap;
  }
  g->start = g->next[0];
}

int main(int argc, char **argv) {
  if (argc != 4)
    return 2;
  unsigned count = strtoul(argv[1], NULL, 0);
  unsigned long steps = strtoul(argv[2], NULL, 0);
  unsigned long seed = strtoul(argv[3], NULL, 0);
  if (count == 0)
    return 2;
  struct graph g = { malloc(count * sizeof *g.next), 0 };
  if (g.next == NULL)
    return 1;
  build(&g, count, seed);
  node_id at = g.start;
  unsigned long laps = 0;
  for (unsigned long step = 0; step < steps; step++) {
    at = follow(&g, at);
    if (at == g.start)
      laps++;
  }
  printf("%lu %u\n", laps, at);
  free(g.next);
  return 0;
}
