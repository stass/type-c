int printf(const char *, ...);
int sum(int *a, int n)
{
  int total = 0, i;
  for (i = 0; i < n; i++) {
    if (a[i] < 0)
      continue;
    else if (a[i] == 0)
      break;
    total += a[i] << 1 | 1;
  }
  for (int j = n; j > 0; --j) total -= j % 3 ? j : -j;
  while (total > 100) total /= 2;
  do { total ^= ~total & 0xff; } while (!total);
  switch (n) {
  case 0: return 0;
  case 1: { int x = (int)total; return x; }
  default: break;
  }
  goto end;
end:
  ;
  printf("%d\n", total, (char){ 'c' }, (int[]){ 1, 2 }[1]);
  return total > 0 && n || !a ? total : (n, -1);
}
