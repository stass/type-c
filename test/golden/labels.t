SPDX-License-Identifier: BSD-2-Clause
Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com>

A label is defined once in its function, or in the block of a GNU local
label (C11 6.8.1p3), and a goto names a label defined there (6.8.6.1p1).
Both backends refuse the breaches under every option, so typec refuses
them in C text too, with the clause and no code (design 13.6).

  $ cat > twice.tc <<'EOF'
  > int f(int n) {
  > again:
  >   if (n--)
  >     goto again;
  > again:
  >   return n;
  > }
  > EOF
  $ ./golden.exe twice.tc
  twice.tc:5: a second definition of a label in its scope (C11 6.8.1p3)
  [1]

  $ cat > missing.tc <<'EOF'
  > int f(int n) {
  >   {
  >     __label__ out;
  >     if (n)
  >       goto out;
  >   }
  > out:
  >   return n;
  > }
  > EOF
  $ ./golden.exe missing.tc
  missing.tc:5: a goto to a label that is not defined in its scope (C11 6.8.6.1p1)
  [1]

The first definition in source order stands, though the condition of a
loop is read after its body.

  $ cat > order.tc <<'EOF'
  > int f(int n) {
  >   while (({ again: ; n--; }))
  >     {
  >     again:
  >       ;
  >     }
  >   return n;
  > }
  > EOF
  $ ./golden.exe order.tc
  order.tc:4: a second definition of a label in its scope (C11 6.8.1p3)
  [1]

GNU C adds three rules that both backends enforce under every option:
the address of a label is taken in a function body, a block declares a
local label once, and a goto does not jump into a statement expression
from outside it. typec refuses them with the GCC manual's section.

  $ cat > address.tc <<'EOF'
  > static void *resume = &&again;
  > EOF
  $ ./golden.exe address.tc
  address.tc:1: the address of a label outside a function body (GCC manual, "Labels as Values")
  [1]

  $ cat > local.tc <<'EOF'
  > int f(int n) {
  >   {
  >     __label__ out, out;
  >     if (n)
  >       goto out;
  >   out:
  >     ;
  >   }
  >   return n;
  > }
  > EOF
  $ ./golden.exe local.tc
  local.tc:3: a local label declared twice in its block (GCC manual, "Local Labels")
  [1]

  $ cat > into.tc <<'EOF'
  > int f(int n) {
  >   if (n)
  >     goto inside;
  >   return ({
  >   inside:
  >     n + 1;
  >   });
  > }
  > EOF
  $ ./golden.exe into.tc
  into.tc:3: a goto into a statement expression from outside it (GCC manual, "Statement Exprs")
  [1]
