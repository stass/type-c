# 1 "expressions.c"
int a[10], *p = a + 1, **pp = &p;
struct s { int m; struct s *n; } v, *q = &v;
int f(int);
void e(void)
{
  int i = 0;
  i = a[i++] + p[-1] * -*p / +**pp % (i ? 1 : 2);
  i <<= 2; i >>= 1; i &= 7; i |= 8; i ^= 3; i -= 1; i *= 2; i /= 1; i %= 5;
  q->n->m = v.m = (i < 3) <= (i > 4) >= (i != 5) == 1;
  i = sizeof(struct s) + sizeof i + f(f(i)) + (unsigned char)~i;
  p = &a[0] - (long)&*p + 0x1fUL + 017 + (int)1e3 + (int).5f + 'a' + u'b' + U'c';
  (void)(i, i);
}
