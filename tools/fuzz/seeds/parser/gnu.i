__extension__ typedef long long i64;
typedef char *va_list;
extern int printf(const char *, ...) __attribute__((format(printf, 1, 2)));
int x __asm__("real_x") = 1;
__asm__(".globl marker");
static __inline__ int sq(int v) { return ({ int t = v; t * t; }); }
int g(int n, va_list ap)
{
  int y = sq(n);
  switch (n) { case 1 ... 3: y++; }
  __asm__ volatile ("" : "=r"(y) : "0"(y) : "memory");
  y += __builtin_va_arg(ap, int);
  y += __builtin_offsetof(struct p, i) + __alignof__(int);
  return y;
}
__complex__ double z;
int __thread tls;
int sel = _Generic(1.0, double: 1, default: 0);
struct __attribute__((packed, aligned(4))) p { char c; int i; };
__typeof__(int[3]) arr;
