SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A function body whose `{` is C text of a system header is passed through
unread, as it is written for its own compiler (design 13.3); every
token from its `{` to its `}` must then be C text of a system header.
A body whose `{` is any other text is read.

Type-C text found through -isystem is read, typed and lowered as any
other Type-C text: the match of an inline function there is lowered.

  $ cat > interface.tc <<'EOF'
  > # 1 "interface.tc"
  > # 1 "system/values.tci" 1 3
  > type e = | A | B(int i);
  > static inline int value(e v) {
  >   match (v) { case B(i): return i; default: return 0; }
  > }
  > # 2 "interface.tc" 2
  > int main(void) { return value(B(1)); }
  > EOF
  $ ./golden.exe interface.tc | grep -c 'match (v)'
  0
  [1]
  $ ./golden.exe interface.tc | grep -c 'switch (__tc_match->tag)'
  1

A Type-C interface that a system header includes inside a body is
refused at its first token.

  $ cat > included.tc <<'EOF'
  > # 1 "included.tc"
  > # 1 "system.h" 1 3
  > static int g(void) {
  > # 1 "inner.tci" 1
  >   type x = | a;
  > # 3 "system.h" 2
  >   return 0; }
  > # 2 "included.tc" 2
  > EOF
  $ ./golden.exe included.tc
  inner.tci:1: a function body that C text of a system header opens is passed through unread, so it holds C text of system headers only (design 13.3) [TC0032]
  [1]

C text of a file that is no system header is refused there too, as the
reason for passing a body through holds for the system header alone.

  $ cat > user.tc <<'EOF'
  > # 1 "user.tc"
  > # 1 "system.h" 1 3
  > static int g(void) {
  > # 1 "user.h" 1
  >   int y = 0;
  > # 3 "system.h" 2
  >   return 0; }
  > # 2 "user.tc" 2
  > EOF
  $ ./golden.exe user.tc
  user.h:1: a function body that C text of a system header opens is passed through unread, so it holds C text of system headers only (design 13.3) [TC0032]
  [1]

A body that the user's text opens is read, each token as the text it
is, whatever an include puts inside it: the match is lowered and the C
text of the system header inside it is kept. A macro of a system header
that opens a body gives such a body too, as the tokens of an expansion
belong to the file where it stands (design 2.4).

  $ cat > filled.tc <<'EOF'
  > # 1 "filled.tc"
  > type e = | A | B(int i);
  > static int value(e v) {
  > # 1 "system.h" 1 3
  >   int base = 0;
  > # 4 "filled.tc" 2
  >   match (v) { case B(i): return base + i; default: return base; }
  > }
  > EOF
  $ ./golden.exe filled.tc | grep -c 'match (v)'
  0
  [1]
  $ ./golden.exe filled.tc | grep 'int base'
    int base = 0;
