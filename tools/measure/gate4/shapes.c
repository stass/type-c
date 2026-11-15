/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* The hand-written twin of shapes.tc: a tag, a union and a switch. */

#include <stdio.h>
#include <stdlib.h>

enum kind { SQUARE, RECTANGLE, TRIANGLE, BOX };
struct shape {
  enum kind kind;
  union {
    struct { unsigned side; } square;
    struct { unsigned width, height; } rectangle;
    struct { unsigned base, height; } triangle;
    struct { unsigned width, height, depth; } box;
  } u;
};

static unsigned long next_random(unsigned long *state) {
  *state = *state * 6364136223846793005UL + 1442695040888963407UL;
  return *state >> 33;
}

static struct shape random_shape(unsigned long *seed) {
  unsigned a = next_random(seed) % 1000, b = next_random(seed) % 1000;
  switch (next_random(seed) % 4) {
  case 0:
    return (struct shape){ SQUARE, { .square = { a } } };
  case 1:
    return (struct shape){ RECTANGLE, { .rectangle = { a, b } } };
  case 2:
    return (struct shape){ TRIANGLE, { .triangle = { a, b } } };
  default:
    return (struct shape){ BOX, { .box = { a, b, a ^ b } } };
  }
}

int main(int argc, char **argv) {
  if (argc != 4)
    return 2;
  unsigned long count = strtoul(argv[1], NULL, 0);
  unsigned long rounds = strtoul(argv[2], NULL, 0);
  unsigned long seed = strtoul(argv[3], NULL, 0);
  if (count == 0)
    return 2;
  struct shape *shapes = malloc(count * sizeof *shapes);
  if (shapes == NULL)
    return 1;
  for (unsigned long i = 0; i < count; i++)
    shapes[i] = random_shape(&seed);
  unsigned long total = 0;
  for (unsigned long round = 0; round < rounds; round++) {
    shapes[round % count] =
        (struct shape){ SQUARE, { .square = { round % 1000 } } };
    for (unsigned long i = 0; i < count; i++) {
      const struct shape *s = &shapes[i];
      switch (s->kind) {
      case SQUARE:
        total += (unsigned long)s->u.square.side * s->u.square.side;
        break;
      case RECTANGLE:
        total += (unsigned long)s->u.rectangle.width * s->u.rectangle.height;
        break;
      case TRIANGLE:
        total += (unsigned long)s->u.triangle.base * s->u.triangle.height / 2;
        break;
      case BOX:
        total += (unsigned long)s->u.box.width * s->u.box.height *
                 s->u.box.depth;
        break;
      }
    }
  }
  printf("%lu\n", total);
  free(shapes);
  return 0;
}
