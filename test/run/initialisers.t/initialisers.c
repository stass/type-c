/* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> */

/* Arrays of unknown size that initialisers complete, and compound
   literals; expression_probe asserts the type of each expression
   statement of a body, and the static assertions check the sizes. */

#define LENGTH(a, n) _Static_assert(sizeof (a) == (n) * sizeof (a)[0], #a);

struct pair { int a, b; };
union number { int i; char c[8]; };
struct nested { int a; union { int b; float c; }; int d; };
struct tail { int a[3]; int b; };
struct named { char name[8]; int value; };
struct bits { int : 3; int x; int : 0; int y; };

int plain[] = { 1, 2, 3 };
LENGTH(plain, 3)
int empty[] = {};
_Static_assert(sizeof empty == 0, "empty");
char text[] = "abc";
LENGTH(text, 4)
char braced_text[] = { "abc" };
LENGTH(braced_text, 4)
char parenthesized[] = ("ab");
LENGTH(parenthesized, 3)
__WCHAR_TYPE__ wide[] = L"ab";
LENGTH(wide, 3)
__CHAR16_TYPE__ utf16[] = u"a\U0001F600";
LENGTH(utf16, 4)
__CHAR32_TYPE__ utf32[] = U"a\U0001F600";
LENGTH(utf32, 3)
char words[][4] = { "ab", "cd", "e" };
LENGTH(words, 3)
int designated[] = { [5] = 1, 2, [1] = 3 };
LENGTH(designated, 7)
int ranged[] = { [2 ... 4] = 1 };
LENGTH(ranged, 5)
int matrix[][2] = { 1, 2, 3 };
LENGTH(matrix, 2)
int mixed[][2] = { { 1 }, 2, 3, { 4 } };
LENGTH(mixed, 3)
struct pair pairs[] = { 1, 2, 3 };
LENGTH(pairs, 2)
struct pair braced_pairs[] = { { 1 }, { .b = 2 }, 3 };
LENGTH(braced_pairs, 3)
union number numbers[] = { 1, 2 };
LENGTH(numbers, 2)
struct nested anonymous[] = { 1, 2, 3, 4 };
LENGTH(anonymous, 2)
struct tail tails[] = { [0].a[1] = 5, 6, 7, 8 };
LENGTH(tails, 2)
struct named names[] = { "abc", 1, "def", 2, { "g" } };
LENGTH(names, 3)
struct bits bits[] = { 1, 2, 3 };
LENGTH(bits, 2)
int *pointers[] = { 0, (int *)0, plain };
LENGTH(pointers, 3)
extern int completed[];
int completed[] = { 1, 2 };
LENGTH(completed, 2)
typedef int open[];
open first = { 1 }, second = { 1, 2, 3 };
LENGTH(first, 1)
LENGTH(second, 3)
int from_literal[] = (int[]){ 1, 2 };
LENGTH(from_literal, 2)
int *literal_pointer = (int[]){ 1, 2, 3 };
const char *strings[] = { "a", "b" };
LENGTH(strings, 2)

/* GCC finds the type of empty compatible with no int[0], so only its size
   is asserted. */
void file_scope(void)
{
	plain; text; braced_text; parenthesized; wide; utf16; utf32;
	words; designated; ranged; matrix; mixed; pairs; braced_pairs;
	numbers; anonymous; tails; names; bits; pointers; completed;
	first; second; from_literal; strings;
}

void block_scope(int n)
{
	int local[] = { n, n + 1 };
	LENGTH(local, 2)
	static int kept[] = { [9] = 1 };
	LENGTH(kept, 10)
	struct pair copies[] = { pairs[0], pairs[1], { n } };
	LENGTH(copies, 3)
	char name[] = "name";
	LENGTH(name, 5)

	local; kept; copies; name;
	(int[]){ 1, 2, 3 };
	(struct pair[]){ 1, 2, 3 };
	(char[]){ "abc" };
	(int[3]){ n };
	(struct pair){ n, n };
	(int){ n };
	(const int[]){ 1 };
}
