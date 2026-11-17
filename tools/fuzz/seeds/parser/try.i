# 1 "try.tc"
typedef result(int, int) result_int;
typedef result(double, int) result_double;
struct named { char name[8]; };
typedef result(struct named, int) result_named;
result_int a(void);
result_int b(void);
result_int next(void);
result_int check(int *p);
result_double d(void);
result_named n(void);
void mark(void);
void note(const char *text);
void use(char *name);
int two(int left, int right);
void put(int *out, int at, int value);
result_int expressions(int *p, int c, slice(int) s, int i) {
  int out[4] = { 0 };
  int pos = 0;
  defer note("done");
  int sum = two(try a(), try b());
  put(out, pos++, try next());
  sum += p && try check(p) > 0;
  sum += c ? try a() : (mark(), try b());
  sum += s[i] + try a();
  sum = try (c ? a() : b());
  use((try n()).name);
  float pair[2] = { try d(), try d() };
  float picked = c ? (float[2]){ try d(), try d() }[1] : 0;
  struct { int b : 3; unsigned u : 3; } bits = { try a(), try a() };
  try a();
  return Ok(sum + (int)pair[0] + (int)picked + bits.b + out[0]);
}
