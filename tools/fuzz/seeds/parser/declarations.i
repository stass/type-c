typedef unsigned long size_t;
typedef struct node { struct node *next; int value : 4; unsigned : 0; } node;
enum colour { red, green = 4, blue = green * 2 + 1 };
union u { int i; float f; struct { char a, b; }; };
static const volatile int table[2][3] = { { 1, 2, 3 }, [1] = { [2] = 6 } };
extern int (*handlers[4])(int, char *restrict);
_Thread_local _Alignas(16) char buffer[sizeof(node) + _Alignof(long)];
_Atomic(int) counter;
_Static_assert(sizeof(int) >= 2, "int is too small");
int f(int, ...), g(void);
inline static int h(int a[static 3], const int n) { return a[n - 1]; }
int old(a, b) int a; char *b; { return a + *b; }
long double ld = 1.5L; _Bool flag = 1; char *s = "a" "b";
size_t n = sizeof table / sizeof table[0];
