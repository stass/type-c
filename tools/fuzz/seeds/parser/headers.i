# 1 "main.c"
# 1 "/usr/include/sys.h" 1 3 4
static inline int __sys(int a) { return a + (a ? : 0); }
typedef int __sys_t;
# 2 "main.c" 2
#pragma once
__sys_t v = 1;
int main(void)
{
#pragma GCC diagnostic push
  return __sys(v);
}
#pragma typec unsafe
