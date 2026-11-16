/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* Declarations whose types and values typec computes; declaration_probe
   asserts each one after the text. */

typedef int T;
typedef T *TP;
typedef TP TA[3];
typedef const TA CTA;
TA ta;
CTA cta;

int a[];
int a[2 * 3];
static int s;
extern int s;
int f();
int f(int, char *);
int g(int n, int m[n], int (*p)[n], const int q[const 4]);
void (*signal(int, void (*)(int)))(int);
char *(*fp)(int, ...);
const volatile int cv;
int *const cp;
_Atomic int at;
_Atomic(long) atl;
_Alignas(16) char aligned;
_Thread_local int tl;
static int h(void);
int h(void);
inline int k(void);
_Noreturn void die(void);
int defined(int x) { return x; }
static void later(void);
void later(void) {}
long double ld;
_Complex double cd;
unsigned short us;
signed char sc;

struct node {
  struct node *next;
  int value : 3;
  unsigned flag : 1;
  union {
    int i;
    float x;
  };
};
struct node node;
union u { int i; float f; } un;
struct forward;
struct forward *forward_pointer;
struct forward { int filled; };

enum small { S0, S1, S2 = 10, S3 };
enum negative { N0 = -5, N1 };
enum big { B0 = 0x80000000 };
enum mixed { M0 = -1, M1 = 0x80000000 };
enum wide { W0 = 0xffffffffffffffff };
enum after_max { X0 = 2147483647, X1, X2 = X1 - X1 - 1 < 0 };
enum unsigned_after { U0 = 4294967295u, U1, U2 = U1 - U1 - 1 < 0 };
/* An enumeration among members or in an array length declares its
   enumerators at file scope. */
struct enum_member { enum { D0 = 7, D1 } member; };
int enum_length[sizeof (enum { L0 = -3, L1 = 0x80000000 })];
typedef enum small small_type;
typedef enum negative negative_type;
typedef enum big big_type;
typedef enum mixed mixed_type;
typedef enum wide wide_type;
typedef enum after_max after_max_type;
typedef enum unsigned_after unsigned_after_type;

enum values {
  V_SIZES = sizeof(int) + sizeof(long) * 2 + sizeof(void *) + sizeof(short),
  V_FLOATS = sizeof(float) + sizeof(double) * 3 + sizeof(long double),
  V_COMPLEX = sizeof(_Complex float) + sizeof(enum negative),
  V_CHAR = 'a',
  V_MULTI = 'ab',
  V_MULTI_HIGH = '\xff\xfe',
  V_LONG_MULTI = 'abcde',
  V_ESCAPE = '\377',
  V_ESCAPES = '\n' + '\0' + '\'' + '\a' + '\v' + '\?',
  V_HEX = '\x7f',
  V_WIDE = L'\x41',
  V_WIDE_HIGH = L'\xffffffff',
  V_UCN = L'\u00e9',
  V_CHAR16 = u'\xffff',
  V_CHAR32 = U'\U0001F600',
  V_SHIFT = 1 << 31,
  V_NEGATIVE_SHIFT = -1 >> 1,
  V_DIVIDE = -7 / 2,
  V_REMAINDER = -7 % 2,
  V_UNSIGNED_CHAR = (unsigned char)300,
  V_SIGNED_CHAR = (signed char)200,
  V_BOOL = (_Bool)256,
  V_UNSIGNED_COMPARE = -1 < 0u,
  V_LONG_COMPARE = -1 < 0l,
  V_CONDITIONAL = 1 ? 2 : 1 / 0,
  V_LOGICAL = 0 && 1 / 0,
  V_SIZE_COMPARE = sizeof(int) - 5 > 0,
  V_TRUNCATE = (int)4294967296ll,
  V_BASES = 017 + 0b101 + 0x1F,
  V_WRAP = (int)(0xffffffffffffffffull >> 33),
  V_UNSIGNED_WRAP = 0u - 1u == 4294967295u,
  V_TYPEDEF = (T)7 + (small_type)2
};

char sized[sizeof(long long) * 3];
int by_enumerator[S3];
int by_size[sizeof(struct node)];
_Static_assert(sizeof(char) == 1, "char");
_Static_assert(sizeof(struct node) > 0, "passes through");

/* The builtin typedef names. The backend adjusts a va_list parameter to
   a pointer where the target's va_list is an array; typec does not, and
   the function types still agree. */
typedef __builtin_va_list va_list;
va_list ap;
va_list aps[2];
struct with_va_list { va_list ap; } wva;
int vf(const char *, va_list);
int vf(const char *, __builtin_va_list);
#ifdef __SIZEOF_INT128__
__int128_t i128;
__uint128_t u128;
#endif
