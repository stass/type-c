# 1 "defer_slices.tc"
void g(int);
int sum(slice(int) s) {
  int total = 0;
  for (unsigned long i = 0; i < s.len; i++) {
    defer g((int)i);
    if (s[i] < 0)
      break;
    total += s[i];
  }
  return total;
}
int f(int c) {
  int rows[3][4];
  defer {
    g(0);
    g(1);
  }
  slice(int) s = slice_from_array(rows[1]);
  if (c)
    return sum(slice_sub(s, 1, 3));
  return (int)slice_from_array(rows[2]).len;
}
