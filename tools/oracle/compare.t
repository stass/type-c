SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The comparison checks the type typec gives each expression against the
oracle's records of Clang's, joined by their byte ranges. The unit below
has an expression of each outcome: typedef names, a noreturn function,
a variable length array, an array that its initialiser completes and a
function of an old-style definition, which agree once read; a builtin
and a va_list parameter, which typec does not type; an anonymous
structure, a tag and a typedef name of a block and a statement
expression in typeof, which Clang's spellings cannot name at file scope;
a typedef name of a block that hides one of file scope, which reads as
that one and disagrees; a string literal that initialises an array,
which Clang gives the array's type; initialisers that only Clang types
and array lengths that only typec keeps as expressions.
The test runs the Clang that TYPEC_TEST_CLANG names, /usr/bin/clang when
it is unset.

  $ clang=${TYPEC_TEST_CLANG:-/usr/bin/clang}
  $ options="-std=gnu11 --target=x86_64-unknown-linux-gnu"
  $ cat > unit.i <<'EOF'
  > # 1 "unit.c"
  > typedef unsigned long size;
  > struct point { int x, y; };
  > int table[] = { 1, 2 };
  > int old() { return 0; }
  > _Noreturn void stop(void);
  > int f(struct point *p, size n, int c) {
  >   char lengths[sizeof (struct point)];
  >   int vla[n];
  >   struct { int a; } anonymous = { 1 };
  >   struct local { int b; } l = { 2 };
  >   if (__builtin_expect(c, 0))
  >     stop();
  >   return p->x + table[0] + old() + anonymous.a + l.b + vla[0] + lengths[0];
  > }
  > typedef int shadowed;
  > int g(__builtin_va_list list, int a) {
  >   typedef int local;
  >   typedef double shadowed;
  >   local v = a;
  >   shadowed d = 0;
  >   char s[] = "ab";
  >   __typeof__(({ int q = a; q; })) w = 0;
  >   (void)d;
  >   return v + w + s[0] + (list == 0);
  > }
  > EOF
  $ ./oracle.exe "$clang" unit.i unit.records $options
  unit.i: 82 expressions, 0 without a source range

typec's half gives its type for each range, before the conversions of
its context:

  $ ./typec_dump.exe "$clang" unit.i $options
  85	86	rvalue	int
  88	89	rvalue	int
  112	113	rvalue	int
  199	220	rvalue	unsigned long
  233	234	lvalue	unsigned long
  271	272	rvalue	int
  308	309	rvalue	int
  319	335	rvalue	<the builtin '__builtin_expect'>
  319	341	rvalue	<the builtin '__builtin_expect'>
  336	337	lvalue	int
  339	340	rvalue	int
  347	351	rvalue	void (void)
  347	353	rvalue	void
  364	365	lvalue	struct point *
  364	368	lvalue	int
  364	379	rvalue	int
  364	387	rvalue	int
  364	401	rvalue	int
  364	407	rvalue	int
  364	416	rvalue	int
  364	429	rvalue	int
  371	376	lvalue	int[2]
  371	379	lvalue	int
  377	378	rvalue	int
  382	385	rvalue	int ()
  382	387	rvalue	int
  390	399	lvalue	struct <anonymous>
  390	401	lvalue	int
  404	405	lvalue	struct local
  404	407	lvalue	int
  410	413	lvalue	int[*]
  410	416	lvalue	int
  414	415	rvalue	int
  419	426	lvalue	char[<constant>]
  419	429	lvalue	char
  427	428	rvalue	int
  554	555	lvalue	int
  572	573	rvalue	int
  588	592	lvalue	char[3]
  607	626	rvalue	int
  618	619	lvalue	int
  621	622	lvalue	int
  632	633	rvalue	int
  637	644	rvalue	void
  643	644	lvalue	double
  655	656	lvalue	int
  655	660	rvalue	int
  655	667	rvalue	int
  655	681	rvalue	int
  659	660	lvalue	int
  663	664	lvalue	char[3]
  663	667	lvalue	char
  665	666	rvalue	int
  670	681	rvalue	int
  671	675	lvalue	<a va_list parameter>
  671	680	rvalue	int
  679	680	rvalue	int
  $ : > none.allow
  $ ./compare.exe "$clang" unit.i unit.records none.allow $options
  unit.i: 43 agree, 1 disagree, 0 allowed, 2 unknown, 6 unresolved, 3 Clang-only, 5 typec-only
  unresolved 1: a builtin function, which has no C type in Clang
  unresolved 1: a spelling with a control byte such as a line break, a backslash, a brace, a semicolon or unbalanced brackets, which is not one type name on one line
  unresolved 1: a string literal that initialises an array, which Clang gives the array's type
  unresolved 1: an anonymous structure, union or enumeration, which Clang names by the location of its keyword
  unresolved 1: it names a tag that no file-scope declaration declares
  unresolved 1: typec refuses it at file scope: 'local' is not declared (C11 6.5.1p2)
  disagreements:
    unit.c:23: [643,644) DeclRefExpr: Clang lvalue 'shadowed', typec lvalue 'double'
  unknown:
    unit.c:11: [319,341) CallExpr: Clang rvalue 'long', typec rvalue '<the builtin '__builtin_expect'>'
    unit.c:24: [671,675) DeclRefExpr: Clang lvalue 'struct __va_list_tag *', typec lvalue '<a va_list parameter>'
  Clang only:
    unit.c:3: [83,91) InitListExpr: Clang rvalue 'int[2]'
    unit.c:9: [269,274) InitListExpr: Clang rvalue 'struct (unnamed struct at unit.c:9:3)'
    unit.c:10: [306,311) InitListExpr: Clang rvalue 'struct local'
  typec only:
    unit.c:7: [199,220) typec rvalue 'unsigned long'
    unit.c:8: [233,234) typec lvalue 'unsigned long'
    unit.c:22: [607,626) typec rvalue 'int'
    unit.c:22: [618,619) typec lvalue 'int'
    unit.c:22: [621,622) typec lvalue 'int'
  unresolved:
    unit.c:11: [319,335) DeclRefExpr: '<builtin fn type>': a builtin function, which has no C type in Clang
    unit.c:13: [390,399) DeclRefExpr: 'struct (unnamed struct at unit.c:9:3)': an anonymous structure, union or enumeration, which Clang names by the location of its keyword
    unit.c:13: [404,405) DeclRefExpr: 'struct local': it names a tag that no file-scope declaration declares
    unit.c:21: [588,592) StringLiteral: 'char[3]': a string literal that initialises an array, which Clang gives the array's type
    unit.c:24: [655,656) DeclRefExpr: 'local': typec refuses it at file scope: 'local' is not declared (C11 6.5.1p2)
    unit.c:24: [659,660) DeclRefExpr: 'typeof (({\x0a    int q = a;\x0a    q;\x0a}))': a spelling with a control byte such as a line break, a backslash, a brace, a semicolon or unbalanced brackets, which is not one type name on one line
  [1]

