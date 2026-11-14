SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

The oracle runs Clang's JSON AST dump on a preprocessed file and writes a
record of each expression in it. The unit below has a header included
through line markers, so that the presumed locations differ from the
offsets in the file, which key the records. Each record is shown with
the text its range covers. The test runs the Clang that
TYPEC_TEST_CLANG names, /usr/bin/clang when it is unset.

  $ clang=${TYPEC_TEST_CLANG:-/usr/bin/clang}
  $ cat > unit.i <<'EOF'
  > # 1 "unit.c"
  > # 1 "point.h" 1
  > typedef struct { int x, y; } point;
  > static int getx(point *p) { return p->x; }
  > # 2 "unit.c" 2
  > int f(point *p, char c) {
  >   point q = { c };
  >   return getx(&q) + p->y + (int)sizeof "ab";
  > }
  > EOF
  $ ./oracle.exe "$clang" unit.i unit.records -std=gnu11 \
  >   --target=x86_64-unknown-linux-gnu
  unit.i: 22 expressions, 1 without a source range
  $ tab=$(printf '\t')
  $ while IFS=$tab read -r first limit rest; do
  >   text=$(tail -c +$((first + 1)) unit.i | head -c $((limit - first)))
  >   echo "$first $limit $rest" | tr "$tab" ' '
  >   echo "  [$text]"
  > done < unit.records
  100 104 ImplicitCastExpr LValueToRValue prvalue int -
    [p->x]
  100 104 MemberExpr - lvalue int -
    [p->x]
  100 101 ImplicitCastExpr LValueToRValue prvalue point * -
    [p]
  100 101 DeclRefExpr - lvalue point * -
    [p]
  161 166 InitListExpr - prvalue point -
    [{ c }]
  163 164 ImplicitCastExpr IntegralCast prvalue int -
    [c]
  163 164 ImplicitCastExpr LValueToRValue prvalue char -
    [c]
  163 164 DeclRefExpr - lvalue char -
    [c]
  177 211 BinaryOperator - prvalue int -
    [getx(&q) + p->y + (int)sizeof "ab"]
  177 192 BinaryOperator - prvalue int -
    [getx(&q) + p->y]
  177 185 CallExpr - prvalue int -
    [getx(&q)]
  177 181 ImplicitCastExpr FunctionToPointerDecay prvalue int (*)(point *) -
    [getx]
  177 181 DeclRefExpr - prvalue int (point *) -
    [getx]
  182 184 UnaryOperator - prvalue point * -
    [&q]
  183 184 DeclRefExpr - lvalue point -
    [q]
  188 192 ImplicitCastExpr LValueToRValue prvalue int -
    [p->y]
  188 192 MemberExpr - lvalue int -
    [p->y]
  188 189 ImplicitCastExpr LValueToRValue prvalue point * -
    [p]
  188 189 DeclRefExpr - lvalue point * -
    [p]
  195 211 CStyleCastExpr IntegralCast prvalue int -
    [(int)sizeof "ab"]
  200 211 UnaryExprOrTypeTraitExpr - prvalue unsigned long -
    [sizeof "ab"]
  207 211 StringLiteral - lvalue char[3] -
    ["ab"]

A record that holds a control byte, here the tab in the name of the
header that declares an anonymous structure, escapes it.

  $ printf '# 1 "a\\tb.h"\nstruct { int i; } s;\n' > tab.i
  $ printf 'int g(void) { return s.i; }\n' >> tab.i
  $ ./oracle.exe "$clang" tab.i tab.records
  tab.i: 3 expressions, 0 without a source range
  $ grep DeclRefExpr tab.records | cut -f 6
  struct (unnamed struct at a\x09b.h:1:1)

When Clang fails, the oracle says so after Clang's diagnostics, which
are left out here, and leaves no output.

  $ printf 'int h(void) { return x; }\n' > bad.i
  $ ./oracle.exe "$clang" bad.i bad.records 2>&1 | tail -n 1 |
  >   sed "s|$clang|CLANG|"
  oracle: bad.i: CLANG exited with 1
  $ ls | grep -c '^bad\.records'
  0
  [1]

A stand-in for Clang prints the JSON in ast.json, which the oracle
refuses when it holds a range outside the input, a location in another
file or in a macro expansion, or is not JSON.

  $ cat > fake-clang <<'EOF'
  > #!/bin/sh
  > cat ast.json
  > EOF
  $ chmod +x fake-clang
  $ fake() {
  >   ./oracle.exe ./fake-clang unit.i fake.records
  > }
  $ refuse() {
  >   printf '%s' "$1" > ast.json
  >   fake
  > }
  $ refuse '{"inner": [{"range": {"begin": {"offset": 0, "file": "unit.i",
  >   "tokLen": 1}, "end": {"offset": 9999, "tokLen": 1}},
  >   "kind": "IntegerLiteral", "type": {"qualType": "int"},
  >   "valueCategory": "prvalue"}]}'
  oracle: unit.i: a range 0-10000 outside the input
  [1]

A refusal early in a long output still names its reason, not the
broken pipe Clang would die of.

  $ { printf '{"inner": [{"loc": {"offset": 0, "file": "other.i",'
  >   printf ' "tokLen": 1}}'
  >   awk 'BEGIN { for (i = 0; i < 100000; i++) printf ", {}" }'
  >   printf ']}'; } > ast.json
  $ fake
  oracle: unit.i: a location in "other.i", not in the input
  [1]
  $ refuse '{"inner": [{"loc": {"offset": 0, "file": "other.i", "tokLen": 1}}]}'
  oracle: unit.i: a location in "other.i", not in the input
  [1]
  $ refuse '{"inner": [{"loc": {"spellingLoc": {}, "expansionLoc": {}}}]}'
  oracle: unit.i: a location in a macro expansion
  [1]
  $ refuse '{"inner": ['
  oracle: unit.i: Line 1, bytes 10-11: Unexpected end of input
  [1]