A disagreement outside the allow-list fails the comparison. An entry is
a pattern over the printed line, in which * matches any run of bytes,
and a reason; the allowed disagreements are counted apart.

  $ echo '# Reviewed.' > shadow.allow
  $ printf '%s\t%s\n' "*: Clang lvalue 'shadowed', typec lvalue 'double'" \
  >   'a typedef name of a block reads as the file-scope one' >> shadow.allow
  $ ./compare.exe --show 0 "$clang" unit.i unit.records shadow.allow $options
  unit.i: 43 agree, 0 disagree, 1 allowed, 2 unknown, 6 unresolved, 3 Clang-only, 5 typec-only
  unresolved 1: a builtin function, which has no C type in Clang
  unresolved 1: a spelling with a control byte such as a line break, a backslash, a brace, a semicolon or unbalanced brackets, which is not one type name on one line
  unresolved 1: a string literal that initialises an array, which Clang gives the array's type
  unresolved 1: an anonymous structure, union or enumeration, which Clang names by the location of its keyword
  unresolved 1: it names a tag that no file-scope declaration declares
  unresolved 1: typec refuses it at file scope: 'local' is not declared (C11 6.5.1p2)
  $ printf '*\tall of them\n' > all.allow
  $ ./compare.exe --show 0 "$clang" unit.i unit.records all.allow $options
  unit.i: 43 agree, 0 disagree, 1 allowed, 2 unknown, 6 unresolved, 3 Clang-only, 5 typec-only
  unresolved 1: a builtin function, which has no C type in Clang
  unresolved 1: a spelling with a control byte such as a line break, a backslash, a brace, a semicolon or unbalanced brackets, which is not one type name on one line
  unresolved 1: a string literal that initialises an array, which Clang gives the array's type
  unresolved 1: an anonymous structure, union or enumeration, which Clang names by the location of its keyword
  unresolved 1: it names a tag that no file-scope declaration declares
  unresolved 1: typec refuses it at file scope: 'local' is not declared (C11 6.5.1p2)

An allow-list entry needs a reason, and a record line its seven fields:

  $ printf '*\t\n' > bad.allow
  $ ./compare.exe "$clang" unit.i unit.records bad.allow $options
  compare: bad.allow: line 1: no pattern or no reason
  [2]
  $ head -n 2 unit.records > bad.records
  $ printf '1\t2\tDeclRefExpr\n' >> bad.records
  $ ./compare.exe "$clang" unit.i bad.records none.allow $options
  compare: bad.records:3: not seven fields
  [2]
  $ printf '1\t2\tDeclRefExpr\t-\tlvalue\tint\\x\t-\n' > bad.records
  $ ./compare.exe "$clang" unit.i bad.records none.allow $options
  compare: bad.records:1: a backslash that starts no escape
  [2]
